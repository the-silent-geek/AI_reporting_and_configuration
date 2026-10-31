# AI Reporting Studio - AI Worker

This workspace contains the integration contract for the AI ingestion worker. The worker is responsible for file extraction, PDF OCR routing, candidate-record creation, and hybrid field-mapping suggestions.

It is not responsible for the frontend, authentication, Server-Sent Events, final business-data writes, dashboards, reports, templates, or final validation.

## Read first

- [AI worker contract](docs/01-ai-worker-contract.md)
- [Mapping and Smart Assistance design](docs/02-mapping-and-smart-assistance.md)
- [AI worker implementation prompt](docs/03-ai-worker-implementation-prompt.md)

## Boundary

```text
Platform API -> ai.ingestion.requested -> AI worker
AI worker -> ai.ingestion.events -> Platform API -> SSE -> UI
```

The Platform API stores the upload and owns batch status. The worker saves raw candidate records and mapping suggestions, then emits worker events for the Platform API to process.
