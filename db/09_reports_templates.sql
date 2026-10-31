-- Reports and document-template workflow for all products.
\set schema erp
\ir _reporting.sql
\set schema aml
\ir _reporting.sql
\set schema lending
\ir _reporting.sql

-- Publish safe starter reports only when an administrator exists.  Report data
-- definitions are deliberately explicit; arbitrary SQL is never stored here.
DO $$ DECLARE u uuid := (SELECT user_id FROM iam.app_user WHERE is_super_admin LIMIT 1); BEGIN
 IF u IS NOT NULL THEN
  INSERT INTO erp.template_version(template_code,version,kind,name,root_entity,definition,status,created_by,published_at) VALUES
   ('PAYABLES_AGEING',1,'REPORT','Payables ageing','invoice','{"dataset":"get_erp_payables_ageing","description":"Outstanding invoices by ageing bucket","widgets":[{"type":"kpis"},{"type":"bar","category":"bucket","value":"outstanding_amount","series":"currency"},{"type":"table"}]}'::jsonb,'PUBLISHED',u,now()),
   ('OVERDUE_SUPPLIERS',1,'REPORT','Overdue suppliers','invoice','{"dataset":"get_erp_overdue_by_supplier","description":"Overdue payables by supplier","widgets":[{"type":"kpis"},{"type":"bar","category":"supplier_name","value":"overdue_amount","series":"currency"},{"type":"table"}]}'::jsonb,'PUBLISHED',u,now()) ON CONFLICT DO NOTHING;
  INSERT INTO lending.template_version(template_code,version,kind,name,root_entity,definition,status,created_by,published_at) VALUES
   ('APPLICATION_SUMMARY',1,'REPORT','Application summary','application','{"dataset":"get_lending_application_summary","widgets":[{"type":"kpis"},{"type":"bar","category":"status","value":"requested_amount","series":"currency"},{"type":"table"}]}'::jsonb,'PUBLISHED',u,now()),
   ('APPLICATION_TREND',1,'REPORT','Application trend','application','{"dataset":"get_lending_application_trend","widgets":[{"type":"kpis"},{"type":"bar","category":"period_start","value":"requested_amount","series":"currency"},{"type":"table"}]}'::jsonb,'PUBLISHED',u,now()) ON CONFLICT DO NOTHING;
  INSERT INTO aml.template_version(template_code,version,kind,name,root_entity,definition,status,created_by,published_at) VALUES
   ('ALERT_SUMMARY',1,'REPORT','AML alert summary','alert','{"dataset":"get_aml_alert_summary","widgets":[{"type":"kpis"},{"type":"bar","category":"severity","value":"alert_count","series":"status"},{"type":"table"}]}'::jsonb,'PUBLISHED',u,now()) ON CONFLICT DO NOTHING;
 END IF;
END $$;

SELECT format('REVOKE ALL ON FUNCTION %s FROM PUBLIC',p.oid::regprocedure)
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname IN ('erp','aml','lending') AND p.proname IN ('_report_permission','_report_dataset_allowed','_run_dataset','_validate_template','fn_list_reports','sp_run_report','fn_list_report_runs','fn_get_report_run','fn_list_templates','fn_get_template','sp_save_template_draft','sp_submit_template','sp_review_template','sp_publish_template','fn_render_document')
\gexec
SELECT format('GRANT EXECUTE ON FUNCTION %s TO %I',p.oid::regprocedure,n.nspname||'_app')
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname IN ('erp','aml','lending') AND p.proname IN ('fn_list_reports','sp_run_report','fn_list_report_runs','fn_get_report_run','fn_list_templates','fn_get_template','sp_save_template_draft','sp_submit_template','sp_review_template','sp_publish_template','fn_render_document')
\gexec
