-- Per-product Reports and Templates implementation. Included by 09.

ALTER TABLE :"schema".report_run ADD COLUMN IF NOT EXISTS result jsonb;

CREATE FUNCTION :"schema"._report_permission(p_user uuid, p_permission text) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = :"schema", public, pg_temp AS $$
DECLARE v_app text := (SELECT code FROM iam.app WHERE schema_name = current_schema());
BEGIN
  IF NOT iam.fn_has_permission(p_user, v_app, p_permission) THEN
    RAISE EXCEPTION 'Not allowed: %', p_permission USING ERRCODE = '42501';
  END IF;
END $$;

CREATE FUNCTION :"schema"._report_dataset_allowed(p_dataset text) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT p_dataset = ANY (CASE current_schema()
    WHEN 'erp' THEN ARRAY['get_erp_payables_ageing','get_erp_overdue_by_supplier']
    WHEN 'lending' THEN ARRAY['get_lending_application_summary','get_lending_application_trend']
    WHEN 'aml' THEN ARRAY['get_aml_alert_summary'] ELSE ARRAY[]::text[] END);
$$;

CREATE FUNCTION :"schema"._run_dataset(p_user uuid, p_dataset text, p_params jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = :"schema", public, pg_temp AS $$
BEGIN
  IF NOT _report_dataset_allowed(p_dataset) THEN RAISE EXCEPTION 'Unknown report dataset %', p_dataset USING ERRCODE='22023'; END IF;
  CASE p_dataset
    WHEN 'get_erp_payables_ageing' THEN RETURN fn_tool_payables_ageing(p_user, (p_params->>'as_of_date')::date, p_params->>'supplier_id', p_params->>'currency');
    WHEN 'get_erp_overdue_by_supplier' THEN RETURN fn_tool_overdue_by_supplier(p_user, (p_params->>'as_of_date')::date, coalesce((p_params->>'limit')::int,10));
    WHEN 'get_lending_application_summary' THEN RETURN fn_tool_application_summary(p_user, (p_params->>'start_date')::date, (p_params->>'end_date')::date, p_params->>'status');
    WHEN 'get_lending_application_trend' THEN RETURN fn_tool_application_trend(p_user, (p_params->>'start_date')::date, (p_params->>'end_date')::date, p_params->>'granularity', p_params->>'status');
    WHEN 'get_aml_alert_summary' THEN RETURN fn_tool_alert_summary(p_user, (p_params->>'start_date')::date, (p_params->>'end_date')::date, p_params->>'status', p_params->>'severity');
  END CASE;
END $$;

CREATE FUNCTION :"schema"._validate_template(p_kind text, p_root text, p_definition jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = :"schema", public, pg_temp AS $$
DECLARE x jsonb; v_source text; v_binding text;
BEGIN
  IF p_kind='REPORT' THEN
    IF NOT _report_dataset_allowed(p_definition->>'dataset') THEN RAISE EXCEPTION 'Invalid report dataset' USING ERRCODE='22023'; END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(p_definition->'widgets','[]')) x WHERE x->>'type' NOT IN ('kpis','bar','table')) THEN RAISE EXCEPTION 'Invalid report widget' USING ERRCODE='22023'; END IF;
    RETURN;
  END IF;
  IF p_kind <> 'DOCUMENT' OR NOT _is_domain_table(p_root) THEN RAISE EXCEPTION 'root_entity must be a domain table' USING ERRCODE='22023'; END IF;
  IF (SELECT count(*) FROM _domain_columns(p_root) WHERE is_key) <> 1 THEN RAISE EXCEPTION 'root_entity must have one key' USING ERRCODE='22023'; END IF;
  FOR x IN SELECT value FROM jsonb_array_elements(coalesce(p_definition->'sections','[]')) LOOP
    IF x->>'type'='fields' THEN FOR v_binding IN SELECT value->>'binding' FROM jsonb_array_elements(coalesce(x->'fields','[]')) value LOOP
      IF NOT EXISTS (SELECT 1 FROM _domain_columns(p_root) WHERE column_name=v_binding) THEN RAISE EXCEPTION 'Unknown field binding %', v_binding USING ERRCODE='22023'; END IF;
    END LOOP; END IF;
    IF x->>'type'='table' THEN
      v_source:=x->>'source';
      IF NOT _is_domain_table(v_source) OR NOT EXISTS (SELECT 1 FROM pg_constraint c JOIN pg_class r ON r.oid=c.conrelid JOIN pg_class p ON p.oid=c.confrelid WHERE c.contype='f' AND r.relname=v_source AND p.relname=p_root AND array_length(c.conkey,1)=1) THEN RAISE EXCEPTION 'Table source must reference root entity' USING ERRCODE='22023'; END IF;
    END IF;
  END LOOP;
END $$;

CREATE FUNCTION :"schema".fn_list_reports(p_user uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = :"schema", public, pg_temp AS $$
 SELECT jsonb_build_object('reports',coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.name),'[]')) FROM (
  SELECT template_code,version,name,definition FROM template_version WHERE kind='REPORT' AND status='PUBLISHED') t
 WHERE (SELECT _report_permission(p_user,'report.view')) IS NULL;
