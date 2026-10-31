# Handoff: continue the Reporting Studio build

For the next engineer or AI session. Read this first, then `docs/WorkDone.md`,
`docs/Decisions.md` (D1–D35), `docs/API_GUIDE.md` and `docs/DB_GUIDE.md`.
**Nothing below is committed yet:** run `git status` to see all changes.

## 1. Where things stand (2026-10-31)

| Module | DB | Backend | Frontend | Verified |
|---|---|---|---|---|
| AI ingestion worker (`worker/`) | uses `raw_record`, `mapping_version`, `validation_issue` | – | – | 36 tests; real run on a CSV |
| Smart Assistance | `db/_assistant.sql` + `07_smart_assistance.sql` | `app/assistant/`, `routers/assistant.py` | `pages/app/Assistant.tsx` | DB asserts, 34 backend tests, real Groq over HTTP |
| Mapping review + Data quality | `db/_review.sql` + `08_mapping_quality.sql` | `routers/review.py` | `MappingReview.tsx`, `DataQuality.tsx`, buttons on `BatchDetail.tsx` | DB asserts (full flow to commit), 36 backend tests, `tsc` clean. **Not yet clicked through in a browser.** |
| Reports | **not started**: design in §3 | – | still `ComingSoon` | – |
| Templates | **not started**: design in §3 | – | still `ComingSoon` | – |

**Last edit (DB tests re-run, pass):** `db/_assistant.sql` → `_assistant_begin` now allows
`dashboard.view` AND (`assistant.use` OR `report.generate`), so reports can reuse the
data tools.

## 2. Running environment (this Mac)

- **Shared PostgreSQL** on the host PC via Tailscale: `100.96.34.125:5432`, db `reporting_studio`. Passwords are in `db/.env` (git-ignored).
- **The host has NOT applied `07`/`08` yet.** Until it does, Assistant / Mapping / Quality return 500 on the shared DB. Apply as superuser, in order:
  ```
  psql -U postgres -d reporting_studio -v ON_ERROR_STOP=1 -1 -f db/07_smart_assistance.sql
  psql -U postgres -d reporting_studio -v ON_ERROR_STOP=1 -1 -f db/08_mapping_quality.sql
  ```
  (and `09` once it exists). `db/build.ps1` already lists `07`; `08` is in its file list too; **add `09` when it exists.**
- **Local RabbitMQ** (Homebrew) on **5682**, UI on 15682 (`guest`/`guest`). Ports 5672, 5673, 15672 and 8000 are held by VS Code port forwarding on this Mac.
- **Backend:** `cd backend && .venv/bin/uvicorn app.main:app --reload --port 8100`.
- **Frontend:** `cd frontend && npm run dev` (5173). `frontend/.env.local` has `VITE_API_TARGET=http://127.0.0.1:8100`.
- **Worker:** `cd worker && .venv/bin/python -m ai_worker`.
- **Groq:** the key is in `worker/.env` and `backend/.env`. The model is `openai/gpt-oss-120b`: Llama models are not available to this key. The free tier allows 8k tokens/min, about 3 assistant questions per minute.

## 3. Remaining work: Reports and Templates (design agreed with the user)

Create `db/_reporting.sql` (per-schema template) + `db/09_reports_templates.sql` (includes it ×3,
adds product-specific parts, seeds, grants), following the pattern of `07`/`08`:
- SECURITY DEFINER functions with `SET search_path = <schema>, public, pg_temp`
- permission checks inside
- `REVOKE ... FROM PUBLIC`, and `GRANT EXECUTE` only on public `fn_`/`sp_` functions to `<schema>_app`
- return types qualified with `:"schema".`

**Existing tables** (in `_product_pipeline.sql`):
- `template_version(template_code, version, kind REPORT|DOCUMENT, name, root_entity, definition, status DRAFT|SUBMITTED|APPROVED|PUBLISHED|REJECTED|RETIRED, created_by, approved_by, published_at)`, with `CHECK approved_by <> created_by` (maker-checker)
- `report_run(run_id, template_code, template_version, filters, period_start, period_end, source_batch_ids, metric_version, output_uri, generated_by, generated_at)`, FK to `template_version`

