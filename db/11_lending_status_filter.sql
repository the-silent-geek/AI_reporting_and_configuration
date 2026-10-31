-- Compare imported Lending statuses without case or surrounding whitespace.
-- CREATE OR REPLACE preserves existing grants and historical tool references.
CREATE OR REPLACE FUNCTION lending.fn_tool_application_summary(
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

CREATE OR REPLACE FUNCTION lending.fn_tool_application_trend(
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

