from __future__ import annotations

import fnmatch
import tempfile
from pathlib import Path
from datetime import UTC, datetime

import pdfplumber
from fastapi import APIRouter, Depends, File, HTTPException, Request, UploadFile
from sqlalchemy.orm import Session

from ccs_platform.api.audit import append_audit_event
from ccs_platform.core.bank_config import load_app_config
from ccs_platform.core.runtime_settings import decode_runtime_setting_row_value
from ccs_platform.db import models
from ccs_platform.db.repositories import JobRepository
from ccs_platform.api.deps import (
    ActorContext,
    ProfileContext,
    get_db,
    get_profile_context,
    require_operator_role,
)
from ccs_platform.api.v1.schemas import JobOut, PaginatedJobs, ReclassifyJobRequest, ScrapeJobRequest
from ccs_platform.api.v1.endpoints.job_utils import request_idempotency_key
from ccs_platform.application.banks.capabilities import get_enabled_banks, resolve_requested_months
from ccs_platform.application.jobs.service import create_or_get_job


router = APIRouter(prefix="/jobs", tags=["jobs"])


def _job_to_out(job: models.Job) -> JobOut:
    return JobOut.model_validate(job)


def _detect_bank_code_from_filename(filename: str) -> str | None:
    app_cfg = load_app_config()
    lower = filename.lower()
    for bank_code, bank_cfg in app_cfg.banks.items():
        patterns = bank_cfg.get("file_glob_patterns", [])
        if any(fnmatch.fnmatch(lower, pattern.lower()) for pattern in patterns):
            return bank_code
    return None


def _extract_pdf_text(pdf_path: Path, max_pages: int = 2, extra_passwords: list[str | None] | None = None) -> str:
    password_candidates: list[str | None] = [None] + (extra_passwords or [])

    def _extract_with_password(password: str | None) -> str | None:
        try:
            kwargs = {"password": password} if password else {}
            with pdfplumber.open(str(pdf_path), **kwargs) as pdf:
                chunks: list[str] = []
                for page in pdf.pages[:max_pages]:
                    chunks.append(page.extract_text() or "")
                return "\n".join(chunks)
        except Exception:  # noqa: BLE001
            return None

    for password in password_candidates:
        extracted = _extract_with_password(password)
        if extracted is not None:
            return extracted
    return ""


def _infer_bank_code_from_text(pdf_text: str) -> str | None:
    text = (pdf_text or "").upper()
    if not text.strip():
        return None

    # EIB statements usually include explicit Emirates Islamic markers.
    if "EMIRATES ISLAMIC BANK" in text or "EMIRATES ISLAMIC" in text or "EMIRATESISLAMIC" in text:
        return "EIB"
    if "EIB" in text and "STATEMENT PERIOD:" in text and "CARD TYPE:" in text:
        return "EIB"

    # ENBD statements reliably include these markers in headers.
    if "EMIRATES NBD" in text or "EMIRATES NATIONAL BANK OF DUBAI" in text:
        return "ENBD"
    if "STATEMENT PERIOD:" in text and "CARD TYPE:" in text:
        return "ENBD"

    # ADCB statements commonly include these section markers.
    if "ABU DHABI COMMERCIAL BANK" in text:
        return "ADCB"
    if "PREVIOUS BALANCE OUTSTANDING" in text or "NEW BALANCE OUTSTANDING" in text:
        return "ADCB"
    if "CARD NO" in text and "CR" in text:
        return "ADCB"

    # FAB statements include these title/body phrases.
    if "FIRST ABU DHABI BANK" in text:
        return "FAB"
    if "SUPPLEMENTARY CARD" in text or "MAIN CARD PRODUCT" in text:
        return "FAB"
    if "CARD E-STATEMENT" in text and "AED" in text:
        return "FAB"

    # SIB statements often include these bank markers.
    if "SHARJAH ISLAMIC BANK" in text:
        return "SIB"
    if "SIB" in text and "ISLAMIC BANK" in text:
        return "SIB"
    if "SIB DIGITAL" in text and "STATEMENT" in text:
        return "SIB"

    # Mashreq statements include these bank markers.
    if "MASHREQ BANK" in text or "MASHREQBANK" in text:
        return "MASHREQ"
    if "MASHREQ" in text and "E-STATEMENT" in text:
        return "MASHREQ"

    return None


