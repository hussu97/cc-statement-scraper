from __future__ import annotations

import hashlib
import logging
import threading
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta
from typing import Any

_log = logging.getLogger(__name__)

from sqlalchemy import select
from sqlalchemy.orm import Session

from ccs_platform.core.metrics import METRICS
from ccs_platform.core.runtime_settings import apply_runtime_settings_to_process_env, get_runtime_settings_as_dict
from ccs_platform.db import models
from ccs_platform.core.settings import PlatformSettings
from ccs_platform.db.session import SessionLocal
from ccs_platform.adapters.storage import StorageAdapter

from ccs_platform.application.jobs.handlers.context import JobContext
from ccs_platform.application.jobs.handlers.upload import handle_upload_job
from ccs_platform.application.jobs.handlers.scrape import handle_scrape_job
from ccs_platform.application.jobs.handlers.reclassify import handle_reclassify_job
from ccs_platform.application.jobs.handlers.export_workbook import handle_export_workbook_job
from ccs_platform.application.jobs.handlers.parser_validate import handle_parser_validate_job
from ccs_platform.application.jobs.handlers.bank_connection_test import handle_bank_connection_test_job
from ccs_platform.application.jobs.handlers.reparse import handle_reparse_statement_job


class JobRunner:
    def __init__(self, *, settings: PlatformSettings, storage: StorageAdapter) -> None:
        self.settings = settings
        self.storage = storage
        self.executor = ThreadPoolExecutor(max_workers=settings.max_worker_threads)

    def shutdown(self) -> None:
        self.executor.shutdown(wait=False, cancel_futures=True)

    def enqueue(self, job_id: int) -> None:
        METRICS.record_job_event("enqueued")
        self.executor.submit(self._run_job, job_id)

    def _is_cancel_requested(self, job: models.Job) -> bool:
        return job.status == models.JobStatus.CANCELLED or job.cancel_requested_at is not None

    def _compute_retry_delay_seconds(self, *, job_id: int, attempt_count: int) -> int:
        base_seconds = max(1, int(self.settings.job_retry_base_seconds))
        max_seconds = max(base_seconds, int(self.settings.job_retry_max_delay_seconds))
        jitter_seconds = max(0, int(self.settings.job_retry_jitter_seconds))

        exponent = max(0, attempt_count - 1)
        delay = min(max_seconds, base_seconds * (2**exponent))
        if jitter_seconds <= 0:
            return delay

        digest = hashlib.sha256(f"{job_id}:{attempt_count}".encode("utf-8")).digest()
        jitter = int.from_bytes(digest[:4], "big") % (jitter_seconds + 1)
        return min(max_seconds, delay + jitter)

    def _heartbeat_loop(self, *, job_id: int, stop_event: threading.Event) -> None:
        interval_seconds = max(1, int(self.settings.job_heartbeat_interval_seconds))
        terminal_states = {
            models.JobStatus.SUCCEEDED,
            models.JobStatus.FAILED,
            models.JobStatus.CANCELLED,
        }

        while not stop_event.wait(interval_seconds):
            try:
                with SessionLocal() as hb_db:
                    row = hb_db.get(models.Job, job_id)
                    if row is None:
                        return
                    if row.status in terminal_states:
                        return
                    row.last_heartbeat_at = datetime.now(UTC)
                    hb_db.commit()
            except Exception:  # noqa: BLE001
                METRICS.record_job_event("heartbeat_error")
                _log.exception("Heartbeat thread error for job %d; heartbeat stopped", job_id)
                return

    def _schedule_retry(self, db: Session, job: models.Job, *, error_message: str) -> bool:
        max_attempts = max(1, int(job.max_attempts or 1))
        if int(job.attempt_count or 0) >= max_attempts:
            return False

        now = datetime.now(UTC)
        delay_seconds = self._compute_retry_delay_seconds(
            job_id=job.id,
            attempt_count=int(job.attempt_count or 1),
        )
        job.status = models.JobStatus.QUEUED
        job.next_retry_at = now + timedelta(seconds=delay_seconds)
        job.error_message = error_message
        job.progress_percent = 0
        job.finished_at = None
        job.last_heartbeat_at = now
        db.commit()

        METRICS.record_job_event("retry_scheduled")
        return True

    def _run_job(self, job_id: int) -> None:
        with SessionLocal() as db:
            job = db.get(models.Job, job_id)
            if not job:
                METRICS.record_job_event("missing")
                return
            if self._is_cancel_requested(job):
                if job.status != models.JobStatus.CANCELLED:
                    job.status = models.JobStatus.CANCELLED
                    job.finished_at = datetime.now(UTC)
                    job.last_heartbeat_at = datetime.now(UTC)
                    db.commit()
                METRICS.record_job_event("cancelled_before_start")
                return
            if job.status not in {models.JobStatus.QUEUED, models.JobStatus.RUNNING}:
                METRICS.record_job_event("skip_not_runnable")
                return

            now = datetime.now(UTC)
            if job.next_retry_at is not None:
                retry_at = job.next_retry_at
                if retry_at.tzinfo is None:
                    retry_at = retry_at.replace(tzinfo=UTC)
                if retry_at > now:
                    METRICS.record_job_event("retry_not_due")
                    return

            if job.status == models.JobStatus.QUEUED:
                job.status = models.JobStatus.RUNNING
            job.started_at = now
            job.next_retry_at = None
            job.progress_percent = max(1, int(job.progress_percent or 0))
            job.attempt_count = int(job.attempt_count or 0) + 1
            job.last_heartbeat_at = now
            db.commit()
            METRICS.record_job_event("started")

            heartbeat_stop = threading.Event()
            heartbeat_thread = threading.Thread(
                target=self._heartbeat_loop,
                kwargs={"job_id": job_id, "stop_event": heartbeat_stop},
                daemon=True,
            )
            heartbeat_thread.start()

            try:
                result = self._dispatch_job(db, job)
                db.refresh(job)
                outcome = "succeeded"
                if not self._is_cancel_requested(job):
                    job.status = models.JobStatus.SUCCEEDED
                else:
                    job.status = models.JobStatus.CANCELLED
                    outcome = "cancelled"
                job.progress_percent = 100
                job.result_json = result
                job.finished_at = datetime.now(UTC)
                job.next_retry_at = None
                job.error_message = None
                job.last_heartbeat_at = datetime.now(UTC)
                db.commit()
                METRICS.record_job_event(outcome)
            except Exception as exc:  # noqa: BLE001
                _log.exception("Job %d failed with unhandled exception", job_id)
                db.rollback()
                job = db.get(models.Job, job_id)
                if not job:
                    METRICS.record_job_event("missing_after_error")
                    return
                if self._is_cancel_requested(job):
                    job.status = models.JobStatus.CANCELLED
                    job.finished_at = datetime.now(UTC)
                    job.last_heartbeat_at = datetime.now(UTC)
                    db.commit()
                    METRICS.record_job_event("cancelled")
                    return
                if self._schedule_retry(db, job, error_message=str(exc)):
                    return
                job.status = models.JobStatus.FAILED
                job.error_message = str(exc)
                job.result_json = {
                    "poison_job": True,
                    "attempt_count": int(job.attempt_count or 0),
                    "max_attempts": int(job.max_attempts or 0),
                }
                job.finished_at = datetime.now(UTC)
                job.last_heartbeat_at = datetime.now(UTC)
                db.commit()
                METRICS.record_job_event("failed")
            finally:
                heartbeat_stop.set()
                heartbeat_thread.join(timeout=2)

    def _dispatch_job(self, db: Session, job: models.Job) -> dict[str, Any]:
        profile = db.get(models.Profile, job.profile_id)
        if profile is None:
            raise RuntimeError(f"Profile not found for job {job.id}: {job.profile_id}")

        # TODO: apply_runtime_settings_to_process_env is still needed for parsers that read env vars directly.
        apply_runtime_settings_to_process_env(db, profile_id=job.profile_id)

        ctx = JobContext(
            settings=self.settings,
            storage=self.storage,
            assert_not_cancelled=self._assert_not_cancelled,
            update_progress=self._update_progress,
        )

        if job.job_type == models.JobType.UPLOAD:
            return handle_upload_job(db, job, ctx, profile_key=profile.key)
        if job.job_type == models.JobType.SCRAPE:
            credentials = get_runtime_settings_as_dict(db, profile_id=job.profile_id)
            return handle_scrape_job(db, job, ctx, profile_key=profile.key, credentials=credentials)
        if job.job_type == models.JobType.RECLASSIFY:
            return handle_reclassify_job(db, job)
        if job.job_type == models.JobType.EXPORT_WORKBOOK:
            return handle_export_workbook_job(db, job, ctx, profile_key=profile.key)
        if job.job_type == models.JobType.PARSER_VALIDATE:
            return handle_parser_validate_job(db, job)
        if job.job_type == models.JobType.BANK_CONNECTION_TEST:
            return handle_bank_connection_test_job(db, job)
        if job.job_type == models.JobType.REPARSE_STATEMENT:
            return handle_reparse_statement_job(db, job, ctx, profile_key=profile.key)
        raise ValueError(f"Unsupported job_type: {job.job_type}")

    def _assert_not_cancelled(self, db: Session, job_id: int) -> None:
        row = db.execute(
            select(models.Job.status, models.Job.cancel_requested_at).where(models.Job.id == job_id)
        ).one()
        status, cancel_requested_at = row
        if status == models.JobStatus.CANCELLED or cancel_requested_at is not None:
            raise RuntimeError(f"Job {job_id} cancelled")

    def _update_progress(self, db: Session, job: models.Job, progress: int) -> None:
        job.progress_percent = max(0, min(progress, 99))
        job.last_heartbeat_at = datetime.now(UTC)
        db.commit()
