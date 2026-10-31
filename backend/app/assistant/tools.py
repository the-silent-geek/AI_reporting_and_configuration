"""The allowlist: every tool Smart Assistance may call (docs_ai/02 § Allowlisted data tools).

A tool = a name the LLM sees + a strict argument model + the DB function that runs
it (db/07_smart_assistance.sql). The LLM never sees SQL or table names, and there
is deliberately no tool that takes free-form queries, table names or file paths.
"""
from dataclasses import dataclass
from datetime import date
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator


class _Args(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


class Period(_Args):
    start_date: date = Field(description="First day, YYYY-MM-DD")
    end_date: date = Field(description="Last day (inclusive), YYYY-MM-DD")

    @model_validator(mode="after")
    def _ordered(self):
        if self.end_date < self.start_date:
            raise ValueError("end_date is before start_date")
        return self


class LendingSummaryArgs(Period):
    status: str | None = Field(None, max_length=40, description="Application status, e.g. APPROVED, REJECTED")


class LendingTrendArgs(Period):
    granularity: Literal["month", "week"] = Field(description="Bucket size")
    status: str | None = Field(None, max_length=40, description="Application status filter")


class ApplicationArgs(_Args):
    application_id: str = Field(min_length=1, max_length=100)


class AgeingArgs(_Args):
    as_of_date: date = Field(description="Date the ageing is measured on, YYYY-MM-DD")
    supplier_id: str | None = Field(None, max_length=100)
    currency: str | None = Field(None, pattern=r"^[A-Za-z]{3}$", description="ISO currency code")


class OverdueArgs(_Args):
    as_of_date: date = Field(description="Date overdue is measured on, YYYY-MM-DD")
    limit: int = Field(10, ge=1, le=50, description="How many suppliers to list")


class PaymentArgs(_Args):
    payment_id: str = Field(min_length=1, max_length=100)


class AlertSummaryArgs(Period):
    status: str | None = Field(None, max_length=40, description="Alert status, e.g. OPEN, CLOSED")
    severity: Literal["LOW", "MEDIUM", "HIGH", "CRITICAL"] | None = None


class AlertArgs(_Args):
    alert_id: str = Field(min_length=1, max_length=100)


class CaseArgs(_Args):
    case_id: str = Field(min_length=1, max_length=100)


@dataclass(frozen=True)
class Tool:
    name: str
    product: str
    description: str
    args: type[_Args]
    function: str                 # DB function, called as <product>_app
    params: tuple[str, ...]       # argument order of the DB function (after p_user_id)

    def schema(self) -> dict:
        """What the planner LLM sees: name, purpose, argument JSON schema."""
        return {"name": self.name, "description": self.description, "arguments": self.args.model_json_schema()}


TOOLS: dict[str, Tool] = {t.name: t for t in (
    Tool("get_lending_application_summary", "lending",
         "Counts and requested amounts of loan applications by status for a period.",
         LendingSummaryArgs, "lending.fn_tool_application_summary", ("start_date", "end_date", "status")),
    Tool("get_lending_application_details", "lending",
         "One loan application with its disbursements and status history.",
         ApplicationArgs, "lending.fn_tool_application_details", ("application_id",)),
    Tool("get_lending_application_trend", "lending",
         "Monthly or weekly number and amount of loan applications.",
         LendingTrendArgs, "lending.fn_tool_application_trend", ("start_date", "end_date", "granularity", "status")),
    Tool("get_erp_payables_ageing", "erp",
         "Outstanding supplier invoices by ageing bucket (current, 1-30, 31-60, 61-90, 90+ days overdue) on a date.",
         AgeingArgs, "erp.fn_tool_payables_ageing", ("as_of_date", "supplier_id", "currency")),
    Tool("get_erp_overdue_by_supplier", "erp",
         "Suppliers with overdue payables on a date, largest overdue amount first.",
         OverdueArgs, "erp.fn_tool_overdue_by_supplier", ("as_of_date", "limit")),
    Tool("get_erp_payment_details", "erp",
         "One recorded supplier payment and the invoices it was allocated to.",
         PaymentArgs, "erp.fn_tool_payment_details", ("payment_id",)),
    Tool("get_aml_alert_summary", "aml",
         "Counts of AML alerts by status and severity for a period.",
         AlertSummaryArgs, "aml.fn_tool_alert_summary", ("start_date", "end_date", "status", "severity")),
    Tool("get_aml_alert_details", "aml",
         "One AML alert with its status history.",
         AlertArgs, "aml.fn_tool_alert_details", ("alert_id",)),
    Tool("get_aml_case_details", "aml",
         "One AML investigation case with its alerts and status history.",
         CaseArgs, "aml.fn_tool_case_details", ("case_id",)),
)}


def catalog(product: str) -> list[Tool]:
    return [t for t in TOOLS.values() if t.product == product]


# What to ask when the planner left a required argument out.
CLARIFY = {
    "start_date": "Which period should I use (for example 'October 2026' or '1-15 Oct 2026')?",
    "end_date": "Which period should I use (for example 'October 2026' or '1-15 Oct 2026')?",
    "as_of_date": "What as-of date should I use?",
    "granularity": "Should the trend be monthly or weekly?",
    "application_id": "Which application ID?",
    "payment_id": "Which payment ID?",
    "alert_id": "Which alert ID?",
    "case_id": "Which case ID?",
}
