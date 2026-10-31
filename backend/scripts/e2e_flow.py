"""End-to-end smoke test of the RUNNING system: API on :8000 + PostgreSQL + RabbitMQ.

What it does (re-runnable):
  1. super admin creates 4 users (one per role) and grants that role in ERP, AML, LENDING
  2. each user logs in -> checks dashboard cards, sidebar, admin access, upload rights
  3. full upload flow on ERP: analyst uploads a CSV, viewer watches progress over SSE,
     this script plays the AI worker (consumes RabbitMQ, COPYs records, publishes progress),
     reviewer commits (maker-checker + permission checks on the way)
  4. session checks: refresh rotation, logout, wrong password
  5. cleanup: its own leftover jobs are removed from RabbitMQ and closed as FAILED

Run:  cd backend;  .venv\\Scripts\\python scripts\\e2e_flow.py
"""
import asyncio
import json
import sys
import threading
import time
import uuid
from pathlib import Path
from urllib.parse import unquote, urlparse

import aio_pika
import httpx
import psycopg

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from app.config import settings  # noqa: E402

API = "http://localhost:8000"
SUPER_ADMIN = ("admin@studio.local", "Studio#2026")      # from db/06_seed.sql
PASSWORD = "Azentio@123"
USERS = {   # role -> email
    "APP_ADMIN": "appadmin@azentio.ai",
    "REVIEWER":  "reviewer@azentio.ai",
    "ANALYST":   "analyst@azentio.ai",
    "VIEWER":    "viewer@azentio.ai",
}
APPS = ("erp", "aml", "lending")

# What each role must see / be able to do (per app)
COMMON = ["dashboard", "datasets", "reports", "templates", "assistant"]
EXPECT = {
    "APP_ADMIN": {"menu": ["dashboard", "datasets", "mapping", "data_quality", "reports", "templates", "assistant", "admin"],
                  "upload": True, "admin": True},
    "REVIEWER":  {"menu": ["dashboard", "datasets", "mapping", "data_quality", "reports", "templates", "assistant"],
                  "upload": False, "admin": False},
    "ANALYST":   {"menu": ["dashboard", "datasets", "mapping", "data_quality", "reports", "templates", "assistant"],
                  "upload": True, "admin": False},
    "VIEWER":    {"menu": COMMON, "upload": False, "admin": False},
}

failures = 0


def check(ok: bool, what: str, detail: str = "") -> None:
    global failures
    print(f"  {'PASS' if ok else 'FAIL'}  {what}" + (f"  [{detail}]" if detail and not ok else ""))
    failures += not ok


def login(email: str, password: str) -> httpx.Client:
    c = httpx.Client(base_url=API, timeout=30)
    r = c.post("/api/auth/login", json={"email": email, "password": password})
    r.raise_for_status()
    c.headers["Authorization"] = f"Bearer {r.json()['access_token']}"
    return c


def section(title: str) -> None:
    print(f"\n== {title}")


# ------------------------------------------------------------------ 1 ----
def create_users() -> None:
    section("1. Super admin creates 4 users and grants roles in ERP, AML, LENDING")
    admin = login(*SUPER_ADMIN)
    users = {}
    for role, email in USERS.items():
        r = admin.post("/api/admin/users", json={"email": email, "full_name": f"Azentio {role.title()}",
                                                 "password": PASSWORD})
        check(r.status_code in (201, 409), f"create {email}", r.text)   # 409 = exists from an earlier run
    listing = admin.get("/api/apps/erp/admin/users").json()
    ids = {u["email"]: u["user_id"] for u in listing}
    for role, email in USERS.items():
        users[email] = ids[email]
        for app in APPS:
            r = admin.post(f"/api/apps/{app}/admin/users/{ids[email]}/roles", json={"role": role})
            check(r.status_code == 200, f"grant {role:<9} in {app.upper():<7} to {email}", r.text)


