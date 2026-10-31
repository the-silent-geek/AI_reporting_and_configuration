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

-- ------------------------------------------- Smart Assistance tools --------
-- Known data, so every KPI can be checked by hand.
DO $$
DECLARE
    mgr uuid := pg_temp.uid('manager@studio.local');
    associate uuid := pg_temp.uid('associate@studio.local');
    b uuid := gen_random_uuid();
    lb uuid := gen_random_uuid();
    ab uuid := gen_random_uuid();
    r jsonb;
    conv uuid;
BEGIN
    -- Isolation: the exact KPI figures below must not include rows left by earlier tests in
    -- this transaction (e.g. the "batch pipeline" INR invoices). Rolled back at the end.
    DELETE FROM erp.credit_note; DELETE FROM erp.payment_allocation; DELETE FROM erp.payment;
    DELETE FROM erp.invoice;     DELETE FROM erp.supplier;

    INSERT INTO erp.ingestion_batch (batch_id, file_name, file_type, file_size_bytes, sha256, storage_uri, uploaded_by)
    VALUES (b, 'a.csv', 'CSV', 1, encode(sha256(gen_random_uuid()::text::bytea), 'hex'), 'file:///a', associate);
    INSERT INTO erp.supplier VALUES ('TS1', 'ACME Ltd', b, 1), ('TS2', 'Globex', b, 2);
    INSERT INTO erp.invoice VALUES
        ('TI1', 'TS1', '2026-08-01', '2026-09-01', 1000, 'USD', b, 3),   -- 400 paid -> 600 open, 60 days late
        ('TI2', 'TS1', '2026-10-01', '2026-11-15',  500, 'USD', b, 4),   -- not yet due
        ('TI3', 'TS2', '2026-06-01', '2026-07-01', 2000, 'EUR', b, 5),   -- 300 approved credit -> 1700, 122 days
        ('TI4', 'TS2', '2026-11-05', '2026-12-05',  999, 'EUR', b, 6);   -- issued after the as-of date
    INSERT INTO erp.payment VALUES ('TP1', 'TS1', '2026-09-10', 400, 'USD', 'wire', b, 7);
    INSERT INTO erp.payment_allocation VALUES ('TP1', 'TI1', 400, '2026-09-10', b, 8);
    INSERT INTO erp.credit_note VALUES ('TC1', 'TI3', 300, '2026-07-15', true, b, 9),
                                       ('TC2', 'TI3', 100, '2026-07-20', false, b, 10);   -- unapproved: ignored

    r := erp.fn_tool_payables_ageing(mgr, '2026-10-31');
    ASSERT r->'kpis'->'outstanding_amount_by_currency' = '{"USD": 1100.00, "EUR": 1700.00}', 'outstanding: ' || (r->'kpis')::text;
    ASSERT r->'kpis'->'overdue_amount_by_currency' = '{"USD": 600.00, "EUR": 1700.00}', 'overdue';
    ASSERT (r->'kpis'->>'overdue_invoice_count')::int = 2, 'two overdue invoices';
    ASSERT r->>'reporting_period' = 'As of 2026-10-31' AND r->>'product' = 'erp', 'result contract';
    ASSERT EXISTS (SELECT 1 FROM erp.assistant_tool_run WHERE run_id = (r->>'result_reference')::uuid
                   AND tool_name = 'get_erp_payables_ageing' AND user_id = mgr), 'tool run recorded';
    ASSERT (SELECT array_agg(x->>'bucket' ORDER BY ord) FROM jsonb_array_elements(r->'chart_data') WITH ORDINALITY t(x, ord))
           = ARRAY['current', '31-60', '90+'], 'ageing buckets';

    r := erp.fn_tool_overdue_by_supplier(mgr, '2026-10-31', 1);
    ASSERT jsonb_array_length(r->'chart_data') = 1 AND r->'chart_data'->0->>'supplier_id' = 'TS2', 'top supplier by amount';
    ASSERT (r->'kpis'->>'overdue_supplier_count')::int = 2, 'kpis ignore the limit';

    r := erp.fn_tool_payment_details(mgr, 'TP1');
    ASSERT (r->'kpis'->>'found')::boolean AND (r->'kpis'->>'unallocated_amount')::numeric = 0, 'payment fully allocated';
    ASSERT NOT (erp.fn_tool_payment_details(mgr, 'NOPE')->'kpis'->>'found')::boolean, 'unknown payment: found=false';

    -- Lending
    INSERT INTO lending.ingestion_batch (batch_id, file_name, file_type, file_size_bytes, sha256, storage_uri, uploaded_by)
    VALUES (lb, 'l.csv', 'CSV', 1, encode(sha256(gen_random_uuid()::text::bytea), 'hex'), 'file:///l', mgr);
    INSERT INTO lending.application VALUES
        ('TA1', 'C1', '2026-10-03', 'REJECTED', 1000, 'INR', 'PL', NULL, 12, lb, 1),
        ('TA2', 'C2', '2026-10-20', 'APPROVED', 5000, 'INR', 'PL', NULL, 24, lb, 2),
        ('TA3', 'C3', '2026-09-30', 'REJECTED', 7000, 'INR', 'PL', NULL, 12, lb, 3);   -- outside October
    r := lending.fn_tool_application_summary(mgr, '2026-10-01', '2026-10-31', 'rejected');
    ASSERT (r->'kpis'->>'application_count')::int = 1 AND r->'kpis'->'requested_amount_by_currency' = '{"INR": 1000.00}',
           'rejected in October: ' || (r->'kpis')::text;
    ASSERT r->'filters'->>'status' = 'REJECTED', 'filters echoed, normalized';
    ASSERT NOT (r->'supporting_rows'->0 ? 'applicant_ref'), 'no applicant refs in summaries';
    r := lending.fn_tool_application_trend(mgr, '2026-09-01', '2026-10-31', 'month');
    ASSERT jsonb_array_length(r->'chart_data') = 2, 'two monthly buckets';
    BEGIN
        PERFORM lending.fn_tool_application_summary(mgr, '2026-10-31', '2026-10-01');
        RAISE EXCEPTION 'reversed period accepted';
    EXCEPTION WHEN invalid_parameter_value THEN NULL;
    END;
    BEGIN   -- associate has no Lending role
        PERFORM lending.fn_tool_application_summary(associate, '2026-10-01', '2026-10-31');
        RAISE EXCEPTION 'associate used lending tool';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;

    -- AML
    INSERT INTO aml.ingestion_batch (batch_id, file_name, file_type, file_size_bytes, sha256, storage_uri, uploaded_by)
    VALUES (ab, 'a.json', 'JSON', 1, encode(sha256(gen_random_uuid()::text::bytea), 'hex'), 'file:///a', mgr);
    INSERT INTO aml.investigation_case VALUES ('TK1', 'OPEN', 'HIGH', 'P1', 'inv', '2026-10-02', NULL, ab, 1);
    INSERT INTO aml.alert VALUES
        ('TL1', 'TK1', '2026-10-02 10:00', 'HIGH', 'OPEN', 'C9', 'Rule A', 'inv', ab, 2),
        ('TL2', NULL,  '2026-10-05 10:00', 'LOW',  'CLOSED', 'C8', 'Rule B', NULL, ab, 3);
    r := aml.fn_tool_alert_summary(mgr, '2026-10-01', '2026-10-31');
    ASSERT (r->'kpis'->>'alert_count')::int = 2 AND (r->'kpis'->>'alerts_without_case')::int = 1, 'alert kpis';
    ASSERT r->'kpis'->'by_severity' = '{"HIGH": 1, "LOW": 1}', 'by severity';
    ASSERT (aml.fn_tool_case_details(mgr, 'TK1')->'kpis'->>'alert_count')::int = 1, 'case has one alert';

    -- Conversations belong to their user
    conv := erp.sp_assistant_save_conversation(mgr, NULL, '{"pending": "as_of_date"}');
    ASSERT erp.fn_assistant_get_conversation(mgr, conv) = '{"pending": "as_of_date"}', 'state saved';
    BEGIN
        PERFORM erp.fn_assistant_get_conversation(associate, conv);
        RAISE EXCEPTION 'read someone else''s conversation';
    EXCEPTION WHEN no_data_found THEN NULL;
    END;
    PERFORM erp.sp_assistant_audit(mgr, conv, 'overdue?', 'data_question', 'get_erp_payables_ageing',
                                   '{}', 'As of 2026-10-31', (erp.fn_tool_payables_ageing(mgr, '2026-10-31')->>'result_reference')::uuid,
                                   'answered');
    BEGIN   -- a reference must be the user's own tool run
        PERFORM erp.sp_assistant_audit(associate, NULL, 'x', NULL, NULL, NULL, NULL,
                                       (SELECT run_id FROM erp.assistant_tool_run WHERE user_id = mgr LIMIT 1), 'answered');
        RAISE EXCEPTION 'borrowed another user''s result reference';
    EXCEPTION WHEN invalid_parameter_value THEN NULL;
    END;
    RAISE NOTICE 'PASS smart assistance tools';
