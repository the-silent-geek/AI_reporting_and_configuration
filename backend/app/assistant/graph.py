"""Smart Assistance as a LangGraph state machine (docs_ai/02 § LangGraph nodes).

  START -> normalize_question -> load_authorized_catalog -> groq_plan_request -> validate_plan
             validate_plan -> clarification_interrupt     (product/period/id unclear)
                           -> execute_data_tool -> groq_grounded_response
                           -> (refusal: other product, report request, out of scope)
        -> persist_audit_context -> END

Only groq_plan_request and groq_grounded_response use the LLM. Every route is decided
by deterministic code from a schema-validated plan, and every number in an answer
must come from the tool result (else a plain template answer is used instead).

Conversation context (a pending clarification, the last few turns) is saved per
conversation_id in <app>.assistant_conversation, so "What as-of date?" -> "today"
continues the original question. (LangGraph's own Postgres checkpointer would need
CREATE rights the product logins deliberately don't have.)
"""
import json
import re
from datetime import date
from decimal import Decimal, InvalidOperation
from typing import Any, Callable, Protocol, TypedDict

from langgraph.graph import END, START, StateGraph
from pydantic import ValidationError

from .llm import LlmUnavailable, Plan
from .tools import CLARIFY, TOOLS, Tool, catalog

MAX_QUESTION = 1000
HISTORY_TURNS = 3
# Personal references stay out of what the LLM sees (the user still gets them in the UI).
_REDACT = {"applicant_ref", "customer_ref", "subject_ref", "investigator", "assigned_investigator"}
_ROWS_FOR_LLM = 10
_OTHER_APP = {"erp": "ERP", "aml": "AML", "lending": "Lending"}
# Deterministic checks on what the user actually typed; the plan alone isn't trusted for these.
_REPORT = re.compile(r"\b(create|build|make|design|save|generate|set up)\b.*\b(report|chart|graph|dashboard|widget)s?\b", re.I)
_MONTHS = "jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec"
_MENTIONS_DATE = re.compile(rf"\d|\b(today|now|current(ly)?|yesterday|as of|month|quarter|year|week|"
                            rf"({_MONTHS})[a-z]*)\b", re.I)


class ToolDenied(Exception): ...
class ToolRejected(Exception): ...      # bad argument the DB refused (message is user-safe)


class Backend(Protocol):
    """What the graph needs from the platform; db.py-backed in service.py, faked in tests."""
    def has_permission(self, user_id: str, app: str, permission: str) -> bool: ...
    def call_tool(self, tool: Tool, user_id: str, args: dict) -> dict: ...
    def audit(self, app: str, user_id: str, conversation_id: str | None, question: str, intent: str | None,
              tool_name: str | None, arguments: dict | None, period: str | None,
              result_reference: str | None, outcome: str) -> None: ...


class Agent(Protocol):
    def plan(self, product: str, question: str, tools: list[dict], history: list[dict], today: date) -> Plan: ...
    def answer(self, question: str, tool_result: dict) -> str: ...


class AssistantState(TypedDict, total=False):
    """docs_ai/02 § LangGraph state, plus the bookkeeping the nodes pass along."""
    conversation_id: str | None
    user_id: str
    app: str
    message: str                       # what the user typed this turn
    question: str                      # what is planned/answered (includes clarification context)
    language: str
    product: str | None
    intent: str | None
    tool_plan: dict | None             # {"tool_name", "arguments"} after validation
    tool_result: dict | None
    report_configuration: dict | None  # step 6 of the plan, not built yet
    needs_clarification: bool
    clarification_question: str | None
    response: str | None
    outcome: str                       # ANSWERED | CLARIFICATION | REFUSED | ERROR
    grounded: bool                     # False = LLM answer replaced by the template
    memory: dict                       # saved conversation state from earlier turns
    audit_context: dict


# ------------------------------------------------------------------ helpers ----

def redact(result: dict) -> dict:
    def clean(v):
        if isinstance(v, dict):
            return {k: clean(x) for k, x in v.items() if k not in _REDACT}
        if isinstance(v, list):
            return [clean(x) for x in v]
        return v
    out = clean(result)
    out["supporting_rows"] = out.get("supporting_rows", [])[:_ROWS_FOR_LLM]
    return out


_NUM = re.compile(r"(?<![\w.])-?\d[\d,]*(?:\.\d+)?")


def _numbers(text: str) -> set[Decimal]:
    out = set()
    for m in _NUM.findall(text):
        try:
            out.add(Decimal(m.replace(",", "")).normalize())
        except InvalidOperation:
            pass
    return out


def is_grounded(answer: str, tool_result: dict, question: str) -> bool:
    """Every number in the answer appears in the tool result (or the question).
    Small counts (<= 31: days, list positions) are allowed as wording."""
    allowed = _numbers(json.dumps(tool_result, default=str)) | _numbers(question)
    return all(n in allowed or (n == n.to_integral_value() and abs(n) <= 31) for n in _numbers(answer))


