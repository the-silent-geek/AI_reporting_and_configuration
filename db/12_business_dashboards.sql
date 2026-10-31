-- Every figure and drill-down share the same committed record set.
-- Currency amounts are always grouped separately. Dates are UTC for timestamps.
CREATE OR REPLACE FUNCTION lending._dashboard_rows(p_start date,p_end date)
RETURNS jsonb LANGUAGE sql STABLE SET search_path=lending,public,pg_temp AS $$
 SELECT jsonb_build_object('applications',coalesce((SELECT jsonb_agg(to_jsonb(a) || jsonb_build_object('status',upper(btrim(status)),'month',to_char(applied_at,'YYYY-MM'))) FROM application a WHERE applied_at BETWEEN p_start AND p_end),'[]'::jsonb),
 'disbursements',coalesce((SELECT jsonb_agg(to_jsonb(d) || jsonb_build_object('month',to_char(paid_at,'YYYY-MM'))) FROM disbursement d WHERE paid_at BETWEEN p_start AND p_end),'[]'::jsonb));
$$;
CREATE OR REPLACE FUNCTION erp._dashboard_rows(p_start date,p_end date)
RETURNS jsonb LANGUAGE sql STABLE SET search_path=erp,public,pg_temp AS $$
 SELECT jsonb_build_object('payables',coalesce((SELECT jsonb_agg(to_jsonb(o) || jsonb_build_object('batch_id',i.batch_id,'source_record_no',i.source_record_no,'ageing',CASE WHEN o.days_overdue=0 THEN 'Current' WHEN o.days_overdue<=30 THEN '1–30' WHEN o.days_overdue<=60 THEN '31–60' WHEN o.days_overdue<=90 THEN '61–90' ELSE '90+' END)) FROM _open_invoices(p_end) o JOIN invoice i USING(invoice_id)),'[]'::jsonb),
 'payments',coalesce((SELECT jsonb_agg(to_jsonb(p) || jsonb_build_object('month',to_char(payment_date,'YYYY-MM'))) FROM payment p WHERE payment_date BETWEEN p_start AND p_end),'[]'::jsonb));
$$;
CREATE OR REPLACE FUNCTION aml._dashboard_rows(p_start date,p_end date)
RETURNS jsonb LANGUAGE sql STABLE SET search_path=aml,public,pg_temp AS $$
 SELECT jsonb_build_object('alerts',coalesce((SELECT jsonb_agg(to_jsonb(a) || jsonb_build_object('status',upper(btrim(status)),'month',to_char(raised_at AT TIME ZONE 'UTC','YYYY-MM'))) FROM alert a WHERE (raised_at AT TIME ZONE 'UTC')::date BETWEEN p_start AND p_end),'[]'::jsonb),
 'investigations',coalesce((SELECT jsonb_agg(to_jsonb(c) || jsonb_build_object('status',upper(btrim(status)),'month',to_char(opened_at AT TIME ZONE 'UTC','YYYY-MM'))) FROM investigation_case c WHERE (opened_at AT TIME ZONE 'UTC')::date BETWEEN p_start AND p_end),'[]'::jsonb));
