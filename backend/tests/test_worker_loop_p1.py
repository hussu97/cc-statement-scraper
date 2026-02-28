from __future__ import annotations

from datetime import UTC, datetime, timedelta

from sqlalchemy import select

from ccs_platform.application.jobs.worker_loop import WorkerLoop
from ccs_platform.core.settings import PlatformSettings
from ccs_platform.db import db_session, init_db, models


class _FakeRunner:
    def __init__(self) -> None:
        self.enqueued: list[int] = []

    def enqueue(self, job_id: int) -> None:
        self.enqueued.append(job_id)


def _ensure_profile() -> int:
    with db_session() as db:
        profile = db.execute(select(models.Profile).where(models.Profile.key == "worker-loop-test")).scalar_one_or_none()
        if profile is None:
            profile = models.Profile(key="worker-loop-test", name="Worker Loop Test", is_default=False)
            db.add(profile)
            db.flush()
        return profile.id


def test_worker_loop_dispatches_only_configured_queues() -> None:
    init_db()
    profile_id = _ensure_profile()
    runner = _FakeRunner()
    settings = PlatformSettings(worker_queues="default")
    loop = WorkerLoop(settings=settings, job_runner=runner)  # type: ignore[arg-type]

    with db_session() as db:
        default_job = models.Job(
            profile_id=profile_id,
            job_type=models.JobType.RECLASSIFY,
            queue_name="default",
            status=models.JobStatus.QUEUED,
            payload_json={},
        )
        scrape_job = models.Job(
            profile_id=profile_id,
            job_type=models.JobType.SCRAPE,
            queue_name="scrape",
            status=models.JobStatus.QUEUED,
            payload_json={"banks": ["ENBD"], "months": ["2025-11"]},
        )
        db.add_all([default_job, scrape_job])
        db.flush()
        default_job_id = default_job.id
        scrape_job_id = scrape_job.id

    try:
        loop._dispatch_queued_jobs()
        assert runner.enqueued == [default_job_id]

        with db_session() as db:
            default_row = db.get(models.Job, default_job_id)
            scrape_row = db.get(models.Job, scrape_job_id)
            assert default_row is not None
            assert scrape_row is not None
            assert default_row.status == models.JobStatus.RUNNING
            assert scrape_row.status == models.JobStatus.QUEUED
    finally:
        with db_session() as db:
            for job_id in (default_job_id, scrape_job_id):
                row = db.get(models.Job, job_id)
                if row is not None:
                    db.delete(row)


def test_worker_loop_recovers_stale_running_jobs() -> None:
    init_db()
    profile_id = _ensure_profile()
    runner = _FakeRunner()
    settings = PlatformSettings(worker_queues="default", job_heartbeat_timeout_seconds=30)
    loop = WorkerLoop(settings=settings, job_runner=runner)  # type: ignore[arg-type]
    stale_at = datetime.now(UTC) - timedelta(minutes=10)

    with db_session() as db:
        requeue_job = models.Job(
            profile_id=profile_id,
            job_type=models.JobType.RECLASSIFY,
            queue_name="default",
            status=models.JobStatus.RUNNING,
            payload_json={},
            attempt_count=1,
            max_attempts=3,
            started_at=stale_at,
            last_heartbeat_at=stale_at,
        )
        fail_job = models.Job(
            profile_id=profile_id,
            job_type=models.JobType.RECLASSIFY,
            queue_name="default",
            status=models.JobStatus.RUNNING,
            payload_json={},
            attempt_count=3,
            max_attempts=3,
            started_at=stale_at,
            last_heartbeat_at=stale_at,
        )
        cancel_job = models.Job(
            profile_id=profile_id,
            job_type=models.JobType.RECLASSIFY,
            queue_name="default",
            status=models.JobStatus.RUNNING,
            payload_json={},
            attempt_count=1,
            max_attempts=3,
            started_at=stale_at,
            last_heartbeat_at=stale_at,
            cancel_requested_at=datetime.now(UTC),
        )
        db.add_all([requeue_job, fail_job, cancel_job])
        db.flush()
        requeue_job_id = requeue_job.id
        fail_job_id = fail_job.id
        cancel_job_id = cancel_job.id

    try:
        loop._recover_stale_running_jobs()

        with db_session() as db:
            requeue_row = db.get(models.Job, requeue_job_id)
            fail_row = db.get(models.Job, fail_job_id)
            cancel_row = db.get(models.Job, cancel_job_id)
            assert requeue_row is not None
            assert fail_row is not None
            assert cancel_row is not None

            assert requeue_row.status == models.JobStatus.QUEUED
            assert requeue_row.next_retry_at is not None

            assert fail_row.status == models.JobStatus.FAILED
            assert fail_row.finished_at is not None

            assert cancel_row.status == models.JobStatus.CANCELLED
            assert cancel_row.finished_at is not None
    finally:
        with db_session() as db:
            for job_id in (requeue_job_id, fail_job_id, cancel_job_id):
                row = db.get(models.Job, job_id)
                if row is not None:
                    db.delete(row)


def test_worker_loop_respects_active_job_capacity() -> None:
    init_db()
    profile_id = _ensure_profile()
    runner = _FakeRunner()
    settings = PlatformSettings(worker_queues="default", max_worker_threads=4, worker_max_active_jobs=2)
    loop = WorkerLoop(settings=settings, job_runner=runner)  # type: ignore[arg-type]

    created_job_ids: list[int] = []
    with db_session() as db:
        now = datetime.now(UTC)
        for offset in range(3):
            row = models.Job(
                profile_id=profile_id,
                job_type=models.JobType.RECLASSIFY,
                queue_name="default",
                status=models.JobStatus.QUEUED,
                payload_json={"offset": offset},
                created_at=now + timedelta(seconds=offset),
            )
            db.add(row)
            db.flush()
            created_job_ids.append(row.id)

    try:
        loop._dispatch_queued_jobs()
        assert len(runner.enqueued) == 2

        with db_session() as db:
            running_count = len(
                db.execute(
                    select(models.Job.id)
                    .where(models.Job.id.in_(created_job_ids), models.Job.status == models.JobStatus.RUNNING)
                ).scalars().all()
            )
            queued_count = len(
                db.execute(
                    select(models.Job.id)
                    .where(models.Job.id.in_(created_job_ids), models.Job.status == models.JobStatus.QUEUED)
                ).scalars().all()
            )
            assert running_count == 2
            assert queued_count == 1

        loop._dispatch_queued_jobs()
        assert len(runner.enqueued) == 2

        with db_session() as db:
            completed = db.get(models.Job, runner.enqueued[0])
            assert completed is not None
            completed.status = models.JobStatus.SUCCEEDED

        loop._cleanup_in_flight()
        loop._dispatch_queued_jobs()
        assert len(runner.enqueued) == 3
    finally:
        with db_session() as db:
            for job_id in created_job_ids:
                row = db.get(models.Job, job_id)
                if row is not None:
                    db.delete(row)
