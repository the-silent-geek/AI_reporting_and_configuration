-- Run on an isolated built test database, never the shared database.
BEGIN;
DO $$
DECLARE u uuid; s text; d jsonb; m jsonb; b jsonb; expected numeric;
BEGIN
 SELECT user_id INTO u FROM iam.app_user WHERE is_super_admin LIMIT 1;
 IF u IS NULL THEN RAISE EXCEPTION 'Test database needs seeded super admin'; END IF;
 FOREACH s IN ARRAY ARRAY['erp','aml','lending'] LOOP
  EXECUTE format('SELECT %I.fn_business_dashboard($1,$2,$3)',s)
   INTO d USING u,DATE '2000-01-01',DATE '2100-12-31';
  ASSERT jsonb_array_length(d->'metrics')=7, 'Missing dashboard metrics';
  FOR m IN SELECT value FROM jsonb_array_elements(d->'metrics') LOOP
   FOR b IN SELECT value FROM jsonb_array_elements(m->'buckets') LOOP
    SELECT coalesce(sum(CASE WHEN m ? 'amount' THEN (r->>(m->>'amount'))::numeric ELSE 1 END),0)
      INTO expected FROM jsonb_array_elements(b->'records') r;
    ASSERT expected=(b->>'value')::numeric, 'Drill-down does not reconcile';
    ASSERT NOT EXISTS(SELECT 1 FROM jsonb_array_elements(b->'records') r WHERE r->>'batch_id' IS NULL), 'Missing lineage';
   END LOOP;
  END LOOP;
  BEGIN
   EXECUTE format('SELECT %I.fn_business_dashboard($1,$2,$3)',s) USING NULL::uuid,DATE '2026-01-01',DATE '2026-12-31';
   RAISE EXCEPTION 'Anonymous dashboard access succeeded';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
   EXECUTE format('SELECT %I.fn_business_dashboard($1,$2,$3)',s) USING u,DATE '2026-12-31',DATE '2026-01-01';
   RAISE EXCEPTION 'Inverted range accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  ASSERT NOT has_function_privilege(s||'_app',format('%I._dashboard_rows(date,date)',s),'EXECUTE'), 'Helper exposed';
 END LOOP;
END $$;
ROLLBACK;