$$;
DO $migration$
DECLARE s text;
BEGIN
 FOREACH s IN ARRAY ARRAY['erp','aml','lending'] LOOP
  EXECUTE format($sql$
   CREATE OR REPLACE FUNCTION %1$I.fn_business_dashboard(p_user uuid,p_start date,p_end date)
   RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=%1$I,public,pg_temp AS $body$
   DECLARE data jsonb; metrics jsonb := '[]'; spec jsonb; selected jsonb; buckets jsonb; total numeric; definitions jsonb;
   BEGIN
    PERFORM _report_permission(p_user,'dashboard.view');
    IF p_start IS NULL OR p_end IS NULL OR p_end<p_start THEN RAISE EXCEPTION 'Choose a valid date range' USING ERRCODE='22023'; END IF;
    data:=_dashboard_rows(p_start,p_end);
    definitions:=CASE current_schema()
    WHEN 'lending' THEN '[{"id":"applications","title":"Total applications","source":"applications"},{"id":"approved","title":"Approved applications","source":"applications","status":"APPROVED"},{"id":"rejected","title":"Rejected applications","source":"applications","status":"REJECTED"},{"id":"disbursed","title":"Disbursement amounts","source":"disbursements","amount":"amount"},{"id":"decisions","title":"Application decisions","source":"applications","group":"status","chart":"donut"},{"id":"products","title":"Applications by product","source":"applications","group":"product","chart":"bar"},{"id":"trend","title":"Application trends","source":"applications","group":"month","chart":"line"}]'::jsonb
    WHEN 'erp' THEN '[{"id":"payables","title":"Total outstanding payables","source":"payables","amount":"outstanding"},{"id":"overdue","title":"Overdue payables","source":"payables","amount":"outstanding","overdue":true},{"id":"payments","title":"Payments processed","source":"payments"},{"id":"paid","title":"Payments amount","source":"payments","amount":"amount"},{"id":"ageing","title":"Payables ageing","source":"payables","group":"ageing","amount":"outstanding","chart":"donut"},{"id":"suppliers","title":"Outstanding by supplier","source":"payables","group":"supplier_id","amount":"outstanding","chart":"bar"},{"id":"trend","title":"Monthly expenditure (payments)","source":"payments","group":"month","amount":"amount","chart":"line"}]'::jsonb
    ELSE '[{"id":"alerts","title":"Total alerts","source":"alerts"},{"id":"open","title":"Open investigations","source":"investigations","open":true},{"id":"closed","title":"Closed alerts","source":"alerts","status":"CLOSED"},{"id":"cases","title":"Investigations opened","source":"investigations"},{"id":"severity","title":"Alert severity","source":"alerts","group":"severity","chart":"donut"},{"id":"statuses","title":"Investigation status","source":"investigations","group":"status","chart":"bar"},{"id":"trend","title":"Investigation opening trends","source":"investigations","group":"month","chart":"line"}]'::jsonb END;
    FOR spec IN SELECT value FROM jsonb_array_elements(definitions) LOOP
     SELECT coalesce(jsonb_agg(r),'[]') INTO selected FROM jsonb_array_elements(data->(spec->>'source')) r
     WHERE (NOT spec ? 'status' OR r->>'status'=spec->>'status')
      AND (NOT spec ? 'overdue' OR (r->>'days_overdue')::int>0)
      AND (NOT spec ? 'open' OR (r->>'closed_at' IS NULL AND r->>'status' NOT IN ('CLOSED','RESOLVED','CANCELLED')));
     SELECT coalesce(jsonb_agg(to_jsonb(b) ORDER BY b.label,b.currency),'[]') INTO buckets FROM (
      SELECT coalesce(r->>(spec->>'group'),'Unspecified') AS label,
       CASE WHEN spec ? 'amount' THEN r->>'currency' ELSE '' END AS currency,
       sum(CASE WHEN spec ? 'amount' THEN (r->>(spec->>'amount'))::numeric ELSE 1 END) AS value,
       jsonb_agg(r) AS records
      FROM jsonb_array_elements(selected) r GROUP BY 1,2
     ) b;
     metrics:=metrics || jsonb_build_array(spec || jsonb_build_object('buckets',buckets,'record_count',jsonb_array_length(selected)));
    END LOOP;
    RETURN jsonb_build_object('metrics',metrics,'start_date',p_start,'end_date',p_end,'generated_at',now());
   END $body$;
  $sql$,s);
  EXECUTE format('REVOKE ALL ON FUNCTION %I._dashboard_rows(date,date) FROM PUBLIC',s);
  EXECUTE format('REVOKE ALL ON FUNCTION %I.fn_business_dashboard(uuid,date,date) FROM PUBLIC',s);
  EXECUTE format('GRANT EXECUTE ON FUNCTION %I.fn_business_dashboard(uuid,date,date) TO %I',s,s||'_app');
 END LOOP;
END $migration$;
