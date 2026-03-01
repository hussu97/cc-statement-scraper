from __future__ import annotations

from datetime import date

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from fastapi.responses import Response
from sqlalchemy.orm import Session

from ccs_platform.api.audit import append_audit_event
from ccs_platform.db import models
from ccs_platform.db.repositories import StatementRepository
from ccs_platform.api.deps import (
    ActorContext,
    ProfileContext,
    get_db,
    get_profile_context,
    require_admin_role,
    require_operator_role,
)
from ccs_platform.api.v1.schemas import (
    JobOut,
    PaginatedStatementLines,
    PaginatedStatements,
    StatementDateUpdate,
    StatementOut,
)
from ccs_platform.api.v1.endpoints.job_utils import request_idempotency_key
from ccs_platform.application.statements.serializers import to_line_out, to_statement_out
from ccs_platform.application.jobs.service import create_or_get_job
from ccs_platform.domain.parsing.utils import statement_month_from_date


router = APIRouter(prefix="/statements", tags=["statements"])


def _enqueue_reparse_job(
    *,
    request: Request,
    db: Session,
    profile_id: int,
    payload: dict[str, int | bool],
) -> JobOut:
    job, created, requeued = create_or_get_job(
        db,
        profile_id=profile_id,
        job_type=models.JobType.REPARSE_STATEMENT,
        payload_json=payload,
        idempotency_key=request_idempotency_key(request),
    )
    if created or requeued:
        append_audit_event(
            db,
            profile_id=profile_id,
            event_type="statement_reparse_enqueued",
            entity_type="job",
            entity_id=str(job.id),
            payload_json={"job_type": job.job_type.value, "payload_json": payload},
            request=request,
        )
        db.commit()
        db.refresh(job)
        request.app.state.job_dispatcher.publish(job.id)
    return JobOut.model_validate(job)


@router.get("", response_model=PaginatedStatements)
def list_statements(
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
    page: int = 1,
    page_size: int = 100,
    bank_codes: list[str] | None = Query(default=None),
    statement_reference: str | None = None,
    date_from: date | None = None,
    date_to: date | None = None,
) -> PaginatedStatements:
    page = max(page, 1)
    page_size = min(max(page_size, 1), 1000)

    repo = StatementRepository(db)
    bank_set = [code.upper() for code in bank_codes] if bank_codes else None
    total, rows = repo.list_paginated(
        profile_id=profile.profile_id,
        page=page,
        page_size=page_size,
        bank_codes=bank_set,
        statement_reference=statement_reference,
        date_from=date_from,
        date_to=date_to,
    )

    statement_ids = [row.id for row in rows]
    line_counts = repo.line_counts_for_ids(statement_ids)
    amount_totals = repo.amount_totals_for_ids(statement_ids)

    return PaginatedStatements(
        total=total,
        page=page,
        page_size=page_size,
        items=[
            to_statement_out(
                row,
                line_count=line_counts[row.id],
                total_debit_aed=amount_totals[row.id]["debit"],
                total_credit_aed=amount_totals[row.id]["credit"],
            )
            for row in rows
        ],
    )


@router.post("/reparse-all", response_model=JobOut)
def reparse_all_statements(
    request: Request,
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
    actor: ActorContext = Depends(require_operator_role),
) -> JobOut:
    return _enqueue_reparse_job(
        request=request,
        db=db,
        profile_id=profile.profile_id,
        payload={"all_statements": True},
    )


@router.get("/{statement_id}")
def get_statement(
    statement_id: int,
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
):
    repo = StatementRepository(db)
    row = repo.get_by_id(statement_id, profile_id=profile.profile_id)
    if not row:
        raise HTTPException(status_code=404, detail="Statement not found")
    return to_statement_out(row, line_count=repo.count_lines(statement_id))


