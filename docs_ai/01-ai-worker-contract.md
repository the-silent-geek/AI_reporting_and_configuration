# AI Worker Contract

## Scope

The AI worker consumes an ingestion request, loads upload metadata from PostgreSQL, reads the file from storage, extracts candidate records, suggests mappings, stores worker-owned results, and publishes events. It has no direct UI responsibilities.

## Queue topology

Use one RabbitMQ request queue and one event queue.

```text
Platform API
  -> ai.ingestion.requested
  -> AI worker
  -> ai.ingestion.events
  -> Platform API
  -> updates ingestion_batches
  -> SSE
  -> browser UI
```

| Queue | Publisher | Consumer | Purpose |
|---|---|---|---|
| `ai.ingestion.requested` | Platform API | AI worker | Start/retry one batch |
| `ai.ingestion.events` | AI worker | Platform API | Progress, completion, failure |

Use durable queues, persistent messages, manual acknowledgement, retry policy, and a dead-letter queue. The worker acknowledges its input only after candidate data/suggestions are persisted or a final failure event is published.

## Request event

The Platform API must store the original file and create the batch row before publishing this event.

```json
{
  "event_id": "uuid",
  "event_type": "ingestion.requested",
  "batch_id": "uuid",
  "product": "lending",
  "attempt": 1,
  "requested_at": "2026-10-31T10:30:00Z"
}
```

Pass only `batch_id` and metadata through RabbitMQ. Never send file bytes, user filesystem paths, credentials, or large OCR results.

## Database contract

The shared PostgreSQL database was inspected on 31 October 2026 and has no application tables. The Platform API team must apply the following migration before starting the worker. Keep the database URL in an environment variable such as `DATABASE_URL`; do not put connection strings in source, events, logs, frontend code, or Markdown.

```sql
CREATE TABLE ingestion_batches (
  id UUID PRIMARY KEY,
  product_type TEXT NOT NULL CHECK (product_type IN ('lending', 'erp', 'aml')),
  original_filename TEXT NOT NULL,
  storage_provider TEXT NOT NULL,
  storage_bucket TEXT,
  storage_key TEXT NOT NULL,
  file_type TEXT NOT NULL CHECK (file_type IN ('csv', 'xlsx', 'json', 'pdf')),
  content_type TEXT,
  file_size_bytes BIGINT,
  checksum_sha256 TEXT,
  status TEXT NOT NULL DEFAULT 'UPLOADED',
  progress_percent SMALLINT NOT NULL DEFAULT 0 CHECK (progress_percent BETWEEN 0 AND 100),
  status_message TEXT,
  total_records INTEGER NOT NULL DEFAULT 0,
  candidate_records INTEGER NOT NULL DEFAULT 0,
  review_records INTEGER NOT NULL DEFAULT 0,
  error_code TEXT,
  error_message TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE candidate_records (
  id UUID PRIMARY KEY,
  batch_id UUID NOT NULL REFERENCES ingestion_batches(id) ON DELETE CASCADE,
  source_type TEXT NOT NULL CHECK (source_type IN ('csv', 'excel', 'json', 'pdf_text', 'pdf_ocr')),
  source_location JSONB NOT NULL,
  raw_fields JSONB NOT NULL,
  extraction_metadata JSONB NOT NULL DEFAULT '{}',
  issues JSONB NOT NULL DEFAULT '[]',
  status TEXT NOT NULL DEFAULT 'PENDING_MAPPING',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE mapping_suggestions (
  id UUID PRIMARY KEY,
  batch_id UUID NOT NULL REFERENCES ingestion_batches(id) ON DELETE CASCADE,
  source_field TEXT NOT NULL,
  target_field TEXT,
  transformation JSONB NOT NULL DEFAULT '{}',
  confidence NUMERIC(5,4),
  reason TEXT,
  status TEXT NOT NULL DEFAULT 'SUGGESTED',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (batch_id, source_field)
);

CREATE INDEX idx_candidate_records_batch_status
  ON candidate_records (batch_id, status);
CREATE INDEX idx_mapping_suggestions_batch
  ON mapping_suggestions (batch_id);
```

