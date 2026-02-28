from __future__ import annotations

import logging
import time
from datetime import UTC, datetime, timedelta

from sqlalchemy import or_, select

from ccs_platform.db import models
from ccs_platform.core.metrics import METRICS
from ccs_platform.core.settings import PlatformSettings
from ccs_platform.db.session import get_session_local
from ccs_platform.application.jobs.runner import JobRunner
from ccs_platform.application.jobs.service import create_or_get_job
from ccs_platform.application.jobs.scheduler import compute_next_run

logger = logging.getLogger(__name__)


class WorkerLoop:
    def __init__(self, *, settings: PlatformSettings, job_runner: JobRunner) -> None:
        self.settings = settings
        self.job_runner = job_runner
        self._in_flight: set[int] = set()
        self._running = True
        self._worker_queues = settings.worker_queue_set()
        self._all_queues = "*" in self._worker_queues or "all" in self._worker_queues

    def stop(self) -> None:
        self._running = False

    def _cleanup_in_flight(self) -> None:
        if not self._in_flight:
            return
        with get_session_local()() as db:
            rows = db.execute(
                select(models.Job.id, models.Job.status).where(models.Job.id.in_(self._in_flight))
            ).all()
            done = {
                job_id
                for job_id, status in rows
                if status in {
                    models.JobStatus.QUEUED,
                    models.JobStatus.SUCCEEDED,
                    models.JobStatus.FAILED,
                    models.JobStatus.CANCELLED,
                }
            }
            self._in_flight.difference_update(done)

    def _scope_job_query_to_worker_queues(self, stmt):
        if self._all_queues:
            return stmt
        return stmt.where(models.Job.queue_name.in_(sorted(self._worker_queues)))

    def _claim_next_queued_jobs(self, db, *, limit: int) -> list[int]:
        if limit <= 0:
            return []

        now = datetime.now(UTC)
        claimed_ids: list[int] = []

        def _mark_claimed(row: models.Job) -> None:
            row.status = models.JobStatus.RUNNING
            row.started_at = now
            row.last_heartbeat_at = now
            row.progress_percent = max(1, int(row.progress_percent or 0))
            row.next_retry_at = None
            claimed_ids.append(row.id)

        base_query = self._scope_job_query_to_worker_queues(
            select(models.Job).where(models.Job.status == models.JobStatus.QUEUED)
        )

        if db.bind is not None and db.bind.dialect.name == "postgresql":
            immediate = db.execute(
                base_query
                .where(models.Job.next_retry_at.is_(None))
                .order_by(models.Job.created_at.asc())
                .limit(limit)
                .with_for_update(skip_locked=True)
            ).scalars().all()
            for row in immediate:
                _mark_claimed(row)

            remaining = limit - len(immediate)
            if remaining > 0:
                retries = db.execute(
                    base_query
                    .where(models.Job.next_retry_at.is_not(None))
                    .where(models.Job.next_retry_at <= now)
                    .order_by(models.Job.next_retry_at.asc(), models.Job.created_at.asc())
                    .limit(remaining)
                    .with_for_update(skip_locked=True)
                ).scalars().all()
                for row in retries:
                    _mark_claimed(row)

            if claimed_ids:
                db.commit()
            return claimed_ids

        # SQLite/local fallback without SKIP LOCKED semantics.
        for _ in range(limit):
            next_job = db.execute(
                base_query
                .where(models.Job.next_retry_at.is_(None))
                .order_by(models.Job.created_at.asc())
                .limit(1)
            ).scalar_one_or_none()
            if next_job is None:
                next_job = db.execute(
                    base_query
                    .where(models.Job.next_retry_at.is_not(None))
                    .where(models.Job.next_retry_at <= now)
                    .order_by(models.Job.next_retry_at.asc(), models.Job.created_at.asc())
                    .limit(1)
                ).scalar_one_or_none()
            if next_job is None:
                break

            _mark_claimed(next_job)
            db.commit()

        return claimed_ids

    def _recover_stale_running_jobs(self) -> None:
        timeout_seconds = max(30, int(self.settings.job_heartbeat_timeout_seconds))
        now = datetime.now(UTC)
        stale_before = now - timedelta(seconds=timeout_seconds)

        with get_session_local()() as db:
            query = select(models.Job).where(models.Job.status == models.JobStatus.RUNNING)
            query = self._scope_job_query_to_worker_queues(query)
            query = query.where(
                or_(
                    (models.Job.last_heartbeat_at.is_not(None) & (models.Job.last_heartbeat_at <= stale_before)),
                    (
                        models.Job.last_heartbeat_at.is_(None)
                        & models.Job.started_at.is_not(None)
                        & (models.Job.started_at <= stale_before)
                    ),
                )
            )
            stale_jobs = db.execute(query).scalars().all()
            if not stale_jobs:
                return

            requeued = 0
            cancelled = 0
            failed = 0
            for job in stale_jobs:
                if job.cancel_requested_at is not None:
                    job.status = models.JobStatus.CANCELLED
                    job.finished_at = now
                    job.error_message = "Cancelled after heartbeat timeout."
                    cancelled += 1
                    METRICS.record_job_event("stale_cancelled")
                elif int(job.attempt_count or 0) < max(1, int(job.max_attempts or 1)):
                    job.status = models.JobStatus.QUEUED
                    job.next_retry_at = now
                    job.progress_percent = 0
                    job.error_message = "Recovered stale running job due to heartbeat timeout."
                    requeued += 1
                    METRICS.record_job_event("stale_requeued")
                else:
                    job.status = models.JobStatus.FAILED
                    job.finished_at = now
                    job.error_message = "Job heartbeat timeout exceeded and max attempts exhausted."
                    failed += 1
                    METRICS.record_job_event("stale_failed")

                job.last_heartbeat_at = now

            db.commit()
            logger.warning(
                "Recovered stale running jobs | requeued=%s cancelled=%s failed=%s timeout_seconds=%s",
                requeued,
                cancelled,
                failed,
                timeout_seconds,
            )

    def _dispatch_queued_jobs(self) -> None:
        available_slots = self.settings.worker_active_job_limit() - len(self._in_flight)
        if available_slots <= 0:
            return

        with get_session_local()() as db:
            claimed_ids = self._claim_next_queued_jobs(db, limit=available_slots)

        for job_id in claimed_ids:
            if job_id in self._in_flight:
                continue
            self._in_flight.add(job_id)
            logger.info("Dispatching queued job | job_id=%s", job_id)
            self.job_runner.enqueue(job_id)

    def _trigger_due_schedules(self) -> None:
        now = datetime.now(UTC)
        with get_session_local()() as db:
            schedules = db.execute(
                select(models.Schedule)
                .where(models.Schedule.status == models.ScheduleStatus.ACTIVE)
                .where(models.Schedule.next_run_at.is_not(None))
                .where(models.Schedule.next_run_at <= now)
                .order_by(models.Schedule.next_run_at.asc())
            ).scalars().all()

            for schedule in schedules:
                create_or_get_job(
                    db,
                    profile_id=schedule.profile_id,
                    job_type=schedule.job_type,
                    payload_json=schedule.payload_json or {},
                    auto_idempotency=False,
                )

                schedule.last_run_at = now
                schedule.next_run_at = compute_next_run(
                    schedule.rrule,
                    timezone=schedule.timezone,
                    now_utc=now,
                )

            db.commit()
            if schedules:
                logger.info("Triggered due schedules | count=%s", len(schedules))

    def ensure_schedule_next_runs(self) -> None:
        with get_session_local()() as db:
            schedules = db.execute(select(models.Schedule)).scalars().all()
            changed = False
            now = datetime.now(UTC)
            for schedule in schedules:
                if schedule.next_run_at is None:
                    schedule.next_run_at = compute_next_run(
                        schedule.rrule,
                        timezone=schedule.timezone,
                        now_utc=now,
                    )
                    changed = True
            if changed:
                db.commit()

    def run_forever(self) -> None:
        logger.info("Worker loop started")
        self.ensure_schedule_next_runs()
        while self._running:
            self._recover_stale_running_jobs()
            self._cleanup_in_flight()
            self._trigger_due_schedules()
            self._dispatch_queued_jobs()
            time.sleep(self.settings.job_poll_interval_seconds)
        logger.info("Worker loop stopped")
