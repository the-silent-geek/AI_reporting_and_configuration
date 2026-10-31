"""PostgreSQL access, as <app>_app (the same per-product login the API uses, D2).

That role may SELECT ingestion_batch but not change it (status moves only through
the API's sp_update_batch_status), and may INSERT raw_record / mapping_version /
validation_issue. So the worker writes results here and reports status over RabbitMQ.

Idempotency: records, the AI mapping proposal and extraction issues are written in
ONE transaction, under a per-batch advisory lock, and only if the batch has no
raw_record rows yet. A redelivered job therefore finds the earlier result and
writes nothing; two workers racing on one batch serialize on the lock.
"""
import json
import logging
from dataclasses import dataclass
from typing import Protocol
from uuid import UUID

import psycopg
from psycopg_pool import ConnectionPool

from .config import PRODUCTS, Settings
from .errors import FinalError, RetryableError
from .mapping import MappingResult
from .records import CandidateRecord

log = logging.getLogger(__name__)


@dataclass(frozen=True)
class Batch:
    batch_id: UUID
    status: str
    file_type: str
    file_name: str
    storage_uri: str
    sha256: str


@dataclass(frozen=True)
class Saved:
    records: int
    needs_review: int
    mappings: int
    already_saved: bool = False


class Repository(Protocol):
    def load_batch(self, app: str, batch_id: UUID) -> Batch | None: ...
    def existing_result(self, app: str, batch_id: UUID) -> Saved | None: ...
    def save(self, app: str, batch_id: UUID, records: list[CandidateRecord], mapping: MappingResult) -> Saved: ...


def _json(value) -> str:
    return json.dumps(value, ensure_ascii=False, default=str)


class PgRepository:
    def __init__(self, settings: Settings):
        self.pools = {app: ConnectionPool(settings.dsn(app), min_size=1, max_size=max(2, settings.concurrency),
                                          kwargs={"autocommit": True}, name=f"worker-{app}", open=True)
                      for app in PRODUCTS}

    def close(self) -> None:
        for p in self.pools.values():
            p.close()

    def _connection(self, app: str):
        return self.pools[app].connection()

    # ------------------------------------------------------------------ reads ----

    def load_batch(self, app: str, batch_id: UUID) -> Batch | None:
        with _db_errors(), self._connection(app) as conn:
            row = conn.execute(f"SELECT batch_id, status, file_type, file_name, storage_uri, sha256 "
                               f"FROM {app}.ingestion_batch WHERE batch_id = %s", (batch_id,)).fetchone()
        return Batch(*row) if row else None

    def existing_result(self, app: str, batch_id: UUID) -> Saved | None:
        with _db_errors(), self._connection(app) as conn:
            return self._existing(conn, app, batch_id)

    @staticmethod
    def _existing(conn, app: str, batch_id: UUID) -> Saved | None:
        total, review = conn.execute(
            f"SELECT count(*), count(*) FILTER (WHERE state = 'NEEDS_REVIEW') "
            f"FROM {app}.raw_record WHERE batch_id = %s", (batch_id,)).fetchone()
        if not total:
            return None
        row = conn.execute(f"SELECT jsonb_array_length(mappings) FROM {app}.mapping_version "
                           f"WHERE batch_id = %s AND created_by IS NULL ORDER BY version LIMIT 1",
                           (batch_id,)).fetchone()
        return Saved(total, review, row[0] if row else 0, already_saved=True)

    # ----------------------------------------------------------------- writes ----

    def save(self, app: str, batch_id: UUID, records: list[CandidateRecord], mapping: MappingResult) -> Saved:
        with _db_errors(), self._connection(app) as conn, conn.transaction():
            conn.execute("SELECT pg_advisory_xact_lock(hashtextextended(%s, 0))", (f"ai-worker:{app}:{batch_id}",))
            if done := self._existing(conn, app, batch_id):
                log.info("batch %s already has results; nothing written", batch_id)
                return done

            with conn.cursor() as cur:
                with cur.copy(f"COPY {app}.raw_record (batch_id, record_no, target_entity, source_location, "
                              f"raw_fields, extraction_method, confidence, state) FROM STDIN") as cp:
                    for no, r in enumerate(records, start=1):
                        cp.write_row((batch_id, no, mapping.entity, _json(r.source_location), _json(r.raw_fields),
                                      r.extraction_method,
                                      None if r.confidence is None else round(r.confidence, 4), r.state))

                with cur.copy(f"COPY {app}.validation_issue (batch_id, record_no, field, rule_code, severity, "
                              f"message, original_value) FROM STDIN") as cp:
                    for no, r in enumerate(records, start=1):
                        for i in r.issues:
                            cp.write_row((batch_id, no, i.field, i.rule_code, i.severity, i.message, i.original_value))

                # created_by NULL = proposed by the AI worker (see mapping_version)
                cur.execute(f"INSERT INTO {app}.mapping_version (batch_id, version, mappings) "
                            f"SELECT %s, coalesce(max(version), 0) + 1, %s::jsonb "
                            f"FROM {app}.mapping_version WHERE batch_id = %s",
                            (batch_id, _json(mapping.mappings()), batch_id))

        return Saved(len(records), sum(r.state == "NEEDS_REVIEW" for r in records), len(mapping.suggestions))


class _db_errors:
    """Connection problems are temporary; anything else the DB rejects is final."""

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        if exc_type is None or not issubclass(exc_type, psycopg.Error):
            return False
        # OperationalError covers lost connections and psycopg_pool.PoolTimeout
        if isinstance(exc, (psycopg.OperationalError, psycopg.errors.SerializationFailure,
                            psycopg.errors.DeadlockDetected)):
            log.warning("database unavailable: %s", type(exc).__name__)
            raise RetryableError("DB_UNAVAILABLE", "The database is temporarily unavailable.") from exc
        log.error("database rejected the results: %s (SQLSTATE %s)", type(exc).__name__, getattr(exc, "sqlstate", None))
        raise FinalError("DB_REJECTED", "The extracted results could not be saved.") from exc
