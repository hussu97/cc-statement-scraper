from __future__ import annotations

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
    profile = models.Profile(key="hussain", name="Hussain", is_default=True)
    db.add(profile)
    db.flush()
    return profile


def test_create_or_get_job_dedupes_same_payload() -> None:
    with _session() as db:
        profile = _seed_profile(db)
        payload = {"banks": ["ENBD"], "months": ["2025-11"], "download": False}

        first, first_created = create_or_get_job(
            db,
            profile_id=profile.id,
            job_type=models.JobType.SCRAPE,
            payload_json=payload,
        )
        second, second_created = create_or_get_job(
            db,
            profile_id=profile.id,
            job_type=models.JobType.SCRAPE,
            payload_json=payload,
        )

        assert first_created is True
        assert second_created is False
        assert first.id == second.id
        assert first.idempotency_key == second.idempotency_key


def test_create_or_get_job_without_auto_idempotency_creates_new_rows() -> None:
    with _session() as db:
        profile = _seed_profile(db)

        first, _ = create_or_get_job(
            db,
            profile_id=profile.id,
            job_type=models.JobType.UPLOAD,
            payload_json={"uploads": [{"filename": "a.pdf"}]},
            auto_idempotency=False,
        )
        second, _ = create_or_get_job(
            db,
            profile_id=profile.id,
            job_type=models.JobType.UPLOAD,
            payload_json={"uploads": [{"filename": "a.pdf"}]},
            auto_idempotency=False,
        )

        assert first.id != second.id
        assert first.idempotency_key is None
        assert second.idempotency_key is None


def test_create_or_get_job_applies_default_max_attempts() -> None:
    with _session() as db:
        profile = _seed_profile(db)
        job, _ = create_or_get_job(
            db,
            profile_id=profile.id,
            job_type=models.JobType.REPARSE_STATEMENT,
            payload_json={"statement_id": 1},
        )

        assert job.max_attempts == default_max_attempts(models.JobType.REPARSE_STATEMENT)
