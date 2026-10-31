"""RabbitMQ side of the worker. Topology is the API's (backend/app/broker.py),
declared here again with identical arguments so either side can start first:

  exchange "ingestion" (topic)  *.requested -> queue ingestion.requested  -> this worker
                                *.progress  -> queue ingestion.progress   -> API
  exchange "ingestion.dlx"                  -> queue ingestion.dead

Per job:
  * manual ack, only after results are committed and the final status published
  * bad message body                    -> rejected to ingestion.dead
  * FinalError (bad file)               -> FAILED published, job acked
  * temporary error / unexpected crash  -> same job re-published with x-attempt + 1 after
                                           a backoff; after WORKER_MAX_ATTEMPTS: FAILED
                                           published and the job dead-lettered for ops
"""
import asyncio
import logging
from typing import Awaitable, Callable

import aio_pika
from pydantic import ValidationError

from .config import Settings
from .errors import WorkerError
from .messages import IngestionRequested, Progress
from .pipeline import IngestionPipeline

log = logging.getLogger(__name__)

_DEAD_LETTER = {"x-dead-letter-exchange": "ingestion.dlx"}
_GENERIC_ERROR = "Processing failed unexpectedly. Please retry the upload."


class ThreadsafePublisher:
    """Lets the pipeline (in a worker thread) publish on the event loop's channel."""

    def __init__(self, loop: asyncio.AbstractEventLoop, publish: Callable[[Progress], Awaitable[None]]):
        self.loop = loop
        self.publish = publish

    def progress(self, p: Progress) -> None:
        asyncio.run_coroutine_threadsafe(self.publish(p), self.loop).result(timeout=60)


class RabbitConsumer:
    def __init__(self, settings: Settings, pipeline: IngestionPipeline):
        self.s = settings
        self.pipeline = pipeline
        self._inflight = 0
        self._idle = asyncio.Event()
        self._idle.set()

    async def start(self) -> None:
        self.conn = await aio_pika.connect_robust(self.s.rabbitmq_url)
        ch = await self.conn.channel()   # publisher confirms on: publish() returns once the broker has it
        await ch.set_qos(prefetch_count=self.s.concurrency)

        dlx = await ch.declare_exchange("ingestion.dlx", aio_pika.ExchangeType.FANOUT, durable=True)
        await (await ch.declare_queue("ingestion.dead", durable=True)).bind(dlx)
        self.exchange = await ch.declare_exchange("ingestion", aio_pika.ExchangeType.TOPIC, durable=True)
        requested = await ch.declare_queue("ingestion.requested", durable=True, arguments=_DEAD_LETTER)
        await requested.bind(self.exchange, "*.requested")
        # declared so progress is never unroutable while the API is down (same args as the API)
        progress = await ch.declare_queue("ingestion.progress", durable=True,
                                          arguments={**_DEAD_LETTER, "x-single-active-consumer": True})
        await progress.bind(self.exchange, "*.progress")

        self.queue = requested
        self.consumer_tag = await requested.consume(self._on_message)
        log.info("worker consuming ingestion.requested (concurrency %s)", self.s.concurrency)

    async def stop(self) -> None:
        """Stop taking jobs, let running ones finish, then disconnect."""
        await self.queue.cancel(self.consumer_tag)
        await self._idle.wait()
        await self.conn.close()

    async def _publish(self, routing_key: str, body: bytes, headers: dict | None = None) -> None:
        await self.exchange.publish(
            aio_pika.Message(body, content_type="application/json", headers=headers or {},
                             delivery_mode=aio_pika.DeliveryMode.PERSISTENT),
            routing_key=routing_key)

    async def publish_progress(self, p: Progress) -> None:
        await self._publish(f"{p.app}.progress", p.body())

    async def _on_message(self, message: aio_pika.abc.AbstractIncomingMessage) -> None:
        self._inflight += 1
        self._idle.clear()
        try:
            await self._handle(message)
        finally:
            self._inflight -= 1
            if not self._inflight:
                self._idle.set()

    async def _handle(self, message: aio_pika.abc.AbstractIncomingMessage) -> None:
        try:
            job = IngestionRequested.model_validate_json(message.body)
        except ValidationError as e:
            log.error("invalid ingestion request rejected to ingestion.dead: %s", e.errors(include_input=False))
            await message.reject(requeue=False)
            return

        attempt = int((message.headers or {}).get("x-attempt", 1))
        log.info("batch %s (%s, %s) attempt %s", job.batch_id, job.app, job.file_type, attempt)
        publisher = ThreadsafePublisher(asyncio.get_running_loop(), self.publish_progress)
        try:
            outcome = await asyncio.to_thread(self.pipeline.run, job, publisher)
        except Exception as e:   # noqa: BLE001 - every failure must end in an event + ack/dead-letter
            await self._failed(message, job, attempt, e)
            return
        log.info("batch %s -> %s (%s records, %s need review, %s mappings)", job.batch_id,
                 outcome.status or "skipped", outcome.records, outcome.needs_review, outcome.mappings)
        await message.ack()

    async def _failed(self, message, job: IngestionRequested, attempt: int, e: Exception) -> None:
        known = isinstance(e, WorkerError)
        if known:
            log.warning("batch %s failed: %s", job.batch_id, e)
        else:
            log.exception("batch %s crashed", job.batch_id)
        retryable = not known or e.retryable

        if retryable and attempt < self.s.max_attempts:
            delay = self.s.retry_base_seconds * 2 ** (attempt - 1)
            await self.publish_progress(Progress(
                batch_id=job.batch_id, app=job.app, status="EXTRACTING",
                message=f"Temporary problem, retrying in {delay:.0f}s (attempt {attempt + 1} of {self.s.max_attempts})"))
            await asyncio.sleep(delay)
            # re-publish first, ack second: a crash in between means a duplicate job, which is harmless
            await self._publish(message.routing_key or f"{job.app}.requested", message.body,
                                {**(message.headers or {}), "x-attempt": attempt + 1})
            await message.ack()
            return

        if known and e.code == "BATCH_NOT_FOUND":   # nothing to report on: the API would reject the event
            await message.ack()
            return
        await self.publish_progress(Progress(
            batch_id=job.batch_id, app=job.app, status="FAILED",
            message=f"Processing failed ({e.code})" if known else "Processing failed",
            error=e.message if known else _GENERIC_ERROR))
        if retryable:
            await message.reject(requeue=False)   # retries used up: keep the job in ingestion.dead for ops
        else:
            await message.ack()
