"""Smart Assistance over HTTP against the real DB tools (db/07); only Groq is scripted."""
import uuid

import pytest

from app.assistant import graph as graph_mod
from app.assistant import service
from app.assistant.service import DbBackend
from test_assistant_graph import FakeAgent

AGEING_PLAN = {"intent": "data_question", "product": "erp", "tool_name": "get_erp_payables_ageing",
               "arguments": {"as_of_date": "2026-10-31"}}


@pytest.fixture
def scripted(monkeypatch):
    """Replace the Groq agent; everything else (auth, graph, DB tools, audit) is real."""
    def use(*plans, answer="No overdue invoices as of 2026-10-31."):
        agent = FakeAgent(list(plans), answer=answer)
        monkeypatch.setattr(service, "enabled", lambda: True)
        monkeypatch.setattr(service, "_graph", lambda: graph_mod.build_graph(DbBackend(), agent))
        return agent
    return use


def _chat(client, app, message, conversation_id=None):
    return client.post(f"/api/apps/{app}/assistant/chat",
                       json={"message": message, **({"conversation_id": conversation_id} if conversation_id else {})})


def test_answer_comes_from_db_tool_and_is_audited(reviewer, scripted):
    scripted(AGEING_PLAN)
    r = _chat(reviewer, "erp", f"Overdue payables today? {uuid.uuid4().hex[:6]}")
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["status"] == "answered" and body["tool_name"] == "get_erp_payables_ageing"
    assert body["sources"]["reporting_period"] == "As of 2026-10-31"
    assert body["result"]["product"] == "erp" and "kpis" in body["result"]
    uuid.UUID(body["sources"]["result_reference"])          # the DB's assistant_tool_run id
    assert body["grounded"] is True


def test_clarification_continues_in_same_conversation(reviewer, scripted):
    agent = scripted({"intent": "data_question", "product": "erp", "needs_clarification": True,
                      "clarification_question": "What as-of date should I use for overdue payments?"},
                     AGEING_PLAN)
    first = _chat(reviewer, "erp", "Show overdue payments").json()
    assert first["status"] == "clarification" and first["result"] is None
    second = _chat(reviewer, "erp", "today", first["conversation_id"]).json()
    assert second["status"] == "answered" and second["conversation_id"] == first["conversation_id"]
    assert "Show overdue payments" in agent.seen_questions[1]


def test_other_users_conversation_is_not_found(reviewer, analyst, scripted):
    scripted(AGEING_PLAN)
    conv = _chat(reviewer, "erp", "overdue today?").json()["conversation_id"]
    r = _chat(analyst, "erp", "and yesterday?", conv)
    assert r.status_code == 404


def test_app_without_role_is_forbidden(analyst, scripted):
    scripted(AGEING_PLAN)
    assert _chat(analyst, "lending", "rejected applications last month?").status_code == 403   # no Lending role


def test_not_configured_without_groq_key(reviewer, monkeypatch):
    monkeypatch.setattr(service, "enabled", lambda: False)
    assert _chat(reviewer, "erp", "hi").status_code == 503