# ------------------------------------------------------------------ 2 ----
def check_rbac() -> None:
    section("2. Each user: login, dashboard cards, sidebar, admin access, upload rights")
    for role, email in USERS.items():
        print(f"  -- {email} ({role})")
        c = login(email, PASSWORD)
        cards = [a["code"] for a in c.get("/api/apps").json()]
        check(cards == ["ERP", "AML", "LENDING"], f"dashboard cards = {cards}")
        for app in APPS:
            sel = c.post(f"/api/apps/{app}/select").json()
            menu = [m["code"] for m in sel["sidebar"]]
            children = [x["code"] for m in sel["sidebar"] if m["code"] == "datasets" for x in m["children"]]
            check(menu == EXPECT[role]["menu"], f"{app.upper():<7} sidebar = {menu}", str(EXPECT[role]["menu"]))
            check(("datasets.upload" in children) == EXPECT[role]["upload"],
                  f"{app.upper():<7} 'Upload file' menu {'shown' if EXPECT[role]['upload'] else 'hidden'}")
        r = c.get("/api/apps/erp/admin/users")
        check(r.status_code == (200 if EXPECT[role]["admin"] else 403), f"ERP user admin -> {r.status_code}")
        r = c.post("/api/apps/aml/batches", files={"file": ("alerts.json", json.dumps([{"alert_id": str(uuid.uuid4())}]).encode(),
                                                               "application/json")})
        check(r.status_code == (201 if EXPECT[role]["upload"] else 403), f"AML upload -> {r.status_code}")
        c.close()


# ------------------------------------------------------------------ 3 ----
def fake_ai_worker(batch_id: str) -> int:
    """Plays the ML teammate's worker: take the job from RabbitMQ, parse, COPY, report progress."""
    async def run() -> int:
        conn = await aio_pika.connect(settings.rabbitmq_url)
        async with conn:
            ch = await conn.channel()
            exchange = await ch.get_exchange("ingestion")
            queue = await ch.get_queue("ingestion.requested")

            # Find our job. Other jobs are held unacked while scanning (a requeued message
            # would come straight back to the head), then returned to the queue untouched.
            job, others = None, []
            for _ in range(100):
                msg = await queue.get(fail=False)
                if msg is None:
                    await asyncio.sleep(0.1)
                    continue
                body = json.loads(msg.body)
                if body["batch_id"] == batch_id:
                    await msg.ack()
                    job = body
                    break
                others.append(msg)
            for msg in others:
                await msg.reject(requeue=True)
            assert job, "job never arrived on ingestion.requested"
            print(f"  worker: got job from RabbitMQ  file={job['file_name']} type={job['file_type']}")

            async def progress(status: str, pct: int | None = None, message: str = "") -> None:
                await exchange.publish(aio_pika.Message(json.dumps(
                    {"batch_id": batch_id, "app": "erp", "status": status, "progress_pct": pct,
                     "message": message}).encode(), content_type="application/json"), routing_key="erp.progress")

            await progress("EXTRACTING", 10, "Reading CSV")
            path = Path(unquote(urlparse(job["storage_uri"]).path).lstrip("/"))
            lines = path.read_text(encoding="utf-8").strip().splitlines()
            header = lines[0].split(",")
            rows, n = [], 0
            suppliers = set()
            for line_no, line in enumerate(lines[1:], start=2):
                raw = dict(zip(header, line.split(",")))
                if raw["Supplier"] not in suppliers:       # one supplier record per distinct supplier
                    suppliers.add(raw["Supplier"])
                    n += 1
                    rows.append((n, "supplier", {"row": line_no, "column": "Supplier"}, {"Supplier": raw["Supplier"]},
                                 {"supplier_id": raw["Supplier"], "supplier_name": raw["Supplier"]}, "ACCEPTED"))
                n += 1
                ok = raw["Amount"] != ""                   # tiny validation: amount is mandatory
                rows.append((n, "invoice", {"row": line_no}, raw,
                             {"invoice_id": raw["Invoice_No"], "supplier_id": raw["Supplier"],
                              "invoice_date": raw["Invoice_Date"], "due_date": raw["Due_Date"],
                              "amount": raw["Amount"], "currency": raw["Currency"]} if ok else None,
                             "ACCEPTED" if ok else "REJECTED"))
            await progress("EXTRACTING", 60, f"Parsed {len(lines) - 1} lines")

            with psycopg.connect(settings.dsn("erp_app"), autocommit=True) as db:
                with db.cursor().copy("COPY erp.raw_record (batch_id, record_no, target_entity, source_location, "
                                      "raw_fields, normalized_fields, extraction_method, state) FROM STDIN") as cp:
                    for no, entity, loc, raw, norm, state in rows:
                        cp.write_row((batch_id, no, entity, json.dumps(loc), json.dumps(raw),
                                      json.dumps(norm) if norm else None, "csv", state))
            print(f"  worker: COPY {len(rows)} candidate records into erp.raw_record")

            await progress("EXTRACTING", 100, "Extraction done")
            await progress("MAPPING_REVIEW", None, "Mapping proposed")
            await progress("VALIDATING", 50, "Checking rules")
            await progress("READY_TO_COMMIT", None, "Ready")
            return len(rows)

    return asyncio.run(run())


