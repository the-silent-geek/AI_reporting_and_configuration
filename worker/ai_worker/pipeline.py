"""One ingestion job, start to finish. Synchronous: runs in a worker thread so
parsing/OCR/embedding never block the RabbitMQ connection.

  load batch -> already done?  -> report the stored result again, write nothing
             -> EXTRACTING  read file (checksum verified) -> parse -> candidate records
             -> EXTRACTING  suggest mappings (alias -> BGE -> Groq)
             -> EXTRACTING  save records + issues + mapping proposal (one transaction)
             -> MAPPING_REVIEW, or NEEDS_REVIEW when some records need a person

Progress goes through the API's state machine, so only these statuses are used;
the stage is in the message ("OCR on scanned page 3 of 10").
"""
import logging
import time
from dataclasses import dataclass
from typing import Protocol

from .errors import FinalError, WorkerError
from .mapping import MappingService
from .messages import IngestionRequested, Progress, WorkerStatus
from .parsers import ParserRouter
from .repository import Repository, Saved
from .storage import StorageRouter

log = logging.getLogger(__name__)

# Batch already past the worker's part: a redelivery must not touch it.
_PAST_WORKER = {"MAPPING_REVIEW", "NEEDS_REVIEW", "VALIDATING", "READY_TO_COMMIT", "COMMITTED"}

# progress_pct bands of the EXTRACTING stage
_READ_FROM, _READ_TO = 5, 60
_MAPPING, _SAVING = 65, 85


class Publisher(Protocol):
    def progress(self, p: Progress) -> None:
        """Publish and wait for the broker's confirm. Thread-safe."""


@dataclass(frozen=True)
class Outcome:
    status: WorkerStatus | None   # None = job skipped (batch not in a state the worker owns)
    records: int = 0
    needs_review: int = 0
    mappings: int = 0


class _Throttle:
    """At most one progress message per 5 % or per 2 s: many-page PDFs shouldn't flood the queue."""

    def __init__(self, emit):
        self.emit = emit
        self.last_pct = -100
        self.last_at = 0.0

    def __call__(self, pct: int, message: str) -> None:
        pct = _READ_FROM + (_READ_TO - _READ_FROM) * max(0, min(pct, 100)) // 100
        now = time.monotonic()
        if pct - self.last_pct >= 5 or now - self.last_at >= 2:
            self.last_pct, self.last_at = pct, now
            self.emit(pct, message)


class IngestionPipeline:
    def __init__(self, repo: Repository, storage: StorageRouter, parsers: ParserRouter, mapper: MappingService):
        self.repo = repo
        self.storage = storage
        self.parsers = parsers
        self.mapper = mapper

    def run(self, job: IngestionRequested, publisher: Publisher) -> Outcome:
        app, batch_id = job.app, job.batch_id

        def emit(status: WorkerStatus, pct: int | None, message: str) -> None:
            publisher.progress(Progress(batch_id=batch_id, app=app, status=status, progress_pct=pct, message=message))

        batch = self.repo.load_batch(app, batch_id)
        if batch is None:
            raise FinalError("BATCH_NOT_FOUND", "The batch no longer exists.")
        if batch.status in _PAST_WORKER or batch.status == "FAILED":
            # FAILED: the API closed it (a user retry moves it back to UPLOADED and re-queues)
            log.info("batch %s is %s; job skipped", batch_id, batch.status)
            return Outcome(None)

        saved = self.repo.existing_result(app, batch_id)
        if saved is None:
            saved = self._extract_and_save(app, batch, emit)
        else:
            log.info("batch %s: results already stored by an earlier attempt", batch_id)
            if batch.status == "UPLOADED":   # UPLOADED -> MAPPING_REVIEW is not a legal jump
                emit("EXTRACTING", _SAVING, "Results already extracted")

        status: WorkerStatus = "NEEDS_REVIEW" if saved.needs_review else "MAPPING_REVIEW"
        message = f"{saved.records} records extracted, {saved.mappings} field mappings suggested"
        if saved.needs_review:
            message += f"; {saved.needs_review} records need review"
        emit(status, None, message)
        return Outcome(status, saved.records, saved.needs_review, saved.mappings)

    def _extract_and_save(self, app: str, batch, emit) -> Saved:
        parser = self.parsers.for_type(batch.file_type)
        emit("EXTRACTING", _READ_FROM, f"Reading {batch.file_type} file")
        with self.storage.local_copy(batch.storage_uri, batch.sha256) as path:
            try:
                records = parser.parse(path, _Throttle(lambda pct, msg: emit("EXTRACTING", pct, msg)))
            except WorkerError:
                raise
            except Exception:
                # A parser crash on this input will crash again: don't retry, keep the details in the log only.
                log.exception("parser failed on batch %s", batch.batch_id)
                raise FinalError("PARSE_FAILED", f"The {batch.file_type} file could not be read.")
        if not records:
            raise FinalError("EMPTY_FILE", "No records were found in the file.")

        emit("EXTRACTING", _MAPPING, f"Extracted {len(records)} records; suggesting field mappings")
        mapping = self.mapper.suggest(app, records)

        emit("EXTRACTING", _SAVING, f"Saving {len(records)} records")
        return self.repo.save(app, batch.batch_id, records, mapping)
