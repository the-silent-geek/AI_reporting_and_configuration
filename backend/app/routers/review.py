"""Mapping review + data quality (db/08_mapping_quality.sql).

Every rule lives in the DB functions; these routes only pass the user through and
push the batch's new status to open SSE streams, like commit does.
"""
from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends
from fastapi.concurrency import run_in_threadpool
from pydantic import BaseModel, Field

from .. import db
from ..broker import broker, latest_event
from ..security import Principal, current_user, product

router = APIRouter(prefix="/api/apps/{app_code}", tags=["review"])


class ApproveMappingIn(BaseModel):
    target_entity: str = Field(min_length=1, max_length=63)
    mappings: list[dict[str, Any]] = Field(max_length=500)   # [{source_field, target_field, transform}]


class CorrectIn(BaseModel):
    field: str = Field(min_length=1, max_length=63)
    value: str | None = Field(None, max_length=1000)


class RejectIn(BaseModel):
    reason: str = Field(min_length=1, max_length=500)


async def _changed(app: str, batch_id: UUID, result: dict) -> dict:
    """The function moved the batch through VALIDATING; tell the batch pages."""
    await broker.broadcast(await run_in_threadpool(latest_event, app, str(batch_id)))
    return result


@router.get("/review/queue")
def review_queue(app: str = Depends(product), me: Principal = Depends(current_user)):
    """{mapping: [batches waiting for mapping], quality: [batches being validated/fixed]}"""
    return db.call(app, f"{app}.fn_review_queue", me.user_id)


@router.get("/batches/{batch_id}/mapping")
def get_mapping(batch_id: UUID, app: str = Depends(product), me: Principal = Depends(current_user)):
    return db.call(app, f"{app}.fn_get_mapping", me.user_id, batch_id)


@router.post("/batches/{batch_id}/mapping/approve")
async def approve_mapping(batch_id: UUID, body: ApproveMappingIn, app: str = Depends(product),
                          me: Principal = Depends(current_user)):
    r = await run_in_threadpool(db.call, app, f"{app}.sp_approve_mapping", me.user_id, batch_id,
                                body.target_entity, body.mappings)
    return await _changed(app, batch_id, r)


@router.get("/batches/{batch_id}/issues")
def list_issues(batch_id: UUID, app: str = Depends(product), me: Principal = Depends(current_user)):
    return db.call(app, f"{app}.fn_list_issues", me.user_id, batch_id)


@router.post("/batches/{batch_id}/records/{record_no}/correct")
async def correct_value(batch_id: UUID, record_no: int, body: CorrectIn, app: str = Depends(product),
                        me: Principal = Depends(current_user)):
    r = await run_in_threadpool(db.call, app, f"{app}.sp_correct_value", me.user_id, batch_id, record_no,
                                body.field, body.value)
    return await _changed(app, batch_id, r)


@router.post("/batches/{batch_id}/records/{record_no}/reject")
async def reject_record(batch_id: UUID, record_no: int, body: RejectIn, app: str = Depends(product),
                        me: Principal = Depends(current_user)):
    r = await run_in_threadpool(db.call, app, f"{app}.sp_reject_record", me.user_id, batch_id, record_no, body.reason)
    return await _changed(app, batch_id, r)


@router.post("/batches/{batch_id}/issues/{issue_id}/confirm")
async def confirm_issue(batch_id: UUID, issue_id: int, app: str = Depends(product),
                        me: Principal = Depends(current_user)):
    r = await run_in_threadpool(db.call, app, f"{app}.sp_confirm_issue", me.user_id, batch_id, issue_id)
    return await _changed(app, batch_id, r)


@router.post("/batches/{batch_id}/validate")
async def revalidate(batch_id: UUID, app: str = Depends(product), me: Principal = Depends(current_user)):
    r = await run_in_threadpool(db.call, app, f"{app}.sp_revalidate_batch", me.user_id, batch_id)
    return await _changed(app, batch_id, r)
