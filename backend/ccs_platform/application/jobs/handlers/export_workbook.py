from __future__ import annotations

import io
from datetime import UTC, datetime
from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from ccs_platform.db import models
from ccs_platform.application.exports.workbook import build_yearly_workbook_from_statements
from .context import JobContext


def handle_export_workbook_job(
    db: Session,
    job: models.Job,
    ctx: JobContext,
    *,
    profile_key: str,
) -> dict[str, Any]:
    payload = job.payload_json or {}
    year = int(payload.get("year", datetime.now().year))
    export_id = payload.get("export_id")

    buf = io.BytesIO()
    build_yearly_workbook_from_statements(db, buf, year, profile_id=job.profile_id)
    content = buf.getvalue()

    stored = ctx.storage.save_binary(
        content=content,
        filename=f"credit-card-tracker-{year}.xlsx",
        folder="exports/workbooks",
        profile_key=profile_key,
    )

    export_row = None
    if export_id:
        export_row = db.execute(
            select(models.Export).where(
                models.Export.id == int(export_id),
                models.Export.profile_id == job.profile_id,
            )
        ).scalar_one_or_none()
    if not export_row:
        export_row = models.Export(
            profile_id=job.profile_id,
            export_type="workbook",
            status=models.ExportStatus.QUEUED,
        )
        db.add(export_row)
        db.flush()

    export_row.status = models.ExportStatus.READY
    export_row.storage_backend = stored.backend
    export_row.storage_key = stored.key
    export_row.filename = f"credit-card-tracker-{year}.xlsx"
    export_row.ready_at = datetime.now(UTC)
    db.commit()

    return {
        "export_id": export_row.id,
        "storage_backend": stored.backend,
        "storage_key": stored.key,
        "filename": export_row.filename,
    }
