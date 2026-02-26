from __future__ import annotations

from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import yaml


def load_slo_policy(path: Path) -> dict[str, Any]:
    payload = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError("SLO policy file must be a mapping")
    return payload


def _float(value: Any, default: float = 0.0) -> float:
    try:
        return float(value)
    except Exception:
        return default


def evaluate_slo_policy(*, policy: dict[str, Any], metrics: dict[str, Any]) -> dict[str, Any]:
    evaluated_at = datetime.now(UTC).isoformat()

    request_metrics = metrics.get("requests", {}) if isinstance(metrics, dict) else {}
    status_counts = request_metrics.get("by_status", {}) if isinstance(request_metrics, dict) else {}
    total_requests = int(request_metrics.get("total", 0) or 0)
    five_xx = sum(int(count) for code, count in dict(status_counts).items() if str(code).startswith("5"))
    availability = 1.0 if total_requests == 0 else max(0.0, (total_requests - five_xx) / total_requests)
    avg_latency_ms = _float(request_metrics.get("avg_duration_ms", 0.0))

    jobs = metrics.get("jobs", {}) if isinstance(metrics, dict) else {}
    events = jobs.get("events", {}) if isinstance(jobs, dict) else {}
    succeeded = int(events.get("succeeded", 0) or 0)
    failed = int(events.get("failed", 0) or 0)
    cancelled = int(events.get("cancelled", 0) or 0)
    completed = succeeded + failed + cancelled
    job_success_rate = 1.0 if completed == 0 else max(0.0, succeeded / completed)

    backlog = jobs.get("queue_backlog", {}) if isinstance(jobs, dict) else {}
    backlog_slo = backlog.get("slo", {}) if isinstance(backlog, dict) else {}
    backlog_status = str(backlog_slo.get("status", "unknown"))

    objectives = policy.get("objectives", {}) if isinstance(policy, dict) else {}

    results: list[dict[str, Any]] = []
    alerts: list[str] = []

    availability_policy = objectives.get("api_availability", {})
    availability_target = _float(availability_policy.get("target", 0.995), 0.995)
    availability_alert = _float(availability_policy.get("alert_below", availability_target), availability_target)
    availability_ok = availability >= availability_target
    if availability < availability_alert:
        alerts.append(f"api_availability below alert threshold: {availability:.5f} < {availability_alert:.5f}")
    results.append(
        {
            "name": "api_availability",
            "value": round(availability, 6),
            "target": availability_target,
            "status": "ok" if availability_ok else "breached",
        }
    )

    latency_policy = objectives.get("api_avg_latency_ms", {})
    latency_target = _float(latency_policy.get("target", 500.0), 500.0)
    latency_alert = _float(latency_policy.get("alert_above", latency_target), latency_target)
    latency_ok = avg_latency_ms <= latency_target
    if avg_latency_ms > latency_alert:
        alerts.append(f"api_avg_latency_ms above alert threshold: {avg_latency_ms:.3f} > {latency_alert:.3f}")
    results.append(
        {
            "name": "api_avg_latency_ms",
            "value": round(avg_latency_ms, 3),
            "target": latency_target,
            "status": "ok" if latency_ok else "breached",
        }
    )

    success_policy = objectives.get("job_success_rate", {})
    success_target = _float(success_policy.get("target", 0.98), 0.98)
    success_alert = _float(success_policy.get("alert_below", success_target), success_target)
    success_ok = job_success_rate >= success_target
    if job_success_rate < success_alert:
        alerts.append(f"job_success_rate below alert threshold: {job_success_rate:.5f} < {success_alert:.5f}")
    results.append(
        {
            "name": "job_success_rate",
            "value": round(job_success_rate, 6),
            "target": success_target,
            "status": "ok" if success_ok else "breached",
        }
    )

    queue_policy = objectives.get("queue_backlog_slo", {})
    required_status = str(queue_policy.get("required_status", "ok"))
    queue_ok = backlog_status == required_status
    if not queue_ok:
        alerts.append(f"queue_backlog_slo status is {backlog_status}; expected {required_status}")
    results.append(
        {
            "name": "queue_backlog_slo",
            "value": backlog_status,
            "target": required_status,
            "status": "ok" if queue_ok else "breached",
        }
    )

    return {
        "evaluated_at": evaluated_at,
        "overall_status": "ok" if not alerts else "alert",
        "objectives": results,
        "alerts": alerts,
    }