def wait_status(c: httpx.Client, batch_id: str, status: str) -> bool:
    for _ in range(100):
        if c.get(f"/api/apps/erp/batches/{batch_id}").json()["status"] == status:
            return True
        time.sleep(0.1)
    return False


def upload_flow() -> None:
    section("3. ERP upload flow: analyst uploads -> worker via RabbitMQ -> SSE -> reviewer commits")
    analyst, viewer = login(USERS["ANALYST"], PASSWORD), login(USERS["VIEWER"], PASSWORD)
    reviewer, appadmin = login(USERS["REVIEWER"], PASSWORD), login(USERS["APP_ADMIN"], PASSWORD)

    tag = uuid.uuid4().hex[:6].upper()
    csv = ("Invoice_No,Supplier,Invoice_Date,Due_Date,Amount,Currency\n"
           f"INV-{tag}-1,SUP-{tag}-A,2026-09-01,2026-09-30,10000.00,INR\n"
           f"INV-{tag}-2,SUP-{tag}-A,2026-09-05,2026-10-05,5000.00,INR\n"
           f"INV-{tag}-3,SUP-{tag}-B,2026-10-01,2026-10-31,7500.50,INR\n"
           f"INV-{tag}-4,SUP-{tag}-B,2026-10-02,2026-11-01,,INR\n")      # missing amount -> rejected
    r = analyst.post("/api/apps/erp/batches", files={"file": (f"payables_{tag}.csv", csv.encode(), "text/csv")},
                     data={"source_system": "SAP", "period_start": "2026-09-01", "period_end": "2026-10-31"})
    check(r.status_code == 201, f"analyst uploads payables_{tag}.csv -> {r.status_code} {r.json().get('status')}")
    batch_id = r.json()["batch_id"]
    r2 = analyst.post("/api/apps/erp/batches", files={"file": ("same_again.csv", csv.encode(), "text/csv")})
    check(r2.json().get("status") == "DUPLICATE", "same file again -> DUPLICATE (no double import)")

    # Viewer watches progress live over SSE (has dataset.view).
    seen: list[dict] = []

    def watch():
        with viewer.stream("GET", f"/api/apps/erp/batches/{batch_id}/events", timeout=60) as s:
            for line in s.iter_lines():
                if line.startswith("data: "):
                    seen.append(json.loads(line[6:]))
                    if seen[-1]["status"] == "COMMITTED":
                        return
    watcher = threading.Thread(target=watch, daemon=True)
    watcher.start()

    fake_ai_worker(batch_id)
    check(wait_status(viewer, batch_id, "READY_TO_COMMIT"), "batch reached READY_TO_COMMIT via RabbitMQ")

    for who, c, code in (("viewer", viewer, 403), ("analyst (no batch.commit)", analyst, 403)):
        r = c.post(f"/api/apps/erp/batches/{batch_id}/commit")
        check(r.status_code == code, f"{who} commit -> {r.status_code}")
    r = reviewer.post(f"/api/apps/erp/batches/{batch_id}/commit")
    body = r.json()
    check(r.status_code == 200 and body["status"] == "COMMITTED", f"reviewer commit -> {r.status_code} {body}")
    check((body["received"], body["accepted"], body["rejected"]) == (6, 5, 1),
          "record accounting: received 6 = accepted 5 + rejected 1")
    check(body["loaded"] == {"supplier": 2, "invoice": 3}, f"loaded into domain tables {body['loaded']}")

    watcher.join(15)
    statuses = [f"{e['status']}{'' if e['progress_pct'] in (0, 100) else ' ' + str(e['progress_pct']) + '%'}" for e in seen]
    print(f"  viewer SSE saw: {' -> '.join(statuses)}")
    check(seen and seen[0]["status"] == "UPLOADED" and seen[-1]["status"] == "COMMITTED",
          "SSE stream covered UPLOADED ... COMMITTED")
    check([e["event_id"] for e in seen] == sorted(e["event_id"] for e in seen), "SSE events arrived in order")

    b = viewer.get(f"/api/apps/erp/batches/{batch_id}").json()
    check(b["committed_by"] != b["uploaded_by"], f"maker-checker: {b['batch_code']} uploaded by analyst, committed by reviewer")
    with psycopg.connect(settings.dsn("erp_app")) as db:
        total = db.execute("SELECT sum(amount) FROM erp.invoice WHERE batch_id = %s", (batch_id,)).fetchone()[0]
    check(str(total) == "22500.50", f"ERP invoice total for batch = {total}")
    for c in (analyst, viewer, reviewer, appadmin):
        c.close()


