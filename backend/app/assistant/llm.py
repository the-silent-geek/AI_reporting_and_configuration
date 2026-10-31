"""The Groq main agent: two narrow jobs, both forced into a JSON schema.

  plan()    question + allowed tools -> Plan (which tool, which arguments). No data answer.
  answer()  question + validated tool result -> short grounded answer text.

The model never sees credentials, SQL, table names or other users' data: only tool
schemas, the user's question and the (redacted) result of an authorized tool.
"""
import json
import logging
import time
from datetime import date
from typing import Any, Literal

import httpx
from pydantic import BaseModel, ConfigDict, Field, ValidationError

log = logging.getLogger(__name__)

Intent = Literal["data_question", "report_request", "out_of_scope", "greeting"]
_MAX_RETRY_WAIT = 8      # seconds; longer rate-limit waits are reported to the user instead


class LlmUnavailable(Exception):
    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason          # "rate_limited" | "unavailable" | "bad_output"


class Plan(BaseModel):
    """docs_ai/02 § Main Groq agent output."""
    model_config = ConfigDict(extra="forbid")
    intent: Intent
    product: Literal["erp", "aml", "lending"] | None = None
    tool_name: str | None = None
    arguments: dict[str, Any] = Field(default_factory=dict)
    needs_clarification: bool = False
    clarification_question: str | None = Field(None, max_length=300)
    report_request: bool = False


class Answer(BaseModel):
    model_config = ConfigDict(extra="forbid")
    answer: str = Field(min_length=1, max_length=2000)


_PLAN_SYSTEM = """You are the request planner of a reporting assistant for the {product} product.
Today is {today}. Choose at most ONE tool from the allowed tools and fill its arguments.
You never answer the question yourself and never invent data.

Rules:
- Dates are YYYY-MM-DD. Resolve relative periods from today ("last month" = the previous calendar month).
- as_of_date: use a date the user gave, or today if they say "today"/"now"/"current". Otherwise ask.
- If a required argument is missing and cannot be inferred, set needs_clarification=true and ask ONE short question.
- Products: erp = supplier invoices/payments/payables; aml = alerts/cases/investigations; lending = loan
  applications/disbursements. A data question about another product: intent="data_question",
  product=that product, tool_name=null.
- "Show", "list", "what", "how many" are data questions. Only an explicit request to create, build,
  save or design a report, chart or dashboard is intent="report_request", report_request=true.
- Anything unrelated to the product's data: intent="out_of_scope". Greetings: intent="greeting".
- Use earlier turns only to understand follow-ups ("and for September?").

Reply with JSON only:
{{"intent":"data_question|report_request|out_of_scope|greeting","product":"erp|aml|lending"|null,
"tool_name":str|null,"arguments":{{}},"needs_clarification":bool,"clarification_question":str|null,
"report_request":bool}}"""

_ANSWER_SYSTEM = """You explain results of a reporting tool to a business user.
Use ONLY numbers and facts present in tool_result. Do not calculate new totals, percentages or averages.
Amounts are per currency; never add different currencies together.
If the question asks for something tool_result does not contain, say you cannot determine it from the authorized data.
If kpis.found is false, say the record was not found.
Mention the reporting period and any filters in plain words. Keep it under 120 words, no tables, no markdown headings.
Answer in the language of the question.
Reply with JSON only: {"answer": "..."}"""


class GroqAgent:
    def __init__(self, api_key: str, model: str, base_url: str, timeout: float,
                 transport: httpx.BaseTransport | None = None):   # transport: tests only
        self.model = model
        self.client = httpx.Client(base_url=base_url, timeout=timeout, transport=transport,
                                   headers={"Authorization": f"Bearer {api_key}"})

    def _json(self, system: str, user: dict, model: type[BaseModel], max_tokens: int) -> BaseModel:
        body = {"model": self.model, "temperature": 0, "response_format": {"type": "json_object"},
                "max_completion_tokens": max_tokens,     # also bounds what counts against tokens/minute
                "messages": [{"role": "system", "content": system},
                             {"role": "user", "content": json.dumps(user, default=str)}]}
        if self.model.startswith("openai/gpt-oss"):
            body["reasoning_effort"] = "low"     # keep latency and token use down
        try:
            r = self.client.post("/chat/completions", json=body)
            if r.status_code == 429 and float(r.headers.get("retry-after") or 99) <= _MAX_RETRY_WAIT:
                time.sleep(float(r.headers["retry-after"]))   # free tier: short waits are common
                r = self.client.post("/chat/completions", json=body)
            r.raise_for_status()
            return model.model_validate_json(r.json()["choices"][0]["message"]["content"])
        except httpx.HTTPStatusError as e:
            log.warning("Groq HTTP %s", e.response.status_code)
            raise LlmUnavailable("rate_limited" if e.response.status_code == 429 else "unavailable")
        except httpx.HTTPError as e:
            log.warning("Groq unreachable: %s", type(e).__name__)
            raise LlmUnavailable("unavailable")
        except (ValidationError, KeyError, IndexError, TypeError, ValueError):
            log.warning("Groq reply did not match the %s schema", model.__name__)
            raise LlmUnavailable("bad_output")

    def plan(self, product: str, question: str, tools: list[dict], history: list[dict], today: date) -> Plan:
        return self._json(_PLAN_SYSTEM.format(product=product, today=today.isoformat()),
                          {"question": question, "allowed_tools": tools, "earlier_turns": history}, Plan, 600)

    def answer(self, question: str, tool_result: dict) -> str:
        return self._json(_ANSWER_SYSTEM, {"question": question, "tool_result": tool_result}, Answer, 800).answer
