"""Smart Assistance graph routing with a scripted planner/answerer and a fake platform
(docs_ai/02 step 2: deterministic routing and validation with mocked Groq JSON plans)."""
from datetime import date

from app.assistant.graph import ToolDenied, build_graph, initial_state, is_grounded, redact, template_answer
from app.assistant.llm import LlmUnavailable, Plan

TODAY = date(2026, 10, 31)
AGEING = {"result_reference": "run-1", "product": "erp", "reporting_period": "As of 2026-10-31",
          "filters": {"as_of_date": "2026-10-31"}, "metric_definitions": [],
          "kpis": {"overdue_invoice_count": 2, "overdue_amount_by_currency": {"USD": 600.00, "EUR": 1700.00}},
          "chart_data": [], "supporting_rows": [{"invoice_id": "I1", "customer_ref": "C-9"}]}


class FakeBackend:
    def __init__(self, allowed=True, result=AGEING, deny_tool=False):
        self.allowed, self.result, self.deny_tool = allowed, result, deny_tool
        self.tool_calls, self.audits = [], []

    def has_permission(self, user_id, app, permission):
        return self.allowed

    def call_tool(self, tool, user_id, args):
        if self.deny_tool:
            raise ToolDenied()
        self.tool_calls.append((tool.name, args))
        return self.result

    def audit(self, app, user_id, conversation_id, question, intent, tool_name, arguments, period, ref, outcome):
        self.audits.append({"tool": tool_name, "outcome": outcome, "ref": ref, "question": question})


class FakeAgent:
    def __init__(self, plans, answer="2 invoices are overdue as of 2026-10-31: USD 600.00 and EUR 1,700.00."):
        self.plans, self.answer_text = list(plans), answer
        self.seen_questions, self.seen_results = [], []

    def plan(self, product, question, tools, history, today):
        self.seen_questions.append(question)
        p = self.plans.pop(0)
        if isinstance(p, Exception):
            raise p
        return Plan.model_validate(p)

    def answer(self, question, tool_result):
        self.seen_results.append(tool_result)
        if isinstance(self.answer_text, Exception):
            raise self.answer_text
        return self.answer_text


def run(backend, agent, message, memory=None, app="erp"):
    graph = build_graph(backend, agent, today=lambda: TODAY)
    return graph.invoke(initial_state(app, "u1", "c1", message, memory or {}))


AGEING_PLAN = {"intent": "data_question", "product": "erp", "tool_name": "get_erp_payables_ageing",
               "arguments": {"as_of_date": "2026-10-31"}}


def test_data_question_runs_tool_and_answers_grounded():
    b, a = FakeBackend(), FakeAgent([AGEING_PLAN])
    s = run(b, a, "Show overdue payables today")
    assert s["outcome"] == "ANSWERED" and s["grounded"]
    assert b.tool_calls == [("get_erp_payables_ageing", {"as_of_date": date(2026, 10, 31), "supplier_id": None,
                                                         "currency": None})]
    assert b.audits[-1] == {"tool": "get_erp_payables_ageing", "outcome": "ANSWERED", "ref": "run-1",
                            "question": "Show overdue payables today"}
    assert "customer_ref" not in str(a.seen_results[0])          # personal refs never reach the LLM
    assert s["memory"]["history"][-1]["tool_name"] == "get_erp_payables_ageing"


def test_invented_number_falls_back_to_template():
    b, a = FakeBackend(), FakeAgent([AGEING_PLAN], answer="Overdue is up 37% to USD 950.")
    s = run(b, a, "overdue as of today?")
    assert s["outcome"] == "ANSWERED" and not s["grounded"]
    assert "USD 600.0" in s["response"] and "37" not in s["response"]


def test_missing_as_of_date_asks_then_continues_original_question():
    b = FakeBackend()
    a = FakeAgent([{"intent": "data_question", "product": "erp", "tool_name": None, "needs_clarification": True,
                    "clarification_question": "What as-of date should I use for overdue payments?"},
                   AGEING_PLAN])
    first = run(b, a, "Show overdue payments")
    assert first["outcome"] == "CLARIFICATION" and b.tool_calls == []
    assert first["memory"]["pending"]["question"] == "Show overdue payments"

    second = run(b, a, "today", memory=first["memory"])
    assert "Show overdue payments" in a.seen_questions[1] and "User replied: today" in a.seen_questions[1]
    assert second["outcome"] == "ANSWERED" and "pending" not in second["memory"]


