-- =============================================================================
-- tests/test_all.sql  -  end-to-end checks of auth, RBAC, sidebar, sessions,
-- batch pipeline and role isolation. Runs in ONE transaction and rolls back,
-- so it never leaves test data behind. Any failed ASSERT stops the run.
-- Run via build.ps1 (or: psql -v ON_ERROR_STOP=1 -f tests/test_all.sql).
-- =============================================================================
\set ON_ERROR_STOP on
\set QUIET on
BEGIN;

-- Small scratch area for values shared between test blocks.
CREATE TEMP TABLE t (k text PRIMARY KEY, v text);
CREATE FUNCTION pg_temp.uid(p_email text) RETURNS uuid LANGUAGE sql AS
    $$ SELECT user_id FROM iam.app_user WHERE email = p_email::citext $$;

-- ------------------------------------------------------------- login -------
DO $$
DECLARE r jsonb;
BEGIN
    r := iam.sp_login('MANAGER@studio.local', 'Studio#2026', '127.0.0.1', 'test');
    ASSERT r->>'status' = 'OK', 'manager login should succeed (email case-insensitive): ' || r::text;
    ASSERT r->'session'->>'refresh_token' IS NOT NULL, 'refresh token returned';
    ASSERT jsonb_array_length(r->'apps') = 3, 'manager sees 3 cards';
    ASSERT r->'user' ? 'password_hash' = false, 'hash never leaves the DB';
    INSERT INTO t VALUES ('mgr_session', r->'session'->>'session_id'), ('mgr_refresh', r->'session'->>'refresh_token');

    ASSERT iam.sp_login('manager@studio.local', 'wrong')->>'status' = 'INVALID_CREDENTIALS', 'bad password';
    ASSERT iam.sp_login('nobody@studio.local', 'x')->>'status'      = 'INVALID_CREDENTIALS', 'unknown email, same answer';
    ASSERT (SELECT count(*) FROM iam.user_session s JOIN iam.app_user u USING (user_id)
            WHERE u.email = 'manager@studio.local') = 1, 'only the good login created a session';
    RAISE NOTICE 'PASS login';
END $$;

-- ------------------------------------------------------------ lockout ------
DO $$
DECLARE i int;
BEGIN
    FOR i IN 1..5 LOOP PERFORM iam.sp_login('viewer@studio.local', 'wrong'); END LOOP;
    ASSERT iam.sp_login('viewer@studio.local', 'Studio#2026')->>'status' = 'ACCOUNT_LOCKED',
        'locked after 5 failures, even with the right password';
    ASSERT EXISTS (SELECT 1 FROM iam.audit_log WHERE action = 'ACCOUNT_LOCKED'), 'lock audited';
    UPDATE iam.app_user SET locked_until = NULL WHERE email = 'viewer@studio.local';   -- undo for later tests
    RAISE NOTICE 'PASS lockout';
END $$;

-- -------------------------------------------------- dashboard cards --------
DO $$
DECLARE codes text;
BEGIN
    SELECT string_agg(c->>'code', ',') INTO codes FROM jsonb_array_elements(iam.fn_get_user_apps(pg_temp.uid('associate@studio.local'))) c;
    ASSERT codes = 'ERP,AML', 'associate cards: ' || coalesce(codes, '-');
    SELECT string_agg(c->>'code', ',') INTO codes FROM jsonb_array_elements(iam.fn_get_user_apps(pg_temp.uid('viewer@studio.local'))) c;
    ASSERT codes = 'LENDING', 'viewer cards: ' || coalesce(codes, '-');
    SELECT string_agg(c->>'code', ',') INTO codes FROM jsonb_array_elements(iam.fn_get_user_apps(pg_temp.uid('admin@studio.local'))) c;
    ASSERT codes = 'ERP,AML,LENDING', 'super admin sees all';
    RAISE NOTICE 'PASS dashboard cards';
