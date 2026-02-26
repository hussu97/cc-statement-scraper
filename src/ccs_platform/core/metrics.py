from __future__ import annotations

from collections import Counter
from datetime import UTC, datetime
from threading import Lock
import time


class MetricsRegistry:
    def __init__(self) -> None:
        self._lock = Lock()
        self._started_at = datetime.now(UTC)
        self._started_monotonic = time.monotonic()

        self._request_count = 0
        self._request_status = Counter()
        self._request_method = Counter()
        self._request_path = Counter()
        self._request_duration_ms_total = 0.0

        self._job_events = Counter()

    def record_request(self, *, method: str, path: str, status_code: int, duration_ms: float) -> None:
        normalized_method = (method or "GET").upper()
        normalized_path = path or "/"

        with self._lock:
            self._request_count += 1
            self._request_status[str(status_code)] += 1
            self._request_method[normalized_method] += 1
            self._request_path[normalized_path] += 1
            self._request_duration_ms_total += max(duration_ms, 0.0)

    def record_job_event(self, event: str) -> None:
        if not event:
            return
        with self._lock:
            self._job_events[event] += 1

    def snapshot(self) -> dict[str, object]:
        with self._lock:
            request_count = self._request_count
            avg_duration = (self._request_duration_ms_total / request_count) if request_count else 0.0
            top_paths = dict(self._request_path.most_common(20))

            request_status = dict(self._request_status)
            request_method = dict(self._request_method)
            job_events = dict(self._job_events)

        uptime_seconds = max(0.0, time.monotonic() - self._started_monotonic)

        return {
            "started_at": self._started_at.isoformat(),
            "uptime_seconds": round(uptime_seconds, 3),
            "requests": {
                "total": request_count,
                "by_status": request_status,
                "by_method": request_method,
                "avg_duration_ms": round(avg_duration, 3),
                "top_paths": top_paths,
            },
            "jobs": {
                "events": job_events,
            },
        }


METRICS = MetricsRegistry()
