"""Mapping review + data quality over HTTP: upload -> (worker stand-in) -> approve
mapping -> fix issues -> commit."""
import json
import uuid

import psycopg

from app.config import settings
from test_api import _progress, _upload, _wait_status


def _worker_stand_in(client, batch_id, rows):
    """What the AI worker does: candidate records + MAPPING_REVIEW."""
    assert _progress(client, batch_id, "EXTRACTING", 50).status_code == 200
    with psycopg.connect(settings.dsn("erp_app"), autocommit=True) as conn:
        with conn.cursor().copy("COPY erp.raw_record (batch_id, record_no, target_entity, source_location, "
                                "raw_fields, extraction_method) FROM STDIN") as cp:
            for no, raw in enumerate(rows, start=1):
                cp.write_row((batch_id, no, "supplier", json.dumps({"row": no + 1}), json.dumps(raw), "csv"))
    assert _progress(client, batch_id, "MAPPING_REVIEW").status_code == 200
    _wait_status(client, batch_id, "MAPPING_REVIEW")


def test_mapping_to_commit(analyst, reviewer):
    tag = uuid.uuid4().hex[:6]
    batch_id = _upload(analyst, name="vendors.csv").json()["batch_id"]
    _worker_stand_in(analyst, batch_id, [
        {"Vendor Code": f"V{tag}-1", "Vendor": "ACME Ltd"},
        {"Vendor Code": f"V{tag}-2", "Vendor": "Globex"},
        {"Vendor Code": f"V{tag}-1", "Vendor": "ACME again"},     # duplicate key
    ])

    queue = analyst.get("/api/apps/erp/review/queue").json()
    assert batch_id in [b["batch_id"] for b in queue["mapping"]]

    m = analyst.get(f"/api/apps/erp/batches/{batch_id}/mapping").json()
    assert m["suggested_entity"] == "supplier"
    assert {f["source_field"] for f in m["fields"]} == {"Vendor Code", "Vendor"}
    assert {c["column"] for c in m["entities"]["supplier"]} == {"supplier_id", "supplier_name"}

    bad = analyst.post(f"/api/apps/erp/batches/{batch_id}/mapping/approve",
                       json={"target_entity": "supplier", "mappings": [
                           {"source_field": "Vendor", "target_field": "supplier_name"}]})
    assert bad.status_code == 400 and "supplier_id" in bad.json()["detail"]      # required key not mapped

    r = analyst.post(f"/api/apps/erp/batches/{batch_id}/mapping/approve", json={"target_entity": "supplier", "mappings": [
        {"source_field": "Vendor Code", "target_field": "supplier_id", "transform": {"type": "trim"}},
        {"source_field": "Vendor", "target_field": "supplier_name", "transform": {"type": "trim"}}]})
    assert r.status_code == 200, r.text
    assert r.json()["status"] == "NEEDS_REVIEW" and r.json()["needs_review"] == 1

    issues = analyst.get(f"/api/apps/erp/batches/{batch_id}/issues").json()
    (dup,) = [i for i in issues["issues"] if i["resolved_at"] is None]
    assert dup["rule_code"] == "DUPLICATE" and dup["record_no"] == 3
    assert batch_id in [b["batch_id"] for b in analyst.get("/api/apps/erp/review/queue").json()["quality"]]

    r = analyst.post(f"/api/apps/erp/batches/{batch_id}/records/3/reject", json={"reason": "Duplicate of row 2"})
    assert r.status_code == 200 and r.json()["status"] == "READY_TO_COMMIT"

    r = reviewer.post(f"/api/apps/erp/batches/{batch_id}/commit")
    assert r.status_code == 200, r.text
    assert (r.json()["accepted"], r.json()["rejected"], r.json()["loaded"]) == (2, 1, {"supplier": 2})


def test_correction_and_revalidation(analyst):
    batch_id = _upload(analyst, name="vendors2.csv").json()["batch_id"]
    _worker_stand_in(analyst, batch_id, [{"Vendor Code": "", "Vendor": "No code Ltd"}])
    r = analyst.post(f"/api/apps/erp/batches/{batch_id}/mapping/approve", json={"target_entity": "supplier", "mappings": [
        {"source_field": "Vendor Code", "target_field": "supplier_id"},
        {"source_field": "Vendor", "target_field": "supplier_name"}]}).json()
    assert r["status"] == "NEEDS_REVIEW"
    issue = analyst.get(f"/api/apps/erp/batches/{batch_id}/issues").json()["issues"][0]
    assert (issue["rule_code"], issue["field"]) == ("REQUIRED", "supplier_id")

    r = analyst.post(f"/api/apps/erp/batches/{batch_id}/records/1/correct",
                     json={"field": "supplier_id", "value": f"NC-{uuid.uuid4().hex[:6]}"})
    assert r.status_code == 200 and r.json()["status"] == "READY_TO_COMMIT"
    assert analyst.post(f"/api/apps/erp/batches/{batch_id}/validate").json()["status"] == "READY_TO_COMMIT"

    bad = analyst.post(f"/api/apps/erp/batches/{batch_id}/records/1/correct", json={"field": "password_hash", "value": "x"})
    assert bad.status_code == 400
