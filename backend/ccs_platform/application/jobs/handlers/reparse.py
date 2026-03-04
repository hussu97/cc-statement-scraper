from __future__ import annotations

from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from ccs_platform.db import models
from ccs_platform.application.statements.ingestion import ingest_statement_pdf
from ccs_platform.core.runtime_settings import get_runtime_settings_as_dict
from .context import JobContext


def handle_reparse_statement_job(
    db: Session,
    job: models.Job,
    ctx: JobContext,
    *,
    profile_key: str,
) -> dict[str, Any]:
    payload = job.payload_json or {}
    bank_settings = get_runtime_settings_as_dict(db, profile_id=job.profile_id)

    if bool(payload.get("all_statements")):
        statement_ids = db.execute(
            select(models.Statement.id)
            .where(models.Statement.profile_id == job.profile_id)
            .order_by(models.Statement.id.asc())
        ).scalars().all()

        reparsed: list[dict[str, Any]] = []
        failures: list[dict[str, Any]] = []

        total = len(statement_ids)
        for idx, statement_id in enumerate(statement_ids):
            ctx.assert_not_cancelled(db, job.id)
            try:
                summary = _reparse_single_statement(
                    db,
                    statement_id=int(statement_id),
                    profile_id=job.profile_id,
                    profile_key=profile_key,
                    ctx=ctx,
                    bank_settings=bank_settings,
                )
                reparsed.append({"statement_id": int(statement_id), "new_summary": summary})
            except Exception as exc:  # noqa: BLE001
                db.rollback()
                failures.append({"statement_id": int(statement_id), "error": str(exc)})

            ctx.update_progress(db, job, int((idx + 1) / max(total, 1) * 90))

        return {
            "total_statements": total,
            "reparsed": reparsed,
            "failures": failures,
        }

    if payload.get("statement_id") is None:
        raise RuntimeError("Reparse job payload must include 'statement_id' or 'all_statements=true'")

    statement_id = int(payload.get("statement_id"))
    summary = _reparse_single_statement(
        db,
        statement_id=statement_id,
        profile_id=job.profile_id,
        profile_key=profile_key,
        ctx=ctx,
        bank_settings=bank_settings,
    )
    return {"reparsed_statement_id": statement_id, "new_summary": summary}


def _reparse_single_statement(
    db: Session,
    *,
    statement_id: int,
    profile_id: int,
    profile_key: str,
    ctx: JobContext,
    bank_settings: dict[str, str],
) -> dict[str, Any]:
    statement = db.execute(
        select(models.Statement).where(
            models.Statement.id == statement_id,
            models.Statement.profile_id == profile_id,
        )
    ).scalar_one_or_none()
    if not statement:
        raise RuntimeError(f"Statement not found: {statement_id}")
    if not statement.pdf_file_id:
        raise RuntimeError("Statement has no source PDF")

    pdf_file = db.execute(
        select(models.PdfFile).where(
            models.PdfFile.id == statement.pdf_file_id,
            models.PdfFile.profile_id == profile_id,
        )
    ).scalar_one_or_none()
    if not pdf_file:
        raise RuntimeError("Source PDF metadata not found")

    content = ctx.storage.read_bytes(pdf_file.storage_key)

    summary = ingest_statement_pdf(
        db,
        settings=ctx.settings,
        storage=ctx.storage,
        profile_id=profile_id,
        profile_key=profile_key,
        bank_code=statement.bank_code,
        filename=pdf_file.original_filename,
        content=content,
        source=models.SourceType.UPLOAD,
        runtime_settings=bank_settings,
    )
    db.commit()
    return summary
