"""Mapping: alias -> BGE -> Groq order, Groq only for ambiguity, strict Groq validation."""
import json
import re
from pathlib import Path

import httpx

from ai_worker.mapping import MappingService
from ai_worker.mapping.catalog import CATALOG
from ai_worker.mapping.groq import GroqResolver
from ai_worker.mapping.profiling import infer_type, mask, normalize_name, profile
from ai_worker.records import CandidateRecord
from fakes import ExactEmbedder

ROOT = Path(__file__).resolve().parents[2]


def _records(rows: list[dict]) -> list[CandidateRecord]:
    return [CandidateRecord({"row": i + 2}, r, "csv") for i, r in enumerate(rows)]


LOANS = _records([
    {"Loan Ref": f"LN-100{i}", "Customer Number": f"C-77{i}", "Value": f"{i + 1}0,000.00",
     "Date 2": f"2026-0{i + 1}-15", "Status": "APPROVED", "Currency": "INR"}
    for i in range(4)])

# BGE similarities for the non-alias headers ("Value" and "Date 2" are deliberately unclear)
SIMS = {
    "Customer Number": {"applicant_ref": 0.88, "application_id": 0.70},
    "Value": {"requested_amount": 0.74, "term_months": 0.72},
    "Date 2": {"applied_at": 0.71, "status": 0.40},
}


def _groq(handler) -> GroqResolver:
    return GroqResolver("test-key", "test-model", "https://groq.test/openai/v1", 5,
                        transport=httpx.MockTransport(handler))


def _reply(mappings: list[dict]) -> httpx.Response:
    return httpx.Response(200, json={"choices": [{"message": {"content": json.dumps({"mappings": mappings})}}]})


def _by_source(result):
    return {s.source_field: s for s in result.suggestions}


# ------------------------------------------------------------------ catalog ----

def test_catalog_matches_domain_tables_sql():
    sql = (ROOT / "db" / "05_domain_tables.sql").read_text()
    in_db, keys_db = set(), set()
    for schema, table, body in re.findall(r"CREATE TABLE (\w+)\.(\w+) \((.*?)\n\);", sql, re.S):
        for line in body.splitlines():
            m = re.match(r"\s+(\w+)\s+\w", line)
            if m and m[1] not in ("PRIMARY", "CHECK", "FOREIGN", "UNIQUE", "batch_id", "source_record_no"):
                in_db.add((schema, table, m[1]))
                if "PRIMARY KEY" in line:
                    keys_db.add((schema, table, m[1]))
        if pk := re.search(r"PRIMARY KEY \(([^)]+)\)", body):
            keys_db |= {(schema, table, c.strip()) for c in pk[1].split(",")}
    in_catalog = {(app, t.entity, t.name) for app, ts in CATALOG.items() for t in ts}
    keys_catalog = {(app, t.entity, t.name) for app, ts in CATALOG.items() for t in ts if t.key}
    assert in_catalog == in_db
    assert keys_catalog == keys_db


# ---------------------------------------------------------------- profiling ----

def test_names_types_and_masking():
    assert normalize_name("Invoice_No") == normalize_name("invoiceNo") == normalize_name("Invoice #") == "invoice no"
    assert normalize_name("Amount (USD)") == "amount"
    assert mask("LN-1001") == "XX-9999"
    assert infer_type(["10,000.50", "2500", "(30.00)"], 3) == ("decimal", None)
    assert infer_type(["05-Oct-2026", "10-Oct-2026"], 2) == ("date", "%d-%b-%Y")
    assert infer_type(["USD", "EUR", "USD"], 2) == ("currency", None)
    assert infer_type([12, 36, 60], 3) == ("integer", None)

    p = {f.name: f for f in profile(LOANS)}
    assert p["Loan Ref"].samples[0] == "XX-9999"          # identifiers masked
    assert p["Status"].samples == ("APPROVED",)            # enum-like values kept


# ------------------------------------------------------------------- layers ----

def test_aliases_first_bge_second_and_review_flags_without_groq():
    result = MappingService(ExactEmbedder(SIMS), None, accept=0.80, margin=0.03).suggest("lending", LOANS)
    s = _by_source(result)
    assert result.entity == "application"
    assert (s["Loan Ref"].target_field, s["Loan Ref"].method) == ("application_id", "alias")
    assert (s["Status"].method, s["Currency"].method) == ("alias", "alias")
    assert (s["Customer Number"].target_field, s["Customer Number"].method) == ("applicant_ref", "bge")
    assert not s["Customer Number"].needs_review
    # unclear + no Groq: best local guess, flagged for review
    assert (s["Value"].target_field, s["Value"].method, s["Value"].needs_review) == ("requested_amount", "bge", True)
    assert s["Value"].transform["type"] == "parse_decimal"
    assert s["Date 2"].needs_review