@router.patch("/{statement_id}", response_model=StatementOut)
def patch_statement_date(
    statement_id: int,
    payload: StatementDateUpdate,
    request: Request,
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
    actor: ActorContext = Depends(require_operator_role),
) -> StatementOut:
    repo = StatementRepository(db)
    statement = repo.get_by_id(statement_id, profile_id=profile.profile_id)
    if not statement:
        raise HTTPException(status_code=404, detail="Statement not found")

    line_rows = repo.get_lines_for_statement(statement.id)
    line_count = len(line_rows)

    old_date = statement.statement_date
    old_period_end = statement.statement_period_end
    new_date = payload.statement_date
    if new_date == old_date:
        return to_statement_out(statement, line_count=line_count)

    if repo.date_conflict_exists(
        profile_id=profile.profile_id,
        exclude_id=statement.id,
        bank_code=statement.bank_code,
        statement_reference=statement.statement_reference,
        new_date=new_date,
    ):
        raise HTTPException(
            status_code=409,
            detail=(
                "Statement date update conflicts with an existing statement identity "
                "(bank_code + statement_reference + statement_date)."
            ),
        )

    statement.statement_date = new_date
    if statement.statement_period_end == old_date:
        statement.statement_period_end = new_date

    statement_month = statement_month_from_date(new_date)
    metadata = dict(statement.metadata_json) if isinstance(statement.metadata_json, dict) else {}
    metadata["statement_date"] = new_date.isoformat()
    metadata["statement_month"] = statement_month
    if statement.statement_period_end is not None:
        metadata["statement_period_end"] = statement.statement_period_end.isoformat()
    statement.metadata_json = metadata

    updated_line_storage_records = 0
    for line in line_rows:
        raw = dict(line.raw_json) if isinstance(line.raw_json, dict) else {}
        if raw.get("statement_month") != statement_month:
            updated_line_storage_records += 1
        raw["statement_month"] = statement_month
        line.raw_json = raw

    append_audit_event(
        db,
        profile_id=profile.profile_id,
        event_type="statement_date_updated",
        entity_type="statement",
        entity_id=str(statement.id),
        payload_json={
            "bank_code": statement.bank_code,
            "statement_reference": statement.statement_reference,
            "old_statement_date": old_date.isoformat(),
            "new_statement_date": new_date.isoformat(),
            "old_statement_period_end": old_period_end.isoformat() if old_period_end else None,
            "new_statement_period_end": (
                statement.statement_period_end.isoformat() if statement.statement_period_end else None
            ),
            "updated_line_storage_records": updated_line_storage_records,
        },
        request=request,
    )
    db.commit()
    db.refresh(statement)
    return to_statement_out(statement, line_count=line_count)


@router.get("/{statement_id}/lines", response_model=PaginatedStatementLines)
def list_statement_lines(
    statement_id: int,
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
    page: int = 1,
    page_size: int = 100,
    search: str | None = None,
) -> PaginatedStatementLines:
    page = max(page, 1)
    page_size = min(max(page_size, 1), 1000)

    repo = StatementRepository(db)
    if not repo.get_by_id(statement_id, profile_id=profile.profile_id):
        raise HTTPException(status_code=404, detail="Statement not found")

    total, rows = repo.list_lines_paginated(
        statement_id, page=page, page_size=page_size, search=search
    )
    return PaginatedStatementLines(
        total=total,
        page=page,
        page_size=page_size,
        items=[to_line_out(row) for row in rows],
    )


@router.get("/{statement_id}/pdf")
def get_statement_pdf(
    statement_id: int,
    request: Request,
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
    download: bool = Query(default=True),
):
    repo = StatementRepository(db)
    statement = repo.get_by_id(statement_id, profile_id=profile.profile_id)
    if not statement:
        raise HTTPException(status_code=404, detail="Statement not found")
    if not statement.pdf_file_id:
        raise HTTPException(status_code=404, detail="Statement has no linked PDF")

    pdf_file = repo.get_pdf_file(statement.pdf_file_id, profile_id=profile.profile_id)
    if not pdf_file:
        raise HTTPException(status_code=404, detail="PDF file metadata not found")

    storage = request.app.state.storage
    content = storage.read_bytes(pdf_file.storage_key)
    disposition = "attachment" if download else "inline"
    return Response(
        content=content,
        media_type="application/pdf",
        headers={
            "Content-Disposition": f'{disposition}; filename="{pdf_file.original_filename}"',
        },
    )


@router.post("/{statement_id}/reparse", response_model=JobOut)
def reparse_statement(
    statement_id: int,
    request: Request,
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
    actor: ActorContext = Depends(require_operator_role),
) -> JobOut:
    if not StatementRepository(db).get_by_id(statement_id, profile_id=profile.profile_id):
        raise HTTPException(status_code=404, detail="Statement not found")

    return _enqueue_reparse_job(
        request=request,
        db=db,
        profile_id=profile.profile_id,
        payload={"statement_id": statement_id},
    )


@router.delete("/{statement_id}")
def delete_statement(
    statement_id: int,
    request: Request,
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
    actor: ActorContext = Depends(require_admin_role),
):
    statement = StatementRepository(db).get_by_id(statement_id, profile_id=profile.profile_id)
    if not statement:
        raise HTTPException(status_code=404, detail="Statement not found")

    append_audit_event(
        db,
        profile_id=profile.profile_id,
        event_type="statement_deleted",
        entity_type="statement",
        entity_id=str(statement.id),
        payload_json={
            "bank_code": statement.bank_code,
            "statement_reference": statement.statement_reference,
            "statement_date": statement.statement_date.isoformat(),
        },
        request=request,
    )
    db.delete(statement)
    db.commit()

    return {"deleted": True, "statement_id": statement_id}
