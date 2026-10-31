"""Runs one chat turn: load conversation -> graph -> save conversation.

DbBackend is the only place the assistant touches PostgreSQL, and only through
the functions of db/07_smart_assistance.sql, as the product's own login.
"""
import logging
from functools import lru_cache

from fastapi import HTTPException

from .. import db
from ..config import settings
from .graph import ToolDenied, ToolRejected, build_graph, initial_state, to_response
from .llm import GroqAgent
from .tools import Tool

log = logging.getLogger(__name__)


class DbBackend:
    def has_permission(self, user_id, app, permission) -> bool:
        return bool(db.call("iam", "iam.fn_has_permission", user_id, app, permission))

    def call_tool(self, tool: Tool, user_id, args: dict) -> dict:
        try:
            return db.call(tool.product, tool.function, user_id, *(args.get(p) for p in tool.params))
        except HTTPException as e:
            if e.status_code == 403:
                raise ToolDenied() from e
            if e.status_code == 400:
                raise ToolRejected(f"{e.detail}.") from e
            raise

    def audit(self, app, user_id, conversation_id, question, intent, tool_name, arguments, period,
              result_reference, outcome) -> None:
        db.call(app, f"{app}.sp_assistant_audit", user_id, conversation_id, question, intent, tool_name,
                arguments, period, result_reference, outcome)


@lru_cache(maxsize=1)
def _graph():
    agent = GroqAgent(settings.groq_api_key, settings.groq_model, settings.groq_base_url,
                      settings.groq_timeout_seconds)
    return build_graph(DbBackend(), agent)


def enabled() -> bool:
    return bool(settings.groq_api_key)


def run_turn(app: str, user_id, conversation_id, message: str, graph=None) -> dict:
    """One user message -> one assistant reply. A new conversation is created on the
    first turn so the audit row can point at it."""
    graph = graph or _graph()
    if conversation_id is None:
        conversation_id = db.call(app, f"{app}.sp_assistant_save_conversation", user_id, None, {})
        memory = {}
    else:
        memory = db.call(app, f"{app}.fn_assistant_get_conversation", user_id, conversation_id)   # 404 if not theirs
    state = graph.invoke(initial_state(app, str(user_id), str(conversation_id), message, memory))
    db.call(app, f"{app}.sp_assistant_save_conversation", user_id, conversation_id, state.get("memory") or {})
    log.info("assistant %s user=%s outcome=%s tool=%s", app, user_id, state["outcome"],
             (state.get("tool_plan") or {}).get("tool_name"))
    return to_response(state, str(conversation_id))
