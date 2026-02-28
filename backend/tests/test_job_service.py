from __future__ import annotations

from datetime import UTC, datetime

from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from ccs_platform.application.jobs.service import create_or_get_job, default_max_attempts
from ccs_platform.db import Base, models


def _session():
    engine = create_engine("sqlite:///:memory:", future=True)
    Base.metadata.create_all(engine)
    Session = sessionmaker(bind=engine, future=True)
    return Session()


def _seed_profile(db) -> models.Profile:
    profile = models.Profile(key="alice", name="Alice", is_default=True)
    db.add(profile)
    db.flush()
    return profile


def test_create_or_get_job_dedupes_same_payload() -> None:
    with _session() as db:
        profile = _seed_profile(db)
        payload = {"uploads": [{"filename": "test.pdf", "storage_key": "staging/test.pdf", "bank_code": "ENBD"}]}

        first, first_created, first_requeued = create_or_get_job(
            db,
            profile_id=profile.id,
            job_type=models.JobType.UPLOAD,
            payload_json=payload,
        )
        second, second_created, second_requeued = create_or_get_job(
            db,
            profile_id=profile.id,
            job_type=models.JobType.UPLOAD,
            payload_json=payload,
        )

        assert first_created is True
        assert second_created is False
        assert first_requeued is False
        assert second_requeued is False
        assert first.id == second.id
        assert first.idempotency_key == second.idempotency_key
        assert first.queue_name == "default"


def test_create_or_get_job_without_auto_idempotency_creates_new_rows() -> None:
    with _session() as db:
        profile = _seed_profile(db)

        first, _, _ = create_or_get_job(
            db,
            profile_id=profile.id,
            job_type=models.JobType.UPLOAD,
            payload_json={"uploads": [{"filename": "a.pdf"}]},
            auto_idempotency=False,
        )
        second, _, _ = create_or_get_job(
            db,
            profile_id=profile.id,
            job_type=models.JobType.UPLOAD,
            payload_json={"uploads": [{"filename": "a.pdf"}]},
            auto_idempotency=False,
        )

        assert first.id != second.id
        assert first.idempotency_key is None
        assert second.idempotency_key is None
        assert first.queue_name == "default"
        assert second.queue_name == "default"


def test_create_or_get_job_applies_default_max_attempts() -> None:
    with _session() as db:
        profile = _seed_profile(db)
        job, _, _ = create_or_get_job(
            db,
            profile_id=profile.id,
            job_type=models.JobType.REPARSE_STATEMENT,
            payload_json={"statement_id": 1},
        )

        assert job.max_attempts == default_max_attempts(models.JobType.REPARSE_STATEMENT)


def test_create_or_get_job_creates_fresh_after_cancelled_auto_idempotent_job() -> None:
    with _session() as db:
        profile = _seed_profile(db)
        payload = {"banks": ["ENBD"], "months": ["2025-11"], "download": False}

        first, first_created, first_requeued = create_or_get_job(
            db,
            profile_id=profile.id,
            job_type=models.JobType.RECLASSIFY,
            payload_json=payload,
        )
        assert first_created is True
        assert first_requeued is False

        now = datetime.now(UTC)
        first.status = models.JobStatus.CANCELLED
        first.started_at = now
        first.finished_at = now
        first.next_retry_at = now
        first.last_heartbeat_at = now
        first.cancel_requested_at = now
        first.result_json = {"old": True}
        first.error_message = "cancelled"
        first.attempt_count = 2
        first.progress_percent = 100
        db.flush()

        second, second_created, second_requeued = create_or_get_job(
            db,
            profile_id=profile.id,
            job_type=models.JobType.RECLASSIFY,
            payload_json=payload,
        )

        assert second_created is True
        assert second_requeued is False
        assert second.id != first.id
        assert second.status == models.JobStatus.QUEUED
        assert second.started_at is None
        assert second.finished_at is None
        assert second.next_retry_at is None
        assert second.last_heartbeat_at is None
        assert second.cancel_requested_at is None
        assert second.result_json is None
        assert second.error_message is None
        assert second.attempt_count == 0
        assert second.progress_percent == 0
        assert second.idempotency_key is not None

        refreshed_first = db.get(models.Job, first.id)
        assert refreshed_first is not None
        assert refreshed_first.idempotency_key is None


def test_create_or_get_job_creates_fresh_after_succeeded_auto_idempotent_job() -> None:
    with _session() as db:
        profile = _seed_profile(db)
        payload = {"banks": ["ENBD"], "months": ["2025-11"], "download": False}

        first, first_created, first_requeued = create_or_get_job(
            db,
            profile_id=profile.id,
            job_type=models.JobType.RECLASSIFY,
            payload_json=payload,
        )
        assert first_created is True
        assert first_requeued is False
        first_key = first.idempotency_key
        assert first_key is not None

        first.status = models.JobStatus.SUCCEEDED
        first.finished_at = datetime.now(UTC)
        db.flush()

        second, second_created, second_requeued = create_or_get_job(
            db,
            profile_id=profile.id,
            job_type=models.JobType.RECLASSIFY,
            payload_json=payload,
        )

        assert second_created is True
        assert second_requeued is False
        assert second.id != first.id
        assert second.idempotency_key == first_key

        refreshed_first = db.get(models.Job, first.id)
        assert refreshed_first is not None
        assert refreshed_first.idempotency_key is None


def test_create_or_get_job_creates_fresh_after_failed_auto_idempotent_job() -> None:
    with _session() as db:
        profile = _seed_profile(db)
        payload = {"banks": ["ENBD"], "months": ["2025-11"], "download": False}

        first, first_created, first_requeued = create_or_get_job(
            db,
            profile_id=profile.id,
            job_type=models.JobType.RECLASSIFY,
            payload_json=payload,
        )
        assert first_created is True
        assert first_requeued is False
        first_key = first.idempotency_key
        assert first_key is not None

        first.status = models.JobStatus.FAILED
        first.error_message = "failure"
        first.finished_at = datetime.now(UTC)
        db.flush()

        second, second_created, second_requeued = create_or_get_job(
            db,
            profile_id=profile.id,
            job_type=models.JobType.RECLASSIFY,
            payload_json=payload,
        )

        assert second_created is True
        assert second_requeued is False
        assert second.id != first.id
        assert second.idempotency_key == first_key

        refreshed_first = db.get(models.Job, first.id)
        assert refreshed_first is not None
        assert refreshed_first.idempotency_key is None


def test_create_or_get_job_does_not_requeue_cancelled_explicit_idempotency() -> None:
    with _session() as db:
        profile = _seed_profile(db)
        payload = {"statement_ids": [1]}

        first, first_created, first_requeued = create_or_get_job(
            db,
            profile_id=profile.id,
            job_type=models.JobType.RECLASSIFY,
            payload_json=payload,
            idempotency_key="manual-key-1",
        )
        assert first_created is True
        assert first_requeued is False

        first.status = models.JobStatus.CANCELLED
        db.flush()

        second, second_created, second_requeued = create_or_get_job(
            db,
            profile_id=profile.id,
            job_type=models.JobType.RECLASSIFY,
            payload_json=payload,
            idempotency_key="manual-key-1",
        )

        assert second.id == first.id
        assert second_created is False
        assert second_requeued is False
        assert second.status == models.JobStatus.CANCELLED
