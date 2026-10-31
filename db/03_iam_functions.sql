-- =============================================================================
-- 03_iam_functions.sql  -  auth, session, RBAC and user-admin logic.
--
-- Conventions
--   sp_*  changes data        fn_*  read-only        _*  internal helper (not granted)
--   All public functions are SECURITY DEFINER with a pinned search_path: the
--   backend role (iam_app) has NO table privileges and can only call these.
--   They are FUNCTIONS (not PROCEDUREs) so the backend can simply
--   `SELECT iam.sp_login(...)` and get a JSON result back.
--
-- Error contract (backend maps SQLSTATE -> HTTP):
--   42501 insufficient_privilege  -> 403
--   22023 invalid_parameter_value -> 400
--   P0002 no_data_found           -> 404
--   23505 unique_violation        -> 409
--   Expected auth outcomes (bad password, locked, ...) are NOT errors: they are
--   returned as {"status": "..."} so the failed-attempt counter is committed.
-- =============================================================================

-- ---------------------------------------------------------------- helpers ----

-- Write one audit row.
CREATE OR REPLACE FUNCTION iam._audit(
    p_actor uuid, p_app_id smallint, p_action text,
    p_target_type text DEFAULT NULL, p_target_id text DEFAULT NULL,
    p_details jsonb DEFAULT '{}', p_ip inet DEFAULT NULL
) RETURNS void
LANGUAGE sql SET search_path = iam, public, pg_temp AS $$
    INSERT INTO audit_log (actor_user_id, app_id, action, target_type, target_id, details, ip)
    VALUES (p_actor, p_app_id, p_action, p_target_type, p_target_id, coalesce(p_details, '{}'), p_ip);
$$;

-- bcrypt, cost 10 (OWASP minimum). Higher cost = more DB CPU per login.
CREATE OR REPLACE FUNCTION iam._hash_password(p_password text) RETURNS text
LANGUAGE sql VOLATILE SET search_path = iam, public, pg_temp AS $$
    SELECT crypt(p_password, gen_salt('bf', 10));
$$;

