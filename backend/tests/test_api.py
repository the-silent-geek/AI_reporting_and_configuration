import json
import threading
import time
import uuid

import httpx
import psycopg

from app.config import settings
from conftest import BASE, login


def _csv(rows: int = 2) -> bytes:
    # unique content -> unique sha256 -> a new batch every run
    return ("Invoice_No,Amount\n" + "".join(f"INV-{uuid.uuid4().hex[:6]},{i}00\n" for i in range(rows))).encode()


def _upload(client, app="erp", name="payables.csv", content=None):
    content = _csv() if content is None else content
    return client.post(f"/api/apps/{app}/batches", files={"file": (name, content, "text/csv")})


def _real_broker() -> bool:
    from app.broker import LocalBroker, broker
    return not isinstance(broker, LocalBroker)


def _progress(client, batch_id, status, pct=None, app="erp"):
    return client.post("/api/dev/progress", json={"batch_id": batch_id, "app": app, "status": status,
                                                  "progress_pct": pct, "message": f"{status} {pct}"})


def _wait_status(client, batch_id, status, app="erp"):
    """With real RabbitMQ, progress is applied asynchronously."""
    for _ in range(100):
        if client.get(f"/api/apps/{app}/batches/{batch_id}").json()["status"] == status:
            return
        time.sleep(0.05)
    raise AssertionError(f"batch never reached {status}")


# ------------------------------------------------------------------ auth ----

def test_health(anon):
    assert anon.get("/api/health").json()["status"] == "ok"


def test_login_ok_sets_httponly_refresh_cookie(anon):
    r = anon.post("/api/auth/login", json={"email": "associate@studio.local", "password": "Studio#2026"})
    assert r.status_code == 200
    body = r.json()
    assert body["access_token"] and "refresh_token" not in json.dumps(body)   # refresh only in cookie
    cookie = r.headers["set-cookie"].lower()
    assert "httponly" in cookie and "samesite=strict" in cookie and "path=/api/auth" in cookie
    assert [a["code"] for a in body["apps"]] == ["ERP", "AML"]


def test_login_wrong_password(anon):
    r = anon.post("/api/auth/login", json={"email": "associate@studio.local", "password": "nope"})
    assert r.status_code == 401 and r.json()["detail"]["status"] == "INVALID_CREDENTIALS"


def test_lockout_returns_423(anon, new_user):
    for _ in range(5):
        anon.post("/api/auth/login", json={"email": new_user["email"], "password": "bad"})
    r = anon.post("/api/auth/login", json={"email": new_user["email"], "password": new_user["password"]})
    assert r.status_code == 423 and r.json()["detail"]["status"] == "ACCOUNT_LOCKED"


def test_requires_token(anon):
    assert anon.get("/api/apps").status_code == 401
    assert anon.get("/api/apps", headers={"Authorization": "Bearer garbage"}).status_code == 401


def test_refresh_rotates_and_detects_reuse(new_user):
    c = login(new_user["email"], new_user["password"])
    old_cookie = c.cookies.get("refresh_token")
    r = c.post("/api/auth/refresh")
    assert r.status_code == 200 and r.json()["access_token"]
    assert c.cookies.get("refresh_token") != old_cookie

    # Attacker replays the old refresh token -> everything for this user dies.
    thief = httpx.Client(base_url=BASE, cookies={"refresh_token": old_cookie})
    r = thief.post("/api/auth/refresh")
    assert r.status_code == 401 and r.json()["detail"]["status"] == "TOKEN_REUSED"
    assert c.post("/api/auth/refresh").status_code == 401


def test_logout_kills_access_token_immediately(new_user):
    c = login(new_user["email"], new_user["password"])
    assert c.get("/api/apps").status_code == 200
    assert c.post("/api/auth/logout").status_code == 204
    assert c.get("/api/apps").status_code == 401    # JWT not expired, but session is gone


# ------------------------------------------------------------- SSO/RBAC ----

