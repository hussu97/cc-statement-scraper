from __future__ import annotations

import fnmatch
import os
from pathlib import Path
from datetime import UTC, datetime

import pdfplumber
from fastapi import APIRouter, Depends, File, HTTPException, Request, UploadFile
from sqlalchemy import func, select
from sqlalchemy.orm import Session, selectinload

from ccs_platform.core.bank_config import load_app_config
from ccs_platform.db import models
from ccs_platform.api.deps import ProfileContext, get_db, get_profile_context
from ccs_platform.api.v1.schemas import JobOut, PaginatedJobs, ReclassifyJobRequest, ScrapeJobRequest
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


def _extract_pdf_text(pdf_path: Path, max_pages: int = 2) -> str:
    password_candidates = [None, os.getenv("ADCB_PDF_PASSWORD"), os.getenv("ADCB_CID")]
    for password in password_candidates:
        try:
            kwargs = {"password": password} if password else {}
            with pdfplumber.open(str(pdf_path), **kwargs) as pdf:
                chunks: list[str] = []
                for page in pdf.pages[:max_pages]:
                    chunks.append(page.extract_text() or "")
                return "\n".join(chunks)
        except Exception:  # noqa: BLE001
            continue
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


def _detect_bank_code_for_upload(filename: str, pdf_path: Path) -> str | None:
    detected = _infer_bank_code_from_text(_extract_pdf_text(pdf_path))
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

    count_query = select(func.count(models.Job.id)).where(models.Job.profile_id == profile.profile_id)
    total = int(db.execute(count_query).scalar_one())

    rows = db.execute(
        select(models.Job)
        .options(selectinload(models.Job.items))
        .where(models.Job.profile_id == profile.profile_id)
        .order_by(models.Job.created_at.desc())
        .offset((page - 1) * page_size)
        .limit(page_size)
    ).scalars().all()
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
    row = db.execute(
        select(models.Job)
        .options(selectinload(models.Job.items))
        .where(models.Job.id == job_id, models.Job.profile_id == profile.profile_id)
    ).scalar_one_or_none()
    if not row:
        raise HTTPException(status_code=404, detail="Job not found")
    return _job_to_out(row)


@router.post("/scrape", response_model=JobOut)
def create_scrape_job(
    payload: ScrapeJobRequest,
    request: Request,
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
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
    job, created = create_or_get_job(
        db,
        profile_id=profile.profile_id,
        job_type=models.JobType.SCRAPE,
        payload_json=payload_json,
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
) -> JobOut:
    if not files:
        raise HTTPException(status_code=400, detail="No files uploaded")

    settings = request.app.state.settings
    profile_upload_dir = settings.uploads_temp_dir / profile.profile_key
    profile_upload_dir.mkdir(parents=True, exist_ok=True)
    allowed_bank_codes = {
        bank.code
        for bank in get_enabled_banks(db, profile_id=profile.profile_id)
    }
    uploads: list[dict] = []

    try:
        for uploaded in files:
            filename = uploaded.filename or "statement.pdf"
            content = await uploaded.read()
            if not content:
                continue

            temp_path = profile_upload_dir / f"upload_{Path(filename).name}_{len(uploads)}.pdf"
            temp_path.write_bytes(content)
            bank_code = (_detect_bank_code_for_upload(filename, temp_path) or "").upper().strip()
            if not bank_code:
                temp_path.unlink(missing_ok=True)
                raise HTTPException(
                    status_code=400,
                    detail=f"Could not infer bank for file '{filename}' from PDF content.",
                )
            if bank_code not in allowed_bank_codes:
                temp_path.unlink(missing_ok=True)
                raise HTTPException(
                    status_code=400,
                    detail=f"Bank {bank_code} is not enabled for profile {profile.profile_key}",
                )
            uploads.append(
                {
                    "filename": filename,
                    "temp_path": str(temp_path),
                    "bank_code": bank_code,
                }
            )
    except Exception:
        for item in uploads:
            Path(item.get("temp_path", "")).unlink(missing_ok=True)
        raise

    if not uploads:
        raise HTTPException(status_code=400, detail="Uploaded files were empty")

    job, _ = create_or_get_job(
        db,
        profile_id=profile.profile_id,
        job_type=models.JobType.UPLOAD,
        payload_json={"uploads": uploads},
        auto_idempotency=False,
    )
    db.commit()
    db.refresh(job)

    request.app.state.job_dispatcher.publish(job.id)
    return _job_to_out(job)


@router.post("/{job_id}/cancel", response_model=JobOut)
def cancel_job(
    job_id: int,
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
) -> JobOut:
    job = db.execute(
        select(models.Job).where(models.Job.id == job_id, models.Job.profile_id == profile.profile_id)
    ).scalar_one_or_none()
    if not job:
        raise HTTPException(status_code=404, detail="Job not found")

    if job.status in {models.JobStatus.SUCCEEDED, models.JobStatus.FAILED}:
        raise HTTPException(status_code=409, detail="Completed jobs cannot be cancelled")

    job.status = models.JobStatus.CANCELLED
    job.cancel_requested_at = datetime.now(UTC)
    db.commit()
    db.refresh(job)
    return _job_to_out(job)


@router.post("/reclassify", response_model=JobOut)
def create_reclassify_job(
    payload: ReclassifyJobRequest,
    request: Request,
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
) -> JobOut:
    job, created = create_or_get_job(
        db,
        profile_id=profile.profile_id,
        job_type=models.JobType.RECLASSIFY,
        payload_json=payload.model_dump(),
    )
    if created:
        db.commit()
        db.refresh(job)
        request.app.state.job_dispatcher.publish(job.id)

    return _job_to_out(job)
