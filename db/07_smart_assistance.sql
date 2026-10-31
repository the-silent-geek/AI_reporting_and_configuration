-- =============================================================================
-- 07_smart_assistance.sql  -  allowlisted data tools for Smart Assistance.
--
-- The assistant (backend/app/assistant) never writes SQL. It may only call these
-- functions, one per tool in docs_ai/02 § Allowlisted data tools:
--
--   lending.fn_tool_application_summary / _details / _trend
--   erp.fn_tool_payables_ageing / _overdue_by_supplier / _payment_details
--   aml.fn_tool_alert_summary / _alert_details / _case_details
--
-- Every tool:
--   * authorizes again (assistant.use + dashboard.view in the product) via _assistant_begin
--   * records the call in assistant_tool_run; its id is the result_reference
--   * returns the result contract: period, filters, metric definitions, kpis,
--     chart_data, supporting_rows. PostgreSQL computes every number.
--   * never sums amounts across currencies: money KPIs are {currency: amount}
--   * leaves customer/applicant references out of summaries
-- =============================================================================

\set schema erp
\ir _assistant.sql
\set schema aml
\ir _assistant.sql
\set schema lending
\ir _assistant.sql

-- ------------------------------------------------------------- LENDING ----

CREATE FUNCTION lending.fn_tool_application_summary(
    p_user_id uuid, p_start date, p_end date, p_status text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = lending, public, pg_temp AS $$
DECLARE
    v_filters jsonb := jsonb_build_object('start_date', p_start, 'end_date', p_end, 'status', upper(btrim(p_status)));
    v_run uuid;
    v_kpis jsonb; v_chart jsonb; v_rows jsonb;
BEGIN
    PERFORM _assistant_check_period(p_start, p_end);
    v_run := _assistant_begin(p_user_id, 'get_lending_application_summary', jsonb_strip_nulls(v_filters));

    CREATE TEMP TABLE IF NOT EXISTS pg_temp.a ON COMMIT DROP AS SELECT * FROM application LIMIT 0;
    TRUNCATE pg_temp.a;
    INSERT INTO pg_temp.a SELECT * FROM application
    WHERE applied_at BETWEEN p_start AND p_end AND (p_status IS NULL OR upper(btrim(status)) = upper(btrim(p_status)));

    SELECT jsonb_build_object(
               'application_count', (SELECT count(*) FROM pg_temp.a),
               'requested_amount_by_currency',
               (SELECT coalesce(jsonb_object_agg(currency, total), '{}')
                FROM (SELECT currency, sum(requested_amount) AS total FROM pg_temp.a GROUP BY currency) x))
    INTO v_kpis;
    SELECT coalesce(jsonb_agg(jsonb_build_object('status', status, 'currency', currency,
                                                 'application_count', n, 'requested_amount', amt)
                              ORDER BY status, currency), '[]')
    INTO v_chart
    FROM (SELECT status, currency, count(*) AS n, sum(requested_amount) AS amt FROM pg_temp.a GROUP BY 1, 2) x;
    SELECT coalesce(jsonb_agg(r ORDER BY r->>'applied_at' DESC, r->>'application_id'), '[]') INTO v_rows
    FROM (SELECT jsonb_build_object('application_id', application_id, 'applied_at', applied_at, 'status', status,
                                    'requested_amount', requested_amount, 'currency', currency, 'product', product) AS r
          FROM pg_temp.a ORDER BY applied_at DESC, application_id LIMIT 20) x;

    RETURN _assistant_result(v_run, p_start || ' to ' || p_end, v_filters,
        '[{"metric":"application_count","definition":"Applications submitted (applied_at) in the period, optionally with the given status."},
          {"metric":"requested_amount_by_currency","definition":"Sum of requested amounts of those applications, per currency."}]',
        v_kpis, v_chart, v_rows);
END $$;