END $$;

-- ------------------------------------------------------------ sidebar ------
DO $$
DECLARE s jsonb; codes text;
BEGIN
    -- Analyst in ERP: has Upload under Datasets, no Administration.
    s := iam.fn_get_sidebar(pg_temp.uid('associate@studio.local'), 'erp');
    SELECT string_agg(m->>'code', ',') INTO codes FROM jsonb_array_elements(s) m;
    ASSERT codes = 'dashboard,datasets,mapping,data_quality,reports,templates,assistant', 'analyst sidebar: ' || codes;
    ASSERT (SELECT string_agg(c->>'code', ',') FROM jsonb_array_elements(s) m, jsonb_array_elements(m->'children') c
            WHERE m->>'code' = 'datasets') = 'datasets.list,datasets.upload', 'analyst can upload';

    -- Viewer in Lending: read-only menu, no upload child.
    s := iam.fn_get_sidebar(pg_temp.uid('viewer@studio.local'), 'LENDING');
    SELECT string_agg(m->>'code', ',') INTO codes FROM jsonb_array_elements(s) m;
    ASSERT codes = 'dashboard,datasets,reports,templates,assistant', 'viewer sidebar: ' || codes;
    ASSERT (SELECT string_agg(c->>'code', ',') FROM jsonb_array_elements(s) m, jsonb_array_elements(m->'children') c
            WHERE m->>'code' = 'datasets') = 'datasets.list', 'viewer cannot upload';

    -- No role in the app -> empty sidebar.
    ASSERT iam.fn_get_sidebar(pg_temp.uid('associate@studio.local'), 'LENDING') = '[]'::jsonb, 'no access -> no menu';
    -- App admin sees Administration.
    s := iam.fn_get_sidebar(pg_temp.uid('erpadmin@studio.local'), 'ERP');
    ASSERT EXISTS (SELECT 1 FROM jsonb_array_elements(s) m WHERE m->>'code' = 'admin'), 'app admin sees admin';
    RAISE NOTICE 'PASS sidebar';
END $$;

-- -------------------------------------------------------- permissions ------
DO $$
BEGIN
    ASSERT     iam.fn_has_permission(pg_temp.uid('associate@studio.local'), 'ERP', 'dataset.upload'), 'analyst uploads ERP';
    ASSERT NOT iam.fn_has_permission(pg_temp.uid('associate@studio.local'), 'ERP', 'batch.commit'), 'analyst cannot commit';
    ASSERT NOT iam.fn_has_permission(pg_temp.uid('associate@studio.local'), 'LENDING', 'dashboard.view'), 'no lending access';
    ASSERT     iam.fn_has_permission(pg_temp.uid('manager@studio.local'), 'AML', 'batch.commit'), 'reviewer commits';
    ASSERT     iam.fn_has_permission(pg_temp.uid('admin@studio.local'), 'LENDING', 'admin.users'), 'super admin all';
    ASSERT NOT iam.fn_has_permission(pg_temp.uid('admin@studio.local'), 'NOPE', 'admin.users'), 'unknown app false';
    RAISE NOTICE 'PASS permissions';
END $$;

-- ---------------------------------------------------------- select app -----
DO $$
DECLARE r jsonb; sid uuid;
BEGIN
    sid := iam.sp_login('associate@studio.local', 'Studio#2026')->'session'->>'session_id';
    r := iam.sp_select_app(sid, 'erp');
    ASSERT r->>'status' = 'OK', 'associate enters ERP';
    ASSERT r->'roles' = '["ANALYST"]'::jsonb, 'roles returned';
    ASSERT r->'permissions' ? 'dataset.upload', 'permissions returned';
    ASSERT (SELECT a.code FROM iam.user_session s JOIN iam.app a USING (app_id) WHERE s.session_id = sid) = 'ERP',
        'app bound to session';
    ASSERT iam.sp_select_app(sid, 'LENDING')->>'status' = 'FORBIDDEN', 'associate blocked from Lending';
    RAISE NOTICE 'PASS select app';
