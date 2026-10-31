"""User and role administration. Authorization is enforced by the DB functions
(admin.users in the app, or super admin); they raise 42501 -> 403."""
from uuid import UUID

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field

from .. import db
from ..security import Principal, current_user, product

router = APIRouter(prefix="/api", tags=["admin"])


class CreateUserIn(BaseModel):
    email: str = Field(max_length=254)
    full_name: str = Field(max_length=200)
    password: str = Field(max_length=200)
    is_super_admin: bool = False


class RoleIn(BaseModel):
    role: str = Field(max_length=50)


class ActiveIn(BaseModel):
    is_active: bool


@router.get("/apps/{app_code}/admin/users")
def list_users(app: str = Depends(product), me: Principal = Depends(current_user)):
    return db.call("iam", "iam.fn_list_users", me.user_id, app)


@router.post("/admin/users", status_code=201)
def create_user(body: CreateUserIn, me: Principal = Depends(current_user)):
    user_id = db.call("iam", "iam.sp_create_user", me.user_id, body.email, body.full_name,
                      body.password, body.is_super_admin)
    return {"user_id": user_id}


@router.post("/apps/{app_code}/admin/users/{user_id}/roles")
def assign_role(user_id: UUID, body: RoleIn, app: str = Depends(product), me: Principal = Depends(current_user)):
    return {"changed": db.call("iam", "iam.sp_assign_role", me.user_id, user_id, app, body.role)}


@router.delete("/apps/{app_code}/admin/users/{user_id}/roles/{role}")
def revoke_role(user_id: UUID, role: str, app: str = Depends(product), me: Principal = Depends(current_user)):
    return {"changed": db.call("iam", "iam.sp_revoke_role", me.user_id, user_id, app, role)}


@router.patch("/admin/users/{user_id}")
def set_active(user_id: UUID, body: ActiveIn, me: Principal = Depends(current_user)):
    db.call("iam", "iam.sp_set_user_active", me.user_id, user_id, body.is_active)
    return {"user_id": user_id, "is_active": body.is_active}
