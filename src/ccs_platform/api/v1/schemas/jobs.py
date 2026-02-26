from __future__ import annotations

from datetime import datetime
from typing import Any

from pydantic import BaseModel, ConfigDict, Field

from ccs_platform.db.models import JobStatus, JobType


class JobItemOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    bank_code: str | None
    target_month: str | None
    status: str
    message: str | None
    metadata_json: dict[str, Any] | None


class JobOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    job_type: JobType
    status: JobStatus
    payload_json: dict[str, Any] | None
    result_json: dict[str, Any] | None
    error_message: str | None
    progress_percent: int
    created_at: datetime
    started_at: datetime | None
    finished_at: datetime | None
    items: list[JobItemOut] = []


class ScrapeJobRequest(BaseModel):
    banks: list[str] = Field(default_factory=list)
    months: list[str] = Field(default_factory=list)
    month_from: str | None = None
    month_to: str | None = None
    download: bool = True
    headless: bool = False
    login_timeout_minutes: int = Field(default=20, ge=5, le=60)


class UploadJobRequest(BaseModel):
    pass


class ReclassifyJobRequest(BaseModel):
    statement_ids: list[int] | None = None
    bank_codes: list[str] | None = None
