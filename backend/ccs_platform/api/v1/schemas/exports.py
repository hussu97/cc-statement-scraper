from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, ConfigDict

from ccs_platform.db.models import ExportStatus


class WorkbookExportRequest(BaseModel):
    year: int


class ExportOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    export_type: str
    status: ExportStatus
    job_id: int | None
    storage_backend: str | None
    storage_key: str | None
    filename: str | None
    error_message: str | None
    created_at: datetime
    ready_at: datetime | None
