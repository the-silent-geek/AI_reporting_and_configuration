# Business dashboards

Migration: `db/12_business_dashboards.sql` (after 07–11).
API: `GET /api/apps/{app}/dashboard?start_date=YYYY-MM-DD&end_date=YYYY-MM-DD`.
Requires authenticated session and the product's `dashboard.view` permission.

Lending shows applications, approved/rejected counts, disbursement amounts,
decision distribution, product distribution and monthly application trends.
Applications use applied date; disbursements use paid date.

ERP shows outstanding and overdue payables as of the end date. Outstanding
equals invoice amount less effective allocations and approved credit notes.
Payments, payment amounts and expenditure use payment date within the range.
Ageing and supplier charts use the same outstanding invoice records as the KPIs.

AML shows alerts raised and investigations opened within the range (UTC dates),
closed alerts, open investigations, severity, investigation status and monthly
opening trends. Status is current, not reconstructed historical status. Open
investigations have no closed date and are not CLOSED, RESOLVED or CANCELLED.

Every card/category opens its contributing records with source batch links.
Money is grouped per currency. SQL calculates values and returns the contributing
records in the same response, so drill-downs reconcile with the displayed figures.
The table pages in groups of 25. Currently all contributing records travel in the
response; server-side drill-down pagination is a scaling follow-up for large data.
No synthetic data or uncommitted staging records are included.
