from __future__ import annotations

from datetime import datetime
from typing import Any

from pydantic import BaseModel, ConfigDict

from ccs_platform.db.models import JobType, ScheduleStatus


class ScheduleOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    name: str
    job_type: JobType
    payload_json: dict[str, Any] | None
    rrule: str
    timezone: str
    status: ScheduleStatus
    next_run_at: datetime | None
    last_run_at: datetime | None


class ScheduleCreate(BaseModel):
    name: str
    job_type: JobType = JobType.SCRAPE
    payload_json: dict[str, Any] | None = None
    rrule: str
    timezone: str = "Asia/Dubai"
    status: ScheduleStatus = ScheduleStatus.ACTIVE


class ScheduleUpdate(BaseModel):
    name: str | None = None
    payload_json: dict[str, Any] | None = None
    rrule: str | None = None
    timezone: str | None = None
    status: ScheduleStatus | None = None
