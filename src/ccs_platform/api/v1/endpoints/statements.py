from __future__ import annotations

from collections import defaultdict
from datetime import date

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from fastapi.responses import Response
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from ccs_platform.db import models
from ccs_platform.api.deps import ProfileContext, get_db, get_profile_context
from ccs_platform.api.v1.schemas import JobOut, PaginatedStatementLines, PaginatedStatements
from ccs_platform.application.statements.serializers import to_line_out, to_statement_out


router = APIRouter(prefix="/statements", tags=["statements"])


@router.get("", response_model=PaginatedStatements)
def list_statements(
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
    page: int = 1,
    page_size: int = 50,
    bank_codes: list[str] | None = Query(default=None),
    statement_reference: str | None = None,
    date_from: date | None = None,
    date_to: date | None = None,
) -> PaginatedStatements:
    page = max(page, 1)
    page_size = min(max(page_size, 1), 200)

    query = select(models.Statement).where(models.Statement.profile_id == profile.profile_id)
    count_query = select(func.count(models.Statement.id)).where(models.Statement.profile_id == profile.profile_id)

    if bank_codes:
        bank_set = [code.upper() for code in bank_codes]
        query = query.where(models.Statement.bank_code.in_(bank_set))
        count_query = count_query.where(models.Statement.bank_code.in_(bank_set))

    if statement_reference:
        like = f"%{statement_reference.upper()}%"
        query = query.where(func.upper(models.Statement.statement_reference).like(like))
        count_query = count_query.where(func.upper(models.Statement.statement_reference).like(like))

    if date_from:
        query = query.where(models.Statement.statement_date >= date_from)
        count_query = count_query.where(models.Statement.statement_date >= date_from)

    if date_to:
        query = query.where(models.Statement.statement_date <= date_to)
        count_query = count_query.where(models.Statement.statement_date <= date_to)

    total = int(db.execute(count_query).scalar_one())
    rows = db.execute(
        query.order_by(models.Statement.statement_date.desc())
        .offset((page - 1) * page_size)
        .limit(page_size)
    ).scalars().all()

    statement_ids = [row.id for row in rows]
    line_counts: dict[int, int] = defaultdict(int)
    if statement_ids:
        counts = db.execute(
            select(models.StatementLine.statement_id, func.count(models.StatementLine.id))
            .where(models.StatementLine.statement_id.in_(statement_ids))
            .group_by(models.StatementLine.statement_id)
        ).all()
        line_counts = defaultdict(int, {sid: int(count) for sid, count in counts})

    return PaginatedStatements(
        total=total,
        page=page,
        page_size=page_size,
        items=[to_statement_out(row, line_count=line_counts[row.id]) for row in rows],
    )


@router.get("/{statement_id}")
def get_statement(
    statement_id: int,
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
):
    row = db.execute(
        select(models.Statement).where(
            models.Statement.id == statement_id,
            models.Statement.profile_id == profile.profile_id,
        )
    ).scalar_one_or_none()
    if not row:
        raise HTTPException(status_code=404, detail="Statement not found")

    count = int(
        db.execute(
            select(func.count(models.StatementLine.id)).where(models.StatementLine.statement_id == statement_id)
        ).scalar_one()
    )
    return to_statement_out(row, line_count=count)


@router.get("/{statement_id}/lines", response_model=PaginatedStatementLines)
def list_statement_lines(
    statement_id: int,
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
    page: int = 1,
    page_size: int = 200,
    search: str | None = None,
) -> PaginatedStatementLines:
    page = max(page, 1)
    page_size = min(max(page_size, 1), 500)

    statement = db.execute(
        select(models.Statement).where(
            models.Statement.id == statement_id,
            models.Statement.profile_id == profile.profile_id,
        )
    ).scalar_one_or_none()
    if not statement:
        raise HTTPException(status_code=404, detail="Statement not found")

    query = select(models.StatementLine).where(models.StatementLine.statement_id == statement_id)
    count_query = select(func.count(models.StatementLine.id)).where(
        models.StatementLine.statement_id == statement_id
    )

    if search:
        like = f"%{search.upper()}%"
        query = query.where(func.upper(models.StatementLine.merchant_normalized).like(like))
        count_query = count_query.where(func.upper(models.StatementLine.merchant_normalized).like(like))

    total = int(db.execute(count_query).scalar_one())
    rows = db.execute(
        query.order_by(models.StatementLine.line_no.asc())
        .offset((page - 1) * page_size)
        .limit(page_size)
    ).scalars().all()

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
    statement = db.execute(
        select(models.Statement).where(
            models.Statement.id == statement_id,
            models.Statement.profile_id == profile.profile_id,
        )
    ).scalar_one_or_none()
    if not statement:
        raise HTTPException(status_code=404, detail="Statement not found")
    if not statement.pdf_file_id:
        raise HTTPException(status_code=404, detail="Statement has no linked PDF")

    pdf_file = db.execute(
        select(models.PdfFile).where(
            models.PdfFile.id == statement.pdf_file_id,
            models.PdfFile.profile_id == profile.profile_id,
        )
    ).scalar_one_or_none()
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
) -> JobOut:
    statement = db.execute(
        select(models.Statement).where(
            models.Statement.id == statement_id,
            models.Statement.profile_id == profile.profile_id,
        )
    ).scalar_one_or_none()
    if not statement:
        raise HTTPException(status_code=404, detail="Statement not found")

    job = models.Job(
        profile_id=profile.profile_id,
        job_type=models.JobType.REPARSE_STATEMENT,
        status=models.JobStatus.QUEUED,
        payload_json={"statement_id": statement_id},
    )
    db.add(job)
    db.commit()
    db.refresh(job)

    request.app.state.job_runner.enqueue(job.id)
    return JobOut.model_validate(job)


@router.delete("/{statement_id}")
def delete_statement(
    statement_id: int,
    db: Session = Depends(get_db),
    profile: ProfileContext = Depends(get_profile_context),
):
    statement = db.execute(
        select(models.Statement).where(
            models.Statement.id == statement_id,
            models.Statement.profile_id == profile.profile_id,
        )
    ).scalar_one_or_none()
    if not statement:
        raise HTTPException(status_code=404, detail="Statement not found")

    db.add(
        models.AuditEvent(
            profile_id=profile.profile_id,
            event_type="statement_deleted",
            entity_type="statement",
            entity_id=str(statement.id),
            payload_json={
                "bank_code": statement.bank_code,
                "statement_reference": statement.statement_reference,
                "statement_date": statement.statement_date.isoformat(),
            },
        )
    )
    db.delete(statement)
    db.commit()

    return {"deleted": True, "statement_id": statement_id}
