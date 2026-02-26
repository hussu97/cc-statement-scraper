from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Any

from fastapi import APIRouter, Request, Response
from sqlalchemy import func, select, text

from ccs_platform.core.metrics import METRICS
from ccs_platform.core.settings import PlatformSettings
from ccs_platform.db import models
from ccs_platform.db.session import SessionLocal, engine


router = APIRouter(tags=["system"])


@router.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


def _as_utc(value: datetime) -> datetime:
    if value.tzinfo is None:
        return value.replace(tzinfo=UTC)
    return value.astimezone(UTC)


def _queue_backlog_snapshot(settings: PlatformSettings) -> dict[str, Any]:
    by_queue: dict[str, dict[str, int]] = {}
    oldest_queued_by_queue: dict[str, datetime] = {}
    completed_last_hour: dict[str, dict[str, int]] = {}
    now = datetime.now(UTC)

    with SessionLocal() as db:
        rows = db.execute(
            select(models.Job.queue_name, models.Job.status, func.count(models.Job.id))
            .group_by(models.Job.queue_name, models.Job.status)
        ).all()
        oldest_rows = db.execute(
            select(models.Job.queue_name, func.min(models.Job.created_at))
            .where(models.Job.status == models.JobStatus.QUEUED)
            .group_by(models.Job.queue_name)
        ).all()
        completed_rows = db.execute(
            select(models.Job.queue_name, models.Job.status, func.count(models.Job.id))
            .where(models.Job.finished_at.is_not(None))
            .where(models.Job.finished_at >= now - timedelta(hours=1))
            .group_by(models.Job.queue_name, models.Job.status)
        ).all()

    for queue_name, status, count in rows:
        normalized_queue = str(queue_name or "default")
        queue_bucket = by_queue.setdefault(normalized_queue, {})
        queue_bucket[str(status.value if hasattr(status, "value") else status)] = int(count)
    for queue_name, oldest in oldest_rows:
        if oldest is None:
            continue
        normalized_queue = str(queue_name or "default")
        oldest_queued_by_queue[normalized_queue] = _as_utc(oldest)
    for queue_name, status, count in completed_rows:
        normalized_queue = str(queue_name or "default")
        bucket = completed_last_hour.setdefault(normalized_queue, {})
        status_key = str(status.value if hasattr(status, "value") else status)
        bucket[status_key] = int(count)

    total_queued = sum(bucket.get("queued", 0) for bucket in by_queue.values())
    total_running = sum(bucket.get("running", 0) for bucket in by_queue.values())
    queue_slo_map = {
        "default": max(0, int(settings.queue_backlog_slo_default)),
        "scrape": max(0, int(settings.queue_backlog_slo_scrape)),
    }
    max_oldest_age = max(1, int(settings.queue_oldest_age_slo_seconds))
    violations: list[dict[str, Any]] = []
    queue_details: dict[str, Any] = {}

    for queue_name in sorted(set(by_queue.keys()) | set(oldest_queued_by_queue.keys())):
        bucket = by_queue.get(queue_name, {})
        queued_count = int(bucket.get("queued", 0))
        running_count = int(bucket.get("running", 0))
        oldest_queued_at = oldest_queued_by_queue.get(queue_name)
        oldest_age_seconds = None
        if oldest_queued_at is not None:
            oldest_age_seconds = int((now - oldest_queued_at).total_seconds())

        backlog_limit = queue_slo_map.get(queue_name, queue_slo_map["default"])
        if queued_count > backlog_limit:
            violations.append(
                {
                    "queue_name": queue_name,
                    "kind": "queued_backlog",
                    "queued_count": queued_count,
                    "limit": backlog_limit,
                }
            )
        if oldest_age_seconds is not None and oldest_age_seconds > max_oldest_age:
            violations.append(
                {
                    "queue_name": queue_name,
                    "kind": "oldest_queued_age",
                    "oldest_age_seconds": oldest_age_seconds,
                    "limit": max_oldest_age,
                }
            )

        queue_details[queue_name] = {
            **bucket,
            "queued": queued_count,
            "running": running_count,
            "oldest_queued_age_seconds": oldest_age_seconds,
            "completed_last_hour": completed_last_hour.get(queue_name, {}),
            "completed_last_hour_total": sum(completed_last_hour.get(queue_name, {}).values()),
        }

    return {
        "observed_at": now.isoformat(),
        "total_queued": total_queued,
        "total_running": total_running,
        "completed_last_hour_total": sum(
            sum(status_counts.values()) for status_counts in completed_last_hour.values()
        ),
        "by_queue": queue_details,
        "slo": {
            "status": "ok" if not violations else "breached",
            "max_oldest_age_seconds": max_oldest_age,
            "queue_limits": queue_slo_map,
            "violations": violations,
        },
    }


def _build_readiness_payload(request: Request) -> dict[str, Any]:
    checks: dict[str, dict[str, Any]] = {}
    settings = request.app.state.settings

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
    backlog = _queue_backlog_snapshot(settings)
    checks["job_queue"] = {
        "status": "ok" if backlog["slo"]["status"] == "ok" else "error",
        "slo": backlog["slo"],
    }
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
def metrics(request: Request) -> dict[str, Any]:
    snapshot = METRICS.snapshot()
    snapshot["jobs"]["queue_backlog"] = _queue_backlog_snapshot(request.app.state.settings)
    return snapshot