CREATE FUNCTION lending.fn_tool_application_details(p_user_id uuid, p_application_id text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = lending, public, pg_temp AS $$
DECLARE
    v_filters jsonb := jsonb_build_object('application_id', p_application_id);
    v_run uuid := _assistant_begin(p_user_id, 'get_lending_application_details', v_filters);
    v_app jsonb;
BEGIN
    SELECT to_jsonb(a) - 'batch_id' - 'source_record_no' INTO v_app FROM application a WHERE application_id = p_application_id;
    RETURN _assistant_result(v_run, 'Current data', v_filters,
        '[{"metric":"disbursed_amount_by_currency","definition":"Sum of all disbursements recorded for the application, per currency."}]',
        jsonb_build_object(
            'found', v_app IS NOT NULL,
            'disbursement_count', (SELECT count(*) FROM disbursement WHERE application_id = p_application_id),
            'disbursed_amount_by_currency',
            (SELECT coalesce(jsonb_object_agg(currency, total), '{}')
             FROM (SELECT currency, sum(amount) AS total FROM disbursement
                   WHERE application_id = p_application_id GROUP BY currency) x)),
        (SELECT coalesce(jsonb_agg(jsonb_build_object('status', status, 'occurred_at', occurred_at) ORDER BY occurred_at), '[]')
         FROM application_status_event WHERE application_id = p_application_id),
        CASE WHEN v_app IS NULL THEN '[]'::jsonb ELSE jsonb_build_array(v_app) ||
            (SELECT coalesce(jsonb_agg(jsonb_build_object('disbursement_id', disbursement_id, 'paid_at', paid_at,
                                                          'amount', amount, 'currency', currency) ORDER BY paid_at), '[]')
             FROM disbursement WHERE application_id = p_application_id) END);
END $$;

CREATE FUNCTION lending.fn_tool_application_trend(
    p_user_id uuid, p_start date, p_end date, p_granularity text, p_status text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = lending, public, pg_temp AS $$
DECLARE
    v_filters jsonb := jsonb_build_object('start_date', p_start, 'end_date', p_end,
                                          'granularity', lower(p_granularity), 'status', upper(btrim(p_status)));
    v_run uuid;
BEGIN
    PERFORM _assistant_check_period(p_start, p_end);
    IF lower(p_granularity) NOT IN ('month', 'week') THEN
        RAISE EXCEPTION 'granularity must be month or week' USING ERRCODE = '22023';
    END IF;
    v_run := _assistant_begin(p_user_id, 'get_lending_application_trend', jsonb_strip_nulls(v_filters));

    RETURN _assistant_result(v_run, p_start || ' to ' || p_end, v_filters,
        '[{"metric":"application_count","definition":"Applications submitted in each period bucket (date_trunc of applied_at)."},
          {"metric":"requested_amount","definition":"Sum of requested amounts in the bucket, per currency."}]',
        (SELECT jsonb_build_object('application_count', count(*), 'bucket_count',
                                   count(DISTINCT date_trunc(lower(p_granularity), applied_at)))
         FROM application WHERE applied_at BETWEEN p_start AND p_end AND (p_status IS NULL OR upper(btrim(status)) = upper(btrim(p_status)))),
        (SELECT coalesce(jsonb_agg(jsonb_build_object('period_start', b::date, 'currency', currency,
                                                      'application_count', n, 'requested_amount', amt)
                                   ORDER BY b, currency), '[]')
         FROM (SELECT date_trunc(lower(p_granularity), applied_at) AS b, currency, count(*) AS n,
                      sum(requested_amount) AS amt
               FROM application
               WHERE applied_at BETWEEN p_start AND p_end AND (p_status IS NULL OR upper(btrim(status)) = upper(btrim(p_status)))
               GROUP BY 1, 2) x),
        '[]');
END $$;

-- ----------------------------------------------------------------- ERP ----
-- Outstanding on an as-of date = invoice amount
--   - payments allocated to it with effective_date <= as-of
--   - APPROVED credit notes on it with effective_date <= as-of
-- Only invoices issued on/before the as-of date count. Overdue = due_date < as-of.

CREATE FUNCTION erp._open_invoices(p_as_of date)
RETURNS TABLE (invoice_id text, supplier_id text, supplier_name text, invoice_date date, due_date date,
               currency char(3), outstanding numeric, days_overdue int)
LANGUAGE sql STABLE SET search_path = erp, public, pg_temp AS $$
    SELECT * FROM (
        SELECT i.invoice_id, i.supplier_id, s.supplier_name, i.invoice_date, i.due_date, i.currency,
               i.amount
                 - coalesce((SELECT sum(pa.amount) FROM payment_allocation pa
                             WHERE pa.invoice_id = i.invoice_id AND pa.effective_date <= p_as_of), 0)
                 - coalesce((SELECT sum(cn.amount) FROM credit_note cn
                             WHERE cn.invoice_id = i.invoice_id AND cn.is_approved AND cn.effective_date <= p_as_of), 0)
                 AS outstanding,
               greatest(p_as_of - i.due_date, 0) AS days_overdue
        FROM invoice i LEFT JOIN supplier s ON s.supplier_id = i.supplier_id
        WHERE i.invoice_date <= p_as_of) x
    WHERE outstanding > 0;
$$;

CREATE FUNCTION erp.fn_tool_payables_ageing(
    p_user_id uuid, p_as_of date, p_supplier_id text DEFAULT NULL, p_currency text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, public, pg_temp AS $$
DECLARE
    v_filters jsonb := jsonb_build_object('as_of_date', p_as_of, 'supplier_id', p_supplier_id,
                                          'currency', upper(p_currency));
    v_run uuid;
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'as_of_date is required' USING ERRCODE = '22023';
    END IF;
    v_run := _assistant_begin(p_user_id, 'get_erp_payables_ageing', jsonb_strip_nulls(v_filters));

    CREATE TEMP TABLE IF NOT EXISTS pg_temp.o ON COMMIT DROP AS SELECT * FROM _open_invoices(p_as_of) LIMIT 0;
    TRUNCATE pg_temp.o;
    INSERT INTO pg_temp.o SELECT * FROM _open_invoices(p_as_of)
    WHERE (p_supplier_id IS NULL OR supplier_id = p_supplier_id) AND (p_currency IS NULL OR currency = upper(p_currency));

    RETURN _assistant_result(v_run, 'As of ' || p_as_of, v_filters,
        '[{"metric":"outstanding_amount","definition":"Invoice amount minus payment allocations and approved credit notes effective on or before the as-of date; only invoices issued by then."},
          {"metric":"overdue_amount","definition":"Outstanding amount of invoices whose due date is before the as-of date."},
          {"metric":"ageing_bucket","definition":"Days past due on the as-of date: current (not yet due), 1-30, 31-60, 61-90, over 90."}]',
        (SELECT jsonb_build_object(
                    'open_invoice_count', count(*),
                    'overdue_invoice_count', count(*) FILTER (WHERE days_overdue > 0),
                    'outstanding_amount_by_currency',
                    coalesce((SELECT jsonb_object_agg(currency, t) FROM (SELECT currency, sum(outstanding) t FROM pg_temp.o GROUP BY 1) x), '{}'),
                    'overdue_amount_by_currency',
                    coalesce((SELECT jsonb_object_agg(currency, t) FROM (SELECT currency, sum(outstanding) t FROM pg_temp.o
                                                                         WHERE days_overdue > 0 GROUP BY 1) x), '{}'))
         FROM pg_temp.o),
        (SELECT coalesce(jsonb_agg(jsonb_build_object('bucket', bucket, 'currency', currency,
                                                      'invoice_count', n, 'outstanding_amount', amt)
                                   ORDER BY ord, currency), '[]')
         FROM (SELECT CASE WHEN days_overdue = 0 THEN 'current' WHEN days_overdue <= 30 THEN '1-30'
                           WHEN days_overdue <= 60 THEN '31-60' WHEN days_overdue <= 90 THEN '61-90' ELSE '90+' END AS bucket,
                      CASE WHEN days_overdue = 0 THEN 0 WHEN days_overdue <= 30 THEN 1
                           WHEN days_overdue <= 60 THEN 2 WHEN days_overdue <= 90 THEN 3 ELSE 4 END AS ord,
                      currency, count(*) AS n, sum(outstanding) AS amt
               FROM pg_temp.o GROUP BY 1, 2, 3) x),
        (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.days_overdue DESC, r.invoice_id), '[]')
         FROM (SELECT invoice_id, supplier_name, due_date, currency, outstanding AS outstanding_amount, days_overdue
               FROM pg_temp.o ORDER BY days_overdue DESC, invoice_id LIMIT 20) r));
