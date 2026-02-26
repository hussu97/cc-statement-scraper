from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import Response
from sqlalchemy import select
from sqlalchemy.orm import Session

from ccs_platform.db import models
from ccs_platform.api.deps import ProfileContext, get_db, get_profile_context
from ccs_platform.api.v1.schemas import ExportOut, JobOut, WorkbookExportRequest


router = APIRouter(prefix="/exports", tags=["exports"])


@router.post("/workbook", response_model=JobOut)
def create_workbook_export(
    payload: WorkbookExportRequest,
    request: Request,
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
) -> JobOut:
    export_row = models.Export(
        profile_id=profile.profile_id,
        export_type="workbook",
        status=models.ExportStatus.QUEUED,
    )
    db.add(export_row)
    db.flush()

    job = models.Job(
        profile_id=profile.profile_id,
        job_type=models.JobType.EXPORT_WORKBOOK,
        status=models.JobStatus.QUEUED,
        payload_json={"year": payload.year, "export_id": export_row.id},
    )
    db.add(job)
    db.flush()

    export_row.job_id = job.id
    db.commit()
    db.refresh(job)

    request.app.state.job_runner.enqueue(job.id)
    return JobOut.model_validate(job)


@router.get("/{export_id}", response_model=ExportOut)
def get_export(
    export_id: int,
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
) -> ExportOut:
    row = db.execute(
        select(models.Export).where(
            models.Export.id == export_id,
            models.Export.profile_id == profile.profile_id,
        )
    ).scalar_one_or_none()
    if not row:
        raise HTTPException(status_code=404, detail="Export not found")
    return ExportOut.model_validate(row)


@router.get("/{export_id}/download")
def download_export(
    export_id: int,
    request: Request,
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
):
    row = db.execute(
        select(models.Export).where(
            models.Export.id == export_id,
            models.Export.profile_id == profile.profile_id,
        )
    ).scalar_one_or_none()
    if not row:
        raise HTTPException(status_code=404, detail="Export not found")
    if row.status != models.ExportStatus.READY or not row.storage_key:
        raise HTTPException(status_code=409, detail="Export is not ready")

    storage = request.app.state.storage
    content = storage.read_bytes(row.storage_key)
    filename = row.filename or f"export-{row.id}.bin"

    return Response(
        content=content,
        media_type="application/octet-stream",
        headers={"Content-Disposition": f"attachment; filename={filename}"},
    )
