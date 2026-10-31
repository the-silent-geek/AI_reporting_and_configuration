-- =============================================================================
-- 01_schemas.sql  (runs inside the application database)
--
-- One schema per concern:
--   iam      users, roles, permissions, apps, sidebar menu, sessions, audit
--   erp      ERP pipeline + domain tables      (connection: erp_app / erp_ro)
--   aml      AML pipeline + domain tables      (connection: aml_app / aml_ro)
--   lending  Lending pipeline + domain tables  (connection: lending_app / lending_ro)
--
-- "iam" instead of "user": USER is a reserved word in PostgreSQL, so a schema
-- named "user" would need double quotes in every single query.
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;  -- crypt()/gen_salt() for bcrypt, digest() for sha256, gen_random_bytes()
CREATE EXTENSION IF NOT EXISTS citext;    -- case-insensitive email column

CREATE SCHEMA IF NOT EXISTS iam;
CREATE SCHEMA IF NOT EXISTS erp;
CREATE SCHEMA IF NOT EXISTS aml;
CREATE SCHEMA IF NOT EXISTS lending;

COMMENT ON SCHEMA iam     IS 'Identity and access management: users, RBAC, apps, sidebar, sessions, audit.';
COMMENT ON SCHEMA erp     IS 'ERP product: ingestion pipeline and payables domain (invoices, payments).';
COMMENT ON SCHEMA aml     IS 'AML product: ingestion pipeline and alerts/cases domain.';
COMMENT ON SCHEMA lending IS 'Lending product: ingestion pipeline and applications/disbursements domain.';

-- Nobody connects unless explicitly allowed.
SELECT format('REVOKE ALL ON DATABASE %I FROM PUBLIC', current_database()) \gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO iam_app, erp_app, aml_app, lending_app, erp_ro, aml_ro, lending_ro',
              current_database()) \gexec