END $$;

-- --------------------------------------------- refresh / reuse / logout ----
DO $$
DECLARE r jsonb; old_token text; new_token text; sid uuid;
BEGIN
    SELECT v INTO old_token FROM t WHERE k = 'mgr_refresh';
    r := iam.sp_refresh_session(old_token);
    ASSERT r->>'status' = 'OK', 'refresh works';
    new_token := r->'session'->>'refresh_token';
    ASSERT new_token <> old_token, 'token rotated';
    ASSERT NOT iam.fn_session_is_active((SELECT v::uuid FROM t WHERE k = 'mgr_session')), 'old session dead';

    -- Replay of the rotated token = theft: every session of the user is revoked.
    ASSERT iam.sp_refresh_session(old_token)->>'status' = 'TOKEN_REUSED', 'reuse detected';
    ASSERT iam.sp_refresh_session(new_token)->>'status' = 'INVALID', 'new token killed too';
    ASSERT iam.sp_refresh_session('garbage')->>'status' = 'INVALID', 'garbage token';

    sid := iam.sp_login('manager@studio.local', 'Studio#2026')->'session'->>'session_id';
    ASSERT iam.fn_session_is_active(sid), 'fresh session active';
    ASSERT iam.sp_logout(sid), 'logout';
    ASSERT NOT iam.fn_session_is_active(sid), 'logged-out session inactive';
    ASSERT NOT iam.sp_logout(sid), 'double logout is a no-op';
    RAISE NOTICE 'PASS refresh/reuse/logout';
END $$;

-- -------------------------------------------------------- password ---------
DO $$
DECLARE s1 uuid; s2 uuid; u uuid := pg_temp.uid('viewer@studio.local');
BEGIN
    s1 := iam.sp_login('viewer@studio.local', 'Studio#2026')->'session'->>'session_id';
    s2 := iam.sp_login('viewer@studio.local', 'Studio#2026')->'session'->>'session_id';
    ASSERT iam.sp_change_password(u, 'wrong', 'NewPass123')->>'status' = 'INVALID_CREDENTIALS', 'old pw checked';
    BEGIN
        PERFORM iam.sp_change_password(u, 'Studio#2026', 'short');
        RAISE EXCEPTION 'weak password accepted';
    EXCEPTION WHEN invalid_parameter_value THEN NULL;
    END;
    ASSERT iam.sp_change_password(u, 'Studio#2026', 'NewPass123', s1)->>'status' = 'OK', 'pw changed';
    ASSERT iam.fn_session_is_active(s1) AND NOT iam.fn_session_is_active(s2), 'other sessions revoked, current kept';
    ASSERT iam.sp_login('viewer@studio.local', 'NewPass123')->>'status' = 'OK', 'login with new pw';
    RAISE NOTICE 'PASS change password';
END $$;