-- Password policy lives in one place.
CREATE OR REPLACE FUNCTION iam._check_password_policy(p_password text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF p_password IS NULL OR length(p_password) < 8
       OR p_password !~ '[A-Za-z]' OR p_password !~ '[0-9]' THEN
        RAISE EXCEPTION 'Password must be at least 8 characters and contain a letter and a digit'
            USING ERRCODE = '22023';
    END IF;
END $$;

-- Resolve an active app code to its id, or fail with 22023.
CREATE OR REPLACE FUNCTION iam._app_id(p_app_code text) RETURNS smallint
LANGUAGE plpgsql STABLE SET search_path = iam, public, pg_temp AS $$
DECLARE v_id smallint;
BEGIN
    SELECT app_id INTO v_id FROM app WHERE code = upper(p_app_code) AND is_active;
    IF v_id IS NULL THEN
        RAISE EXCEPTION 'Unknown or inactive app: %', p_app_code USING ERRCODE = '22023';
    END IF;
    RETURN v_id;
END $$;

-- Create a session row; returns the RAW refresh token once (only its hash is stored).
CREATE OR REPLACE FUNCTION iam._new_session(
    p_user_id uuid, p_app_id smallint, p_ip inet, p_user_agent text,
    p_ttl interval DEFAULT interval '7 days'
) RETURNS jsonb
LANGUAGE plpgsql SET search_path = iam, public, pg_temp AS $$
DECLARE
    v_token text := encode(gen_random_bytes(32), 'hex');  -- 256-bit random token
    v_row   user_session;
BEGIN
    INSERT INTO user_session (user_id, app_id, refresh_token_hash, expires_at, ip, user_agent)
    VALUES (p_user_id, p_app_id, digest(v_token, 'sha256'), now() + p_ttl, p_ip, p_user_agent)
    RETURNING * INTO v_row;

    RETURN jsonb_build_object(
        'session_id',    v_row.session_id,
        'refresh_token', v_token,
        'expires_at',    v_row.expires_at);
END $$;

-- Public user shape returned to the backend (never includes the hash).
CREATE OR REPLACE FUNCTION iam._user_json(p_user_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SET search_path = iam, public, pg_temp AS $$
    SELECT jsonb_build_object('user_id', user_id, 'email', email, 'full_name', full_name,
                              'is_super_admin', is_super_admin)
    FROM app_user WHERE user_id = p_user_id;
$$;

-- ------------------------------------------------------------ RBAC reads ----

-- THE authorization check. Backend calls this before every protected action.
-- Super admins pass for any active app; others need the permission via a role in that app.
CREATE OR REPLACE FUNCTION iam.fn_has_permission(p_user_id uuid, p_app_code text, p_permission text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = iam, public, pg_temp AS $$
    SELECT EXISTS (
        SELECT 1
        FROM app a
        JOIN app_user u ON u.user_id = p_user_id
        WHERE a.code = upper(p_app_code) AND a.is_active AND u.is_active
          AND (u.is_super_admin OR EXISTS (
                SELECT 1
                FROM user_app_role uar
                JOIN role_permission rp USING (role_id)
                JOIN permission p USING (permission_id)
                WHERE uar.user_id = u.user_id AND uar.app_id = a.app_id AND p.code = p_permission)));
$$;

-- All permission codes the user holds in one app (sent to the UI to show/hide buttons).
CREATE OR REPLACE FUNCTION iam.fn_get_user_permissions(p_user_id uuid, p_app_code text)
RETURNS text[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = iam, public, pg_temp AS $$
    SELECT coalesce(array_agg(DISTINCT p.code ORDER BY p.code), '{}')
    FROM app a
    JOIN app_user u ON u.user_id = p_user_id AND u.is_active
    JOIN permission p ON true
    WHERE a.code = upper(p_app_code) AND a.is_active
      AND (u.is_super_admin OR EXISTS (
            SELECT 1 FROM user_app_role uar JOIN role_permission rp USING (role_id)
            WHERE uar.user_id = u.user_id AND uar.app_id = a.app_id AND rp.permission_id = p.permission_id));
$$;

-- Dashboard cards: every active app the user can enter, with their roles there.
CREATE OR REPLACE FUNCTION iam.fn_get_user_apps(p_user_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = iam, public, pg_temp AS $$
    SELECT coalesce(jsonb_agg(jsonb_build_object(
               'code', a.code, 'name', a.name, 'description', a.description,
               'icon', a.icon, 'route', a.route, 'roles', r.roles)
           ORDER BY a.sort_order), '[]'::jsonb)
    FROM app a
    JOIN app_user u ON u.user_id = p_user_id AND u.is_active
    CROSS JOIN LATERAL (
        SELECT coalesce(jsonb_agg(ro.code ORDER BY ro.code), '[]'::jsonb) AS roles
        FROM user_app_role uar JOIN role ro USING (role_id)
        WHERE uar.user_id = u.user_id AND uar.app_id = a.app_id) r
    WHERE a.is_active
      AND (u.is_super_admin OR jsonb_array_length(r.roles) > 0);
$$;

-- Sidebar tree for one app, filtered by the user's permissions there.
-- Returns [] if the user has no access to the app at all.
CREATE OR REPLACE FUNCTION iam.fn_get_sidebar(p_user_id uuid, p_app_code text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = iam, public, pg_temp AS $$
DECLARE
    v_perms  text[] := fn_get_user_permissions(p_user_id, p_app_code);
    v_app_id smallint;
    v_result jsonb;
BEGIN
    IF cardinality(v_perms) = 0 THEN
        RETURN '[]'::jsonb;    -- no role in this app -> no menu
    END IF;
    v_app_id := _app_id(p_app_code);

    WITH visible AS (
        SELECT m.*
        FROM menu_item m
        LEFT JOIN permission p ON p.permission_id = m.required_permission_id
        WHERE m.is_active
          AND (m.app_id IS NULL OR m.app_id = v_app_id)
          AND (p.code IS NULL OR p.code = ANY (v_perms))
    )
    SELECT coalesce(jsonb_agg(jsonb_build_object(
               'code', v.code, 'label', v.label, 'route', v.route, 'icon', v.icon,
               'children', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                                   'code', c.code, 'label', c.label, 'route', c.route, 'icon', c.icon)
                                   ORDER BY c.sort_order), '[]'::jsonb)
                            FROM visible c WHERE c.parent_id = v.menu_item_id))
           ORDER BY v.sort_order), '[]'::jsonb)
    INTO v_result
    FROM visible v
    WHERE v.parent_id IS NULL;   -- a hidden parent hides its children too

    RETURN v_result;
END $$;

-- -------------------------------------------------------- authentication ----

-- Login: verify password, apply lockout, create session.
-- Returns {"status": OK | INVALID_CREDENTIALS | ACCOUNT_LOCKED | ACCOUNT_DISABLED, ...}
-- On OK also returns user, session (with refresh_token) and apps (dashboard cards).
CREATE OR REPLACE FUNCTION iam.sp_login(
    p_email text, p_password text, p_ip inet DEFAULT NULL, p_user_agent text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = iam, public, pg_temp AS $$
DECLARE
    c_max_attempts constant smallint := 5;
    c_lock_for     constant interval := interval '15 minutes';
    v_user  app_user;
    v_session jsonb;
BEGIN
    -- FOR UPDATE serializes concurrent attempts on the same account (accurate counter).
    SELECT * INTO v_user FROM app_user WHERE email = p_email::citext FOR UPDATE;

    IF NOT FOUND THEN
        -- Burn the same CPU as a real check so response time doesn't reveal which emails exist.
        PERFORM crypt(coalesce(p_password, ''), gen_salt('bf', 10));
        PERFORM _audit(NULL, NULL, 'LOGIN_FAILED', 'email', p_email, '{"reason":"unknown_email"}', p_ip);
        RETURN jsonb_build_object('status', 'INVALID_CREDENTIALS');
    END IF;

    IF v_user.locked_until > now() THEN
        PERFORM _audit(v_user.user_id, NULL, 'LOGIN_BLOCKED', 'user', v_user.user_id::text, '{"reason":"locked"}', p_ip);
        RETURN jsonb_build_object('status', 'ACCOUNT_LOCKED', 'locked_until', v_user.locked_until);
    END IF;

    IF v_user.password_hash <> crypt(coalesce(p_password, ''), v_user.password_hash) THEN
        IF v_user.failed_login_count + 1 >= c_max_attempts THEN
            UPDATE app_user SET failed_login_count = 0, locked_until = now() + c_lock_for
            WHERE user_id = v_user.user_id;
            PERFORM _audit(v_user.user_id, NULL, 'ACCOUNT_LOCKED', 'user', v_user.user_id::text, '{}', p_ip);
        ELSE
            UPDATE app_user SET failed_login_count = failed_login_count + 1 WHERE user_id = v_user.user_id;
        END IF;
        PERFORM _audit(v_user.user_id, NULL, 'LOGIN_FAILED', 'user', v_user.user_id::text, '{"reason":"bad_password"}', p_ip);
        RETURN jsonb_build_object('status', 'INVALID_CREDENTIALS');
    END IF;

    -- Checked after the password so a disabled status is only revealed to the real owner.
    IF NOT v_user.is_active THEN
        PERFORM _audit(v_user.user_id, NULL, 'LOGIN_BLOCKED', 'user', v_user.user_id::text, '{"reason":"disabled"}', p_ip);
        RETURN jsonb_build_object('status', 'ACCOUNT_DISABLED');
    END IF;

    UPDATE app_user SET failed_login_count = 0, locked_until = NULL, last_login_at = now()
    WHERE user_id = v_user.user_id;

    v_session := _new_session(v_user.user_id, NULL, p_ip, p_user_agent);
    PERFORM _audit(v_user.user_id, NULL, 'LOGIN_SUCCESS', 'session', v_session->>'session_id', '{}', p_ip);

    RETURN jsonb_build_object(
        'status',  'OK',
        'user',    _user_json(v_user.user_id),
        'session', v_session,
        'apps',    fn_get_user_apps(v_user.user_id));
END $$;

-- Exchange a refresh token for a new one (rotation).
-- Returns {"status": OK | INVALID | EXPIRED | TOKEN_REUSED | ACCOUNT_DISABLED, ...}
CREATE OR REPLACE FUNCTION iam.sp_refresh_session(
    p_refresh_token text, p_ip inet DEFAULT NULL, p_user_agent text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = iam, public, pg_temp AS $$
DECLARE
    v_s       user_session;
    v_active  boolean;
    v_new     jsonb;
BEGIN
    SELECT * INTO v_s FROM user_session
    WHERE refresh_token_hash = digest(coalesce(p_refresh_token, ''), 'sha256')
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'INVALID');
    END IF;

    -- A token that was already rotated is being replayed: assume it was stolen
    -- and kill every live session of this user.
    IF v_s.revoked_at IS NOT NULL THEN
        IF v_s.revoke_reason = 'ROTATED' THEN
            UPDATE user_session SET revoked_at = now(), revoke_reason = 'TOKEN_REUSE'
            WHERE user_id = v_s.user_id AND revoked_at IS NULL;
            PERFORM _audit(v_s.user_id, v_s.app_id, 'TOKEN_REUSE_DETECTED', 'session', v_s.session_id::text, '{}', p_ip);
            RETURN jsonb_build_object('status', 'TOKEN_REUSED');
        END IF;
        RETURN jsonb_build_object('status', 'INVALID');
    END IF;

    IF v_s.expires_at <= now() THEN
        RETURN jsonb_build_object('status', 'EXPIRED');
    END IF;

    SELECT is_active INTO v_active FROM app_user WHERE user_id = v_s.user_id;
    IF NOT v_active THEN
        UPDATE user_session SET revoked_at = now(), revoke_reason = 'USER_DISABLED' WHERE session_id = v_s.session_id;
        RETURN jsonb_build_object('status', 'ACCOUNT_DISABLED');
    END IF;

    UPDATE user_session SET revoked_at = now(), revoke_reason = 'ROTATED' WHERE session_id = v_s.session_id;
    v_new := _new_session(v_s.user_id, v_s.app_id, p_ip, p_user_agent);   -- keeps the selected app

    RETURN jsonb_build_object(
        'status',   'OK',
        'user',     _user_json(v_s.user_id),
        'session',  v_new,
        'app_code', (SELECT code FROM app WHERE app_id = v_s.app_id));
END $$;

-- Logout = revoke this session. Returns true if something was revoked.
CREATE OR REPLACE FUNCTION iam.sp_logout(p_session_id uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = iam, public, pg_temp AS $$
DECLARE v_user uuid;
BEGIN
    UPDATE user_session SET revoked_at = now(), revoke_reason = 'LOGOUT'
    WHERE session_id = p_session_id AND revoked_at IS NULL
    RETURNING user_id INTO v_user;

    IF v_user IS NOT NULL THEN
        PERFORM _audit(v_user, NULL, 'LOGOUT', 'session', p_session_id::text);
    END IF;
    RETURN v_user IS NOT NULL;
END $$;

-- Per-request check that the session behind an access token is still alive.
-- Makes logout / disable / password change take effect immediately, not after JWT expiry.
CREATE OR REPLACE FUNCTION iam.fn_session_is_active(p_session_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = iam, public, pg_temp AS $$
    SELECT EXISTS (
        SELECT 1 FROM user_session s JOIN app_user u USING (user_id)
        WHERE s.session_id = p_session_id AND s.revoked_at IS NULL
          AND s.expires_at > now() AND u.is_active);
$$;

-- SSO step 2: user clicks a dashboard card. Binds the app to the session and
-- returns everything the UI needs to render that app.
-- Returns {"status": OK | FORBIDDEN | SESSION_INVALID, ...}
CREATE OR REPLACE FUNCTION iam.sp_select_app(p_session_id uuid, p_app_code text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = iam, public, pg_temp AS $$
DECLARE
    v_user  uuid;
    v_app   app;
    v_perms text[];
BEGIN
    IF NOT fn_session_is_active(p_session_id) THEN
        RETURN jsonb_build_object('status', 'SESSION_INVALID');
    END IF;
    SELECT user_id INTO v_user FROM user_session WHERE session_id = p_session_id;
    SELECT * INTO v_app FROM app WHERE app_id = _app_id(p_app_code);

    v_perms := fn_get_user_permissions(v_user, v_app.code);
    IF cardinality(v_perms) = 0 THEN
        PERFORM _audit(v_user, v_app.app_id, 'APP_ACCESS_DENIED', 'app', v_app.code);
        RETURN jsonb_build_object('status', 'FORBIDDEN');
    END IF;

    UPDATE user_session SET app_id = v_app.app_id WHERE session_id = p_session_id;
    PERFORM _audit(v_user, v_app.app_id, 'APP_SELECTED', 'app', v_app.code);

    RETURN jsonb_build_object(
        'status',      'OK',
        'app',         jsonb_build_object('code', v_app.code, 'name', v_app.name, 'route', v_app.route, 'icon', v_app.icon),
        'roles',       (SELECT coalesce(jsonb_agg(r.code ORDER BY r.code), '[]'::jsonb)
                        FROM user_app_role uar JOIN role r USING (role_id)
                        WHERE uar.user_id = v_user AND uar.app_id = v_app.app_id),
        'permissions', to_jsonb(v_perms),
        'sidebar',     fn_get_sidebar(v_user, v_app.code));
END $$;

-- Change own password; revokes every other session of the user.
CREATE OR REPLACE FUNCTION iam.sp_change_password(
    p_user_id uuid, p_old_password text, p_new_password text, p_keep_session_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = iam, public, pg_temp AS $$
DECLARE v_hash text;
BEGIN
    SELECT password_hash INTO v_hash FROM app_user WHERE user_id = p_user_id AND is_active FOR UPDATE;
    IF v_hash IS NULL OR v_hash <> crypt(coalesce(p_old_password, ''), v_hash) THEN
        RETURN jsonb_build_object('status', 'INVALID_CREDENTIALS');
    END IF;
    PERFORM _check_password_policy(p_new_password);

    UPDATE app_user SET password_hash = _hash_password(p_new_password) WHERE user_id = p_user_id;
    UPDATE user_session SET revoked_at = now(), revoke_reason = 'PASSWORD_CHANGED'
    WHERE user_id = p_user_id AND revoked_at IS NULL
      AND session_id IS DISTINCT FROM p_keep_session_id;
    PERFORM _audit(p_user_id, NULL, 'PASSWORD_CHANGED', 'user', p_user_id::text);
    RETURN jsonb_build_object('status', 'OK');
END $$;

-- ------------------------------------------------------- user management ----

-- Create a user. Super admin can create anyone; an APP_ADMIN (admin.users in
-- any app) can create normal users and then assign them roles in their app.
CREATE OR REPLACE FUNCTION iam.sp_create_user(
    p_actor uuid, p_email text, p_full_name text, p_password text,
    p_is_super_admin boolean DEFAULT false
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = iam, public, pg_temp AS $$
DECLARE
    v_actor_super boolean;
    v_id uuid;
BEGIN
    SELECT is_super_admin INTO v_actor_super FROM app_user WHERE user_id = p_actor AND is_active;
    IF NOT coalesce(v_actor_super, false) AND (
           p_is_super_admin
           OR NOT EXISTS (SELECT 1 FROM app a WHERE fn_has_permission(p_actor, a.code, 'admin.users'))) THEN
        RAISE EXCEPTION 'Not allowed to create users' USING ERRCODE = '42501';
    END IF;
    IF coalesce(trim(p_email), '') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
        RAISE EXCEPTION 'Invalid email' USING ERRCODE = '22023';
    END IF;
    IF coalesce(trim(p_full_name), '') = '' THEN
        RAISE EXCEPTION 'Full name is required' USING ERRCODE = '22023';
    END IF;
    PERFORM _check_password_policy(p_password);

    INSERT INTO app_user (email, full_name, password_hash, is_super_admin, created_by)
    VALUES (trim(p_email), trim(p_full_name), _hash_password(p_password), p_is_super_admin, p_actor)
    RETURNING user_id INTO v_id;     -- duplicate email raises 23505

    PERFORM _audit(p_actor, NULL, 'USER_CREATED', 'user', v_id::text,
                   jsonb_build_object('email', trim(p_email), 'is_super_admin', p_is_super_admin));
    RETURN v_id;
END $$;

-- Grant a role in an app. Actor needs admin.users in THAT app.
CREATE OR REPLACE FUNCTION iam.sp_assign_role(p_actor uuid, p_user_id uuid, p_app_code text, p_role_code text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = iam, public, pg_temp AS $$
DECLARE
    v_app_id  smallint := _app_id(p_app_code);
    v_role_id smallint;
    v_rows    int;
BEGIN
    IF NOT fn_has_permission(p_actor, p_app_code, 'admin.users') THEN
        RAISE EXCEPTION 'Not allowed to manage users in %', p_app_code USING ERRCODE = '42501';
    END IF;
    SELECT role_id INTO v_role_id FROM role WHERE code = upper(p_role_code);
    IF v_role_id IS NULL THEN
        RAISE EXCEPTION 'Unknown role: %', p_role_code USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM app_user WHERE user_id = p_user_id) THEN
        RAISE EXCEPTION 'User not found' USING ERRCODE = 'P0002';
    END IF;

    INSERT INTO user_app_role (user_id, app_id, role_id, granted_by)
    VALUES (p_user_id, v_app_id, v_role_id, p_actor)
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS v_rows = ROW_COUNT;

    IF v_rows > 0 THEN
        PERFORM _audit(p_actor, v_app_id, 'ROLE_ASSIGNED', 'user', p_user_id::text,
                       jsonb_build_object('role', upper(p_role_code)));
    END IF;
    RETURN v_rows > 0;   -- false = user already had that role
END $$;

-- Remove a role in an app. Same permission rule as assign.
CREATE OR REPLACE FUNCTION iam.sp_revoke_role(p_actor uuid, p_user_id uuid, p_app_code text, p_role_code text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = iam, public, pg_temp AS $$
DECLARE
    v_app_id smallint := _app_id(p_app_code);
    v_rows   int;
BEGIN
    IF NOT fn_has_permission(p_actor, p_app_code, 'admin.users') THEN
        RAISE EXCEPTION 'Not allowed to manage users in %', p_app_code USING ERRCODE = '42501';
    END IF;

    DELETE FROM user_app_role
    WHERE user_id = p_user_id AND app_id = v_app_id
      AND role_id = (SELECT role_id FROM role WHERE code = upper(p_role_code));
    GET DIAGNOSTICS v_rows = ROW_COUNT;

    IF v_rows > 0 THEN
        PERFORM _audit(p_actor, v_app_id, 'ROLE_REVOKED', 'user', p_user_id::text,
                       jsonb_build_object('role', upper(p_role_code)));
    END IF;
    RETURN v_rows > 0;
END $$;

-- Enable/disable an account (super admin only). Disabling also kills sessions;
-- enabling also clears a lockout.
CREATE OR REPLACE FUNCTION iam.sp_set_user_active(p_actor uuid, p_user_id uuid, p_active boolean)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = iam, public, pg_temp AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM app_user WHERE user_id = p_actor AND is_active AND is_super_admin) THEN
        RAISE EXCEPTION 'Only a super admin can enable or disable users' USING ERRCODE = '42501';
    END IF;
    IF p_actor = p_user_id THEN
        RAISE EXCEPTION 'You cannot change your own active status' USING ERRCODE = '22023';
    END IF;

    UPDATE app_user
    SET is_active = p_active,
        failed_login_count = 0,
        locked_until = NULL
    WHERE user_id = p_user_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'User not found' USING ERRCODE = 'P0002';
    END IF;

    IF NOT p_active THEN
        UPDATE user_session SET revoked_at = now(), revoke_reason = 'USER_DISABLED'
        WHERE user_id = p_user_id AND revoked_at IS NULL;
    END IF;
    PERFORM _audit(p_actor, NULL, CASE WHEN p_active THEN 'USER_ENABLED' ELSE 'USER_DISABLED' END,
                   'user', p_user_id::text);
END $$;

-- Admin screen: all users with their roles in one app (roles [] = no access yet).
CREATE OR REPLACE FUNCTION iam.fn_list_users(p_actor uuid, p_app_code text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = iam, public, pg_temp AS $$
DECLARE
    v_app_id smallint := _app_id(p_app_code);
    v_result jsonb;
BEGIN
    IF NOT fn_has_permission(p_actor, p_app_code, 'admin.users') THEN
        RAISE EXCEPTION 'Not allowed to manage users in %', p_app_code USING ERRCODE = '42501';
    END IF;

    SELECT coalesce(jsonb_agg(jsonb_build_object(
               'user_id', u.user_id, 'email', u.email, 'full_name', u.full_name,
               'is_active', u.is_active, 'is_super_admin', u.is_super_admin,
               'last_login_at', u.last_login_at,
               'locked', coalesce(u.locked_until > now(), false),
               'roles', (SELECT coalesce(jsonb_agg(r.code ORDER BY r.code), '[]'::jsonb)
                         FROM user_app_role uar JOIN role r USING (role_id)
                         WHERE uar.user_id = u.user_id AND uar.app_id = v_app_id))
           ORDER BY u.full_name), '[]'::jsonb)
    INTO v_result
    FROM app_user u;
    RETURN v_result;
END $$;

-- ---------------------------------------------------------------- grants ----
-- Functions are executable by PUBLIC by default in PostgreSQL; lock that down,
-- then open only the public API (no leading underscore) to the backend role.
REVOKE ALL ON ALL TABLES    IN SCHEMA iam FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA iam FROM PUBLIC;
GRANT USAGE ON SCHEMA iam TO iam_app;

SELECT format('GRANT EXECUTE ON FUNCTION %s TO iam_app', p.oid::regprocedure)
FROM pg_proc p
WHERE p.pronamespace = 'iam'::regnamespace
  AND (p.proname LIKE 'sp\_%' OR p.proname LIKE 'fn\_%')
\gexec