**Permissions** (already seeded): `report.view`, `report.generate`, `template.view`, `template.edit`, `template.approve`.

### Reports
- **Schema change:** `ALTER TABLE report_run ADD COLUMN result jsonb`. It holds a snapshot, so a run can be reopened exactly as it was.
- **REPORT definition:** `{"dataset": "<tool name>", "description": "...", "widgets": [{"type":"kpis"}, {"type":"bar","category":"bucket","value":"outstanding_amount","series":"currency"}, {"type":"table"}]}`.
- **`_run_dataset(p_user, p_dataset, p_params jsonb)`** (per product, explicit CASE allowlist): calls the existing `fn_tool_*`. Allowed datasets:
  - ERP: `get_erp_payables_ageing`, `get_erp_overdue_by_supplier`
  - Lending: `get_lending_application_summary`, `get_lending_application_trend`
  - AML: `get_aml_alert_summary`
- **`sp_run_report(p_user, p_code, p_params)`:**
  - checks `report.generate`
  - uses the latest PUBLISHED REPORT version
  - runs the dataset
  - inserts `report_run`:
    - `filters` = params; `period_start`/`period_end` from params
    - `source_batch_ids` = distinct `batch_id`s of the dataset's base table
    - `metric_version` = `code:vN`; `result` = the dataset result
  - returns `{run_id, ...result}`
- **`fn_list_reports(p_user)`** (`report.view`): published REPORT templates.
- **`fn_list_report_runs(p_user, p_limit)`** and **`fn_get_report_run(p_user, p_run_id)`**.
- **Seeds:** one PUBLISHED REPORT per dataset above, `created_by` = the first super admin, `approved_by` NULL. Seed only if a super admin exists.
- **Backend `routers/reports.py`:**
  - `GET /reports` adds each dataset's parameter JSON schema from `app/assistant/tools.py` `TOOLS[name].args`
  - `POST /reports/{code}/run {params}` validates params with that pydantic model, then calls `sp_run_report`
  - `GET /reports/runs`, `GET /reports/runs/{id}`
- **UI `pages/app/Reports.tsx`:**
  - report cards → run form generated from the parameter schema (dates, granularity, ...)
  - result view: KPI cards (money KPIs are `{currency: amount}`), a CSS bar chart (no chart library in the deps), a table
  - Download CSV (Blob), Print (`window.print`), recent runs
  - routes `/reports`, `/reports/:code`, `/reports/runs/:runId`

### Templates (document templates)
- **DOCUMENT definition:** `{"title": "...", "sections": [{"type":"fields","heading":"Payment","fields":[{"label":"Payment ID","binding":"payment_id"}]}, {"type":"table","heading":"Allocations","source":"payment_allocation","columns":["invoice_id","amount"]}], "footer": "..."}`.
- **Definition checks in SQL:**
  - `root_entity` is a domain table (`_is_domain_table` from `08`) with a single-column PK
  - field bindings ⊂ root columns (`_domain_columns`)
  - a table `source` is a domain table with a single-column FK to the root PK
  - REPORT definitions: dataset in the allowlist, widget types in {kpis, bar, table}
  - template code matches `^[A-Z][A-Z0-9_]{2,49}$`, and `kind` never changes for a code
- **Functions:**
  - `fn_list_templates` / `fn_get_template` (`template.view`): the latest version per code plus history
  - `sp_save_template_draft(p_user, code, kind, name, root_entity, definition)` (`template.edit`):
    - latest version DRAFT → update it in place
    - latest SUBMITTED/APPROVED → refuse ("waiting for review")
    - latest PUBLISHED/RETIRED/REJECTED or none → new version (max+1) DRAFT
  - `sp_submit_template` (`template.edit`): DRAFT → SUBMITTED
  - `sp_review_template(p_user, code, version, p_approve bool, p_comment)` (`template.approve`): SUBMITTED → APPROVED/REJECTED. If the approver is the creator, give a friendly 42501 error instead of tripping the CHECK.
  - `sp_publish_template` (`template.approve`): APPROVED → PUBLISHED, the previous PUBLISHED version → RETIRED, `published_at`
  - `fn_render_document(p_user, code, p_record_key, p_version default NULL)` (`report.generate`; with a version, also `template.view`, for previews):
    - fetches the root row by PK and the child rows
    - records a `report_run`
    - returns `{run_id, template, data: {root: {...}, tables: {source: [...]}}}`
  - all of these audit through `iam._audit`
