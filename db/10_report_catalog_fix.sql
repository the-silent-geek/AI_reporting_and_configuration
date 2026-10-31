-- Permission checks returning void must be executed, not used as NULL filters.
DO $migration$
DECLARE s text;
BEGIN
 FOREACH s IN ARRAY ARRAY['erp','aml','lending'] LOOP
  EXECUTE format($sql$
   CREATE OR REPLACE FUNCTION %1$I.fn_list_reports(p_user uuid) RETURNS jsonb
   LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = %1$I, public, pg_temp AS $body$
   DECLARE result jsonb;
   BEGIN
    PERFORM _report_permission(p_user,'report.view');
    SELECT jsonb_build_object('reports',coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.name),'[]')) INTO result
    FROM (SELECT template_code,version,name,definition FROM template_version WHERE kind='REPORT' AND status='PUBLISHED') t;
    RETURN result;
   END $body$;
  $sql$,s);
 END LOOP;
END $migration$;
