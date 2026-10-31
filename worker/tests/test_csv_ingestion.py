"""CSV end to end through the pipeline: records, statuses, mapping, idempotency."""
import json

import pytest

from ai_worker.errors import FinalError
from ai_worker.parsers.tabular import CsvParser
from fakes import job_for

PAYABLES = (
    "Invoice_No,Supplier,Invoice_Date,Due_Date,Amount,Currency\n"
    "INV-001,ACME,2026-01-05,2026-02-04,\"10,000.50\",USD\n"
    "INV-002,ACME,2026-01-09,2026-02-08,2500,USD\n"
    "INV-003,Globex,2026-01-12,2026-02-11,10000,EUR\n"
)


def _write(tmp_path, text, name="payables.csv"):
    path = tmp_path / name
    path.write_text(text, encoding="utf-8")
    return path


def test_csv_rows_become_candidate_records(tmp_path):
    records = CsvParser().parse(_write(tmp_path, PAYABLES), lambda pct, msg: None)
    assert len(records) == 3
    first = records[0]
    assert first.source_location == {"row": 2}
    assert first.raw_fields == {"Invoice_No": "INV-001", "Supplier": "ACME", "Invoice_Date": "2026-01-05",
                                "Due_Date": "2026-02-04", "Amount": "10,000.50", "Currency": "USD"}
    assert first.extraction_method == "csv" and first.confidence is None and first.state == "PENDING"
    json.dumps([r.raw_fields for r in records])   # jsonb-ready


def test_csv_semicolon_bom_multiline_and_ragged_rows(tmp_path):
    text = "﻿Ref;Note;Amount\nA1;\"two\nlines\";5\n\nA2;x\nA3;y;7;extra\n"
    records = CsvParser().parse(_write(tmp_path, text), lambda pct, msg: None)
    assert [r.raw_fields["Ref"] for r in records] == ["A1", "A2", "A3"]
    assert records[0].raw_fields["Note"] == "two\nlines"
    assert records[1].source_location == {"row": 5}          # after the 2-line record and a blank line
    assert records[1].state == "NEEDS_REVIEW"                # missing Amount
    assert records[2].raw_fields["_extra"] == ["extra"]
    assert records[2].issues[0].severity == "ERROR"


def test_pipeline_csv_happy_path(tmp_path, pipeline, repo, publisher):
    batch = repo.add_batch(_write(tmp_path, PAYABLES), "CSV")
    outcome = pipeline.run(job_for(batch), publisher)

    assert outcome.status == "MAPPING_REVIEW" and outcome.records == 3
    assert publisher.statuses[0] == "EXTRACTING" and publisher.statuses[-1] == "MAPPING_REVIEW"
    pcts = [p.progress_pct for p in publisher.sent if p.status == "EXTRACTING"]
    assert pcts == sorted(pcts)
    assert "3 records extracted" in publisher.sent[-1].message

    mapping = {m["source_field"]: m for m in repo.mappings[batch.batch_id]}
    assert {k: m["target_field"] for k, m in mapping.items()} == {
        "Invoice_No": "invoice_id", "Supplier": "supplier_id", "Invoice_Date": "invoice_date",
        "Due_Date": "due_date", "Amount": "amount", "Currency": "currency"}
    assert all(m["target_entity"] == "invoice" and m["method"] == "alias" for m in mapping.values())
    assert mapping["Amount"]["transform"]["type"] == "parse_decimal"
    assert mapping["Invoice_Date"]["transform"] == {"type": "parse_date", "format": "%Y-%m-%d"}


def test_redelivery_does_not_duplicate(tmp_path, pipeline, repo, publisher):
    batch = repo.add_batch(_write(tmp_path, PAYABLES), "CSV")
    job = job_for(batch)
    pipeline.run(job, publisher)
    sent = len(publisher.sent)

    again = pipeline.run(job, publisher)          # same message delivered twice
    assert again.status is None                    # batch already in MAPPING_REVIEW -> skipped
    assert len(publisher.sent) == sent and repo.save_calls == 1
    assert len(repo.rows[batch.batch_id]) == 3


def test_crash_after_commit_reports_stored_result(tmp_path, pipeline, repo, publisher):
    """Worker died after the DB commit but before the final event: the retry must
    re-announce the stored result without parsing or writing again."""
    batch = repo.add_batch(_write(tmp_path, PAYABLES), "CSV")
    pipeline.run(job_for(batch), publisher)
    repo.set_status(batch.batch_id, "EXTRACTING")  # final event never reached the API
    publisher.sent.clear()

    outcome = pipeline.run(job_for(batch), publisher)
    assert outcome.status == "MAPPING_REVIEW" and outcome.records == 3
    assert publisher.statuses == ["MAPPING_REVIEW"]
    assert repo.save_calls == 1


def test_retry_from_uploaded_with_stored_result_stays_legal(tmp_path, pipeline, repo, publisher):
    batch = repo.add_batch(_write(tmp_path, PAYABLES), "CSV")
    pipeline.run(job_for(batch), publisher)
    repo.set_status(batch.batch_id, "UPLOADED")    # user retried after a FAILED
    publisher.sent.clear()
    pipeline.run(job_for(batch), publisher)        # StatePublisher asserts every transition
    assert publisher.statuses == ["EXTRACTING", "MAPPING_REVIEW"]


def test_records_needing_review_end_in_needs_review(tmp_path, pipeline, repo, publisher):
    batch = repo.add_batch(_write(tmp_path, PAYABLES + "INV-004,ACME\n"), "CSV")
    outcome = pipeline.run(job_for(batch), publisher)
    assert outcome.status == "NEEDS_REVIEW" and outcome.needs_review == 1
    assert "1 records need review" in publisher.sent[-1].message


def test_checksum_mismatch_is_final(tmp_path, pipeline, repo, publisher):
    path = _write(tmp_path, PAYABLES)
    batch = repo.add_batch(path, "CSV")
    path.write_text(PAYABLES + "INV-9,X,2026-01-01,2026-01-02,1,USD\n")
    with pytest.raises(FinalError) as e:
        pipeline.run(job_for(batch), publisher)
    assert e.value.code == "CHECKSUM_MISMATCH"
    assert batch.batch_id not in repo.rows


def test_file_outside_storage_dir_is_refused(tmp_path, pipeline, repo, publisher, settings):
    outside = tmp_path.parent / f"{tmp_path.name}-outside.csv"
    outside.write_text(PAYABLES)
    try:
        batch = repo.add_batch(outside, "CSV")
        with pytest.raises(FinalError) as e:
            pipeline.run(job_for(batch), publisher)
        assert e.value.code == "STORAGE_PATH_REJECTED"
    finally:
        outside.unlink()


def test_header_only_file_is_final(tmp_path, pipeline, repo, publisher):
    batch = repo.add_batch(_write(tmp_path, "Invoice_No,Amount\n"), "CSV")
    with pytest.raises(FinalError) as e:
        pipeline.run(job_for(batch), publisher)
    assert e.value.code == "EMPTY_FILE"
