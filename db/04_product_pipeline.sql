-- =============================================================================
-- 04_product_pipeline.sql
--
-- Every product schema gets the SAME ingestion/reporting pipeline from one
-- template (_product_pipeline.sql), so ERP, AML and Lending behave identically
-- and a 4th product is two more lines here plus a row in iam.app.
-- =============================================================================

\set schema erp
\ir _product_pipeline.sql

\set schema aml
\ir _product_pipeline.sql

\set schema lending
\ir _product_pipeline.sql
