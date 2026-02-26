from __future__ import annotations

import hashlib
import json
from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from ccs_platform.db import models


DEFAULT_MAX_ATTEMPTS: dict[models.JobType, int] = {
    models.JobType.SCRAPE: 3,
    models.JobType.UPLOAD: 3,
    models.JobType.RECLASSIFY: 2,
    models.JobType.EXPORT_WORKBOOK: 2,
    models.JobType.PARSER_VALIDATE: 2,
    models.JobType.BANK_CONNECTION_TEST: 2,
    models.JobType.REPARSE_STATEMENT: 2,
}

DEFAULT_QUEUE_BY_JOB_TYPE: dict[models.JobType, str] = {
    models.JobType.SCRAPE: "scrape",
    models.JobType.BANK_CONNECTION_TEST: "scrape",
}


def default_max_attempts(job_type: models.JobType) -> int:
    return max(1, int(DEFAULT_MAX_ATTEMPTS.get(job_type, 1)))


def default_queue_name(job_type: models.JobType) -> str:
    return DEFAULT_QUEUE_BY_JOB_TYPE.get(job_type, "default")


def _normalized_payload(payload_json: dict[str, Any] | None) -> dict[str, Any]:
    if not payload_json:
        return {}
    # Keep deterministic ordering for idempotency fingerprints.
    return json.loads(json.dumps(payload_json, ensure_ascii=True, sort_keys=True, separators=(",", ":")))


def _normalized_idempotency_key(value: str | None) -> str | None:
    if value is None:
        return None
    normalized = value.strip()
    if not normalized:
        return None
    return normalized[:128]


def build_auto_idempotency_key(
    *,
    profile_id: int,
    job_type: models.JobType,
    payload_json: dict[str, Any] | None,
) -> str:
    normalized_payload = _normalized_payload(payload_json)
    payload_text = json.dumps(normalized_payload, ensure_ascii=True, sort_keys=True, separators=(",", ":"))
    digest = hashlib.sha256(f"{profile_id}:{job_type.value}:{payload_text}".encode("utf-8")).hexdigest()
    return f"auto:{digest}"


def create_or_get_job(
    db: Session,
    *,
    profile_id: int,
    job_type: models.JobType,
    payload_json: dict[str, Any] | None = None,
    idempotency_key: str | None = None,
    auto_idempotency: bool = True,
    max_attempts: int | None = None,
    queue_name: str | None = None,
) -> tuple[models.Job, bool]:
    normalized_payload = _normalized_payload(payload_json)
    resolved_idempotency_key = _normalized_idempotency_key(idempotency_key)
    if resolved_idempotency_key is None and auto_idempotency:
        resolved_idempotency_key = build_auto_idempotency_key(
            profile_id=profile_id,
            job_type=job_type,
            payload_json=normalized_payload,
        )

    if resolved_idempotency_key:
        existing = db.execute(
            select(models.Job).where(
                models.Job.profile_id == profile_id,
                models.Job.job_type == job_type,
                models.Job.idempotency_key == resolved_idempotency_key,
            )
        ).scalar_one_or_none()
        if existing is not None:
            return existing, False

    job = models.Job(
        profile_id=profile_id,
        job_type=job_type,
        queue_name=(queue_name or default_queue_name(job_type)).strip().lower(),
        status=models.JobStatus.QUEUED,
        payload_json=normalized_payload,
        idempotency_key=resolved_idempotency_key,
        max_attempts=max_attempts if max_attempts is not None else default_max_attempts(job_type),
        attempt_count=0,
    )
    db.add(job)
    db.flush()
    return job, True