def test_cards_and_sidebar_follow_roles(analyst, reviewer):
    assert [a["code"] for a in reviewer.get("/api/apps").json()] == ["ERP", "AML", "LENDING"]

    r = analyst.post("/api/apps/erp/select")
    assert r.status_code == 200
    menu = {m["code"]: m for m in r.json()["sidebar"]}
    assert "admin" not in menu
    assert [c["code"] for c in menu["datasets"]["children"]] == ["datasets.list", "datasets.upload"]

    assert analyst.post("/api/apps/lending/select").status_code == 403
    assert analyst.post("/api/apps/hr/select").status_code == 404


def test_admin_flow(admin, analyst, new_user):
    uid = new_user["user_id"]
    assert analyst.post("/api/admin/users", json={"email": "x@studio.local", "full_name": "X",
                                                  "password": "Passw0rd1"}).status_code == 403
    assert admin.post("/api/apps/aml/admin/users/" + uid + "/roles", json={"role": "VIEWER"}).json()["changed"]
    u = login(new_user["email"], new_user["password"])
    assert [a["code"] for a in u.get("/api/apps").json()] == ["AML"]
    assert admin.delete(f"/api/apps/aml/admin/users/{uid}/roles/VIEWER").json()["changed"]
    assert admin.patch(f"/api/admin/users/{uid}", json={"is_active": False}).status_code == 200
    assert u.get("/api/apps").status_code == 401          # disabled -> session dead
    weak = admin.post("/api/admin/users", json={"email": "w@studio.local", "full_name": "W", "password": "short"})
    assert weak.status_code == 400


# --------------------------------------------------------------- upload ----

def test_upload_rules(analyst, reviewer):
    content = _csv()
    r = _upload(analyst, content=content)
    assert r.status_code == 201 and r.json()["status"] == "CREATED"
    again = _upload(analyst, name="renamed.csv", content=content)
    assert again.status_code == 200 and again.json()["status"] == "DUPLICATE"
    assert again.json()["batch_id"] == r.json()["batch_id"]

    assert _upload(reviewer).status_code == 403                                   # reviewer can't upload
    assert _upload(analyst, app="lending").status_code == 403                     # no lending role
    assert _upload(analyst, name="evil.exe", content=b"MZ...").status_code == 415  # extension
    assert _upload(analyst, name="fake.pdf", content=b"hello").status_code == 415  # signature
    assert _upload(analyst, name="empty.csv", content=b"").status_code == 400


def _queued_requests() -> list[dict]:
    """Messages waiting for the AI worker (LocalBroker list, or drained from RabbitMQ)."""
    from app.broker import LocalBroker, broker
    if isinstance(broker, LocalBroker):
        return broker.requested

    import asyncio
    import aio_pika

    async def drain():
        conn = await aio_pika.connect(settings.rabbitmq_url)
        async with conn:
            q = await (await conn.channel()).get_queue("ingestion.requested")
            out = []
            while msg := await q.get(fail=False):
                await msg.ack()
                out.append(json.loads(msg.body))
            return out
    return asyncio.run(drain())


def test_storage_dir_absolute_even_if_env_empty(monkeypatch):
    # regression: STORAGE_DIR= (empty, as in .env.example) made a relative path -> 500 on upload
    from app import config
    monkeypatch.setenv("STORAGE_DIR", "")
    assert config.load().storage_dir.is_absolute()


def test_upload_queues_worker_message(analyst):
    batch_id = _upload(analyst).json()["batch_id"]
    msg = next(m for m in _queued_requests() if m["batch_id"] == batch_id)
    assert msg["app"] == "erp" and msg["storage_uri"].startswith("file:") and msg["file_type"] == "CSV"


# ------------------------------------------------- SSE + full pipeline ----

def _read_sse(client, url, want, out, headers=None):
    with client.stream("GET", url, headers=headers or {}, timeout=30) as r:
        out.append(r.status_code)
        for line in r.iter_lines():
            if line.startswith("data: "):
                out.append(json.loads(line[6:]))
                if len(out) - 1 >= want:
                    return