-- ------------------------------------------------- user administration -----
DO $$
DECLARE new_user uuid; admin uuid := pg_temp.uid('admin@studio.local'); erpadmin uuid := pg_temp.uid('erpadmin@studio.local');
BEGIN
    -- Non-admin cannot create users.
    BEGIN
        PERFORM iam.sp_create_user(pg_temp.uid('associate@studio.local'), 'x@studio.local', 'X', 'Passw0rd1');
        RAISE EXCEPTION 'analyst created a user';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    -- App admin can create a normal user but not a super admin.
    new_user := iam.sp_create_user(erpadmin, 'new@studio.local', 'New Person', 'Passw0rd1');
    BEGIN
        PERFORM iam.sp_create_user(erpadmin, 'boss@studio.local', 'Boss', 'Passw0rd1', true);
        RAISE EXCEPTION 'app admin created a super admin';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    -- Duplicate email.
    BEGIN
        PERFORM iam.sp_create_user(admin, 'NEW@studio.local', 'Dup', 'Passw0rd1');
        RAISE EXCEPTION 'duplicate email accepted';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;

    -- New user has no apps until a role is assigned.
    ASSERT iam.fn_get_user_apps(new_user) = '[]'::jsonb, 'no roles -> no cards';
    ASSERT iam.sp_assign_role(erpadmin, new_user, 'ERP', 'VIEWER'), 'erp admin grants ERP role';
    ASSERT NOT iam.sp_assign_role(erpadmin, new_user, 'ERP', 'VIEWER'), 'second grant is a no-op';
    BEGIN
        PERFORM iam.sp_assign_role(erpadmin, new_user, 'AML', 'VIEWER');
        RAISE EXCEPTION 'erp admin granted an AML role';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    ASSERT jsonb_array_length(iam.fn_get_user_apps(new_user)) = 1, 'now 1 card';
    ASSERT jsonb_array_length(iam.fn_list_users(erpadmin, 'ERP')) >= 6, 'admin lists users';
    ASSERT iam.sp_revoke_role(erpadmin, new_user, 'ERP', 'VIEWER'), 'revoke';
    ASSERT iam.fn_get_user_apps(new_user) = '[]'::jsonb, 'revoked -> no cards';
    ASSERT (SELECT count(*) FROM iam.audit_log WHERE action IN ('ROLE_ASSIGNED','ROLE_REVOKED') AND target_id = new_user::text) = 2,
        'role changes audited';

    -- Disable: sessions die, login refused.
    PERFORM iam.sp_assign_role(admin, new_user, 'ERP', 'VIEWER');
    INSERT INTO t VALUES ('new_session', iam.sp_login('new@studio.local', 'Passw0rd1')->'session'->>'session_id');
    PERFORM iam.sp_set_user_active(admin, new_user, false);
    ASSERT NOT iam.fn_session_is_active((SELECT v::uuid FROM t WHERE k = 'new_session')), 'disabled -> session dead';
    ASSERT iam.sp_login('new@studio.local', 'Passw0rd1')->>'status' = 'ACCOUNT_DISABLED', 'disabled login';
    ASSERT NOT iam.fn_has_permission(new_user, 'ERP', 'dashboard.view'), 'disabled user has no permissions';
    BEGIN
        PERFORM iam.sp_set_user_active(erpadmin, new_user, true);
        RAISE EXCEPTION 'non-super-admin re-enabled a user';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    RAISE NOTICE 'PASS user administration';
END $$;

-- ------------------------------------------------- batch pipeline (ERP) ----
DO $$
DECLARE
    analyst uuid := pg_temp.uid('associate@studio.local');
    manager uuid := pg_temp.uid('manager@studio.local');
    viewer  uuid := pg_temp.uid('viewer@studio.local');
    sha text := repeat('a', 64);
    r jsonb; b uuid;
