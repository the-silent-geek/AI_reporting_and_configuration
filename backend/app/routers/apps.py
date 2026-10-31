"""SSO: dashboard cards and entering an app (sidebar + permissions)."""
from fastapi import APIRouter, Depends, HTTPException

from .. import db
from ..security import Principal, current_user, product

router = APIRouter(prefix="/api/apps", tags=["apps"])


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
