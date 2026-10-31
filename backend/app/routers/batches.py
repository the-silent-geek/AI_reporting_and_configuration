"""Upload -> batch -> worker progress over SSE -> commit.

Upload path (built for many concurrent users):
  * permission checked BEFORE reading the body
  * file streamed to disk in 1 MB chunks while hashing (never fully in memory)
  * stored content-addressed: storage/<app>/<sha256><ext> -> same file is stored once
  * real file signature checked, not just the extension
  * DB registers the batch (duplicate file -> existing batch returned)
  * ingestion.requested published for the AI worker
"""
import asyncio
import hashlib
import json
import os
import uuid
from datetime import date
from pathlib import Path
from uuid import UUID

from fastapi import APIRouter, Depends, File, Form, Header, HTTPException, Request, UploadFile
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import JSONResponse, StreamingResponse

from .. import db, events
from ..broker import broker, latest_event
from ..config import settings
from ..security import Principal, current_user, product

router = APIRouter(prefix="/api/apps/{app_code}/batches", tags=["batches"])

_TYPES = {".csv": "CSV", ".json": "JSON", ".pdf": "PDF", ".xlsx": "EXCEL", ".xls": "EXCEL"}
_CHUNK = 1024 * 1024
_HEARTBEAT_SECONDS = 15


def _signature_ok(file_type: str, head: bytes) -> bool:
    if file_type == "PDF":
        return head.startswith(b"%PDF-")
    if file_type == "EXCEL":
        return head.startswith(b"PK\x03\x04") or head.startswith(b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1")
    if file_type == "JSON":
        return head.removeprefix(b"\xef\xbb\xbf").lstrip()[:1] in (b"{", b"[")
    return b"\x00" not in head  # CSV: must be text


async def _store(app: str, upload: UploadFile, ext: str) -> tuple[Path, str, int, bytes]:
    """Stream to a temp file while hashing; move to its content address. Returns (path, sha256, size, head)."""
    limit = settings.max_upload_mb * 1024 * 1024
    folder = settings.storage_dir / app
    folder.mkdir(parents=True, exist_ok=True)
    tmp = folder / f".upload-{uuid.uuid4().hex}"
    sha, size, head = hashlib.sha256(), 0, b""
    try:
        with tmp.open("wb") as out:
            while chunk := await upload.read(_CHUNK):
                size += len(chunk)
                if size > limit:
                    raise HTTPException(413, f"File larger than {settings.max_upload_mb} MB")
                if len(head) < 8192:
                    head += chunk[: 8192 - len(head)]
                sha.update(chunk)
                out.write(chunk)
        if size == 0:
            raise HTTPException(400, "Empty file")
        digest = sha.hexdigest()
        final = folder / f"{digest}{ext}"
        if final.exists():
            tmp.unlink()            # identical content already stored
        else:
            os.replace(tmp, final)  # atomic on the same volume
        return final, digest, size, head
    except BaseException:
        tmp.unlink(missing_ok=True)
        raise


@router.post("")
async def upload(
    app: str = Depends(product),
    me: Principal = Depends(current_user),
    file: UploadFile = File(...),
    source_system: str | None = Form(None, max_length=100),
    period_start: date | None = Form(None),
    period_end: date | None = Form(None),
):
    if not await run_in_threadpool(db.call, "iam", "iam.fn_has_permission", me.user_id, app, "dataset.upload"):
        raise HTTPException(403, "Not allowed to upload in this app")

    ext = Path(file.filename or "").suffix.lower()
    file_type = _TYPES.get(ext)
    if not file_type:
        raise HTTPException(415, "Only CSV, Excel, JSON and PDF files are accepted")

    path, digest, size, head = await _store(app, file, ext)
    if not _signature_ok(file_type, head):
        raise HTTPException(415, f"File content is not a valid {file_type}")

    r = await run_in_threadpool(
        db.call, app, f"{app}.sp_create_batch", me.user_id, (file.filename or "")[:255], file_type, size,
        digest, path.as_uri(), file.content_type, source_system, period_start, period_end)
    if r["status"] == "DUPLICATE":
        return JSONResponse(r, status_code=200)

    try:
        await broker.publish_request({
            "batch_id": r["batch_id"], "app": app, "file_type": file_type, "file_name": file.filename,
            "storage_uri": path.as_uri(), "sha256": digest, "uploaded_by": str(me.user_id)})
    except Exception:
        # Never leave a batch that no worker will ever pick up.
        await run_in_threadpool(db.call, app, f"{app}.sp_update_batch_status", r["batch_id"], "FAILED",
                                None, None, "Could not queue for processing")
        raise HTTPException(503, "Processing queue unavailable, please retry")
    return JSONResponse(r, status_code=201)


@router.get("")
def list_batches(limit: int = 50, offset: int = 0, app: str = Depends(product), me: Principal = Depends(current_user)):
    return db.call(app, f"{app}.fn_list_batches", me.user_id, limit, offset)


@router.get("/{batch_id}")
def get_batch(batch_id: UUID, app: str = Depends(product), me: Principal = Depends(current_user)):
    return db.call(app, f"{app}.fn_get_batch", me.user_id, batch_id)


@router.post("/{batch_id}/commit")
async def commit_batch(batch_id: UUID, app: str = Depends(product), me: Principal = Depends(current_user)):
    result = await run_in_threadpool(db.call, app, f"{app}.sp_commit_batch", me.user_id, batch_id)
    # sp_commit_batch stored a COMMITTED event; push it to open SSE streams too.
    await broker.broadcast(await run_in_threadpool(latest_event, app, str(batch_id)))
    return result


@router.get("/{batch_id}/events")
async def batch_events(
    batch_id: UUID, request: Request,
    app: str = Depends(product), me: Principal = Depends(current_user),
    last_event_id: int = Header(0, alias="Last-Event-ID"),
):
    """Server-Sent Events for one batch.

    Browser's native EventSource can't send an Authorization header, so the UI
    uses a fetch-based SSE client. On reconnect it sends Last-Event-ID and gets
    everything it missed from the DB first.
    """
    await run_in_threadpool(db.call, app, f"{app}.fn_get_batch", me.user_id, batch_id)  # 403 / 404
    bid = str(batch_id)

    async def stream():
        queue = events.subscribe(bid)   # subscribe BEFORE replay so nothing falls in the gap
        sent = last_event_id
        try:
            missed = await run_in_threadpool(
                db.rows, app, f"SELECT event_id, status, progress_pct, message, created_at "
                              f"FROM {app}.fn_get_batch_events(%s, %s)", bid, sent)
            for event_id, status, pct, message, created_at in missed:
                yield _sse({"event_id": event_id, "batch_id": bid, "app": app, "status": status,
                            "progress_pct": pct, "message": message, "created_at": created_at.isoformat()})
                sent = event_id
            while True:
                try:
                    event = await asyncio.wait_for(queue.get(), _HEARTBEAT_SECONDS)
                except TimeoutError:
                    if await request.is_disconnected():
                        return
                    if not await run_in_threadpool(db.call, "iam", "iam.fn_session_is_active", me.session_id):
                        yield "event: session_ended\ndata: {}\n\n"
                        return
                    yield ": ping\n\n"   # keeps proxies from closing an idle stream
                    continue
                if event["event_id"] > sent:
                    yield _sse(event)
                    sent = event["event_id"]
        finally:
            events.unsubscribe(bid, queue)

    return StreamingResponse(stream(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})


def _sse(event: dict) -> str:
    return f"id: {event['event_id']}\nevent: progress\ndata: {json.dumps(event, default=str)}\n\n"