END $$;

-- -------------------------------------- Mapping review + data quality ------
-- A worker-style batch with one good and four bad records goes through mapping,
-- validation, corrections and commit.
DO $$
DECLARE
    mgr uuid := pg_temp.uid('manager@studio.local');
    associate uuid := pg_temp.uid('associate@studio.local');
    b uuid;
    r jsonb;
    m jsonb := '[
        {"source_field":"Invoice No","target_field":"invoice_id","transform":{"type":"trim"}},
        {"source_field":"Supplier","target_field":"supplier_id","transform":{"type":"trim"}},
        {"source_field":"Invoice Date","target_field":"invoice_date","transform":{"type":"parse_date","format":"%d-%b-%Y"}},
        {"source_field":"Due Date","target_field":"due_date","transform":{"type":"parse_date","format":"%d-%b-%Y"}},
        {"source_field":"Amount","target_field":"amount","transform":{"type":"parse_decimal","remove_characters":[","]}},
        {"source_field":"Notes","target_field":null}]';
BEGIN
    INSERT INTO erp.ingestion_batch (batch_id, file_name, file_type, file_size_bytes, sha256, storage_uri, uploaded_by)
    VALUES (gen_random_uuid(), 'sup.csv', 'CSV', 1, encode(sha256(gen_random_uuid()::text::bytea), 'hex'), 'file:///s', associate)
    RETURNING batch_id INTO b;
    INSERT INTO erp.supplier VALUES ('RV-S1', 'Review Supplier', b, 1);

    b := (erp.sp_create_batch(associate, 'inv.csv', 'CSV', 10, encode(sha256(gen_random_uuid()::text::bytea), 'hex'),
                              'file:///inv.csv')->>'batch_id')::uuid;
    PERFORM erp.sp_update_batch_status(b, 'EXTRACTING');
    INSERT INTO erp.raw_record (batch_id, record_no, target_entity, source_location, raw_fields, extraction_method) VALUES
      (b, 1, 'invoice', '{"row":2}', '{"Invoice No":"RV-1","Supplier":"RV-S1","Invoice Date":"05-Oct-2026","Due Date":"04-Nov-2026","Amount":"1,000.50","Notes":"x"}', 'csv'),
      (b, 2, 'invoice', '{"row":3}', '{"Invoice No":"RV-2","Supplier":"RV-S1","Invoice Date":"05-Oct-2026","Due Date":"04-Nov-2026","Amount":"abc"}', 'csv'),
      (b, 3, 'invoice', '{"row":4}', '{"Invoice No":"RV-3","Supplier":"NOPE","Invoice Date":"05-Oct-2026","Due Date":"04-Nov-2026","Amount":"5"}', 'csv'),
      (b, 4, 'invoice', '{"row":5}', '{"Invoice No":"RV-1","Supplier":"RV-S1","Invoice Date":"05-Oct-2026","Due Date":"04-Nov-2026","Amount":"7"}', 'csv'),
      (b, 5, 'invoice', '{"row":6}', '{"Invoice No":"RV-5","Supplier":"RV-S1","Invoice Date":"05-Oct-2026","Due Date":"01-Oct-2026","Amount":"9"}', 'csv');
    PERFORM erp.sp_update_batch_status(b, 'MAPPING_REVIEW');

    ASSERT jsonb_array_length(erp.fn_review_queue(mgr)->'mapping') >= 1, 'batch is in the mapping queue';
    r := erp.fn_get_mapping(mgr, b);
    ASSERT r->>'suggested_entity' = 'invoice' AND r->'entities' ? 'supplier', 'mapping screen data';
    ASSERT jsonb_array_length(r->'fields') = 6, 'six source fields with samples';

    BEGIN   -- currency is required and neither mapped nor fixed
        PERFORM erp.sp_approve_mapping(mgr, b, 'invoice', m);
        RAISE EXCEPTION 'approved without currency';
    EXCEPTION WHEN invalid_parameter_value THEN NULL;
    END;
    BEGIN   -- associate has mapping.review in ERP, viewer has no ERP role at all
        PERFORM erp.sp_approve_mapping(pg_temp.uid('viewer@studio.local'), b, 'invoice', m);
        RAISE EXCEPTION 'viewer approved a mapping';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN
        PERFORM erp.sp_approve_mapping(mgr, b, 'iam.app_user', m);
        RAISE EXCEPTION 'mapped into a non-domain table';
    EXCEPTION WHEN invalid_parameter_value THEN NULL;
    END;

    m := m || '[{"source_field":null,"target_field":"currency","transform":{"type":"constant","value":"USD"}}]';
    r := erp.sp_approve_mapping(mgr, b, 'invoice', m);
    ASSERT r->>'status' = 'NEEDS_REVIEW' AND (r->>'accepted')::int = 1 AND (r->>'needs_review')::int = 4, 'after approval: ' || r::text;
    ASSERT (SELECT normalized_fields FROM erp.raw_record WHERE batch_id = b AND record_no = 1)
           = '{"invoice_id":"RV-1","supplier_id":"RV-S1","invoice_date":"2026-10-05","due_date":"2026-11-04","amount":1000.50,"currency":"USD"}',
           'transforms applied';
    ASSERT (SELECT array_agg(record_no || ':' || rule_code ORDER BY record_no) FROM erp.validation_issue WHERE batch_id = b)
           = ARRAY['2:CONVERSION', '3:REFERENCE', '4:DUPLICATE', '5:CHECK'], 'one finding per bad record';
    ASSERT (SELECT status FROM erp.mapping_version WHERE batch_id = b ORDER BY version DESC LIMIT 1) = 'APPROVED', 'versioned';

    r := erp.sp_correct_value(mgr, b, 2, 'amount', '200');
    ASSERT (SELECT state FROM erp.raw_record WHERE batch_id = b AND record_no = 2) = 'ACCEPTED', 'corrected record accepted';
    ASSERT (SELECT original_value || '->' || corrected_value FROM erp.validation_issue
            WHERE batch_id = b AND record_no = 2) = 'abc->200', 'original value kept with the correction';
    PERFORM erp.sp_reject_record(mgr, b, 3, 'Unknown supplier');
    PERFORM erp.sp_reject_record(mgr, b, 4, 'Duplicate of row 2');
    BEGIN
        PERFORM erp.sp_confirm_issue(mgr, b, (SELECT issue_id FROM erp.validation_issue WHERE batch_id = b AND record_no = 5));
        RAISE EXCEPTION 'confirmed a CHECK failure without fixing it';
    EXCEPTION WHEN invalid_parameter_value THEN NULL;
    END;
    r := erp.sp_correct_value(mgr, b, 5, 'due_date', '2026-12-01');
    ASSERT r->>'status' = 'READY_TO_COMMIT', 'ready after fixes: ' || r::text;

    r := erp.sp_commit_batch(mgr, b);
    ASSERT (r->>'accepted')::int = 3 AND (r->>'rejected')::int = 2 AND r->'loaded'->>'invoice' = '3', 'commit: ' || r::text;
    ASSERT (SELECT amount FROM erp.invoice WHERE invoice_id = 'RV-2') = 200, 'corrected value committed';
    RAISE NOTICE 'PASS mapping review + data quality';
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
    ASSERT pg_temp.denied('erp_app', 'SELECT 1 FROM erp.assistant_audit'),     'assistant tables only via functions';
    ASSERT pg_temp.denied('erp_app', 'SELECT erp._assistant_begin(NULL, ''x'', ''{}'')'), 'internal helper not callable';
    ASSERT pg_temp.denied('erp_app', 'SELECT lending.fn_tool_application_summary(NULL, now()::date, now()::date)'),
           'erp_app cannot call lending tools';
    ASSERT pg_temp.denied('erp_ro',  'SELECT erp.fn_tool_payables_ageing(NULL, now()::date)'), 'read-only login has no tools';
    RAISE NOTICE 'PASS role isolation';
END $$;

ROLLBACK;
\echo 'ALL TESTS PASSED (changes rolled back)'