BEGIN
    -- Viewer has no ERP role -> cannot upload.
    BEGIN
        PERFORM erp.sp_create_batch(viewer, 'x.csv', 'CSV', 10, sha, 'file:///x');
        RAISE EXCEPTION 'viewer uploaded';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;

    r := erp.sp_create_batch(analyst, 'payables.csv', 'csv', 1024, sha, 'file:///uploads/payables.csv');
    ASSERT r->>'status' = 'CREATED', 'batch created';
    b := r->>'batch_id';
    ASSERT erp.sp_create_batch(analyst, 'again.csv', 'CSV', 1024, upper(sha), 'file:///y')->>'status' = 'DUPLICATE',
        'same checksum -> duplicate, not a second batch';

    -- Illegal jump.
    BEGIN
        PERFORM erp.sp_update_batch_status(b, 'READY_TO_COMMIT');
        RAISE EXCEPTION 'skipped states';
    EXCEPTION WHEN invalid_parameter_value THEN NULL;
    END;

    PERFORM erp.sp_update_batch_status(b, 'EXTRACTING', 40::smallint, 'OCR 40 percent');
    PERFORM erp.sp_update_batch_status(b, 'EXTRACTING', 80::smallint, 'OCR 80 percent');

    -- Worker writes candidate records (in real life: COPY from the backend).
    INSERT INTO erp.raw_record (batch_id, record_no, target_entity, source_location, raw_fields, normalized_fields, extraction_method, state) VALUES
      (b, 1, 'supplier', '{"row":2}', '{"Supplier":"SUP-1"}', '{"supplier_id":"SUP-1","supplier_name":"Acme"}', 'csv', 'ACCEPTED'),
      (b, 2, 'invoice',  '{"row":3}', '{"Invoice_No":"INV-1"}',
          '{"invoice_id":"INV-1","supplier_id":"SUP-1","invoice_date":"2026-10-01","due_date":"2026-10-31","amount":"10000.00","currency":"INR"}', 'csv', 'ACCEPTED'),
      (b, 3, 'invoice',  '{"row":4}', '{"Invoice_No":"INV-2"}',
          '{"invoice_id":"INV-2","supplier_id":"SUP-1","invoice_date":"2026-10-02","due_date":"2026-11-30","amount":"5000.00","currency":"INR"}', 'csv', 'ACCEPTED'),
      (b, 4, 'invoice',  '{"row":5}', '{"Invoice_No":""}', NULL, 'csv', 'REJECTED'),
      (b, 5, 'invoice',  '{"row":6}', '{"Invoice_No":"INV-3"}', NULL, 'csv', 'NEEDS_REVIEW');

    PERFORM erp.sp_update_batch_status(b, 'MAPPING_REVIEW');
    PERFORM erp.sp_update_batch_status(b, 'VALIDATING');
    PERFORM erp.sp_update_batch_status(b, 'READY_TO_COMMIT');
    -- UPLOADED, EXTRACTING 40, EXTRACTING 80, MAPPING_REVIEW, VALIDATING, READY_TO_COMMIT
    ASSERT (SELECT count(*) FROM erp.fn_get_batch_events(b, 0)) = 6, 'every step recorded as an event';
    ASSERT (SELECT count(*) FROM erp.fn_get_batch_events(b, (SELECT min(event_id) FROM erp.batch_event WHERE batch_id = b))) = 5,
        'replay after an event id';

    -- Analyst has no batch.commit.
    BEGIN
        PERFORM erp.sp_commit_batch(analyst, b);
        RAISE EXCEPTION 'analyst committed';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    -- Record still awaiting review -> blocked.
    BEGIN
        PERFORM erp.sp_commit_batch(manager, b);
        RAISE EXCEPTION 'committed with open review';
    EXCEPTION WHEN invalid_parameter_value THEN NULL;
    END;

    UPDATE erp.raw_record SET state = 'REJECTED' WHERE batch_id = b AND record_no = 5;
    r := erp.sp_commit_batch(manager, b);
    ASSERT r->>'status' = 'COMMITTED', 'committed';
    ASSERT (r->>'received')::int = 5 AND (r->>'accepted')::int = 3 AND (r->>'rejected')::int = 2,
        'record accounting: received = accepted + rejected: ' || r::text;
    ASSERT (SELECT count(*) FROM erp.invoice) = 2 AND (SELECT amount FROM erp.invoice WHERE invoice_id = 'INV-1') = 10000.00,
        'domain rows loaded with correct types';
    ASSERT (SELECT source_record_no FROM erp.invoice WHERE invoice_id = 'INV-2') = 3, 'lineage kept';
    ASSERT (erp.fn_get_batch(manager, b)->'counts'->>'received')::int = 5, 'fn_get_batch counts';
    ASSERT jsonb_array_length(erp.fn_list_batches(analyst)) = 1, 'list batches';
    INSERT INTO t VALUES ('erp_batch', b::text);
    RAISE NOTICE 'PASS batch pipeline';