def test_sse_live_and_replay(analyst):
    batch_id = _upload(analyst).json()["batch_id"]
    url = f"/api/apps/erp/batches/{batch_id}/events"

    got: list = []
    t = threading.Thread(target=_read_sse, args=(analyst, url, 3, got))   # UPLOADED + 2 live events
    t.start()
    while len(got) < 2:          # wait until the replayed UPLOADED event arrived
        t.join(0.05)
    assert _progress(analyst, batch_id, "EXTRACTING", 40).status_code == 200
    assert _progress(analyst, batch_id, "EXTRACTING", 80).status_code == 200
    t.join(10)
    assert got[0] == 200
    assert [(e["status"], e["progress_pct"]) for e in got[1:]] == [("UPLOADED", 0), ("EXTRACTING", 40), ("EXTRACTING", 80)]

    # Reconnect with Last-Event-ID -> only what came after.
    replay: list = []
    _read_sse(analyst, url, 1, replay, {"Last-Event-ID": str(got[2]["event_id"])})
    assert replay[1]["progress_pct"] == 80


def test_illegal_transition_rejected(analyst):
    batch_id = _upload(analyst).json()["batch_id"]
    r = _progress(analyst, batch_id, "READY_TO_COMMIT")
    if _real_broker():
        # async: the message is dead-lettered; prove a later legal one still applies and the jump didn't
        assert _progress(analyst, batch_id, "EXTRACTING").status_code == 200
        _wait_status(analyst, batch_id, "EXTRACTING")
    else:
        assert r.status_code == 400


def test_full_pipeline_with_maker_checker(analyst, reviewer):
    batch_id = _upload(analyst).json()["batch_id"]
    for status in ("EXTRACTING", "MAPPING_REVIEW"):
        assert _progress(analyst, batch_id, status).status_code == 200
    _wait_status(analyst, batch_id, "MAPPING_REVIEW")

    # What the AI worker does: write candidate records (normally COPY).
    sup, inv = f"SUP-{uuid.uuid4().hex[:6]}", f"INV-{uuid.uuid4().hex[:6]}"
    with psycopg.connect(settings.dsn("erp_app"), autocommit=True) as conn:
        conn.execute(
            """INSERT INTO erp.raw_record (batch_id, record_no, target_entity, source_location, raw_fields,
                                           normalized_fields, extraction_method, state)
               VALUES (%(b)s, 1, 'supplier', '{"row":2}', '{}', %(s)s, 'csv', 'ACCEPTED'),
                      (%(b)s, 2, 'invoice',  '{"row":3}', '{}', %(i)s, 'csv', 'ACCEPTED'),
                      (%(b)s, 3, 'invoice',  '{"row":4}', '{}', NULL,  'csv', 'REJECTED')""",
            {"b": batch_id,
             "s": json.dumps({"supplier_id": sup, "supplier_name": "Acme"}),
             "i": json.dumps({"invoice_id": inv, "supplier_id": sup, "invoice_date": "2026-10-01",
                              "due_date": "2026-10-31", "amount": "2500.50", "currency": "INR"})})

    for status in ("VALIDATING", "READY_TO_COMMIT"):
        assert _progress(analyst, batch_id, status).status_code == 200
    _wait_status(analyst, batch_id, "READY_TO_COMMIT")

    assert analyst.post(f"/api/apps/erp/batches/{batch_id}/commit").status_code == 403   # no batch.commit
    r = reviewer.post(f"/api/apps/erp/batches/{batch_id}/commit")
    assert r.status_code == 200, r.text
    assert r.json() | {"loaded": None} == {"status": "COMMITTED", "received": 3, "accepted": 2, "rejected": 1,
                                           "loaded": None}
    b = reviewer.get(f"/api/apps/erp/batches/{batch_id}").json()
    assert b["status"] == "COMMITTED" and b["counts"]["received"] == 3 and "storage_uri" not in b
    assert any(x["batch_id"] == batch_id for x in reviewer.get("/api/apps/erp/batches").json())
