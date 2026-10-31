"""Against a real built DB (db/build.ps1), as erp_app: COPY, grants, idempotency, and
every status the worker emits applied through erp.sp_update_batch_status exactly as
the API would. Skipped when no DB is reachable."""
import dataclasses
import hashlib
import os
import uuid

import psycopg
import pytest
from psycopg.types.numeric import Int2

from ai_worker.config import load
from ai_worker.mapping import MappingService
from ai_worker.parsers import ParserRouter
from ai_worker.pipeline import IngestionPipeline
from ai_worker.repository import PgRepository
from ai_worker.storage import LocalFileStorage, StorageRouter
from fakes import ScriptedOcr

S = load()


def _reachable() -> bool:
    if not (S.role_passwords["erp_app"] and os.getenv("IAM_APP_PASSWORD")):
        return False
    try:
        psycopg.connect(S.dsn("erp"), connect_timeout=2).close()
        return True
    except psycopg.OperationalError:
        return False


pytestmark = pytest.mark.skipif(not _reachable(), reason="no built DB reachable (db/.env)")


class DbPublisher:
    """Does what the API's handle_progress does with a progress message."""

    def __init__(self):
        self.statuses = []

    def progress(self, p):
        with psycopg.connect(S.dsn(p.app), autocommit=True) as conn:
            conn.execute(f"SELECT {p.app}.sp_update_batch_status(%s, %s, %s, %s, %s)",
                         (p.batch_id, p.status, None if p.progress_pct is None else Int2(p.progress_pct),
                          p.message, p.error))
        self.statuses.append(p.status)


@pytest.fixture
def uploaded(tmp_path):
    """A CSV stored and registered like the API's upload endpoint does."""
    content = ("Invoice_No,Supplier,Invoice_Date,Due_Date,Amount,Currency\n"
               f"INV-{uuid.uuid4().hex[:8]},ACME,2026-01-05,2026-02-04,\"10,000.50\",USD\n"
               "INV-B,ACME,2026-01-09,2026-02-08,2500,USD\n"
               "INV-C,Globex\n").encode()
    path = tmp_path / "erp" / f"{hashlib.sha256(content).hexdigest()}.csv"
    path.parent.mkdir()
    path.write_bytes(content)
    iam = S.dsn("erp").replace("user=erp_app", "user=iam_app").replace(
        f"password={S.role_passwords['erp_app']}", f"password={os.environ['IAM_APP_PASSWORD']}")
    with psycopg.connect(iam, autocommit=True) as conn:
        login = conn.execute("SELECT iam.sp_login(%s, %s)", ("associate@studio.local", "Studio#2026")).fetchone()[0]
    with psycopg.connect(S.dsn("erp"), autocommit=True) as conn:
        r = conn.execute("SELECT erp.sp_create_batch(%s, %s, 'CSV', %s, %s, %s, 'text/csv')",
                         (login["user"]["user_id"], "payables.csv", len(content),
                          hashlib.sha256(content).hexdigest(), path.as_uri())).fetchone()[0]
    return uuid.UUID(r["batch_id"]), path


def _counts(batch_id):
    with psycopg.connect(S.dsn("erp")) as conn:
        return conn.execute(
            "SELECT (SELECT count(*) FROM erp.raw_record WHERE batch_id = %(b)s),"
            "       (SELECT count(*) FROM erp.mapping_version WHERE batch_id = %(b)s),"
            "       (SELECT count(*) FROM erp.validation_issue WHERE batch_id = %(b)s),"
            "       (SELECT status FROM erp.ingestion_batch WHERE batch_id = %(b)s)", {"b": batch_id}).fetchone()


def test_pipeline_against_real_schema(tmp_path, uploaded):
    from ai_worker.messages import IngestionRequested
    batch_id, path = uploaded
    settings = dataclasses.replace(S, storage_dir=tmp_path)
    repo = PgRepository(settings)
    try:
        pipeline = IngestionPipeline(repo, StorageRouter({"file": LocalFileStorage(tmp_path)}),
                                     ParserRouter(ScriptedOcr([]), settings), MappingService(None, None, 0.8, 0.03))
        job = IngestionRequested(batch_id=batch_id, app="erp", file_type="CSV", file_name="payables.csv",
                                 storage_uri=path.as_uri(), sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                                 uploaded_by=uuid.uuid4())
        pub = DbPublisher()
        outcome = pipeline.run(job, pub)
        assert outcome.status == "NEEDS_REVIEW" and (outcome.records, outcome.needs_review) == (3, 1)
        assert pub.statuses[0] == "EXTRACTING" and pub.statuses[-1] == "NEEDS_REVIEW"
        assert _counts(batch_id) == (3, 1, 1, "NEEDS_REVIEW")

        with psycopg.connect(S.dsn("erp")) as conn:
            entity, loc, raw, method, state = conn.execute(
                "SELECT target_entity, source_location, raw_fields, extraction_method, state "
                "FROM erp.raw_record WHERE batch_id = %s AND record_no = 1", (batch_id,)).fetchone()
            mappings, created_by, status = conn.execute(
                "SELECT mappings, created_by, status FROM erp.mapping_version WHERE batch_id = %s",
                (batch_id,)).fetchone()
        assert (entity, loc, method, state) == ("invoice", {"row": 2}, "csv", "PENDING")
        assert raw["Amount"] == "10,000.50"
        assert created_by is None and status == "PROPOSED"
        assert {m["source_field"]: m["target_field"] for m in mappings}["Invoice_No"] == "invoice_id"

        # redelivery: nothing new written, no event sent
        pub2 = DbPublisher()
        assert pipeline.run(job, pub2).status is None and pub2.statuses == []
        # even a direct second save (two workers racing) writes nothing
        assert repo.save("erp", batch_id, [], None).already_saved
        assert _counts(batch_id) == (3, 1, 1, "NEEDS_REVIEW")
    finally:
        repo.close()