END $$;

CREATE FUNCTION erp.fn_tool_overdue_by_supplier(p_user_id uuid, p_as_of date, p_limit int DEFAULT 10) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, public, pg_temp AS $$
DECLARE
    v_limit int := least(greatest(coalesce(p_limit, 10), 1), 50);
    v_filters jsonb := jsonb_build_object('as_of_date', p_as_of, 'limit', least(greatest(coalesce(p_limit, 10), 1), 50));
    v_run uuid;
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'as_of_date is required' USING ERRCODE = '22023';
    END IF;
    v_run := _assistant_begin(p_user_id, 'get_erp_overdue_by_supplier', v_filters);

    RETURN _assistant_result(v_run, 'As of ' || p_as_of, v_filters,
        '[{"metric":"overdue_amount","definition":"Outstanding amount (invoice minus allocations and approved credits effective by the as-of date) of invoices due before the as-of date, per supplier and currency."}]',
        (SELECT jsonb_build_object('overdue_supplier_count', count(DISTINCT supplier_id),
                                   'overdue_invoice_count', count(*),
                                   'overdue_amount_by_currency',
                                   coalesce((SELECT jsonb_object_agg(currency, t) FROM (
                                       SELECT currency, sum(outstanding) t FROM _open_invoices(p_as_of)
                                       WHERE days_overdue > 0 GROUP BY 1) x), '{}'))
         FROM _open_invoices(p_as_of) WHERE days_overdue > 0),
        (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.overdue_amount DESC, r.supplier_id), '[]')
         FROM (SELECT supplier_id, max(supplier_name) AS supplier_name, currency, count(*) AS overdue_invoice_count,
                      sum(outstanding) AS overdue_amount, max(days_overdue) AS max_days_overdue
               FROM _open_invoices(p_as_of) WHERE days_overdue > 0
               GROUP BY supplier_id, currency ORDER BY overdue_amount DESC, supplier_id LIMIT v_limit) r),
        '[]');