# ------------------------------------------------------------------ 4 ----
def session_checks() -> None:
    section("4. Sessions: wrong password, refresh rotation, logout")
    anon = httpx.Client(base_url=API)
    r = anon.post("/api/auth/login", json={"email": USERS["VIEWER"], "password": "wrong"})
    check(r.status_code == 401, f"wrong password -> {r.status_code}")

    c = login(USERS["VIEWER"], PASSWORD)
    old = c.cookies.get("refresh_token")
    r = c.post("/api/auth/refresh")
    check(r.status_code == 200 and c.cookies.get("refresh_token") != old, "refresh -> new access + rotated refresh token")
    c.headers["Authorization"] = f"Bearer {r.json()['access_token']}"
    check(c.post("/api/auth/logout").status_code == 204, "logout -> 204")
    check(c.get("/api/apps").status_code == 401, "token after logout -> 401")


# ------------------------------------------------------------------ 5 ----
def cleanup() -> None:
    """Remove this script's own jobs from ingestion.requested (only jobs uploaded by the
    test users) and close their batches as FAILED, so the real AI worker never sees them."""
    section("5. Cleanup: drain smoke-test jobs from RabbitMQ, mark their batches FAILED")
    admin = login(*SUPER_ADMIN)
    test_ids = {u["user_id"] for u in admin.get("/api/apps/erp/admin/users").json() if u["email"] in USERS.values()}
    admin.close()

    async def run() -> int:
        conn = await aio_pika.connect(settings.rabbitmq_url)
        async with conn:
            ch = await conn.channel()
            exchange = await ch.get_exchange("ingestion")
            queue = await ch.get_queue("ingestion.requested")
            mine, others = [], []
            while msg := await queue.get(fail=False):
                (mine if json.loads(msg.body)["uploaded_by"] in test_ids else others).append(msg)
            for msg in others:
                await msg.reject(requeue=True)
            for msg in mine:
                job = json.loads(msg.body)
                await exchange.publish(aio_pika.Message(json.dumps(
                    {"batch_id": job["batch_id"], "app": job["app"], "status": "FAILED",
                     "error": "Smoke test upload - not processed"}).encode()), routing_key=f"{job['app']}.progress")
                await msg.ack()
            return len(mine)
    print(f"  removed {asyncio.run(run())} smoke-test job(s); other jobs left untouched")


if __name__ == "__main__":
    try:
        httpx.get(f"{API}/api/health", timeout=5).raise_for_status()
    except Exception as e:
        sys.exit(f"API not reachable at {API}: {e}")
    print("API health:", httpx.get(f"{API}/api/health").json())
    create_users()
    check_rbac()
    upload_flow()
    session_checks()
    cleanup()
    print(f"\n{'ALL CHECKS PASSED' if not failures else f'{failures} CHECK(S) FAILED'}")
    sys.exit(1 if failures else 0)
