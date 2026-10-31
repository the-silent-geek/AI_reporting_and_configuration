# AI Worker Implementation Prompt

Implement only the AI ingestion worker defined in `docs/01-ai-worker-contract.md`.

Read these files first:

- `README.md`
- `docs/01-ai-worker-contract.md`
- `docs/02-mapping-and-smart-assistance.md`

## Build

Create a typed AI ingestion worker that consumes RabbitMQ queue `ai.ingestion.requested` and publishes `ingestion.progress`, `ingestion.completed`, and `ingestion.failed` events to `ai.ingestion.events`.

For every request:

1. Validate the request schema and load the batch metadata using `batch_id`.
2. Read the upload via `storage_provider`, `storage_bucket`, and `storage_key`.
3. Extract CSV, Excel, JSON, text PDF, or scanned PDF content. Use PaddleOCR only when a PDF region is scanned/image based.
4. Convert every parsed row or form into the common candidate-record JSON format.
5. Bulk-insert candidate records into PostgreSQL.
6. Produce mapping suggestions using aliases and inferred types first, local `BAAI/bge-small-en-v1.5` second, and Groq only for ambiguous fields.
7. Validate Groq output against a strict JSON schema before saving it.
8. Upsert mapping suggestions and publish completion only after database writes succeed.

## Do not build

- Frontend, authentication, upload UI, or Server-Sent Events.
- Final record validation/normalization or writes to Lending, ERP, or AML final tables.
- Dashboards, report rendering, template rendering, or PDF download.
- Unrestricted SQL tools, arbitrary file paths, or browser-controlled database access.

## Safety and reliability

- Use environment variables for RabbitMQ, PostgreSQL, storage, Groq, and model configuration.
- Never place credentials in code, events, logs, or docs.
- Use manual RabbitMQ acknowledgement, idempotent processing, durable queues, retry handling, and dead-letter routing.
- Redelivered messages must not duplicate candidate records or mapping suggestions.
- Publish only meaningful stages: `EXTRACTING`, `OCR_PROCESSING`, `MAPPING_SUGGESTED`, and `SAVING_RESULTS`.
- Preserve source location, parser/OCR method, and confidence for every candidate record.
- The worker suggests mappings but never writes approved final business records.

## Deliverables

- Typed event schemas.
- RabbitMQ consumer and event publisher.
- PostgreSQL repositories for candidate records and mapping suggestions.
- Storage-reader abstraction.
- Parser-router interface with CSV implementation and stubs/interfaces for Excel, JSON, PDF text, and PaddleOCR.
- Alias, BGE, and Groq mapping service abstractions.
- Idempotency checks and tests for CSV ingestion plus PDF OCR routing.
