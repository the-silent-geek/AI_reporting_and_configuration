"""Smart Assistance chat (docs_ai/02). One POST per user message."""
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from fastapi.concurrency import run_in_threadpool
from pydantic import BaseModel, Field

from .. import db
from ..assistant import service
from ..security import Principal, current_user, product

router = APIRouter(prefix="/api/apps/{app_code}/assistant", tags=["assistant"])


class ChatIn(BaseModel):
    message: str = Field(min_length=1, max_length=2000)
    conversation_id: UUID | None = None


@router.post("/chat")
async def chat(body: ChatIn, app: str = Depends(product), me: Principal = Depends(current_user)):
    """{message, conversation_id?} -> {conversation_id, status, answer, clarification_question,
    tool_name, grounded, sources, result}. status: answered | clarification | refused | error."""
    if not await run_in_threadpool(db.call, "iam", "iam.fn_has_permission", me.user_id, app, "assistant.use"):
        raise HTTPException(403, "Not allowed to use Smart Assistance in this app")
    if not service.enabled():
        raise HTTPException(503, "Smart Assistance is not configured (GROQ_API_KEY)")
    return await run_in_threadpool(service.run_turn, app, me.user_id, body.conversation_id, body.message)