END $$;

-- -------------------------------------------- re-import: no double count ---
DO $$
DECLARE
    analyst uuid := pg_temp.uid('associate@studio.local');
    manager uuid := pg_temp.uid('manager@studio.local');
    r jsonb; b uuid;
BEGIN
    b := erp.sp_create_batch(analyst, 'payables_v2.csv', 'CSV', 900, repeat('b', 64), 'file:///v2')->>'batch_id';
    INSERT INTO erp.raw_record (batch_id, record_no, target_entity, source_location, raw_fields, normalized_fields, extraction_method, state) VALUES
      (b, 1, 'invoice', '{"row":2}', '{}',
          '{"invoice_id":"INV-1","supplier_id":"SUP-1","invoice_date":"2026-10-01","due_date":"2026-10-31","amount":"12000.00","currency":"INR"}', 'csv', 'ACCEPTED');
    PERFORM erp.sp_update_batch_status(b, s) FROM unnest(ARRAY['EXTRACTING','MAPPING_REVIEW','VALIDATING','READY_TO_COMMIT']) s;
    PERFORM erp.sp_commit_batch(manager, b);
    ASSERT (SELECT count(*) FROM erp.invoice) = 2, 'same business key updated, not duplicated';
    ASSERT (SELECT amount FROM erp.invoice WHERE invoice_id = 'INV-1') = 12000.00, 'newer batch wins';
    ASSERT (SELECT batch_id FROM erp.invoice WHERE invoice_id = 'INV-1') = b, 'lineage points to newer batch';

    -- A bad type aborts the commit atomically.
    b := erp.sp_create_batch(analyst, 'bad.csv', 'CSV', 900, repeat('c', 64), 'file:///bad')->>'batch_id';
    INSERT INTO erp.raw_record (batch_id, record_no, target_entity, source_location, raw_fields, normalized_fields, extraction_method, state) VALUES
      (b, 1, 'invoice', '{"row":2}', '{}',
          '{"invoice_id":"INV-9","supplier_id":"SUP-1","invoice_date":"2026-10-01","due_date":"2026-10-31","amount":"abc","currency":"INR"}', 'csv', 'ACCEPTED');
    PERFORM erp.sp_update_batch_status(b, s) FROM unnest(ARRAY['EXTRACTING','MAPPING_REVIEW','VALIDATING','READY_TO_COMMIT']) s;
    BEGIN
        PERFORM erp.sp_commit_batch(manager, b);
        RAISE EXCEPTION 'bad amount committed';
    EXCEPTION WHEN invalid_text_representation THEN NULL;
    END;
    ASSERT (SELECT status FROM erp.ingestion_batch WHERE batch_id = b) = 'READY_TO_COMMIT', 'failed commit left batch untouched';

    -- Unknown target entity is refused (no writing into arbitrary tables).
    UPDATE erp.raw_record SET target_entity = 'ingestion_batch' WHERE batch_id = b;
    BEGIN
        PERFORM erp.sp_commit_batch(manager, b);
        RAISE EXCEPTION 'wrote into a non-domain table';
    EXCEPTION WHEN invalid_parameter_value THEN NULL;
    END;

    -- Maker-checker: ERP admin has BOTH upload and commit, but not on their own batch.
    DECLARE
        erpadmin uuid := pg_temp.uid('erpadmin@studio.local');
        own uuid;
    BEGIN
        own := erp.sp_create_batch(erpadmin, 'own.csv', 'CSV', 5, repeat('f', 64), 'file:///own')->>'batch_id';
        PERFORM erp.sp_update_batch_status(own, s) FROM unnest(ARRAY['EXTRACTING','MAPPING_REVIEW','VALIDATING','READY_TO_COMMIT']) s;
        BEGIN
            PERFORM erp.sp_commit_batch(erpadmin, own);
            RAISE EXCEPTION 'uploader committed own batch';
        EXCEPTION WHEN insufficient_privilege THEN NULL;
        END;
    END;

    -- FAILED -> retry allowed, and a FAILED file's checksum can be uploaded again.
    PERFORM erp.sp_update_batch_status(b, 'FAILED', NULL, NULL, 'parser crashed');
    ASSERT erp.sp_create_batch(analyst, 'bad.csv', 'CSV', 900, repeat('c', 64), 'file:///bad2')->>'status' = 'CREATED',
        'failed file can be re-uploaded';
    RAISE NOTICE 'PASS re-import / atomic commit';
