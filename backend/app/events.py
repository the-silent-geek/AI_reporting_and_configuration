"""In-process fan-out of batch events to open SSE connections.

Each SSE connection subscribes to one batch and gets an asyncio.Queue.
Events arrive here from the broker (RabbitMQ fanout, or the local broker),
already persisted in the DB with an event_id.
"""
import asyncio
from collections import defaultdict

_subscribers: dict[str, set[asyncio.Queue]] = defaultdict(set)


def subscribe(batch_id: str) -> asyncio.Queue:
    q: asyncio.Queue = asyncio.Queue(maxsize=100)
    _subscribers[batch_id].add(q)
    return q


def unsubscribe(batch_id: str, q: asyncio.Queue) -> None:
    _subscribers[batch_id].discard(q)
    if not _subscribers[batch_id]:
        del _subscribers[batch_id]


def publish(event: dict) -> None:
    """Must be called on the event loop thread."""
    for q in list(_subscribers.get(event["batch_id"], ())):
        try:
            q.put_nowait(event)
        except asyncio.QueueFull:
            pass  # slow client: it will resync from the DB on reconnect (Last-Event-ID)