`ingestion_batches` is Platform API-owned. The worker reads `product_type`, `storage_provider`, `storage_bucket`, `storage_key`, and `file_type` from it. The worker writes only `candidate_records` and `mapping_suggestions`. The Platform API updates batch state after it consumes worker events.

## Worker event schema

Every event includes `event_id`, `batch_id`, `event_type`, and `occurred_at`. The Platform API must de-duplicate `event_id` values before updating status or emitting SSE.

### Progress

Publish only meaningful stages: `EXTRACTING`, `OCR_PROCESSING`, `MAPPING_SUGGESTED`, and `SAVING_RESULTS`.

```json
{
  "event_id": "uuid",
  "event_type": "ingestion.progress",
  "batch_id": "uuid",
  "status": "OCR_PROCESSING",
  "progress_percent": 60,
  "message": "Reading scanned PDF page 6 of 10",
  "occurred_at": "2026-10-31T10:31:02Z"
}
```

### Completion

Publish only after candidate records and suggestions are committed.

```json
{
  "event_id": "uuid",
  "event_type": "ingestion.completed",
  "batch_id": "uuid",
  "status": "READY_FOR_REVIEW",
  "progress_percent": 100,
  "candidate_record_count": 250,
  "mapping_suggestion_count": 8,
  "review_record_count": 12,
  "occurred_at": "2026-10-31T10:34:12Z"
}
```

### Failure

```json
{
  "event_id": "uuid",
  "event_type": "ingestion.failed",
  "batch_id": "uuid",
  "status": "FAILED_RETRYABLE",
  "progress_percent": 35,
  "error_code": "OCR_TIMEOUT",
  "message": "OCR processing exceeded the configured time limit.",
  "retryable": true,
  "occurred_at": "2026-10-31T10:34:12Z"
}
```

Never send stack traces, prompts, secrets, database URLs, or storage credentials in an event.

## Common candidate record

Every parser writes this format so the mapping UI has one source-independent contract.

```json
{
  "source_type": "pdf_ocr",
  "source_location": { "page": 1, "table": 1, "row": 2 },
  "raw_fields": {
    "Invoice No": "INV-001",
    "Supplier": "ABC Ltd",
    "Due Date": "10-Oct-2026",
    "Amount": "10,000"
  },
  "extraction_metadata": {
    "method": "paddleocr",
    "confidence": 0.93
  },
  "issues": [],
  "status": "PENDING_MAPPING"
}
```

## Worker algorithm

```text
1. Consume ai.ingestion.requested.
2. Validate event and load the ingestion batch by batch_id.
3. Publish EXTRACTING progress.
4. Read storage_provider/storage_key and stream the file.
5. Route CSV, Excel, JSON, text PDF, or scanned PDF extraction.
6. Construct common candidate records.
7. Bulk insert candidate_records in a transaction.
8. Generate mapping suggestions: aliases -> BGE -> Groq only for ambiguity.
9. Upsert mapping_suggestions.
10. Publish ingestion.completed.
11. Acknowledge the request message.
```

If a temporary dependency fails, publish a retryable failure and follow the retry policy. If the format is unsupported or invalid, publish `FAILED_FINAL` and acknowledge the job.

## Backend/UI integration requirements

The Platform team must provide:

- An upload endpoint that stores the file, inserts `ingestion_batches`, and publishes `ai.ingestion.requested`.
- A RabbitMQ event consumer that writes worker event status to `ingestion_batches`.
- An SSE endpoint that sends those status updates to the browser.
- A mapping-review API/UI that reads candidate records and suggestions by `batch_id`.
- A later action that stores approved mappings and writes final normalized Lending/ERP/AML data. That action is outside worker scope.
