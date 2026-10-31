"""SSO: dashboard cards and entering an app (sidebar + permissions)."""
from fastapi import APIRouter, Depends, HTTPException
from datetime import date

from .. import db
from ..security import Principal, current_user, product

router = APIRouter(prefix="/api/apps", tags=["apps"])


@router.get('/{app_code}/dashboard')
def business_dashboard(start_date: date, end_date: date,
                       app: str = Depends(product), me: Principal = Depends(current_user)):
    return db.call(app, f'{app}.fn_business_dashboard', me.user_id, start_date, end_date)


@router.get("")
def my_apps(me: Principal = Depends(current_user)):
    """Dashboard cards: only apps the user has a role in."""
    return db.call("iam", "iam.fn_get_user_apps", me.user_id)


@router.post("/{app_code}/select")
def select_app(app: str = Depends(product), me: Principal = Depends(current_user)):
    """User clicked a card -> roles, permissions and sidebar for that app."""
    r = db.call("iam", "iam.sp_select_app", me.session_id, app)
    if r["status"] == "FORBIDDEN":
        raise HTTPException(403, {"status": "FORBIDDEN"})
    if r["status"] != "OK":
        raise HTTPException(401, {"status": r["status"]})
    return r
