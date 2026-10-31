"""Typed RabbitMQ messages. Contract: docs/API_GUIDE.md § AI worker contract.

  in   queue ingestion.requested            (API publishes ingestion / <app>.requested)
  out  exchange ingestion, key <app>.progress (API applies it via <app>.sp_update_batch_status)
"""
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field

App = Literal["erp", "aml", "lending"]
FileType = Literal["CSV", "EXCEL", "JSON", "PDF"]

# The subset of the batch state machine (db/_product_pipeline.sql) the worker drives:
#   UPLOADED -> EXTRACTING -> MAPPING_REVIEW | NEEDS_REVIEW,   any of them -> FAILED
WorkerStatus = Literal["EXTRACTING", "MAPPING_REVIEW", "NEEDS_REVIEW", "FAILED"]


class IngestionRequested(BaseModel):
    """Body the API publishes after sp_create_batch (routers/batches.py)."""
    model_config = ConfigDict(extra="ignore", frozen=True)

    batch_id: UUID
    app: App
    file_type: FileType
    file_name: str = Field(max_length=255)
    storage_uri: str
    sha256: str = Field(pattern=r"^[0-9a-f]{64}$")
    uploaded_by: UUID


class Progress(BaseModel):
    """Body the API's handle_progress() accepts. progress_pct None = let the DB decide
    (a status change restarts the bar), same as the API's own fake worker."""
    model_config = ConfigDict(extra="forbid", frozen=True)

    batch_id: UUID
    app: App
    status: WorkerStatus
    progress_pct: int | None = Field(default=None, ge=0, le=100)
    message: str | None = Field(default=None, max_length=500)
    error: str | None = Field(default=None, max_length=500)

    def body(self) -> bytes:
        return self.model_dump_json(exclude_none=True).encode()
