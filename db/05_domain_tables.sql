-- =============================================================================
-- 05_domain_tables.sql  -  the normalized business entities per product.
--
-- Rules every domain table follows (sp_commit_batch relies on them):
--   * PRIMARY KEY = the source system's business key (invoice_id, alert_id, ...)
--     -> re-importing the same record updates it instead of double counting.
--   * batch_id + source_record_no = lineage: which file/row last wrote this row.
--   * NO column defaults: values come only from approved normalized_fields.
--   * FKs between domain tables are DEFERRABLE so one batch can contain parents
--     and children in any order (checked at commit time).
--   * Only sp_commit_batch writes here; <schema>_app/_ro roles get SELECT only.
-- Amounts: numeric(18,2), never float. Currency: ISO-4217 3-letter code.
-- =============================================================================

-- ------------------------------------------------------------------- ERP ----
CREATE TABLE erp.supplier (
    supplier_id       text PRIMARY KEY,
    supplier_name     text,
    batch_id          uuid NOT NULL REFERENCES erp.ingestion_batch(batch_id),
    source_record_no  integer NOT NULL
);

CREATE TABLE erp.invoice (
    invoice_id        text PRIMARY KEY,
    supplier_id       text NOT NULL REFERENCES erp.supplier(supplier_id) DEFERRABLE INITIALLY DEFERRED,
    invoice_date      date NOT NULL,
    due_date          date NOT NULL,
    amount            numeric(18,2) NOT NULL,
    currency          char(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    batch_id          uuid NOT NULL REFERENCES erp.ingestion_batch(batch_id),
    source_record_no  integer NOT NULL,
    CHECK (due_date >= invoice_date)
);
CREATE INDEX ix_invoice_supplier ON erp.invoice(supplier_id);
CREATE INDEX ix_invoice_due      ON erp.invoice(due_date);   -- ageing buckets

CREATE TABLE erp.payment (
    payment_id        text PRIMARY KEY,
    supplier_id       text NOT NULL REFERENCES erp.supplier(supplier_id) DEFERRABLE INITIALLY DEFERRED,
    payment_date      date NOT NULL,
    amount            numeric(18,2) NOT NULL CHECK (amount > 0),
    currency          char(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    reference         text,
    batch_id          uuid NOT NULL REFERENCES erp.ingestion_batch(batch_id),
    source_record_no  integer NOT NULL
);

-- Which part of a payment settled which invoice (drives the Payment Advice template).
CREATE TABLE erp.payment_allocation (
    payment_id        text NOT NULL REFERENCES erp.payment(payment_id) DEFERRABLE INITIALLY DEFERRED,
    invoice_id        text NOT NULL REFERENCES erp.invoice(invoice_id) DEFERRABLE INITIALLY DEFERRED,
    amount            numeric(18,2) NOT NULL CHECK (amount > 0),
    effective_date    date NOT NULL,
    batch_id          uuid NOT NULL REFERENCES erp.ingestion_batch(batch_id),
    source_record_no  integer NOT NULL,
    PRIMARY KEY (payment_id, invoice_id)
);
CREATE INDEX ix_payment_allocation_invoice ON erp.payment_allocation(invoice_id);

CREATE TABLE erp.credit_note (
    credit_note_id    text PRIMARY KEY,
    invoice_id        text NOT NULL REFERENCES erp.invoice(invoice_id) DEFERRABLE INITIALLY DEFERRED,
    amount            numeric(18,2) NOT NULL CHECK (amount > 0),
    effective_date    date NOT NULL,
    is_approved       boolean NOT NULL,     -- only approved credits reduce outstanding
    batch_id          uuid NOT NULL REFERENCES erp.ingestion_batch(batch_id),
    source_record_no  integer NOT NULL
);
CREATE INDEX ix_credit_note_invoice ON erp.credit_note(invoice_id);

-- ------------------------------------------------------------------- AML ----
-- "investigation_case" because CASE is a reserved word.
CREATE TABLE aml.investigation_case (
    case_id           text PRIMARY KEY,
    status            text NOT NULL,
    priority          text,
    subject_ref       text,
    investigator      text,
    opened_at         timestamptz,
    closed_at         timestamptz,
    batch_id          uuid NOT NULL REFERENCES aml.ingestion_batch(batch_id),
    source_record_no  integer NOT NULL
);

CREATE TABLE aml.alert (
    alert_id              text PRIMARY KEY,
    case_id               text REFERENCES aml.investigation_case(case_id) DEFERRABLE INITIALLY DEFERRED,  -- an alert may have no case
    raised_at             timestamptz NOT NULL,
    severity              text NOT NULL CHECK (severity IN ('LOW','MEDIUM','HIGH','CRITICAL')),
    status                text NOT NULL,
    customer_ref          text,
    rule_description      text,
    assigned_investigator text,
    batch_id              uuid NOT NULL REFERENCES aml.ingestion_batch(batch_id),
    source_record_no      integer NOT NULL
);
CREATE INDEX ix_alert_case   ON aml.alert(case_id);
CREATE INDEX ix_alert_raised ON aml.alert(raised_at);

-- Status history -> historical snapshots ("open cases as of date X").
CREATE TABLE aml.status_event (
    event_ref         text PRIMARY KEY,        -- source id of the event
    entity_type       text NOT NULL CHECK (entity_type IN ('ALERT','CASE')),
    entity_id         text NOT NULL,
    status            text NOT NULL,
    occurred_at       timestamptz NOT NULL,
    batch_id          uuid NOT NULL REFERENCES aml.ingestion_batch(batch_id),
    source_record_no  integer NOT NULL
);
CREATE INDEX ix_status_event_entity ON aml.status_event(entity_type, entity_id, occurred_at);

-- --------------------------------------------------------------- LENDING ----
CREATE TABLE lending.application (
    application_id    text PRIMARY KEY,
    applicant_ref     text NOT NULL,
    applied_at        date NOT NULL,
    status            text NOT NULL,
    requested_amount  numeric(18,2) NOT NULL CHECK (requested_amount > 0),
    currency          char(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    product           text,
    purpose           text,
    term_months       smallint CHECK (term_months > 0),
    batch_id          uuid NOT NULL REFERENCES lending.ingestion_batch(batch_id),
    source_record_no  integer NOT NULL
);
CREATE INDEX ix_application_applied ON lending.application(applied_at);
CREATE INDEX ix_application_status  ON lending.application(status);

CREATE TABLE lending.disbursement (
    disbursement_id   text PRIMARY KEY,
    application_id    text NOT NULL REFERENCES lending.application(application_id) DEFERRABLE INITIALLY DEFERRED,
    paid_at           date NOT NULL,
    amount            numeric(18,2) NOT NULL CHECK (amount > 0),
    currency          char(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    batch_id          uuid NOT NULL REFERENCES lending.ingestion_batch(batch_id),
    source_record_no  integer NOT NULL
);
CREATE INDEX ix_disbursement_application ON lending.disbursement(application_id);

CREATE TABLE lending.application_status_event (
    event_ref         text PRIMARY KEY,
    application_id    text NOT NULL REFERENCES lending.application(application_id) DEFERRABLE INITIALLY DEFERRED,
    status            text NOT NULL,
    occurred_at       timestamptz NOT NULL,
    batch_id          uuid NOT NULL REFERENCES lending.ingestion_batch(batch_id),
    source_record_no  integer NOT NULL
);

-- ---------------------------------------------------------------- grants ----
GRANT SELECT ON erp.supplier, erp.invoice, erp.payment, erp.payment_allocation, erp.credit_note TO erp_app, erp_ro;
GRANT SELECT ON aml.investigation_case, aml.alert, aml.status_event TO aml_app, aml_ro;
GRANT SELECT ON lending.application, lending.disbursement, lending.application_status_event TO lending_app, lending_ro;
