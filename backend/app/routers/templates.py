"""Thin HTTP facade for the maker-checker template workflow."""
from typing import Any, Literal
from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field
from .. import db
from ..security import Principal, current_user, product
router = APIRouter(prefix='/api/apps/{app_code}/templates', tags=['templates'])
class Draft(BaseModel):
    code: str = Field(pattern=r'^[A-Z][A-Z0-9_]{2,49}$'); kind: Literal['REPORT','DOCUMENT']; name: str; root_entity: str; definition: dict[str,Any]
class Review(BaseModel): approve: bool; comment: str | None = None
class Render(BaseModel): record_key: str; version: int | None = None
@router.get('/record/preview')
def record_preview(entity: str, record_key: str, app: str=Depends(product), me: Principal=Depends(current_user)):
    return db.call(app, f'{app}.fn_record_template', me.user_id, entity, record_key)
@router.get('')
def list_templates(app: str=Depends(product),me:Principal=Depends(current_user)): return db.call(app,f'{app}.fn_list_templates',me.user_id)
@router.get('/{code}')
def get_template(code:str,app:str=Depends(product),me:Principal=Depends(current_user)): return db.call(app,f'{app}.fn_get_template',me.user_id,code)
@router.post('/draft')
def save(x:Draft,app:str=Depends(product),me:Principal=Depends(current_user)): return db.call(app,f'{app}.sp_save_template_draft',me.user_id,x.code,x.kind,x.name,x.root_entity,x.definition)
@router.post('/{code}/submit')
def submit(code:str,app:str=Depends(product),me:Principal=Depends(current_user)): return db.call(app,f'{app}.sp_submit_template',me.user_id,code)
@router.post('/{code}/{version}/review')
def review(code:str,version:int,x:Review,app:str=Depends(product),me:Principal=Depends(current_user)): return db.call(app,f'{app}.sp_review_template',me.user_id,code,version,x.approve,x.comment)
@router.post('/{code}/{version}/publish')
def publish(code:str,version:int,app:str=Depends(product),me:Principal=Depends(current_user)): return db.call(app,f'{app}.sp_publish_template',me.user_id,code,version)
@router.post('/{code}/render')
def render(code:str,x:Render,app:str=Depends(product),me:Principal=Depends(current_user)): return db.call(app,f'{app}.fn_render_document',me.user_id,code,x.record_key,x.version)
