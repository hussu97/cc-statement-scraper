from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol

from ccs_platform.core.metrics import METRICS
from ccs_platform.application.jobs.runner import JobRunner
from ccs_platform.core.settings import PlatformSettings


class JobDispatcher(Protocol):
    def publish(self, job_id: int) -> None:
        ...


@dataclass
class DatabaseQueueDispatcher:
    def publish(self, job_id: int) -> None:  # noqa: ARG002
        # Queue semantics are represented by persisted queued rows in jobs table.
        METRICS.record_job_event("queued")


@dataclass
class InProcessDispatcher:
    runner: JobRunner

    def publish(self, job_id: int) -> None:
        METRICS.record_job_event("queued")
        self.runner.enqueue(job_id)


def build_job_dispatcher(*, settings: PlatformSettings, runner: JobRunner) -> JobDispatcher:
    backend = settings.job_dispatch_backend.strip().lower()
    if backend == "database":
        return DatabaseQueueDispatcher()
    if backend == "inprocess":
        return InProcessDispatcher(runner=runner)
    raise RuntimeError(
        f"Unsupported job dispatch backend '{settings.job_dispatch_backend}'. "
        "Expected one of: database, inprocess."
    )
