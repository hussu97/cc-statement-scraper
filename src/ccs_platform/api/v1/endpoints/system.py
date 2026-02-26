from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Request, Response
from sqlalchemy import text

from ccs_platform.core.metrics import METRICS
from ccs_platform.db.session import SessionLocal, engine


router = APIRouter(tags=["system"])


@router.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


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
    return {
        "status": "ok" if all(check["status"] == "ok" for check in checks.values()) else "degraded",
        "checks": checks,
        "metrics": {
            "requests_total": metrics["requests"]["total"],
            "job_events": metrics["jobs"]["events"],
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
    return METRICS.snapshot()