def template_answer(r: dict) -> str:
    """Deterministic fallback: the KPIs exactly as PostgreSQL returned them."""
    kpis = r.get("kpis", {})
    if kpis.get("found") is False:
        return "I couldn't find that record in the data you have access to."
    parts = []
    for k, v in kpis.items():
        if k == "found":
            continue
        label = k.replace("_", " ")
        if isinstance(v, dict):
            v = ", ".join(f"{c} {amt}" for c, amt in v.items()) or "none"
        parts.append(f"{label}: {v}")
    return f"For {r.get('reporting_period', 'the selected period')}: " + "; ".join(parts) + "."


def sources(r: dict) -> dict:
    return {k: r.get(k) for k in ("result_reference", "reporting_period", "filters", "metric_definitions")}


# -------------------------------------------------------------------- graph ----

def build_graph(backend: Backend, agent: Agent, today: Callable[[], date] = date.today):

    def normalize_question(s: AssistantState) -> AssistantState:
        message = " ".join((s.get("message") or "").split())
        if not message:
            return {"outcome": "REFUSED", "response": "Please type a question."}
        if len(message) > MAX_QUESTION:
            return {"outcome": "REFUSED", "response": f"Please keep questions under {MAX_QUESTION} characters."}
        pending = (s.get("memory") or {}).get("pending")
        question = message
        if pending:   # this message answers the assistant's clarification question
            question = (f"{pending['question']}\n(The assistant asked: {pending['clarification_question']})\n"
                        f"User replied: {message}")
        language = "en" if all(ord(c) < 128 for c in message) else "auto"
        return {"message": message, "question": question, "language": language}

    def load_authorized_catalog(s: AssistantState) -> AssistantState:
        app, user = s["app"], s["user_id"]
        if not (backend.has_permission(user, app, "assistant.use") and backend.has_permission(user, app, "dashboard.view")):
            return {"outcome": "REFUSED", "response": "You don't have access to Smart Assistance in this app."}
        return {"product": app}

    def groq_plan_request(s: AssistantState) -> AssistantState:
        history = (s.get("memory") or {}).get("history", [])
        try:
            plan = agent.plan(s["app"], s["question"], [t.schema() for t in catalog(s["app"])], history, today())
        except LlmUnavailable as e:
            return _llm_down(e)
        return {"intent": plan.intent, "audit_context": {"plan": plan.model_dump()}}

    def validate_plan(s: AssistantState) -> AssistantState:
        plan = Plan.model_validate(s["audit_context"]["plan"])
        app = s["app"]
        if plan.product and plan.product != app:
            name = _OTHER_APP[plan.product]
            return {"outcome": "REFUSED", "response": f"That question is about {name} data. Open the {name} app to ask it there."}
        if (plan.intent == "report_request" or plan.report_request) and (_REPORT.search(s["question"]) or not plan.tool_name):
            return {"outcome": "REFUSED", "response": "Creating reports from chat isn't available yet. "
                    "Ask me a question about the data instead, for example a summary for a period."}
        if plan.intent == "greeting":
            return {"outcome": "REFUSED", "response": _capabilities(app, "Hi! ")}
        if plan.intent == "out_of_scope":
            return {"outcome": "REFUSED", "response": _capabilities(app, "I can only answer questions about this app's data. ")}
        if plan.needs_clarification:
            return _clarify(plan.clarification_question or "Could you give a bit more detail?")

        tool = TOOLS.get(plan.tool_name or "")
        if tool is None or tool.product != app:
            return _clarify("Which data should I look at? " + _capabilities(app, ""))
        try:
            args = tool.args.model_validate(plan.arguments)
        except ValidationError as e:
            err = e.errors()[0]
            field = str(err["loc"][0]) if err["loc"] else ""
            if err["type"] == "missing" and field in CLARIFY:
                return _clarify(CLARIFY[field])
            return _clarify(f"I couldn't use '{field or 'the request'}': {err['msg'].lower()}. Could you rephrase it?")
        if "as_of_date" in tool.args.model_fields and not _MENTIONS_DATE.search(s["question"]):
            return _clarify(CLARIFY["as_of_date"])   # never assume the cut-off date for overdue/ageing
        return {"tool_plan": {"tool_name": tool.name, "arguments": args.model_dump(mode="json")},
                "needs_clarification": False}

    def clarification_interrupt(s: AssistantState) -> AssistantState:
        """Human-in-the-loop: the question goes back to the user; the original
        question is remembered so the reply continues it."""
        original = ((s.get("memory") or {}).get("pending") or {}).get("question") or s["message"]
        return {"outcome": "CLARIFICATION", "response": s["clarification_question"],
                "memory": {**(s.get("memory") or {}),
                           "pending": {"question": original, "clarification_question": s["clarification_question"]}}}

    def execute_data_tool(s: AssistantState) -> AssistantState:
        tool = TOOLS[s["tool_plan"]["tool_name"]]
        try:
            result = backend.call_tool(tool, s["user_id"], tool.args.model_validate(s["tool_plan"]["arguments"]).model_dump())
        except ToolDenied:
            return {"outcome": "REFUSED", "response": "You don't have access to that data."}
        except ToolRejected as e:
            return _clarify(f"{e} Could you adjust the request?")
        return {"tool_result": result}

    def groq_grounded_response(s: AssistantState) -> AssistantState:
        result = s["tool_result"]
        try:
            text = agent.answer(s["question"], redact(result))
            grounded = is_grounded(text, result, s["question"])
        except LlmUnavailable:
            text, grounded = None, False
        if not grounded:
            text = template_answer(result)
        return {"outcome": "ANSWERED", "response": text, "grounded": grounded}

    def persist_audit_context(s: AssistantState) -> AssistantState:
        plan, result = s.get("tool_plan") or {}, s.get("tool_result") or {}
        backend.audit(s["app"], s["user_id"], s.get("conversation_id"), s.get("question") or s.get("message") or "",
                      s.get("intent"), plan.get("tool_name"), plan.get("arguments"), result.get("reporting_period"),
                      result.get("result_reference"), s["outcome"])
        memory = dict(s.get("memory") or {})
        if s["outcome"] != "CLARIFICATION":
            memory.pop("pending", None)
        if s["outcome"] == "ANSWERED":
            memory["history"] = (memory.get("history", []) + [{
                "question": s["question"], "tool_name": plan.get("tool_name"), "arguments": plan.get("arguments"),
                "answer": (s.get("response") or "")[:300]}])[-HISTORY_TURNS:]
        return {"memory": memory}

    g = StateGraph(AssistantState)
    for fn in (normalize_question, load_authorized_catalog, groq_plan_request, validate_plan,
               clarification_interrupt, execute_data_tool, groq_grounded_response, persist_audit_context):
        g.add_node(fn.__name__, fn)

    def done_or(next_node: str):
        return lambda s: "persist_audit_context" if s.get("outcome") else next_node

    g.add_edge(START, "normalize_question")
    g.add_conditional_edges("normalize_question", done_or("load_authorized_catalog"))
    g.add_conditional_edges("load_authorized_catalog", done_or("groq_plan_request"))
    g.add_conditional_edges("groq_plan_request", done_or("validate_plan"))
    def route(next_node: str):
        return lambda s: ("persist_audit_context" if s.get("outcome") else
                          "clarification_interrupt" if s.get("needs_clarification") else next_node)

    g.add_conditional_edges("validate_plan", route("execute_data_tool"))
    g.add_edge("clarification_interrupt", "persist_audit_context")
    g.add_conditional_edges("execute_data_tool", route("groq_grounded_response"))
    g.add_edge("groq_grounded_response", "persist_audit_context")
    g.add_edge("persist_audit_context", END)
    return g.compile()


