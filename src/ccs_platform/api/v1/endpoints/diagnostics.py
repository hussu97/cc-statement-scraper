from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Request
from sqlalchemy.orm import Session

from ccs_platform.db import models
from ccs_platform.api.deps import ProfileContext, get_db, get_profile_context
from ccs_platform.api.v1.schemas import BankConnectionTestRequest, JobOut, ParserValidateRequest
from ccs_platform.application.banks.capabilities import get_enabled_banks
from ccs_platform.application.jobs.service import create_or_get_job


router = APIRouter(prefix="/diagnostics", tags=["diagnostics"])


@router.post("/parser-validate", response_model=JobOut)
def parser_validate(
    payload: ParserValidateRequest,
    request: Request,
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
) -> JobOut:
    job, created = create_or_get_job(
        db,
        profile_id=profile.profile_id,
        job_type=models.JobType.PARSER_VALIDATE,
        payload_json=payload.model_dump(),
    )
    if created:
        db.commit()
        db.refresh(job)
        request.app.state.job_dispatcher.publish(job.id)

    return JobOut.model_validate(job)


@router.post("/bank-connection-test", response_model=JobOut)
def bank_connection_test(
    payload: BankConnectionTestRequest,
    request: Request,
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
) -> JobOut:
    allowed = {
        bank.code for bank in get_enabled_banks(db, requested=[payload.bank_code], profile_id=profile.profile_id)
    }
    if payload.bank_code.upper() not in allowed:
        raise HTTPException(
            status_code=400,
            detail=f"Bank {payload.bank_code.upper()} is not enabled for profile {profile.profile_key}",
        )

    job, created = create_or_get_job(
        db,
        profile_id=profile.profile_id,
        job_type=models.JobType.BANK_CONNECTION_TEST,
        payload_json=payload.model_dump(),
    )
    if created:
        db.commit()
        db.refresh(job)
        request.app.state.job_dispatcher.publish(job.id)

    return JobOut.model_validate(job)
