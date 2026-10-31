"""Canonical fields the worker may suggest: the domain tables of db/05_domain_tables.sql
(minus lineage columns batch_id / source_record_no, which commit fills in).

target_field must be a real column of target_entity, because sp_commit_batch turns
normalized_fields into a row with jsonb_populate_record. Keep this file in step with
05_domain_tables.sql; tests/test_mapping.py checks the two agree.

Types: text | date | datetime | decimal | integer | boolean | currency (ISO-4217 code)
"""
from dataclasses import dataclass


@dataclass(frozen=True)
class Target:
    entity: str
    name: str
    type: str
    description: str
    aliases: tuple[str, ...] = ()
    key: bool = False   # part of the primary key (business key)

    @property
    def qualified(self) -> str:
        return f"{self.entity}.{self.name}"


def _t(entity, name, type_, description, aliases="", key=False) -> Target:
    return Target(entity, name, type_, description, tuple(a.strip() for a in aliases.split(",") if a.strip()), key)


_SUPPLIER_REF = "supplier, supplier id, supplier code, supplier no, vendor, vendor id, vendor code, vendor no"
_CURRENCY = "currency, ccy, currency code, cur, curr"

CATALOG: dict[str, list[Target]] = {
    "erp": [
        _t("supplier", "supplier_id", "text", "unique supplier or vendor identifier/code", _SUPPLIER_REF, key=True),
        _t("supplier", "supplier_name", "text", "supplier or vendor legal/display name",
           "supplier name, vendor name, payee, payee name, supplier, vendor"),

        _t("invoice", "invoice_id", "text", "unique supplier invoice number",
           "invoice, invoice id, invoice no, invoice number, invoice ref, inv no, bill no, bill number", key=True),
        _t("invoice", "supplier_id", "text", "supplier/vendor the invoice is owed to", _SUPPLIER_REF),
        _t("invoice", "invoice_date", "date", "date the invoice was issued",
           "invoice date, bill date, document date, inv date, issue date"),
        _t("invoice", "due_date", "date", "date payment of the invoice is due",
           "due date, payment due, payment due date, due on, maturity date"),
        _t("invoice", "amount", "decimal", "invoice amount payable",
           "amount, invoice amount, total amount, bill amount, gross amount, invoice total, invoice value"),
        _t("invoice", "currency", "currency", "ISO-4217 currency code of the invoice amount", _CURRENCY),

        _t("payment", "payment_id", "text", "unique payment identifier",
           "payment id, payment no, payment number, payment ref, receipt no, voucher no", key=True),
        _t("payment", "supplier_id", "text", "supplier/vendor that was paid", _SUPPLIER_REF),
        _t("payment", "payment_date", "date", "date the payment was made",
           "payment date, paid on, paid date, value date, date paid"),
        _t("payment", "amount", "decimal", "amount paid, positive", "amount, payment amount, paid amount, amount paid"),
        _t("payment", "currency", "currency", "ISO-4217 currency code of the payment", _CURRENCY),
        _t("payment", "reference", "text", "free-text payment reference or narration",
           "reference, ref, payment reference, narration, remarks, utr, memo"),

        _t("payment_allocation", "payment_id", "text", "payment being allocated",
           "payment id, payment no, payment number, payment ref", key=True),
        _t("payment_allocation", "invoice_id", "text", "invoice the payment is applied to",
           "invoice, invoice id, invoice no, invoice number, invoice ref", key=True),
        _t("payment_allocation", "amount", "decimal", "amount of the payment applied to the invoice",
           "amount, allocated amount, applied amount, allocation amount"),
        _t("payment_allocation", "effective_date", "date", "date the allocation takes effect",
           "effective date, allocation date, applied date, applied on"),

        _t("credit_note", "credit_note_id", "text", "unique credit note number",
           "credit note, credit note id, credit note no, credit note number, cn no, credit memo no", key=True),
        _t("credit_note", "invoice_id", "text", "invoice the credit note reduces",
           "invoice, invoice id, invoice no, invoice number, invoice ref"),
        _t("credit_note", "amount", "decimal", "credit amount, positive", "amount, credit amount, credit note amount"),
        _t("credit_note", "effective_date", "date", "date the credit note takes effect",
           "effective date, credit note date, cn date, credit date"),
        _t("credit_note", "is_approved", "boolean", "whether the credit note is approved (only approved credits count)",
           "approved, is approved, approval status"),
    ],
    "aml": [
        _t("investigation_case", "case_id", "text", "unique investigation case identifier",
           "case, case id, case no, case number, case ref", key=True),
        _t("investigation_case", "status", "text", "current case status", "status, case status"),
        _t("investigation_case", "priority", "text", "case priority", "priority, case priority"),
        _t("investigation_case", "subject_ref", "text", "customer/party under investigation",
           "subject, subject id, subject ref, party id, party ref"),
        _t("investigation_case", "investigator", "text", "investigator owning the case",
           "investigator, assigned to, owner, case owner, analyst"),
        _t("investigation_case", "opened_at", "datetime", "when the case was opened",
           "opened at, opened on, open date, opened date, created at, created on"),
        _t("investigation_case", "closed_at", "datetime", "when the case was closed",
           "closed at, closed on, close date, closed date"),

        _t("alert", "alert_id", "text", "unique transaction-monitoring alert identifier",
           "alert, alert id, alert no, alert number, alert ref", key=True),
        _t("alert", "case_id", "text", "investigation case the alert belongs to, optional",
           "case, case id, case no, case number, case ref"),
        _t("alert", "raised_at", "datetime", "when the alert was raised",
           "raised at, raised on, alert date, created at, generated at, triggered at, alert time"),
        _t("alert", "severity", "text", "alert severity: LOW, MEDIUM, HIGH or CRITICAL",
           "severity, risk level, risk rating, alert severity"),
        _t("alert", "status", "text", "current alert status", "status, alert status"),
        _t("alert", "customer_ref", "text", "customer the alert is about",
           "customer, customer id, customer ref, client id, client ref, account holder"),
        _t("alert", "rule_description", "text", "monitoring rule or scenario that fired",
           "rule, rule name, rule description, scenario, scenario name, typology"),
        _t("alert", "assigned_investigator", "text", "investigator assigned to the alert",
           "investigator, assigned investigator, assigned to, assignee, analyst"),

        _t("status_event", "event_ref", "text", "unique status change event identifier",
           "event id, event ref, event no", key=True),
        _t("status_event", "entity_type", "text", "ALERT or CASE", "entity type, object type, record type"),
        _t("status_event", "entity_id", "text", "id of the alert or case whose status changed",
           "entity id, object id, record id"),
        _t("status_event", "status", "text", "status after the change", "status, new status"),
        _t("status_event", "occurred_at", "datetime", "when the status changed",
           "occurred at, event time, timestamp, changed at, changed on"),
    ],
    "lending": [
        _t("application", "application_id", "text", "unique lending application identifier",
           "application, application id, application no, application number, app id, loan ref, "
           "loan application id, loan application no", key=True),
        _t("application", "applicant_ref", "text", "applicant/borrower identifier",
           "applicant, applicant id, applicant ref, borrower, borrower id, customer id"),
        _t("application", "applied_at", "date", "date the application was submitted",
           "application date, applied on, applied at, applied date, submitted on, submission date"),
        _t("application", "status", "text", "application decision status", "status, application status"),
        _t("application", "requested_amount", "decimal", "loan amount requested, positive",
           "requested amount, loan amount, amount requested, applied amount, amount"),
        _t("application", "currency", "currency", "ISO-4217 currency code of the requested amount", _CURRENCY),
        _t("application", "product", "text", "loan product", "product, loan product, product type, loan type"),
        _t("application", "purpose", "text", "purpose of the loan", "purpose, loan purpose"),
        _t("application", "term_months", "integer", "loan term in months",
           "term, term months, tenure, tenor, loan term, tenure months"),

        _t("disbursement", "disbursement_id", "text", "unique disbursement identifier",
           "disbursement, disbursement id, disbursement no, disbursal id, disbursal no", key=True),
        _t("disbursement", "application_id", "text", "application the money was paid out for",
           "application, application id, application no, application number, loan ref"),
        _t("disbursement", "paid_at", "date", "date the money was paid out",
           "disbursement date, disbursed on, disbursal date, paid at, paid on"),
        _t("disbursement", "amount", "decimal", "amount disbursed, positive",
           "amount, disbursed amount, disbursement amount, disbursal amount"),
        _t("disbursement", "currency", "currency", "ISO-4217 currency code of the disbursement", _CURRENCY),

        _t("application_status_event", "event_ref", "text", "unique status change event identifier",
           "event id, event ref, event no", key=True),
        _t("application_status_event", "application_id", "text", "application whose status changed",
           "application, application id, application no, application number, loan ref"),
        _t("application_status_event", "status", "text", "status after the change", "status, new status"),
        _t("application_status_event", "occurred_at", "datetime", "when the status changed",
           "occurred at, event time, timestamp, changed at, changed on, status date"),
    ],
}


def entities(app: str) -> list[str]:
    return list(dict.fromkeys(t.entity for t in CATALOG[app]))


def targets(app: str, entity: str | None = None) -> list[Target]:
    return [t for t in CATALOG[app] if entity is None or t.entity == entity]