def _clarify(question: str) -> AssistantState:
    return {"needs_clarification": True, "clarification_question": question[:300]}


def _llm_down(e: LlmUnavailable) -> AssistantState:
    msg = ("The assistant is busy right now (rate limit). Please try again in a minute."
           if e.reason == "rate_limited" else "The assistant is temporarily unavailable. Please try again.")
    return {"outcome": "ERROR", "response": msg}


def _capabilities(app: str, prefix: str) -> str:
    names = {"lending": "loan application summaries, trends and application details",
             "erp": "payables ageing, overdue suppliers and payment details",
             "aml": "alert summaries, alert details and case details"}
    return f"{prefix}In this app I can answer questions about {names[app]}."


def initial_state(app: str, user_id: str, conversation_id: str | None, message: str, memory: dict) -> AssistantState:
    return {"app": app, "user_id": user_id, "conversation_id": conversation_id, "message": message,
            "memory": memory, "product": None, "intent": None, "tool_plan": None, "tool_result": None,
            "report_configuration": None, "needs_clarification": False, "clarification_question": None,
            "response": None, "audit_context": {}}


def to_response(s: AssistantState, conversation_id: str) -> dict[str, Any]:
    result = s.get("tool_result")
    return {
        "conversation_id": conversation_id,
        "status": s["outcome"].lower(),
        "answer": s.get("response"),
        "clarification_question": s.get("clarification_question") if s["outcome"] == "CLARIFICATION" else None,
        "tool_name": (s.get("tool_plan") or {}).get("tool_name") if result else None,
        "grounded": s.get("grounded"),
        "sources": sources(result) if result else None,
        "result": result,
    }