$$;

CREATE FUNCTION :"schema".sp_run_report(p_user uuid,p_code text,p_params jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = :"schema", public, pg_temp AS $$
DECLARE t template_version; r jsonb; rid uuid; v_batches uuid[]; v_table text;
BEGIN
 PERFORM _report_permission(p_user,'report.generate');
 SELECT * INTO t FROM template_version WHERE template_code=p_code AND kind='REPORT' AND status='PUBLISHED' ORDER BY version DESC LIMIT 1;
 IF NOT FOUND THEN RAISE EXCEPTION 'Published report % not found',p_code USING ERRCODE='P0002'; END IF;
 r:=_run_dataset(p_user,t.definition->>'dataset',coalesce(p_params,'{}'));
 v_table:=CASE t.definition->>'dataset' WHEN 'get_erp_payables_ageing' THEN 'invoice' WHEN 'get_erp_overdue_by_supplier' THEN 'invoice' WHEN 'get_lending_application_summary' THEN 'application' WHEN 'get_lending_application_trend' THEN 'application' WHEN 'get_aml_alert_summary' THEN 'alert' END;
 EXECUTE format('SELECT coalesce(array_agg(DISTINCT batch_id),''{}''::uuid[]) FROM %I.%I',current_schema(),v_table) INTO v_batches;
 INSERT INTO report_run(template_code,template_version,filters,period_start,period_end,source_batch_ids,metric_version,result,generated_by)
 VALUES(t.template_code,t.version,coalesce(p_params,'{}'),coalesce((p_params->>'start_date')::date,(p_params->>'as_of_date')::date),coalesce((p_params->>'end_date')::date,(p_params->>'as_of_date')::date),v_batches,t.template_code||':v'||t.version,r,p_user) RETURNING run_id INTO rid;
 PERFORM iam._audit(p_user,(SELECT app_id FROM iam.app WHERE schema_name=current_schema()),'REPORT_RUN','report_run',rid::text,jsonb_build_object('code',p_code));
 RETURN jsonb_build_object('run_id',rid)||r;
END $$;

CREATE FUNCTION :"schema".fn_list_report_runs(p_user uuid,p_limit int DEFAULT 20) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = :"schema", public, pg_temp AS $$
 SELECT jsonb_build_object('runs',coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.generated_at DESC),'[]')) FROM (SELECT * FROM report_run ORDER BY generated_at DESC LIMIT least(greatest(coalesce(p_limit,20),1),100)) x WHERE (SELECT _report_permission(p_user,'report.view')) IS NULL;
$$;
CREATE FUNCTION :"schema".fn_get_report_run(p_user uuid,p_run uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = :"schema", public, pg_temp AS $$
DECLARE r report_run; BEGIN PERFORM _report_permission(p_user,'report.view'); SELECT * INTO r FROM report_run WHERE run_id=p_run; IF NOT FOUND THEN RAISE EXCEPTION 'Run not found' USING ERRCODE='P0002'; END IF; RETURN to_jsonb(r); END $$;

CREATE FUNCTION :"schema".fn_list_templates(p_user uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = :"schema", public, pg_temp AS $$
 SELECT jsonb_build_object('templates',coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.template_code,x.version),'[]')) FROM template_version x WHERE (SELECT _report_permission(p_user,'template.view')) IS NULL;