def test_groq_called_once_only_for_ambiguous_fields_with_masked_data():
    seen = []

    def handler(request: httpx.Request) -> httpx.Response:
        body = json.loads(request.content)
        seen.append(json.loads(body["messages"][1]["content"]))
        assert request.headers["Authorization"] == "Bearer test-key"
        return _reply([
            {"source_field": "Value", "target_field": "requested_amount",
             "transformation": {"type": "parse_decimal", "remove_characters": [","]},
             "confidence": 0.78, "reason": "Values look monetary; confirm business meaning."},
            {"source_field": "Date 2", "target_field": None, "transformation": {"type": "none"},
             "confidence": 0.3, "reason": "Unclear which date this is."},
            {"source_field": "Loan Ref", "target_field": "status", "transformation": {"type": "none"},
             "confidence": 0.9, "reason": "not asked about this one"},
        ])

    groq = _groq(handler)
    s = _by_source(MappingService(ExactEmbedder(SIMS), groq, accept=0.80, margin=0.03).suggest("lending", LOANS))

    assert groq.calls == 1
    payload = seen[0]
    assert [f["source_field"] for f in payload["source_fields"]] == ["Value", "Date 2"]
    assert {f["name"] for f in payload["allowed_target_fields"]} == {
        "application_id", "applicant_ref", "applied_at", "status", "requested_amount", "currency",
        "product", "purpose", "term_months"}
    assert "LN-1001" not in json.dumps(payload) and "10,000.00" not in json.dumps(payload)

    assert (s["Value"].target_field, s["Value"].method, s["Value"].confidence) == ("requested_amount", "groq", 0.78)
    assert s["Value"].transform == {"type": "parse_decimal", "remove_characters": [","]}
    assert s["Value"].needs_review                                   # below 0.85
    assert (s["Date 2"].target_field, s["Date 2"].needs_review) == (None, True)
    assert s["Loan Ref"].target_field == "application_id"           # unasked answer ignored


def test_groq_not_called_when_everything_is_clear(tmp_path):
    calls = []
    groq = _groq(lambda r: calls.append(r) or _reply([]))
    rows = _records([{"Invoice No": "INV-1", "Supplier": "ACME", "Amount": "10.00", "Currency": "USD"}])
    MappingService(None, groq, accept=0.80, margin=0.03).suggest("erp", rows)
    assert calls == []


def test_groq_answer_outside_allowlist_or_schema_is_ignored():
    bad_field = _groq(lambda r: _reply([{"source_field": "Value", "target_field": "salary",
                                         "transformation": {"type": "none"}, "confidence": 0.9, "reason": "x"}]))
    s = _by_source(MappingService(ExactEmbedder(SIMS), bad_field, 0.80, 0.03).suggest("lending", LOANS))
    assert (s["Value"].method, s["Value"].target_field) == ("bge", "requested_amount")

    extra_key = _groq(lambda r: _reply([{"source_field": "Value", "target_field": "requested_amount",
                                         "transformation": {"type": "none", "sql": "DROP TABLE x"},
                                         "confidence": 0.9, "reason": "x"}]))
    s = _by_source(MappingService(ExactEmbedder(SIMS), extra_key, 0.80, 0.03).suggest("lending", LOANS))
    assert s["Value"].method == "bge"


def test_groq_unavailable_keeps_local_suggestions():
    down = _groq(lambda r: httpx.Response(503))
    s = _by_source(MappingService(ExactEmbedder(SIMS), down, 0.80, 0.03).suggest("lending", LOANS))
    assert (s["Value"].target_field, s["Value"].needs_review) == ("requested_amount", True)

    def timeout(request):
        raise httpx.ReadTimeout("slow", request=request)
    s = _by_source(MappingService(ExactEmbedder(SIMS), _groq(timeout), 0.80, 0.03).suggest("lending", LOANS))
    assert s["Value"].method == "bge"


def test_two_fields_never_share_a_target():
    rows = _records([{"Invoice No": "INV-1", "Amount": "10.00", "Invoice Amount": "10.00", "Currency": "USD"}])
    s = _by_source(MappingService(None, None, 0.80, 0.03).suggest("erp", rows))
    targets = [x.target_field for x in s.values() if x.target_field]
    assert len(targets) == len(set(targets))
    loser = s["Invoice Amount"] if s["Amount"].target_field == "amount" else s["Amount"]
    assert loser.target_field is None and loser.needs_review


def test_unrelated_file_gets_no_entity():
    rows = _records([{"foo": "1", "bar": "x"}])
    result = MappingService(None, None, 0.80, 0.03).suggest("aml", rows)
    assert result.entity is None
    assert all(s.target_field is None and s.needs_review for s in result.suggestions)
