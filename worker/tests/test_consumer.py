"""Ack / retry / dead-letter decisions, with a fake channel (no RabbitMQ needed)."""
import asyncio
import dataclasses
import json
from uuid import uuid4

from ai_worker.consumer import RabbitConsumer
from ai_worker.errors import FinalError, RetryableError
from ai_worker.pipeline import Outcome

JOB = {"batch_id": str(uuid4()), "app": "erp", "file_type": "CSV", "file_name": "p.csv",
       "storage_uri": "file:///x/p.csv", "sha256": "a" * 64, "uploaded_by": str(uuid4())}


class FakeMessage:
    def __init__(self, body: dict | bytes, headers=None):
        self.body = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.headers = headers or {}
        self.routing_key = "erp.requested"
        self.result = None

    async def ack(self):
        self.result = "ack"

    async def reject(self, requeue=False):
        self.result = f"reject(requeue={requeue})"


class FakeExchange:
    def __init__(self):
        self.published: list[tuple[str, dict, dict]] = []

    async def publish(self, message, routing_key):
        self.published.append((routing_key, json.loads(message.body), dict(message.headers)))


class FakePipeline:
    def __init__(self, result):
        self.result = result

    def run(self, job, publisher):
        if isinstance(self.result, Exception):
            raise self.result
        return self.result


def _consumer(settings, result) -> tuple[RabbitConsumer, FakeExchange]:
    s = dataclasses.replace(settings, retry_base_seconds=0, max_attempts=3)
    c = RabbitConsumer(s, FakePipeline(result))
    c.exchange = FakeExchange()
    return c, c.exchange


def _run(consumer, message):
    asyncio.run(consumer._on_message(message))


def test_success_acks(settings):
    c, ex = _consumer(settings, Outcome("MAPPING_REVIEW", 3, 0, 6))
    m = FakeMessage(JOB)
    _run(c, m)
    assert m.result == "ack" and ex.published == []


def test_invalid_message_is_dead_lettered(settings):
    c, ex = _consumer(settings, Outcome(None))
    m = FakeMessage(b'{"batch_id": "not-a-uuid"}')
    _run(c, m)
    assert m.result == "reject(requeue=False)" and ex.published == []


def test_final_error_publishes_failed_and_acks(settings):
    c, ex = _consumer(settings, FinalError("INVALID_FILE", "The PDF file could not be opened."))
    m = FakeMessage(JOB)
    _run(c, m)
    assert m.result == "ack"
    (key, body, _), = ex.published
    assert key == "erp.progress"
    assert body == {"batch_id": JOB["batch_id"], "app": "erp", "status": "FAILED",
                    "message": "Processing failed (INVALID_FILE)", "error": "The PDF file could not be opened."}


def test_temporary_error_is_requeued_with_next_attempt(settings):
    c, ex = _consumer(settings, RetryableError("DB_UNAVAILABLE", "The database is temporarily unavailable."))
    m = FakeMessage(JOB, {"x-attempt": 1})
    _run(c, m)
    assert m.result == "ack"
    progress, retry = ex.published
    assert progress[1]["status"] == "EXTRACTING" and "attempt 2 of 3" in progress[1]["message"]
    assert retry == ("erp.requested", JOB, {"x-attempt": 2})


def test_retries_exhausted_fail_and_dead_letter(settings):
    c, ex = _consumer(settings, RetryableError("OCR_TIMEOUT", "OCR processing exceeded the configured time limit."))
    m = FakeMessage(JOB, {"x-attempt": 3})
    _run(c, m)
    assert m.result == "reject(requeue=False)"
    (_, body, _), = ex.published
    assert body["status"] == "FAILED" and body["error"].startswith("OCR processing exceeded")


def test_unexpected_crash_is_retried_and_never_leaks_details(settings):
    c, ex = _consumer(settings, RuntimeError("password=secret at /srv/storage/x"))
    m = FakeMessage(JOB, {"x-attempt": 3})
    _run(c, m)
    (_, body, _), = ex.published
    assert body["status"] == "FAILED"
    assert "secret" not in json.dumps(body) and "/srv" not in json.dumps(body)


def test_missing_batch_is_acked_silently(settings):
    c, ex = _consumer(settings, FinalError("BATCH_NOT_FOUND", "The batch no longer exists."))
    m = FakeMessage(JOB)
    _run(c, m)
    assert m.result == "ack" and ex.published == []
