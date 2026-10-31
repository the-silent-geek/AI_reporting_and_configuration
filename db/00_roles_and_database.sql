-- =============================================================================
-- 00_roles_and_database.sql
-- Run as superuser against the "postgres" maintenance database (build.ps1 does this).
--
-- Creates:
--   * 7 LOGIN roles, one per (product x access level), so the backend physically
--     cannot touch another product's schema with the wrong connection pool.
--       iam_app      -> can only EXECUTE iam.* functions (auth, RBAC)
--       erp_app      -> read/write erp.*      erp_ro      -> read-only erp.*
--       aml_app      -> read/write aml.*      aml_ro      -> read-only aml.*
--       lending_app  -> read/write lending.*  lending_ro  -> read-only lending.*
--   * the application database.
--
-- psql variables (passed by build.ps1 with -v):
--   db_name, reset ('true' drops the DB first), pw_<role> for each role.
-- =============================================================================

-- Optional clean rebuild. WITH (FORCE) kicks out open connections (PG13+).
SELECT format('DROP DATABASE IF EXISTS %I WITH (FORCE)', :'db_name')
WHERE :'reset' = 'true'
\gexec

-- Create each role only if missing, so the script is safe to re-run.
SELECT format('CREATE ROLE %I LOGIN', r)
FROM unnest(ARRAY['iam_app','erp_app','aml_app','lending_app','erp_ro','aml_ro','lending_ro']) AS r
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r)
\gexec

-- (Re)set passwords every run; values come from db/.env, never from this file.
ALTER ROLE iam_app     PASSWORD :'pw_iam_app';
ALTER ROLE erp_app     PASSWORD :'pw_erp_app';
ALTER ROLE aml_app     PASSWORD :'pw_aml_app';
ALTER ROLE lending_app PASSWORD :'pw_lending_app';
ALTER ROLE erp_ro      PASSWORD :'pw_erp_ro';
ALTER ROLE aml_ro      PASSWORD :'pw_aml_ro';
ALTER ROLE lending_ro  PASSWORD :'pw_lending_ro';

SELECT format('CREATE DATABASE %I ENCODING ''UTF8''', :'db_name')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'db_name')
\gexec