END $$;

CREATE FUNCTION erp.fn_tool_payment_details(p_user_id uuid, p_payment_id text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = erp, public, pg_temp AS $$
DECLARE
    v_filters jsonb := jsonb_build_object('payment_id', p_payment_id);
    v_run uuid := _assistant_begin(p_user_id, 'get_erp_payment_details', v_filters);
    v_pay jsonb;
BEGIN
    SELECT to_jsonb(p) - 'batch_id' - 'source_record_no' || jsonb_build_object('supplier_name', s.supplier_name)
    INTO v_pay FROM payment p LEFT JOIN supplier s USING (supplier_id) WHERE p.payment_id = p_payment_id;
    RETURN _assistant_result(v_run, 'Current data', v_filters,
        '[{"metric":"allocated_amount","definition":"Part of the payment applied to invoices (payment_allocation)."},
          {"metric":"unallocated_amount","definition":"Payment amount minus allocated amount."}]',
        jsonb_build_object(
            'found', v_pay IS NOT NULL,
            'allocation_count', (SELECT count(*) FROM payment_allocation WHERE payment_id = p_payment_id),
            'allocated_amount', (SELECT coalesce(sum(amount), 0) FROM payment_allocation WHERE payment_id = p_payment_id),
            'unallocated_amount', (SELECT p.amount - coalesce(sum(pa.amount), 0) FROM payment p
                                   LEFT JOIN payment_allocation pa USING (payment_id)
                                   WHERE p.payment_id = p_payment_id GROUP BY p.amount)),
        (SELECT coalesce(jsonb_agg(jsonb_build_object('invoice_id', invoice_id, 'amount', amount,
                                                      'effective_date', effective_date) ORDER BY effective_date, invoice_id), '[]')
         FROM payment_allocation WHERE payment_id = p_payment_id),
        CASE WHEN v_pay IS NULL THEN '[]'::jsonb ELSE jsonb_build_array(v_pay) END);
END $$;

-- ----------------------------------------------------------------- AML ----

CREATE FUNCTION aml.fn_tool_alert_summary(
    p_user_id uuid, p_start date, p_end date, p_status text DEFAULT NULL, p_severity text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = aml, public, pg_temp AS $$
DECLARE
    v_filters jsonb := jsonb_build_object('start_date', p_start, 'end_date', p_end,
                                          'status', upper(p_status), 'severity', upper(p_severity));
    v_run uuid;
BEGIN
    PERFORM _assistant_check_period(p_start, p_end);
    IF p_severity IS NOT NULL AND upper(p_severity) NOT IN ('LOW','MEDIUM','HIGH','CRITICAL') THEN
        RAISE EXCEPTION 'severity must be LOW, MEDIUM, HIGH or CRITICAL' USING ERRCODE = '22023';
    END IF;
    v_run := _assistant_begin(p_user_id, 'get_aml_alert_summary', jsonb_strip_nulls(v_filters));

    CREATE TEMP TABLE IF NOT EXISTS pg_temp.al ON COMMIT DROP AS SELECT * FROM alert LIMIT 0;
    TRUNCATE pg_temp.al;
    INSERT INTO pg_temp.al SELECT * FROM alert
    WHERE raised_at::date BETWEEN p_start AND p_end
      AND (p_status IS NULL OR status = upper(p_status)) AND (p_severity IS NULL OR severity = upper(p_severity));

    RETURN _assistant_result(v_run, p_start || ' to ' || p_end, v_filters,
        '[{"metric":"alert_count","definition":"Alerts raised (raised_at) in the period, after the status/severity filters."},
          {"metric":"alerts_without_case","definition":"Of those, alerts not linked to an investigation case."}]',
        (SELECT jsonb_build_object(
                    'alert_count', count(*),
                    'alerts_without_case', count(*) FILTER (WHERE case_id IS NULL),
                    'by_severity', coalesce((SELECT jsonb_object_agg(severity, n) FROM
                                             (SELECT severity, count(*) n FROM pg_temp.al GROUP BY 1) x), '{}'),
                    'by_status', coalesce((SELECT jsonb_object_agg(status, n) FROM
                                           (SELECT status, count(*) n FROM pg_temp.al GROUP BY 1) x), '{}'))
         FROM pg_temp.al),
        (SELECT coalesce(jsonb_agg(jsonb_build_object('severity', severity, 'status', status, 'alert_count', n)
                                   ORDER BY array_position(ARRAY['CRITICAL','HIGH','MEDIUM','LOW'], severity), status), '[]')
         FROM (SELECT severity, status, count(*) AS n FROM pg_temp.al GROUP BY 1, 2) x),
        (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.raised_at DESC, r.alert_id), '[]')
         FROM (SELECT alert_id, raised_at, severity, status, case_id, rule_description
               FROM pg_temp.al ORDER BY raised_at DESC, alert_id LIMIT 20) r));
