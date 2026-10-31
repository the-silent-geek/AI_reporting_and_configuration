"""Access tokens and the request-level auth dependency.

Access token  = short-lived JWT (sub=user_id, sid=session_id) sent as Bearer header.
Refresh token = random string from the DB, kept in an httpOnly cookie, rotated on use.
Every request also asks the DB whether the session is still alive, so logout,
disabling a user or a password change take effect immediately.
"""
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from uuid import UUID

import jwt
from fastapi import Depends, HTTPException, Path
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from . import db
from .config import PRODUCTS, settings

REFRESH_COOKIE = "refresh_token"
_bearer = HTTPBearer(auto_error=False)


@dataclass(frozen=True)
class Principal:
    user_id: UUID
    session_id: UUID


def create_access_token(user_id: str, session_id: str) -> str:
    now = datetime.now(timezone.utc)
    return jwt.encode(
        {"sub": str(user_id), "sid": str(session_id), "iat": now,
         "exp": now + timedelta(minutes=settings.access_token_minutes)},
        settings.jwt_secret, algorithm="HS256")


def current_user(creds: HTTPAuthorizationCredentials | None = Depends(_bearer)) -> Principal:
    if creds is None:
        raise HTTPException(401, "Not authenticated")
    try:
        claims = jwt.decode(creds.credentials, settings.jwt_secret, algorithms=["HS256"],
                            options={"require": ["sub", "sid", "exp"]})
        principal = Principal(UUID(claims["sub"]), UUID(claims["sid"]))
    except (jwt.PyJWTError, ValueError):
        raise HTTPException(401, "Invalid or expired token")
    if not db.call("iam", "iam.fn_session_is_active", principal.session_id):
        raise HTTPException(401, "Session ended")
    return principal


def product(app_code: str = Path(description="ERP, AML or LENDING")) -> str:
    """Path param -> schema/pool name. Unknown app -> 404."""
    name = app_code.lower()
    if name not in PRODUCTS:
        raise HTTPException(404, "Unknown app")
    return name
