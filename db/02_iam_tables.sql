-- =============================================================================
-- 02_iam_tables.sql
--
-- RBAC model (roles are granted PER APP, not globally):
--
--   app_user --< user_app_role >-- role --< role_permission >-- permission
--                     |
--                    app  --< menu_item (sidebar, gated by required_permission)
--
-- A user can be ANALYST in ERP and only VIEWER in Lending at the same time.
-- Dashboard cards = apps where the user holds at least one role.
-- Sidebar        = menu items whose required permission the user holds in that app.
-- =============================================================================

-- Shared trigger: keep updated_at honest without trusting the caller.
CREATE OR REPLACE FUNCTION iam.tg_set_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END $$;

-- -----------------------------------------------------------------------------
-- app: the products shown as dashboard cards (ERP, AML, LENDING).
-- schema_name tells product-schema functions which app they belong to.
-- -----------------------------------------------------------------------------
CREATE TABLE iam.app (
    app_id       smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code         text NOT NULL UNIQUE CHECK (code = upper(code)),  -- 'ERP', 'AML', 'LENDING'
    name         text NOT NULL,
    description  text,
    icon         text,                    -- icon key the React app maps to a component
    route        text NOT NULL,           -- base route in the UI, e.g. '/app/erp'
    schema_name  text NOT NULL UNIQUE,    -- backing schema, e.g. 'erp'
    sort_order   smallint NOT NULL DEFAULT 0,
    is_active    boolean NOT NULL DEFAULT true
);
COMMENT ON TABLE iam.app IS 'Products available through SSO; each maps to its own schema.';

-- -----------------------------------------------------------------------------
-- app_user: login identity. Password stored as bcrypt hash only.
-- "app_user" not "user" (reserved word).
-- -----------------------------------------------------------------------------
CREATE TABLE iam.app_user (
    user_id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    email               citext NOT NULL UNIQUE,      -- case-insensitive unique
    full_name           text NOT NULL,
    password_hash       text NOT NULL,               -- bcrypt via pgcrypto crypt()
    is_super_admin      boolean NOT NULL DEFAULT false, -- bypasses per-app RBAC, can manage everything
    is_active           boolean NOT NULL DEFAULT true,
    failed_login_count  smallint NOT NULL DEFAULT 0,  -- reset on success
    locked_until        timestamptz,                  -- set after too many failures
    last_login_at       timestamptz,
    created_by          uuid REFERENCES iam.app_user(user_id),
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER trg_app_user_updated BEFORE UPDATE ON iam.app_user
    FOR EACH ROW EXECUTE FUNCTION iam.tg_set_updated_at();
COMMENT ON TABLE iam.app_user IS 'User accounts. Never read password_hash outside iam functions.';

-- -----------------------------------------------------------------------------
-- role: a named bundle of permissions. Same role definitions are reused per app.
-- -----------------------------------------------------------------------------
CREATE TABLE iam.role (
    role_id      smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code         text NOT NULL UNIQUE CHECK (code = upper(code)),  -- 'APP_ADMIN', 'ANALYST', ...
    name         text NOT NULL,
    description  text
);

-- -----------------------------------------------------------------------------
-- permission: the smallest checkable action, '<area>.<action>' e.g. 'batch.commit'.
-- The backend asks fn_has_permission(user, app, code); it never checks role names.
-- -----------------------------------------------------------------------------
CREATE TABLE iam.permission (
    permission_id  smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code           text NOT NULL UNIQUE CHECK (code ~ '^[a-z_]+(\.[a-z_]+)+$'),
    description    text
);

CREATE TABLE iam.role_permission (
    role_id        smallint NOT NULL REFERENCES iam.role(role_id) ON DELETE CASCADE,
    permission_id  smallint NOT NULL REFERENCES iam.permission(permission_id) ON DELETE CASCADE,
    PRIMARY KEY (role_id, permission_id)
);

-- -----------------------------------------------------------------------------
-- user_app_role: the actual grant. (user, app, role) - a user may hold several
-- roles in one app; permissions are the union.
-- -----------------------------------------------------------------------------
CREATE TABLE iam.user_app_role (
    user_id     uuid NOT NULL REFERENCES iam.app_user(user_id) ON DELETE CASCADE,
    app_id      smallint NOT NULL REFERENCES iam.app(app_id),
    role_id     smallint NOT NULL REFERENCES iam.role(role_id),
    granted_by  uuid REFERENCES iam.app_user(user_id),
    granted_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, app_id, role_id)
);
CREATE INDEX ix_user_app_role_app ON iam.user_app_role(app_id);  -- "list users of app X"

-- -----------------------------------------------------------------------------
-- menu_item: sidebar entries. app_id NULL = shown in every app (shared workspace
-- navigation from the brief). Max 2 levels (parent -> children).
-- required_permission_id NULL = visible to anyone with access to the app.
-- -----------------------------------------------------------------------------
CREATE TABLE iam.menu_item (
    menu_item_id            smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    app_id                  smallint REFERENCES iam.app(app_id),
    parent_id               smallint REFERENCES iam.menu_item(menu_item_id) ON DELETE CASCADE,
    code                    text NOT NULL UNIQUE,
    label                   text NOT NULL,
    route                   text NOT NULL,       -- relative to the app route, e.g. '/datasets'
    icon                    text,
    sort_order              smallint NOT NULL DEFAULT 0,
    required_permission_id  smallint REFERENCES iam.permission(permission_id),
    is_active               boolean NOT NULL DEFAULT true
);

-- -----------------------------------------------------------------------------
-- user_session: one row per refresh token. Only the sha256 of the token is
-- stored, so a DB leak does not leak usable tokens.
-- Rotation: each refresh revokes the old row (reason ROTATED) and creates a new
-- one. Presenting a ROTATED token again = theft -> all user sessions revoked.
-- -----------------------------------------------------------------------------
CREATE TABLE iam.user_session (
    session_id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id             uuid NOT NULL REFERENCES iam.app_user(user_id) ON DELETE CASCADE,
    app_id              smallint REFERENCES iam.app(app_id),   -- app picked after login (SSO context)
    refresh_token_hash  bytea NOT NULL UNIQUE,
    created_at          timestamptz NOT NULL DEFAULT now(),
    expires_at          timestamptz NOT NULL,
    revoked_at          timestamptz,
    revoke_reason       text CHECK (revoke_reason IN ('LOGOUT','ROTATED','TOKEN_REUSE','PASSWORD_CHANGED','USER_DISABLED')),
    ip                  inet,
    user_agent          text
);
CREATE INDEX ix_user_session_user_active ON iam.user_session(user_id) WHERE revoked_at IS NULL;

-- -----------------------------------------------------------------------------
-- audit_log: append-only trail of security events (logins, role changes, ...).
-- -----------------------------------------------------------------------------
CREATE TABLE iam.audit_log (
    audit_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    occurred_at    timestamptz NOT NULL DEFAULT now(),
    actor_user_id  uuid REFERENCES iam.app_user(user_id),
    app_id         smallint REFERENCES iam.app(app_id),
    action         text NOT NULL,          -- e.g. LOGIN_SUCCESS, ROLE_ASSIGNED
    target_type    text,
    target_id      text,
    details        jsonb NOT NULL DEFAULT '{}',
    ip             inet
);
CREATE INDEX ix_audit_log_time  ON iam.audit_log(occurred_at DESC);
CREATE INDEX ix_audit_log_actor ON iam.audit_log(actor_user_id, occurred_at DESC);
