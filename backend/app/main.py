"""FastAPI entry point.  Run:  uvicorn app.main:app --reload  (from backend/)"""
import logging
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI
from fastapi.middleware.cors import CORSMiddleware

from . import db
from .broker import broker
from .config import settings
from .routers import admin, apps, assistant, auth, batches, review, reports, templates
from .security import Principal, current_user

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")


@asynccontextmanager
async def lifespan(_: FastAPI):
    db.open_pools()
    await broker.start()
    yield
    await broker.stop()
    db.close_pools()


app = FastAPI(title="Reporting Studio API", version="0.1.0", lifespan=lifespan)
app.add_middleware(CORSMiddleware, allow_origins=settings.cors_origins, allow_credentials=True,
                   allow_methods=["*"], allow_headers=["*"])

for r in (auth.router, apps.router, admin.router, batches.router, assistant.router, review.router, reports.router, templates.router):
    app.include_router(r)


@app.get("/api/health", tags=["ops"])
def health():
    db.call("iam", "iam.fn_has_permission", None, "ERP", "dashboard.view")  # proves DB + grants work
    return {"status": "ok", "broker": type(broker).__name__}


if settings.dev_endpoints:
    @app.post("/api/dev/progress", tags=["dev"])
    async def fake_worker_progress(payload: dict, _: Principal = Depends(current_user)):
        """DEV ONLY: pretend to be the AI worker and push a progress message
        ({"batch_id","app","status","progress_pct","message"}) through the broker."""
        await broker.publish_progress(payload)
        return {"published": True}