$$;
CREATE FUNCTION :"schema".fn_get_template(p_user uuid,p_code text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = :"schema", public, pg_temp AS $$
DECLARE r jsonb; BEGIN PERFORM _report_permission(p_user,'template.view'); SELECT jsonb_build_object('history',coalesce(jsonb_agg(to_jsonb(t) ORDER BY version DESC),'[]')) INTO r FROM template_version t WHERE template_code=p_code; IF r->'history'='[]'::jsonb THEN RAISE EXCEPTION 'Template not found' USING ERRCODE='P0002'; END IF; RETURN r; END $$;

CREATE FUNCTION :"schema".sp_save_template_draft(p_user uuid,p_code text,p_kind text,p_name text,p_root text,p_definition jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = :"schema", public, pg_temp AS $$
DECLARE t template_version; v int; BEGIN
 PERFORM _report_permission(p_user,'template.edit'); IF p_code !~ '^[A-Z][A-Z0-9_]{2,49}$' THEN RAISE EXCEPTION 'Invalid template code' USING ERRCODE='22023'; END IF; PERFORM _validate_template(p_kind,p_root,p_definition);
 SELECT * INTO t FROM template_version WHERE template_code=p_code ORDER BY version DESC LIMIT 1;
 IF FOUND AND t.kind<>p_kind THEN RAISE EXCEPTION 'Template kind cannot change' USING ERRCODE='22023'; END IF;
 IF FOUND AND t.status IN ('SUBMITTED','APPROVED') THEN RAISE EXCEPTION 'Template is waiting for review' USING ERRCODE='22023'; END IF;
 IF FOUND AND t.status='DRAFT' THEN UPDATE template_version SET name=p_name,root_entity=p_root,definition=p_definition WHERE template_code=p_code AND version=t.version; v:=t.version; ELSE v:=coalesce(t.version,0)+1; INSERT INTO template_version(template_code,version,kind,name,root_entity,definition,created_by) VALUES(p_code,v,p_kind,p_name,p_root,p_definition,p_user); END IF;
 RETURN jsonb_build_object('template_code',p_code,'version',v,'status','DRAFT'); END $$;
CREATE FUNCTION :"schema".sp_submit_template(p_user uuid,p_code text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = :"schema", public, pg_temp AS $$ DECLARE t template_version; BEGIN PERFORM _report_permission(p_user,'template.edit'); SELECT * INTO t FROM template_version WHERE template_code=p_code ORDER BY version DESC LIMIT 1 FOR UPDATE; IF NOT FOUND OR t.status<>'DRAFT' THEN RAISE EXCEPTION 'Draft not found' USING ERRCODE='22023'; END IF; UPDATE template_version SET status='SUBMITTED' WHERE template_code=p_code AND version=t.version; RETURN jsonb_build_object('status','SUBMITTED','version',t.version); END $$;
CREATE FUNCTION :"schema".sp_review_template(p_user uuid,p_code text,p_version int,p_approve boolean,p_comment text DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = :"schema", public, pg_temp AS $$ DECLARE t template_version; BEGIN PERFORM _report_permission(p_user,'template.approve'); SELECT * INTO t FROM template_version WHERE template_code=p_code AND version=p_version FOR UPDATE; IF NOT FOUND OR t.status<>'SUBMITTED' THEN RAISE EXCEPTION 'Submitted template not found' USING ERRCODE='22023'; END IF; IF p_approve AND t.created_by=p_user THEN RAISE EXCEPTION 'A different user must approve this template' USING ERRCODE='42501'; END IF; UPDATE template_version SET status=CASE WHEN p_approve THEN 'APPROVED' ELSE 'REJECTED' END,approved_by=CASE WHEN p_approve THEN p_user END WHERE template_code=p_code AND version=p_version; RETURN jsonb_build_object('status',CASE WHEN p_approve THEN 'APPROVED' ELSE 'REJECTED' END); END $$;
CREATE FUNCTION :"schema".sp_publish_template(p_user uuid,p_code text,p_version int) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = :"schema", public, pg_temp AS $$ BEGIN PERFORM _report_permission(p_user,'template.approve'); IF NOT EXISTS(SELECT 1 FROM template_version WHERE template_code=p_code AND version=p_version AND status='APPROVED') THEN RAISE EXCEPTION 'Approved template not found' USING ERRCODE='22023'; END IF; UPDATE template_version SET status='RETIRED' WHERE template_code=p_code AND status='PUBLISHED'; UPDATE template_version SET status='PUBLISHED',published_at=now() WHERE template_code=p_code AND version=p_version; RETURN jsonb_build_object('status','PUBLISHED','version',p_version); END $$;

CREATE FUNCTION :"schema".fn_render_document(p_user uuid,p_code text,p_record_key text,p_version int DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = :"schema", public, pg_temp AS $$
DECLARE t template_version; v_pk text; v_root jsonb; v_run uuid;
BEGIN
 PERFORM _report_permission(p_user,'report.generate');
 IF p_version IS NOT NULL THEN PERFORM _report_permission(p_user,'template.view'); END IF;
 SELECT * INTO t FROM template_version WHERE template_code=p_code AND kind='DOCUMENT' AND (version=p_version OR (p_version IS NULL AND status='PUBLISHED')) ORDER BY version DESC LIMIT 1;
 IF NOT FOUND THEN RAISE EXCEPTION 'Document template not found' USING ERRCODE='P0002'; END IF;
 SELECT column_name INTO v_pk FROM _domain_columns(t.root_entity) WHERE is_key ORDER BY ordinal LIMIT 1;
 EXECUTE format('SELECT to_jsonb(x) - ''batch_id'' - ''source_record_no'' FROM %I.%I x WHERE %I::text=$1',current_schema(),t.root_entity,v_pk) INTO v_root USING p_record_key;
 IF v_root IS NULL THEN RAISE EXCEPTION 'Record not found' USING ERRCODE='P0002'; END IF;
 INSERT INTO report_run(template_code,template_version,filters,metric_version,result,generated_by) VALUES(t.template_code,t.version,jsonb_build_object('record_key',p_record_key),t.template_code||':v'||t.version,jsonb_build_object('template',t.definition,'data',jsonb_build_object('root',v_root,'tables','{}'::jsonb)),p_user) RETURNING run_id INTO v_run;
 RETURN jsonb_build_object('run_id',v_run,'template',t.definition,'data',jsonb_build_object('root',v_root,'tables','{}'::jsonb));
END $$;