- **Seeds:** one PUBLISHED DOCUMENT per product: ERP `PAYMENT_ADVICE` (payment + allocations), Lending `APPLICATION_SUMMARY` (application + disbursements), AML `CASE_SUMMARY` (case + alerts).
- **Backend `routers/templates.py`:** thin routes over these functions.
- **UI `pages/app/Templates.tsx`:**
  - list with status/version badges
  - editor: name, root entity or dataset, section builder with field checkboxes and labels
  - action buttons by status and permission (Save draft, Submit, Approve/Reject (checker only), Publish, New version)
  - Preview/Generate: enter a record key → printable document view
  - routes `/templates`, `/templates/:code`

### Then
- **Tests:** DB asserts in `db/tests/test_all.sql` (before "DB-level role isolation"), plus backend tests `tests/test_reports_api.py` and `tests/test_templates_api.py`.
  - Add role-isolation asserts: `erp_app` cannot call `erp._validate_batch`, `erp._run_dataset`, or the internal helpers.
- **Docs:** API_GUIDE endpoint rows, DB_GUIDE sections, Decisions D36+, WorkDone entry, `build.ps1` file list.
- **Optional:** commit/push only when the user asks; then the host applies `07`–`09`.

## 4. How to test without touching the shared DB

**Never run the test suites against the shared DB** (`db/.env` points at it).
1. Start a throwaway PostgreSQL 16 on 127.0.0.1:54329. `pgserver`'s wheel has binaries; Homebrew `postgresql@16` also works and includes pgcrypto and citext.
2. Build it with `db/00…09` (passwords `pw`).
3. Run the DB tests: `psql -h 127.0.0.1 -p 54329 -U postgres -d reporting_studio -f db/tests/test_all.sql`.
4. Backend tests, with env overriding `.env`:
   ```
   cd backend && DB_HOST=127.0.0.1 DB_PORT=54329 IAM_APP_PASSWORD=pw ERP_APP_PASSWORD=pw AML_APP_PASSWORD=pw \
     LENDING_APP_PASSWORD=pw ERP_RO_PASSWORD=pw AML_RO_PASSWORD=pw LENDING_RO_PASSWORD=pw JWT_SECRET=test \
     RABBITMQ_URL= GROQ_API_KEY= .venv/bin/python -m pytest -q
   ```
5. Worker tests: `cd worker && .venv/bin/python -m pytest -q`.
6. Frontend: `cd frontend && npx tsc -b && npx oxlint src`.

**`test_all.sql` assumes a freshly built DB.** The assistant block's KPI asserts fail on a DB holding other data.

## 5. Gotchas learned the hard way
- **psql variables:** they don't expand inside `$$ … $$`. Use unqualified names with the function's `SET search_path`, but qualify RETURN types (`:"schema".ingestion_batch`).
- **plpgsql naming clashes:** a loop variable named like a table alias breaks the statement, e.g. `r` in `_validate_batch`. Use distinct aliases.
- **Groq misclassifies intent at times:** rules that matter (ask for the as-of date, what counts as a report request) are enforced in code (`graph.py` `validate_plan`), not only in the prompt.
- **Batch state machine** (`sp_update_batch_status`): `UPLOADED → EXTRACTING → MAPPING_REVIEW|NEEDS_REVIEW → VALIDATING → READY_TO_COMMIT|NEEDS_REVIEW`. Commit is only via `sp_commit_batch`, and the uploader cannot commit (maker-checker).
- **Repo style:** business rules in DB functions; routes are thin; short module docstrings explain the why; frontend uses the `Card`/`Button`/`PageHeader`/`StatusBadge` tokens (black and white, colour only for meaning).
