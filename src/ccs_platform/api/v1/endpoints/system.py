from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Request, Response
from sqlalchemy import func, select, text

from ccs_platform.core.metrics import METRICS
from ccs_platform.db import models
from ccs_platform.db.session import SessionLocal, engine


router = APIRouter(tags=["system"])


@router.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


def _queue_backlog_snapshot() -> dict[str, Any]:
    by_queue: dict[str, dict[str, int]] = {}
    with SessionLocal() as db:
        rows = db.execute(
            select(models.Job.queue_name, models.Job.status, func.count(models.Job.id))
            .group_by(models.Job.queue_name, models.Job.status)
        ).all()

    for queue_name, status, count in rows:
        queue_bucket = by_queue.setdefault(str(queue_name or "default"), {})
        queue_bucket[str(status.value if hasattr(status, "value") else status)] = int(count)

    total_queued = sum(bucket.get("queued", 0) for bucket in by_queue.values())
    total_running = sum(bucket.get("running", 0) for bucket in by_queue.values())
    return {
        "total_queued": total_queued,
        "total_running": total_running,
        "by_queue": by_queue,
    }


def _build_readiness_payload(request: Request) -> dict[str, Any]:
    checks: dict[str, dict[str, Any]] = {}

    try:
        with SessionLocal() as db:
            db.execute(text("SELECT 1"))
        checks["database"] = {"status": "ok", "dialect": engine.dialect.name}
    except Exception as exc:  # noqa: BLE001
        checks["database"] = {"status": "error", "detail": str(exc)}

    storage = getattr(request.app.state, "storage", None)
    if storage is None:
        checks["storage"] = {"status": "error", "detail": "Storage adapter not initialized"}
    elif getattr(storage, "backend_name", "") == "local":
        root_dir = getattr(storage, "root_dir", None)
        is_ready = bool(root_dir and getattr(root_dir, "exists", lambda: False)())
        checks["storage"] = {
            "status": "ok" if is_ready else "error",
            "backend": "local",
            "path": str(root_dir) if root_dir is not None else None,
        }
    elif getattr(storage, "backend_name", "") == "gcs":
        bucket = getattr(storage, "bucket", None)
        checks["storage"] = {
            "status": "ok" if bucket else "error",
            "backend": "gcs",
            "bucket": bucket,
        }
    else:
        checks["storage"] = {"status": "error", "detail": "Unknown storage backend"}

    metrics = METRICS.snapshot()
    backlog = _queue_backlog_snapshot()
    return {
        "status": "ok" if all(check["status"] == "ok" for check in checks.values()) else "degraded",
        "checks": checks,
        "metrics": {
            "requests_total": metrics["requests"]["total"],
            "job_events": metrics["jobs"]["events"],
            "queue_backlog": backlog,
        },
    }


@router.get("/health/ready")
def health_ready(request: Request, response: Response) -> dict[str, Any]:
    payload = _build_readiness_payload(request)
    if payload["status"] != "ok":
        response.status_code = 503
    return payload


@router.get("/metrics")
def metrics() -> dict[str, Any]:
    snapshot = METRICS.snapshot()
    snapshot["jobs"]["queue_backlog"] = _queue_backlog_snapshot()
    return snapshot
