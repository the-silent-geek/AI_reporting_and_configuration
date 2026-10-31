"""Login, token refresh, logout, password change.

The refresh token never reaches JavaScript: it lives in an httpOnly,
SameSite=Strict cookie scoped to /api/auth. The access token is returned in
the body and kept in memory by the UI.
"""
from fastapi import APIRouter, Cookie, Depends, HTTPException, Request, Response
from pydantic import BaseModel, Field

from .. import db
from ..config import settings
from ..security import REFRESH_COOKIE, Principal, create_access_token, current_user

router = APIRouter(prefix="/api/auth", tags=["auth"])

# DB status -> HTTP status for failed logins
_LOGIN_FAIL = {"INVALID_CREDENTIALS": 401, "ACCOUNT_LOCKED": 423, "ACCOUNT_DISABLED": 403}


class LoginIn(BaseModel):
    email: str = Field(max_length=254)
    password: str = Field(max_length=200)


class ChangePasswordIn(BaseModel):
    old_password: str = Field(max_length=200)
    new_password: str = Field(max_length=200)


def _set_refresh_cookie(resp: Response, session: dict) -> None:
    resp.set_cookie(REFRESH_COOKIE, session["refresh_token"], httponly=True, secure=settings.cookie_secure,
                    samesite="strict", path="/api/auth", max_age=7 * 24 * 3600)


def _client(req: Request) -> tuple[str | None, str | None]:
    return (req.client.host if req.client else None), req.headers.get("user-agent")


@router.post("/login")
def login(body: LoginIn, request: Request, response: Response):
    r = db.call("iam", "iam.sp_login", body.email, body.password, *_client(request))
    if r["status"] != "OK":
        raise HTTPException(_LOGIN_FAIL.get(r["status"], 401),
                            {"status": r["status"], "locked_until": r.get("locked_until")})
    _set_refresh_cookie(response, r["session"])
    return {"access_token": create_access_token(r["user"]["user_id"], r["session"]["session_id"]),
            "token_type": "bearer", "user": r["user"], "apps": r["apps"]}


@router.post("/refresh")
def refresh(request: Request, response: Response, refresh_token: str | None = Cookie(None)):
    if not refresh_token:
        raise HTTPException(401, {"status": "NO_REFRESH_TOKEN"})
    r = db.call("iam", "iam.sp_refresh_session", refresh_token, *_client(request))
    if r["status"] != "OK":
        # an HTTPException drops `response`, so clear the cookie via its own header
        raise HTTPException(401, {"status": r["status"]},
                            headers={"set-cookie": f"{REFRESH_COOKIE}=; Max-Age=0; Path=/api/auth"})
    _set_refresh_cookie(response, r["session"])
    return {"access_token": create_access_token(r["user"]["user_id"], r["session"]["session_id"]),
            "token_type": "bearer", "user": r["user"], "app_code": r["app_code"]}


@router.post("/logout", status_code=204)
def logout(response: Response, me: Principal = Depends(current_user)):
    db.call("iam", "iam.sp_logout", me.session_id)
    response.delete_cookie(REFRESH_COOKIE, path="/api/auth")


@router.post("/change-password")
def change_password(body: ChangePasswordIn, me: Principal = Depends(current_user)):
    r = db.call("iam", "iam.sp_change_password", me.user_id, body.old_password, body.new_password, me.session_id)
    if r["status"] != "OK":
        raise HTTPException(400, {"status": r["status"]})
    return r
