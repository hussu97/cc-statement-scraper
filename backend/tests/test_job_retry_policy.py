from __future__ import annotations

from datetime import UTC, datetime, timedelta
from pathlib import Path

from sqlalchemy import select

from ccs_platform.adapters.storage.local import LocalStorageAdapter
from ccs_platform.application.jobs.runner import JobRunner
from ccs_platform.core.settings import get_settings
from ccs_platform.db import db_session, init_db, models


def test_runner_retries_before_marking_failed(monkeypatch) -> None:
    init_db()
    settings = get_settings()
    storage = LocalStorageAdapter(Path(settings.local_storage_dir))
    runner = JobRunner(settings=settings, storage=storage)

    def _always_fail(_db, _job):  # noqa: ANN001
        raise RuntimeError("forced-error")

    monkeypatch.setattr(runner, "_dispatch_job", _always_fail)

    profile_key = "retry-test-profile"
    with db_session() as db:
        profile = db.execute(select(models.Profile).where(models.Profile.key == profile_key)).scalar_one_or_none()
        if profile is None:
            profile = models.Profile(key=profile_key, name="Retry Test", is_default=False)
            db.add(profile)
            db.flush()

        job = models.Job(
            profile_id=profile.id,
            job_type=models.JobType.RECLASSIFY,
            status=models.JobStatus.QUEUED,
            payload_json={},
            max_attempts=2,
        )
        db.add(job)
        db.flush()
        job_id = job.id

    try:
        runner._run_job(job_id)

        with db_session() as db:
            first = db.get(models.Job, job_id)
            assert first is not None
            assert first.status == models.JobStatus.QUEUED
            assert first.attempt_count == 1
            assert first.next_retry_at is not None
            first.next_retry_at = datetime.now(UTC) - timedelta(seconds=1)

        runner._run_job(job_id)

        with db_session() as db:
            final = db.get(models.Job, job_id)
            assert final is not None
            assert final.status == models.JobStatus.FAILED
            assert final.attempt_count == 2
            assert final.error_message == "forced-error"
    finally:
        with db_session() as db:
            job = db.get(models.Job, job_id)
            if job is not None:
                db.delete(job)
    runner.shutdown()
