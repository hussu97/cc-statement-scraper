from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import UTC, datetime
import json
from pathlib import Path
import random
from threading import Lock
import time
from typing import Any
from urllib import error, request


DEFAULT_PATHS = (
    "/api/v1/health",
    "/api/v1/health/ready",
    "/api/v1/metrics",
)


@dataclass
class _LoadStats:
    latencies_ms: list[float]
    status_codes: dict[str, int]
    errors: int
    requests: int


def _percentile(values: list[float], percentile: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    rank = max(0, min(len(ordered) - 1, int(round((percentile / 100.0) * (len(ordered) - 1)))))
    return round(ordered[rank], 3)


def _send_request(*, url: str, timeout_seconds: float, headers: dict[str, str]) -> tuple[float, int | None, bool]:
    req = request.Request(url=url, headers=headers)
    start = time.perf_counter()
    try:
        with request.urlopen(req, timeout=timeout_seconds) as response:  # noqa: S310
            status = int(response.status)
            _ = response.read(1024)
        latency_ms = (time.perf_counter() - start) * 1000.0
        return latency_ms, status, False
    except error.HTTPError as exc:
        latency_ms = (time.perf_counter() - start) * 1000.0
        return latency_ms, int(exc.code), False
    except Exception:
        latency_ms = (time.perf_counter() - start) * 1000.0
        return latency_ms, None, True


def run_api_load_test(
    *,
    base_url: str,
    duration_seconds: int = 30,
    concurrency: int = 8,
    timeout_seconds: float = 5.0,
    paths: tuple[str, ...] = DEFAULT_PATHS,
) -> dict[str, Any]:
    duration = max(1, int(duration_seconds))
    workers = max(1, int(concurrency))
    timeout = max(0.1, float(timeout_seconds))
    normalized_base = base_url.rstrip("/")

    lock = Lock()
    stats = _LoadStats(latencies_ms=[], status_codes={}, errors=0, requests=0)
    deadline = time.time() + duration
    headers: dict[str, str] = {}

    def _worker() -> None:
        rng = random.Random()
        while time.time() < deadline:
            path = rng.choice(paths)
            url = f"{normalized_base}{path}"
            latency_ms, status, had_error = _send_request(url=url, timeout_seconds=timeout, headers=headers)

            with lock:
                stats.requests += 1
                stats.latencies_ms.append(latency_ms)
                if had_error:
                    stats.errors += 1
                if status is not None:
                    key = str(status)
                    stats.status_codes[key] = int(stats.status_codes.get(key, 0)) + 1

    started_at = datetime.now(UTC)
    start_counter = time.perf_counter()
    with ThreadPoolExecutor(max_workers=workers) as executor:
        for _ in range(workers):
            executor.submit(_worker)

    elapsed_seconds = max(0.001, time.perf_counter() - start_counter)
    successful_requests = sum(count for code, count in stats.status_codes.items() if code.startswith("2"))
    error_rate = (stats.errors / stats.requests) if stats.requests else 1.0

    result = {
        "started_at": started_at.isoformat(),
        "duration_seconds": round(elapsed_seconds, 3),
        "concurrency": workers,
        "base_url": normalized_base,
        "requests_total": stats.requests,
        "requests_successful": successful_requests,
        "errors": stats.errors,
        "error_rate": round(error_rate, 6),
        "throughput_rps": round(stats.requests / elapsed_seconds, 3),
        "latency_ms": {
            "p50": _percentile(stats.latencies_ms, 50),
            "p95": _percentile(stats.latencies_ms, 95),
            "p99": _percentile(stats.latencies_ms, 99),
            "max": round(max(stats.latencies_ms), 3) if stats.latencies_ms else 0.0,
            "avg": round(sum(stats.latencies_ms) / len(stats.latencies_ms), 3) if stats.latencies_ms else 0.0,
        },
        "status_codes": dict(sorted(stats.status_codes.items())),
    }
    return result


def load_performance_budget(*, budget_file: Path, budget_name: str = "api_smoke") -> dict[str, Any]:
    payload = json.loads(budget_file.read_text(encoding="utf-8"))
    if budget_name not in payload:
        raise KeyError(f"Budget not found: {budget_name}")
    budget = payload[budget_name]
    if not isinstance(budget, dict):
        raise ValueError(f"Budget payload must be an object: {budget_name}")
    return budget


def evaluate_budget(*, result: dict[str, Any], budget: dict[str, Any]) -> list[str]:
    violations: list[str] = []

    max_error_rate = budget.get("max_error_rate")
    if isinstance(max_error_rate, (float, int)) and float(result.get("error_rate", 1.0)) > float(max_error_rate):
        violations.append(
            f"error_rate {result.get('error_rate')} exceeded budget {max_error_rate}"
        )

    max_p95_ms = budget.get("max_p95_ms")
    p95_ms = result.get("latency_ms", {}).get("p95", 0.0)
    if isinstance(max_p95_ms, (float, int)) and float(p95_ms) > float(max_p95_ms):
        violations.append(f"p95 latency {p95_ms}ms exceeded budget {max_p95_ms}ms")

    min_rps = budget.get("min_rps")
    throughput = result.get("throughput_rps", 0.0)
    if isinstance(min_rps, (float, int)) and float(throughput) < float(min_rps):
        violations.append(f"throughput {throughput}rps fell below budget {min_rps}rps")

    return violations
