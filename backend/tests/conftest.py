"""Starts the real API (uvicorn, in a thread) against the local DB, so tests
exercise HTTP, SSE streaming and the DB together.

Broker: in-process LocalBroker by default. Set TEST_RABBITMQ_URL (use a separate
vhost, e.g. amqp://studio:<pw>@localhost:5672/studio_test) to run the same tests
through real RabbitMQ.

Needs a built DB (db/build.ps1 -Reset). Tests create their own uniquely-named
users/files, so they can be re-run without a rebuild.
"""
import os
import tempfile
import threading
import time
import uuid

os.environ["RABBITMQ_URL"] = os.getenv("TEST_RABBITMQ_URL", "")
os.environ["DEV_ENDPOINTS"] = "true"
os.environ["STORAGE_DIR"] = tempfile.mkdtemp(prefix="studio-test-")

import httpx  # noqa: E402
import pytest  # noqa: E402
import uvicorn  # noqa: E402

from app.main import app  # noqa: E402

PORT = 8765
BASE = f"http://127.0.0.1:{PORT}"
DEMO_PASSWORD = "Studio#2026"   # from db/06_seed.sql


@pytest.fixture(scope="session", autouse=True)
def server():
    srv = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=PORT, log_level="warning"))
    t = threading.Thread(target=srv.run, daemon=True)
    t.start()
    for _ in range(100):
        if srv.started:
            break
        time.sleep(0.1)
    assert srv.started, "API did not start"
    yield
    srv.should_exit = True
    t.join(5)


def login(email: str, password: str = DEMO_PASSWORD) -> httpx.Client:
    """Logged-in client: Bearer header set, refresh cookie in its jar."""
    c = httpx.Client(base_url=BASE, timeout=30)
    r = c.post("/api/auth/login", json={"email": email, "password": password})
    assert r.status_code == 200, r.text
    c.headers["Authorization"] = f"Bearer {r.json()['access_token']}"
    return c


@pytest.fixture
def anon():
    with httpx.Client(base_url=BASE, timeout=30) as c:
        yield c


@pytest.fixture
def admin():
    c = login("admin@studio.local")
    yield c
    c.close()


@pytest.fixture
def analyst():
    c = login("associate@studio.local")   # ANALYST in ERP + AML
    yield c
    c.close()


@pytest.fixture
def reviewer():
    c = login("manager@studio.local")     # REVIEWER in all apps
    yield c
    c.close()


@pytest.fixture
def new_user(admin):
    """A throwaway user (so lockout/token-theft tests don't touch demo users)."""
    email = f"t-{uuid.uuid4().hex[:10]}@studio.local"
    r = admin.post("/api/admin/users", json={"email": email, "full_name": "Test User", "password": "Passw0rd1"})
    assert r.status_code == 201, r.text
    return {"email": email, "password": "Passw0rd1", "user_id": r.json()["user_id"]}
