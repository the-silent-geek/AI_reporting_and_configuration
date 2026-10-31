-- Published, field-bound documents for records returned by assistant tools.
DO $migration$
DECLARE s text; entity text; u uuid; fields jsonb; code text;
BEGIN
 SELECT user_id INTO u FROM iam.app_user WHERE is_super_admin ORDER BY created_at LIMIT 1;
 IF u IS NULL THEN RAISE EXCEPTION 'A super admin is required to seed record templates'; END IF;
 FOREACH s IN ARRAY ARRAY['erp','lending','aml'] LOOP
  FOR entity IN SELECT unnest(CASE s WHEN 'erp' THEN ARRAY['invoice','payment','supplier'] WHEN 'lending' THEN ARRAY['application','disbursement'] ELSE ARRAY['alert','investigation_case'] END) LOOP
   EXECUTE format('SELECT jsonb_agg(jsonb_build_object(''label'',initcap(replace(column_name,''_'','' '')),''binding'',column_name) ORDER BY ordinal) FROM %I._domain_columns($1)',s) INTO fields USING entity;
   code:='RECORD_'||upper(entity);
   EXECUTE format('INSERT INTO %I.template_version(template_code,version,kind,name,root_entity,definition,status,created_by,published_at) VALUES($1,1,''DOCUMENT'',$2,$3,$4,''PUBLISHED'',$5,now()) ON CONFLICT DO NOTHING',s)
    USING code,initcap(replace(entity,'_',' '))||' record',entity,jsonb_build_object('title',initcap(replace(entity,'_',' '))||' record','sections',jsonb_build_array(jsonb_build_object('type','fields','heading','Record details','fields',fields))),u;
  END LOOP;
  EXECUTE format($sql$
   CREATE OR REPLACE FUNCTION %1$I.fn_record_template(p_user uuid,p_entity text,p_key text) RETURNS jsonb
   LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=%1$I,public,pg_temp AS $body$
   DECLARE t template_version; pk text; r jsonb;
   BEGIN
    PERFORM _report_permission(p_user,'template.view');
    PERFORM _report_permission(p_user,'report.generate');
    IF NOT _is_domain_table(p_entity) THEN RAISE EXCEPTION 'Unsupported record type' USING ERRCODE='22023'; END IF;
    IF (SELECT count(*) FROM _domain_columns(p_entity) WHERE is_key)<>1 THEN RAISE EXCEPTION 'Unsupported record key' USING ERRCODE='22023'; END IF;
    SELECT * INTO t FROM template_version WHERE kind='DOCUMENT' AND status='PUBLISHED' AND root_entity=p_entity AND template_code='RECORD_'||upper(p_entity) ORDER BY version DESC LIMIT 1;
    IF NOT FOUND THEN RAISE EXCEPTION 'No published record template' USING ERRCODE='P0002'; END IF;
    SELECT column_name INTO pk FROM _domain_columns(p_entity) WHERE is_key;
    EXECUTE format('SELECT to_jsonb(x) - ''batch_id'' - ''source_record_no'' FROM %%I.%%I x WHERE %%I::text=$1',current_schema(),p_entity,pk) INTO r USING p_key;
    IF r IS NULL THEN RAISE EXCEPTION 'Record not found' USING ERRCODE='P0002'; END IF;
    RETURN jsonb_build_object('template_code',t.template_code,'version',t.version,'template',t.definition,'record',r);
   END $body$;
  $sql$,s);
  EXECUTE format('REVOKE ALL ON FUNCTION %I.fn_record_template(uuid,text,text) FROM PUBLIC',s);
  EXECUTE format('GRANT EXECUTE ON FUNCTION %I.fn_record_template(uuid,text,text) TO %I',s,s||'_app');
 END LOOP;
END $migration$;
