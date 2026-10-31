"""Report catalogue and reproducible report runs."""
from typing import Any
from uuid import UUID
from fastapi import APIRouter, Depends
from pydantic import BaseModel
from .. import db
from ..assistant.tools import TOOLS
from ..security import Principal, current_user, product

router = APIRouter(prefix='/api/apps/{app_code}/reports', tags=['reports'])
class RunIn(BaseModel): params: dict[str, Any] = {}

@router.get('')
def list_reports(app: str = Depends(product), me: Principal = Depends(current_user)):
    data = db.call(app, f'{app}.fn_list_reports', me.user_id)
    for report in data['reports']:
        tool = TOOLS.get(report['definition'].get('dataset'))
        report['parameter_schema'] = tool.args.model_json_schema() if tool else {}
    return data

@router.post('/{code}/run')
def run(code: str, body: RunIn, app: str = Depends(product), me: Principal = Depends(current_user)):
    # The DB owns report selection; validating with its published tool schema
    # makes malformed requests fail before any report data is read.
    reports = db.call(app, f'{app}.fn_list_reports', me.user_id)['reports']
    report = next((x for x in reports if x['template_code'] == code), None)
    if report is None: return db.call(app, f'{app}.sp_run_report', me.user_id, code, body.params)
    tool = TOOLS[report['definition']['dataset']]
    params = tool.args.model_validate(body.params).model_dump(mode='json')
    return db.call(app, f'{app}.sp_run_report', me.user_id, code, params)

@router.get('/runs')
def runs(limit: int = 20, app: str = Depends(product), me: Principal = Depends(current_user)):
    return db.call(app, f'{app}.fn_list_report_runs', me.user_id, limit)
@router.get('/runs/{run_id}')
def get_run(run_id: UUID, app: str = Depends(product), me: Principal = Depends(current_user)):
    return db.call(app, f'{app}.fn_get_report_run', me.user_id, run_id)
