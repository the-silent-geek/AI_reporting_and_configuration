# Mapping and Smart Assistance

## Hybrid field mapping

The worker suggests what uploaded fields mean. It does not approve mappings or write final business data.

```text
Source header and masked samples
  -> alias/type rules
  -> local BGE semantic similarity
  -> Groq only when ambiguity remains
  -> mapping suggestion for user review
```

### Rule layer

Use an alias dictionary and normal code for primitive types. Example:

```json
{
  "application_id": ["application id", "application number", "loan ref"],
  "invoice_id": ["invoice no", "invoice number", "bill no"],
  "supplier_name": ["supplier", "vendor", "vendor name"]
}
```

### BGE layer

Use local `BAAI/bge-small-en-v1.5` to compare source-field descriptions and approved canonical-field descriptions. Include product context, inferred type, and masked samples.

```text
Source: Loan Ref | samples: LN-1001, LN-1002 | string | lending
Target: application_id | unique lending application identifier | string
```

Return the best candidates and scores. BGE scores are only suggestions.

### Groq ambiguity layer

Call Groq only when the rule/BGE result is tied or unclear, for example `Value`, `Date 2`, or `Status Code`. Require structured JSON:

```json
{
  "source_field": "Value",
  "target_field": "outstanding_amount",
  "transformation": { "type": "parse_decimal", "remove_characters": [","] },
  "confidence": 0.78,
  "reason": "The values look monetary, but the user must confirm their business meaning."
}
```

Send Groq only allowed canonical fields, source headers, inferred types, masked samples, and BGE candidates. Do not send the complete dataset or secrets. If Groq is unavailable, retain BGE/rule suggestions and mark uncertain mappings for review.

## PDF/OCR routing

Use normal native text extraction for PDFs with usable embedded text. Use PaddleOCR for scanned/image regions. The worker must construct rows/label-value forms from OCR output before storing candidate records.

For table PDFs:

```text
OCR words + positions
  -> group similar vertical positions into rows
  -> use header positions to assign columns
  -> remove repeated headers, totals, and blank rows
  -> candidate records
```

## Smart Assistance: detailed LangGraph plan

Smart Assistance is separate from ingestion. Its main agent uses a Groq-hosted LLM. LangGraph controls the state, tool routing, validation, human clarification, and grounded response flow. PostgreSQL calculates all official totals; Groq interprets requests, chooses permitted tools, creates report configuration proposals, and explains returned results.

### Agent boundary

```text
User question
  -> Groq main agent
  -> LangGraph validation and routing nodes
  -> allowlisted Platform API tool
  -> PostgreSQL result
  -> Groq grounded answer
  -> chat UI
```

The Groq agent must never receive database credentials, execute raw SQL, bypass access permissions, or invent a KPI value. It receives tool schemas and the safe tool results only.

### LangGraph state

Use a typed state object. Persist a run/checkpoint by conversation ID so a user can clarify an ambiguous request without losing context.

```json
{
  "conversation_id": "uuid",
  "user_id": "uuid",
  "user_roles": ["reporting_user"],
  "question": "Show rejected loan applications last month",
  "language": "en",
  "product": null,
  "intent": null,
  "tool_plan": null,
  "tool_result": null,
  "report_configuration": null,
  "needs_clarification": false,
  "clarification_question": null,
  "response": null,
  "audit_context": {}
}
```

### LangGraph nodes

```text
START
  -> normalize_question
  -> load_authorized_catalog
  -> groq_plan_request
  -> validate_plan
       -> clarification_interrupt      when product, period, or metric is unclear
       -> execute_data_tool            when answering a data question
       -> build_report_configuration   when user requests a report/dashboard
       -> retrieve_reference_context    only when documented definitions are needed
  -> groq_grounded_response
  -> persist_audit_context
  -> END
```

| Node | Type | Responsibility |
|---|---|---|
| `normalize_question` | Deterministic | Trim input, limit length, detect/display language, reject empty input |
| `load_authorized_catalog` | Deterministic tool | Load the user’s allowed products, fields, metrics, tools, and template/report actions |
| `groq_plan_request` | Groq main agent | Return strict JSON intent/tool plan; no data answer yet |
| `validate_plan` | Deterministic | Check tool name, arguments, dates, fields, filters, authorization scope, and required context |
| `clarification_interrupt` | Human-in-the-loop | Ask one focused question when the plan is ambiguous |
| `execute_data_tool` | Backend tool | Call the allowlisted Platform API; Platform API authorizes and queries PostgreSQL |
| `build_report_configuration` | Groq + validator | Produce validated report/widget configuration, not SQL or chart values |
| `retrieve_reference_context` | Optional RAG tool | Retrieve metric/data-dictionary/regulatory text, never live transaction data |
| `groq_grounded_response` | Groq main agent | Explain only the validated tool result and context |
| `persist_audit_context` | Deterministic | Store question, selected tool, filters, period, result reference, and config version |

### Main Groq agent output

