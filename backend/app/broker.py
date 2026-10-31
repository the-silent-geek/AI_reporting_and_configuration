"""Messaging between the API and the AI worker.

RabbitMQ topology (all declared here, idempotently):

  exchange "ingestion" (topic, durable)
    <app>.requested  -> queue "ingestion.requested"  -> AI worker consumes
    <app>.progress   -> queue "ingestion.progress"   -> API instances consume (competing:
                                                         each update is written to the DB once)
  exchange "batch.updates" (fanout)                   -> one exclusive queue per API instance
                                                         -> in-process SSE hub (events.py)
  exchange "ingestion.dlx" -> queue "ingestion.dead"  (messages that failed processing)

Message bodies are JSON, see docs/API_GUIDE.md (worker contract).

Without RABBITMQ_URL a LocalBroker does the same in-process, so the API and
its tests run without a broker (dev only, single instance).
"""
import json
import logging
from uuid import UUID

import aio_pika
from fastapi.concurrency import run_in_threadpool
from psycopg.types.numeric import Int2

from . import db, events
from .config import PRODUCTS, settings

log = logging.getLogger(__name__)

STATUSES = {"EXTRACTING", "MAPPING_REVIEW", "VALIDATING", "READY_TO_COMMIT", "NEEDS_REVIEW", "FAILED", "UPLOADED"}


def latest_event(app: str, batch_id: str) -> dict:
    """Most recent stored event of a batch (e.g. COMMITTED written by sp_commit_batch)."""
    (event_id,) = db.rows(app, f"SELECT max(event_id) FROM {app}.fn_get_batch_events(%s, 0)", batch_id)[0]
    return _event_row(app, batch_id, event_id)


def _event_row(app: str, batch_id: str, event_id: int) -> dict:
    (row,) = db.rows(app, f"SELECT event_id, status, progress_pct, message, created_at "
                          f"FROM {app}.fn_get_batch_events(%s, %s)", batch_id, event_id - 1)[:1]
    return {"event_id": row[0], "batch_id": batch_id, "app": app, "status": row[1],
            "progress_pct": row[2], "message": row[3], "created_at": row[4].isoformat()}


async def handle_progress(payload: dict) -> dict:
    """Persist one worker progress message; return the stored event for fan-out.

    Raises ValueError / HTTPException on bad input or an illegal transition.
    """
    app = str(payload.get("app", "")).lower()
    status = str(payload.get("status", "")).upper()
    if app not in PRODUCTS or status not in STATUSES:
        raise ValueError(f"bad progress message: {payload}")
    batch_id = str(UUID(str(payload["batch_id"])))
    pct = payload.get("progress_pct")
    if pct is not None and not 0 <= int(pct) <= 100:
        raise ValueError("progress_pct out of range")

    event_id = await run_in_threadpool(
        db.call, app, f"{app}.sp_update_batch_status", batch_id, status,
        None if pct is None else Int2(int(pct)), payload.get("message"), payload.get("error"))
    return await run_in_threadpool(_event_row, app, batch_id, event_id)


class LocalBroker:
    """In-process stand-in for RabbitMQ (dev/tests). Requests go nowhere but are kept."""

    def __init__(self):
        self.requested: list[dict] = []

    async def start(self): log.warning("RABBITMQ_URL not set: using in-process LocalBroker (dev only)")
    async def stop(self): pass

    async def publish_request(self, payload: dict) -> None:
        self.requested.append(payload)

    async def publish_progress(self, payload: dict) -> None:
        events.publish(await handle_progress(payload))

    async def broadcast(self, event: dict) -> None:
        events.publish(event)


class RabbitBroker:
    def __init__(self, url: str):
        self.url = url

    async def start(self) -> None:
        self.conn = await aio_pika.connect_robust(self.url)
        ch = await self.conn.channel()
        await ch.set_qos(prefetch_count=20)          # don't flood one instance

        dlx = await ch.declare_exchange("ingestion.dlx", aio_pika.ExchangeType.FANOUT, durable=True)
        await (await ch.declare_queue("ingestion.dead", durable=True)).bind(dlx)
        dead_letter = {"x-dead-letter-exchange": "ingestion.dlx"}

        self.ingestion = await ch.declare_exchange("ingestion", aio_pika.ExchangeType.TOPIC, durable=True)
        requested = await ch.declare_queue("ingestion.requested", durable=True, arguments=dead_letter)
        await requested.bind(self.ingestion, "*.requested")
        # Progress must be applied in the order the worker sent it (40% before 80%,
        # EXTRACTING before MAPPING_REVIEW). single-active-consumer = only one API
        # instance consumes at a time (automatic failover); prefetch 1 on its own
        # channel = one message at a time, in order.
        ordered = await self.conn.channel()
        await ordered.set_qos(prefetch_count=1)
        progress = await ordered.declare_queue(
            "ingestion.progress", durable=True, arguments={**dead_letter, "x-single-active-consumer": True})
        await progress.bind(self.ingestion, "*.progress")

        self.updates = await ch.declare_exchange("batch.updates", aio_pika.ExchangeType.FANOUT)
        mine = await ch.declare_queue(exclusive=True, auto_delete=True)
        await mine.bind(self.updates)

        await progress.consume(self._on_progress)
        await mine.consume(self._on_update)
        log.info("RabbitMQ connected")

    async def stop(self) -> None:
        await self.conn.close()

    async def _publish(self, exchange, routing_key: str, payload: dict) -> None:
        await exchange.publish(
            aio_pika.Message(json.dumps(payload, default=str).encode(), content_type="application/json",
                             delivery_mode=aio_pika.DeliveryMode.PERSISTENT),
            routing_key=routing_key)

    async def publish_request(self, payload: dict) -> None:
        await self._publish(self.ingestion, f"{payload['app']}.requested", payload)

    async def publish_progress(self, payload: dict) -> None:   # used by /dev endpoint only
        await self._publish(self.ingestion, f"{payload['app']}.progress", payload)

    async def broadcast(self, event: dict) -> None:
        """Send an already-stored event to the SSE clients of every API instance."""
        await self._publish(self.updates, "", event)

    async def _on_progress(self, message: aio_pika.abc.AbstractIncomingMessage) -> None:
        # requeue=False: a message that fails (bad JSON, illegal transition) goes to
        # ingestion.dead instead of looping forever. Ack happens only after the DB write.
        async with message.process(requeue=False):
            event = await handle_progress(json.loads(message.body))
            await self._publish(self.updates, "", event)

    async def _on_update(self, message: aio_pika.abc.AbstractIncomingMessage) -> None:
        async with message.process():
            events.publish(json.loads(message.body))


broker = RabbitBroker(settings.rabbitmq_url) if settings.rabbitmq_url else LocalBroker()