def test_plan_missing_required_argument_gets_deterministic_question():
    b = FakeBackend()
    s = run(b, FakeAgent([{"intent": "data_question", "tool_name": "get_erp_payables_ageing", "arguments": {}}]), "ageing")
    assert s["outcome"] == "CLARIFICATION" and s["response"] == "What as-of date should I use?"
    assert b.tool_calls == []


def test_unknown_tool_or_extra_arguments_never_execute():
    for plan in ({"intent": "data_question", "tool_name": "run_sql", "arguments": {"sql": "select 1"}},
                 {"intent": "data_question", "tool_name": "get_erp_payables_ageing",
                  "arguments": {"as_of_date": "2026-10-31", "table": "iam.app_user"}},
                 {"intent": "data_question", "tool_name": "get_aml_alert_summary",      # other product's tool
                  "arguments": {"start_date": "2026-10-01", "end_date": "2026-10-31"}}):
        b = FakeBackend()
        s = run(b, FakeAgent([plan]), "q")
        assert s["outcome"] == "CLARIFICATION" and b.tool_calls == [], plan


def test_reversed_period_is_not_sent_to_the_database():
    b = FakeBackend()
    s = run(b, FakeAgent([{"intent": "data_question", "tool_name": "get_lending_application_summary",
                           "arguments": {"start_date": "2026-10-31", "end_date": "2026-10-01"}}]), "q", app="lending")
    assert s["outcome"] == "CLARIFICATION" and b.tool_calls == []


def test_refusals():
    cases = [({"intent": "data_question", "product": "aml", "tool_name": None}, "Open the AML app"),
             ({"intent": "report_request", "report_request": True}, "isn't available yet"),
             ({"intent": "out_of_scope"}, "only answer questions about this app's data")]
    for plan, text in cases:
        s = run(FakeBackend(), FakeAgent([plan]), "q")
        assert s["outcome"] == "REFUSED" and text in s["response"], plan


def test_no_permission_stops_before_the_llm():
    a = FakeAgent([])
    s = run(FakeBackend(allowed=False), a, "overdue?")
    assert s["outcome"] == "REFUSED" and a.seen_questions == []


def test_database_denial_is_a_refusal():
    s = run(FakeBackend(deny_tool=True), FakeAgent([AGEING_PLAN]), "overdue today?")
    assert s["outcome"] == "REFUSED"


def test_llm_down():
    s = run(FakeBackend(), FakeAgent([LlmUnavailable("rate_limited")]), "overdue?")
    assert s["outcome"] == "ERROR" and "rate limit" in s["response"]
    s = run(FakeBackend(), FakeAgent([AGEING_PLAN], answer=LlmUnavailable("unavailable")), "overdue today?")
    assert s["outcome"] == "ANSWERED" and not s["grounded"]          # data still shown, from the template


def test_empty_and_overlong_questions():
    assert run(FakeBackend(), FakeAgent([]), "   ")["outcome"] == "REFUSED"
    assert run(FakeBackend(), FakeAgent([]), "x" * 1001)["outcome"] == "REFUSED"


def test_grounding_helpers():
    assert is_grounded("EUR 1,700.00 overdue across 2 invoices", AGEING, "q")
    assert not is_grounded("EUR 2,300.00 overdue", AGEING, "q")
    assert redact(AGEING)["supporting_rows"] == [{"invoice_id": "I1"}]
    assert template_answer({"kpis": {"found": False}}).startswith("I couldn't find")


def test_as_of_date_is_never_assumed():
    """docs_ai/02: 'Show overdue payments' without a cut-off date must ask, even if the plan guessed today."""
    b = FakeBackend()
    s = run(b, FakeAgent([AGEING_PLAN]), "Show overdue payments")
    assert s["outcome"] == "CLARIFICATION" and s["response"] == "What as-of date should I use?" and b.tool_calls == []


def test_report_label_on_a_plain_question_still_answers():
    b = FakeBackend()
    plan = {**AGEING_PLAN, "intent": "report_request", "report_request": True}
    assert run(b, FakeAgent([plan]), "Show overdue payables as of today")["outcome"] == "ANSWERED"
    s = run(FakeBackend(), FakeAgent([plan]), "Create a chart of overdue payables as of today")
    assert s["outcome"] == "REFUSED"
