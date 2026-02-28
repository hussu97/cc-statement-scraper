from __future__ import annotations

from pathlib import Path
from typing import Any

from sqlalchemy.orm import Session

from ccs_platform.db import models
from ccs_platform.application.statements.ingestion import ingest_statement_pdf
from .context import JobContext


def handle_upload_job(
    db: Session,
    job: models.Job,
    ctx: JobContext,
    *,
    profile_key: str,
) -> dict[str, Any]:
    payload = job.payload_json or {}
    uploads: list[dict[str, str]] = payload.get("uploads", [])
    ingested: list[dict[str, Any]] = []
    failures: list[dict[str, Any]] = []

    for idx, item in enumerate(uploads):
        ctx.assert_not_cancelled(db, job.id)
        bank_code = (item.get("bank_code") or "").upper().strip()
        file_path = Path(item.get("temp_path", ""))
        if not bank_code or not file_path.exists():
            failures.append(
                {
                    "bank_code": bank_code,
                    "file": str(file_path),
                    "error": "Missing bank code or upload file",
                }
            )
            continue

        content = file_path.read_bytes()
        try:
            summary = ingest_statement_pdf(
                db,
                settings=ctx.settings,
                storage=ctx.storage,
                profile_id=job.profile_id,
                profile_key=profile_key,
                bank_code=bank_code,
                filename=item.get("filename") or file_path.name,
                content=content,
                source=models.SourceType.UPLOAD,
            )
            ingested.append(summary)
            db.commit()
        except Exception as exc:  # noqa: BLE001
            db.rollback()
            failures.append(
                {
                    "bank_code": bank_code,
                    "file": str(file_path),
                    "error": str(exc),
                }
            )
        finally:
            file_path.unlink(missing_ok=True)

        ctx.update_progress(db, job, int((idx + 1) / max(len(uploads), 1) * 90))

    return {"ingested": ingested, "failures": failures}