def _detect_bank_code_for_upload(
    filename: str, pdf_path: Path, extra_passwords: list[str | None] | None = None
) -> str | None:
    detected = _infer_bank_code_from_text(_extract_pdf_text(pdf_path, extra_passwords=extra_passwords))
    if detected:
        return detected
    return _detect_bank_code_from_filename(filename)


@router.get("", response_model=PaginatedJobs)
def list_jobs(
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
    page: int = 1,
    page_size: int = 100,
) -> PaginatedJobs:
    page = max(page, 1)
    page_size = min(max(page_size, 1), 1000)

    total, rows = JobRepository(db).list_paginated(
        profile_id=profile.profile_id, page=page, page_size=page_size
    )
    return PaginatedJobs(
        total=total,
        page=page,
        page_size=page_size,
        items=[_job_to_out(job) for job in rows],
    )


@router.get("/{job_id}", response_model=JobOut)
def get_job(
    job_id: int,
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
) -> JobOut:
    row = JobRepository(db).get_by_id(job_id, profile_id=profile.profile_id)
    if not row:
        raise HTTPException(status_code=404, detail="Job not found")
    return _job_to_out(row)


@router.post("/scrape", response_model=JobOut)
def create_scrape_job(
    payload: ScrapeJobRequest,
    request: Request,
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
    actor: ActorContext = Depends(require_operator_role),
) -> JobOut:
    requested_banks = sorted({token.upper().strip() for token in (payload.banks or []) if token and token.strip()})
    banks = get_enabled_banks(db, requested_banks or None, profile_id=profile.profile_id)
    if requested_banks:
        found_codes = {bank.code for bank in banks}
        denied = [code for code in requested_banks if code not in found_codes]
        if denied:
            raise HTTPException(
                status_code=400,
                detail=f"Banks not enabled for profile {profile.profile_key}: {', '.join(denied)}",
            )
    if not banks:
        raise HTTPException(status_code=400, detail="No matching banks")

    try:
        settings = request.app.state.settings
        months = resolve_requested_months(
            months=payload.months,
            month_from=payload.month_from,
            month_to=payload.month_to,
            timezone=settings.timezone,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    payload_json = {
        "banks": [bank.code for bank in banks],
        "months": months,
        "download": payload.download,
        "headless": payload.headless,
        "login_timeout_minutes": payload.login_timeout_minutes,
    }
    job, created, requeued = create_or_get_job(
        db,
        profile_id=profile.profile_id,
        job_type=models.JobType.SCRAPE,
        payload_json=payload_json,
        idempotency_key=request_idempotency_key(request),
    )
    if not created and job.status in {models.JobStatus.QUEUED, models.JobStatus.RUNNING}:
        raise HTTPException(
            status_code=409,
            detail=f"An identical scrape job is already {job.status.value}.",
        )

    if created:
        for bank in banks:
            for month in months:
                db.add(
                    models.JobItem(
                        job_id=job.id,
                        bank_code=bank.code,
                        target_month=month,
                        status="queued",
                    )
                )
    if created or requeued:
        append_audit_event(
            db,
            profile_id=profile.profile_id,
            event_type="job_enqueued",
            entity_type="job",
            entity_id=str(job.id),
            payload_json={
                "job_type": job.job_type.value,
                "queue_name": job.queue_name,
                "payload_json": payload_json,
                "requeued": requeued,
            },
            request=request,
        )
        db.commit()
        db.refresh(job)
        request.app.state.job_dispatcher.publish(job.id)

    return _job_to_out(job)


@router.post("/upload", response_model=JobOut)
async def create_upload_job(
    request: Request,
    files: list[UploadFile] = File(...),
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
    actor: ActorContext = Depends(require_operator_role),
) -> JobOut:
    if not files:
        raise HTTPException(status_code=400, detail="No files uploaded")

    allowed_bank_codes = {
        bank.code
        for bank in get_enabled_banks(db, profile_id=profile.profile_id)
    }

    # Load ADCB PDF passwords from runtime settings instead of os.environ so that
    # credentials updated via the admin UI are reflected without a process restart.
    adcb_password_rows = JobRepository(db).get_runtime_settings(
        profile_id=profile.profile_id,
        keys=["ADCB_PDF_PASSWORD", "ADCB_CID"],
    )
    adcb_pdf_passwords: list[str | None] = [
        decode_runtime_setting_row_value(row) or None for row in adcb_password_rows
    ]

    uploads: list[dict] = []

    try:
        for uploaded in files:
            filename = uploaded.filename or "statement.pdf"
            content = await uploaded.read()
            if not content:
                continue

            with tempfile.NamedTemporaryFile(suffix=".pdf", delete=True) as tmp:
                tmp.write(content)
                tmp.flush()
                bank_code = (
                    _detect_bank_code_for_upload(filename, Path(tmp.name), extra_passwords=adcb_pdf_passwords) or ""
                ).upper().strip()

            if not bank_code:
                raise HTTPException(
                    status_code=400,
                    detail=f"Could not infer bank for file '{filename}' from PDF content.",
                )
            if bank_code not in allowed_bank_codes:
                raise HTTPException(
                    status_code=400,
                    detail=f"Bank {bank_code} is not enabled for profile {profile.profile_key}",
                )

            staging = request.app.state.storage.save_binary(
                content=content,
                filename=f"upload_{Path(filename).name}_{len(uploads)}.pdf",
                folder="staging",
                profile_key=profile.profile_key,
            )
            uploads.append(
                {
                    "filename": filename,
                    "storage_key": staging.key,
                    "bank_code": bank_code,
                }
            )
    except Exception:
        raise

    if not uploads:
        raise HTTPException(status_code=400, detail="Uploaded files were empty")

    job, created, requeued = create_or_get_job(
        db,
        profile_id=profile.profile_id,
        job_type=models.JobType.UPLOAD,
        payload_json={"uploads": uploads},
        idempotency_key=request_idempotency_key(request),
        auto_idempotency=False,
    )
    if not (created or requeued):
        pass  # staging objects in storage are cleaned up by the upload handler or retention
    else:
        append_audit_event(
            db,
            profile_id=profile.profile_id,
            event_type="job_enqueued",
            entity_type="job",
            entity_id=str(job.id),
            payload_json={"job_type": job.job_type.value, "queue_name": job.queue_name},
            request=request,
        )
    db.commit()
    db.refresh(job)

    if created or requeued:
        request.app.state.job_dispatcher.publish(job.id)
    return _job_to_out(job)


@router.post("/{job_id}/cancel", response_model=JobOut)
def cancel_job(
    job_id: int,
    request: Request,
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
    actor: ActorContext = Depends(require_operator_role),
) -> JobOut:
    job = JobRepository(db).get_by_id(job_id, profile_id=profile.profile_id)
    if not job:
        raise HTTPException(status_code=404, detail="Job not found")

    previous_status = job.status.value
    if job.status in {models.JobStatus.SUCCEEDED, models.JobStatus.FAILED}:
        raise HTTPException(status_code=409, detail="Completed jobs cannot be cancelled")
    if job.status == models.JobStatus.QUEUED:
        job.status = models.JobStatus.CANCELLED
        job.finished_at = datetime.now(UTC)
    elif job.status == models.JobStatus.RUNNING:
        # Signal cooperative cancellation; runner observes this token.
        job.cancel_requested_at = datetime.now(UTC)
    elif job.status == models.JobStatus.CANCELLED:
        if job.finished_at is None:
            job.finished_at = datetime.now(UTC)

    if job.cancel_requested_at is None and job.status == models.JobStatus.CANCELLED:
        job.cancel_requested_at = datetime.now(UTC)
    append_audit_event(
        db,
        profile_id=profile.profile_id,
        event_type="job_cancel_requested",
        entity_type="job",
        entity_id=str(job.id),
        payload_json={
            "before_status": previous_status,
            "after_status": job.status.value,
            "cancel_requested_at": (
                job.cancel_requested_at.isoformat() if job.cancel_requested_at is not None else None
            ),
        },
        request=request,
    )
    db.commit()
    db.refresh(job)
    return _job_to_out(job)


@router.post("/reclassify", response_model=JobOut)
def create_reclassify_job(
    payload: ReclassifyJobRequest,
    request: Request,
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
    actor: ActorContext = Depends(require_operator_role),
) -> JobOut:
    job, created, requeued = create_or_get_job(
        db,
        profile_id=profile.profile_id,
        job_type=models.JobType.RECLASSIFY,
        payload_json=payload.model_dump(),
        idempotency_key=request_idempotency_key(request),
    )
    if created or requeued:
        append_audit_event(
            db,
            profile_id=profile.profile_id,
            event_type="job_enqueued",
            entity_type="job",
            entity_id=str(job.id),
            payload_json={"job_type": job.job_type.value, "queue_name": job.queue_name},
            request=request,
        )
        db.commit()
        db.refresh(job)
        request.app.state.job_dispatcher.publish(job.id)

    return _job_to_out(job)