END $$;

CREATE FUNCTION aml.fn_tool_alert_details(p_user_id uuid, p_alert_id text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = aml, public, pg_temp AS $$
DECLARE
    v_filters jsonb := jsonb_build_object('alert_id', p_alert_id);
    v_run uuid := _assistant_begin(p_user_id, 'get_aml_alert_details', v_filters);
    v_alert jsonb;
BEGIN
    SELECT to_jsonb(a) - 'batch_id' - 'source_record_no' INTO v_alert FROM alert a WHERE alert_id = p_alert_id;
    RETURN _assistant_result(v_run, 'Current data', v_filters, '[]',
        jsonb_build_object('found', v_alert IS NOT NULL,
                           'status_change_count', (SELECT count(*) FROM status_event
                                                   WHERE entity_type = 'ALERT' AND entity_id = p_alert_id)),
        (SELECT coalesce(jsonb_agg(jsonb_build_object('status', status, 'occurred_at', occurred_at) ORDER BY occurred_at), '[]')
         FROM status_event WHERE entity_type = 'ALERT' AND entity_id = p_alert_id),
        CASE WHEN v_alert IS NULL THEN '[]'::jsonb ELSE jsonb_build_array(v_alert) END);
END $$;

CREATE FUNCTION aml.fn_tool_case_details(p_user_id uuid, p_case_id text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = aml, public, pg_temp AS $$
DECLARE
    v_filters jsonb := jsonb_build_object('case_id', p_case_id);
    v_run uuid := _assistant_begin(p_user_id, 'get_aml_case_details', v_filters);
    v_case jsonb;
BEGIN
    SELECT to_jsonb(c) - 'batch_id' - 'source_record_no' INTO v_case FROM investigation_case c WHERE case_id = p_case_id;
    RETURN _assistant_result(v_run, 'Current data', v_filters, '[]',
        jsonb_build_object('found', v_case IS NOT NULL,
                           'alert_count', (SELECT count(*) FROM alert WHERE case_id = p_case_id),
                           'alerts_by_severity', coalesce((SELECT jsonb_object_agg(severity, n) FROM
                               (SELECT severity, count(*) n FROM alert WHERE case_id = p_case_id GROUP BY 1) x), '{}')),
        (SELECT coalesce(jsonb_agg(jsonb_build_object('status', status, 'occurred_at', occurred_at) ORDER BY occurred_at), '[]')
         FROM status_event WHERE entity_type = 'CASE' AND entity_id = p_case_id),
        CASE WHEN v_case IS NULL THEN '[]'::jsonb ELSE jsonb_build_array(v_case) ||
            (SELECT coalesce(jsonb_agg(jsonb_build_object('alert_id', alert_id, 'raised_at', raised_at,
                                                          'severity', severity, 'status', status) ORDER BY raised_at), '[]')
             FROM alert WHERE case_id = p_case_id) END);
END $$;

-- =============================================================================
-- Grants: the product login may only EXECUTE the public functions (sp_/fn_);
-- tables and _internal helpers stay private to the function owner.
-- =============================================================================
SELECT format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', p.oid::regprocedure)
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname IN ('erp', 'aml', 'lending')
  AND (p.proname LIKE 'fn_tool_%' OR p.proname LIKE '%assistant%' OR p.proname = '_open_invoices')
\gexec

SELECT format('GRANT EXECUTE ON FUNCTION %s TO %I', p.oid::regprocedure, n.nspname || '_app')
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname IN ('erp', 'aml', 'lending')
  AND (p.proname LIKE 'fn_tool_%' OR p.proname IN ('sp_assistant_save_conversation',
                                                   'fn_assistant_get_conversation', 'sp_assistant_audit'))
\gexec