Force the main agent to return one structured action. Validate it with a JSON schema before LangGraph follows any route.

```json
{
  "intent": "data_question",
  "product": "lending",
  "tool_name": "get_lending_application_summary",
  "arguments": {
    "start_date": "2026-10-01",
    "end_date": "2026-10-31",
    "status": "REJECTED"
  },
  "needs_clarification": false,
  "clarification_question": null,
  "report_request": false
}
```

If the user asks “Show overdue payments” without a cutoff date, the agent should return:

```json
{
  "intent": "data_question",
  "product": "erp",
  "tool_name": null,
  "arguments": {},
  "needs_clarification": true,
  "clarification_question": "What as-of date should I use for overdue payments?",
  "report_request": false
}
```

### Allowlisted data tools

The Platform API owns these tools. Each tool applies authorization again before querying PostgreSQL. Tools return structured JSON, not prose.

| Tool | Use | Required arguments |
|---|---|---|
| `get_lending_application_summary` | Counts/amounts by application status | `start_date`, `end_date`, optional `status`, `branch_id` |
| `get_lending_application_details` | One authorized application | `application_id` |
| `get_lending_application_trend` | Monthly/weekly lending trend | `start_date`, `end_date`, `granularity`, optional `status` |
| `get_erp_payables_ageing` | Outstanding amounts by ageing bucket | `as_of_date`, optional `supplier_id`, `currency` |
| `get_erp_overdue_by_supplier` | Supplier-wise overdue payables | `as_of_date`, optional `limit` |
| `get_erp_payment_details` | One recorded payment and allocations | `payment_id` |
| `get_aml_alert_summary` | Alert counts by status/severity | `start_date`, `end_date`, optional `status`, `severity` |
| `get_aml_alert_details` | One authorized AML alert | `alert_id` |
| `get_aml_case_details` | One authorized case with related alerts | `case_id` |
| `create_report_configuration` | Validated configuration proposal; no query execution | `product`, `metrics`, `dimensions`, `filters`, `widgets` |
| `create_template_configuration` | Validated document-template proposal | `product`, `root_entity`, `sections`, `bindings` |

Do not provide `run_sql`, `read_any_table`, `download_any_file`, or any tool that accepts arbitrary database or filesystem instructions.

### Tool result contract

Every data tool returns the actual result plus enough context to explain and verify it.

```json
{
  "result_reference": "report-run-uuid",
  "product": "erp",
  "reporting_period": "As of 2026-10-31",
  "filters": {
    "outstanding_amount": { "operator": "greater_than", "value": 0 }
  },
  "metric_definitions": [
    {
      "metric": "total_overdue_amount",
      "definition": "Open invoice balance where due date is before the as-of date."
    }
  ],
  "kpis": {
    "total_overdue_amount": 100000,
    "overdue_invoice_count": 42,
    "overdue_supplier_count": 12
  },
  "chart_data": [
    { "supplier_name": "ABC Ltd", "overdue_amount": 40000 }
  ],
  "supporting_rows": [
    {
      "invoice_id": "INV-001",
      "supplier_name": "ABC Ltd",
      "due_date": "2026-10-10",
      "outstanding_amount": 10000,
      "days_overdue": 21
    }
  ]
}
```

The final Groq response must cite the returned period, filters, metric definition, and result reference in a user-friendly form. If a requested fact is missing from `tool_result`, the model must say it cannot determine it from the authorized data.

### Report generation through chat

For “Create a chart of AML alerts by severity this quarter,” the graph has two phases:

```text
1. Groq proposes report configuration.
2. Validator checks approved fields/metrics/widget types.
3. Platform tool runs the associated PostgreSQL metric query.
4. UI previews the actual KPI/chart/table data.
5. User saves, edits, or publishes the report configuration.
```

Example validated report configuration:

```json
{
  "title": "AML Alerts by Severity",
  "product": "aml",
  "filters": {
    "start_date": "2026-10-01",
    "end_date": "2026-12-31"
  },
  "metrics": [
    { "id": "alert_count", "aggregation": "count_distinct", "field": "alert_id" }
  ],
  "dimensions": ["severity"],
  "widgets": [
    { "type": "donut_chart", "metric": "alert_count", "group_by": "severity" },
    { "type": "table", "columns": ["alert_id", "severity", "status", "raised_at"] }
  ]
}
```

### Optional RAG node

Add `retrieve_reference_context` only after data-tool answers work. Its vector index may contain approved business definitions, data dictionaries, regulatory specifications, and report/template guidance. It must not be used to calculate current totals or replace the PostgreSQL tools.

### Suggested implementation order

1. Implement the three summary tools: Lending application summary, ERP payables ageing, AML alert summary.
2. Implement LangGraph deterministic routing and validation with mocked Groq JSON plans.
3. Connect Groq as `groq_plan_request` and require structured output.
4. Add grounded response generation using returned tool JSON.
5. Add clarification interrupts and checkpoint persistence.
6. Add report-configuration generation and UI preview.
7. Add optional RAG for documentation only.
