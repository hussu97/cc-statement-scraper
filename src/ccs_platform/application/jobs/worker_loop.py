from __future__ import annotations

import time
from datetime import UTC, datetime

from sqlalchemy import select

from ccs_platform.db import models
from ccs_platform.core.settings import PlatformSettings
from ccs_platform.db.session import SessionLocal
from ccs_platform.application.jobs.runner import JobRunner
from ccs_platform.application.jobs.scheduler import compute_next_run


class WorkerLoop:
    def __init__(self, *, settings: PlatformSettings, job_runner: JobRunner) -> None:
        self.settings = settings
        self.job_runner = job_runner
        self._in_flight: set[int] = set()
        self._running = True

    def stop(self) -> None:
        self._running = False

    def _cleanup_in_flight(self) -> None:
        if not self._in_flight:
            return
        with SessionLocal() as db:
            rows = db.execute(
                select(models.Job.id, models.Job.status).where(models.Job.id.in_(self._in_flight))
            ).all()
            done = {
                job_id
                for job_id, status in rows
                if status in {models.JobStatus.SUCCEEDED, models.JobStatus.FAILED, models.JobStatus.CANCELLED}
            }
            self._in_flight.difference_update(done)

    def _dispatch_queued_jobs(self) -> None:
        with SessionLocal() as db:
            queued_ids = db.execute(
                select(models.Job.id)
                .where(models.Job.status == models.JobStatus.QUEUED)
                .order_by(models.Job.created_at.asc())
                .limit(20)
            ).scalars().all()

        for job_id in queued_ids:
            if job_id in self._in_flight:
                continue
            self._in_flight.add(job_id)
            self.job_runner.enqueue(job_id)

    def _trigger_due_schedules(self) -> None:
        now = datetime.now(UTC)
        with SessionLocal() as db:
            schedules = db.execute(
                select(models.Schedule)
                .where(models.Schedule.status == models.ScheduleStatus.ACTIVE)
                .where(models.Schedule.next_run_at.is_not(None))
                .where(models.Schedule.next_run_at <= now)
                .order_by(models.Schedule.next_run_at.asc())
            ).scalars().all()

            for schedule in schedules:
                job = models.Job(
                    profile_id=schedule.profile_id,
                    job_type=schedule.job_type,
                    status=models.JobStatus.QUEUED,
                    payload_json=schedule.payload_json or {},
                )
                db.add(job)

                schedule.last_run_at = now
                schedule.next_run_at = compute_next_run(
                    schedule.rrule,
                    timezone=schedule.timezone,
                    now_utc=now,
                )

            db.commit()

    def ensure_schedule_next_runs(self) -> None:
        with SessionLocal() as db:
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
        self.ensure_schedule_next_runs()
        while self._running:
            self._cleanup_in_flight()
            self._trigger_due_schedules()
            self._dispatch_queued_jobs()
            time.sleep(self.settings.job_poll_interval_seconds)
