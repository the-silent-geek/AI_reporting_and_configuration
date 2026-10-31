-- =============================================================================
-- 08_mapping_quality.sql  -  Mapping review + Data quality for every product.
-- Same template for all three schemas (like the pipeline), see _review.sql.
-- =============================================================================

\set schema erp
\ir _review.sql
\set schema aml
\ir _review.sql
\set schema lending
\ir _review.sql

-- The product login may EXECUTE only the public functions; _helpers stay private.
SELECT format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', p.oid::regprocedure)
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname IN ('erp', 'aml', 'lending')
  AND p.proname IN ('_domain_columns', '_is_domain_table', '_pg_format', '_transform', '_validate_batch',
                    '_validate_and_advance', '_assert_permission', '_lock_batch',
                    'fn_review_queue', 'fn_get_mapping', 'sp_approve_mapping', 'fn_list_issues',
                    'sp_correct_value', 'sp_reject_record', 'sp_confirm_issue', 'sp_revalidate_batch')
\gexec

SELECT format('GRANT EXECUTE ON FUNCTION %s TO %I', p.oid::regprocedure, n.nspname || '_app')
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname IN ('erp', 'aml', 'lending')
  AND p.proname IN ('fn_review_queue', 'fn_get_mapping', 'sp_approve_mapping', 'fn_list_issues',
                    'sp_correct_value', 'sp_reject_record', 'sp_confirm_issue', 'sp_revalidate_batch')
\gexec