END $$;

-- ----------------------------------------- AML + LENDING pipelines exist ----
DO $$
DECLARE manager uuid := pg_temp.uid('manager@studio.local'); associate uuid := pg_temp.uid('associate@studio.local');
BEGIN
    ASSERT aml.sp_create_batch(associate, 'alerts.json', 'JSON', 10, repeat('d', 64), 'file:///a')->>'status' = 'CREATED', 'aml upload';
    -- manager is a REVIEWER in Lending: no dataset.upload.
    BEGIN
        PERFORM lending.sp_create_batch(manager, 'apps.xlsx', 'EXCEL', 10, repeat('e', 64), 'file:///l');
        RAISE EXCEPTION 'reviewer uploaded';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    -- associate has no Lending role at all.
    BEGIN
        PERFORM lending.fn_list_batches(associate);
        RAISE EXCEPTION 'associate read lending';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    RAISE NOTICE 'PASS aml/lending pipelines';
END $$;

-- ------------------------------------------ DB-level role isolation --------
-- Each login role must be physically unable to cross into another schema.
CREATE FUNCTION pg_temp.denied(p_role text, p_sql text) RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE format('SET LOCAL ROLE %I', p_role);
    BEGIN
        EXECUTE p_sql;
    EXCEPTION WHEN insufficient_privilege THEN
        RESET ROLE;
        RETURN true;
    END;
    RESET ROLE;
    RETURN false;
END $$;

DO $$
BEGIN
    ASSERT pg_temp.denied('erp_app', 'SELECT 1 FROM aml.alert'),               'erp_app cannot read AML';
    ASSERT pg_temp.denied('erp_app', 'SELECT 1 FROM iam.app_user'),            'erp_app cannot read users';
    ASSERT pg_temp.denied('erp_app', 'SELECT lending.fn_list_batches(NULL)'),  'erp_app cannot call lending functions';
    ASSERT pg_temp.denied('erp_app', 'UPDATE erp.ingestion_batch SET status = ''COMMITTED'''), 'state machine not bypassable';
    ASSERT pg_temp.denied('erp_app', 'DELETE FROM erp.invoice'),               'domain tables are read-only for the app';
    ASSERT pg_temp.denied('erp_ro',  'INSERT INTO erp.raw_record SELECT * FROM erp.raw_record LIMIT 0'), 'ro cannot write';
    ASSERT pg_temp.denied('iam_app', 'SELECT 1 FROM iam.app_user'),            'iam_app has no direct table access';
    ASSERT pg_temp.denied('iam_app', 'SELECT iam._hash_password(''x'')'),      'internal helpers not callable';
    ASSERT NOT pg_temp.denied('iam_app', 'SELECT iam.fn_has_permission(NULL, ''ERP'', ''x'')'), 'iam_app calls public API';
    ASSERT NOT pg_temp.denied('erp_app', 'SELECT 1 FROM erp.invoice'),         'erp_app reads ERP';
    ASSERT NOT pg_temp.denied('aml_ro',  'SELECT 1 FROM aml.alert'),           'aml_ro reads AML';
    RAISE NOTICE 'PASS role isolation';
END $$;

ROLLBACK;
\echo 'ALL TESTS PASSED (changes rolled back)'
