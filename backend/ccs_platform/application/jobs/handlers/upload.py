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
        storage_key = item.get("storage_key") or ""
        temp_path_str = item.get("temp_path") or ""

        if storage_key:
            try:
                content = ctx.storage.read_bytes(storage_key)
            except Exception as exc:  # noqa: BLE001
                failures.append({"bank_code": bank_code, "error": f"Failed to read staging file: {exc}"})
                continue
        elif temp_path_str:
            file_path = Path(temp_path_str)
            if not file_path.exists():
                failures.append({"bank_code": bank_code, "error": "Missing staging file"})
                continue
            content = file_path.read_bytes()
        else:
            failures.append({"bank_code": bank_code, "error": "No storage_key or temp_path in payload"})
            continue

        if not bank_code or not content:
            failures.append({"bank_code": bank_code, "error": "Missing bank code or empty content"})
            continue

        try:
            summary = ingest_statement_pdf(
                db,
                settings=ctx.settings,
                storage=ctx.storage,
                profile_id=job.profile_id,
                profile_key=profile_key,
                bank_code=bank_code,
                filename=item.get("filename") or (Path(temp_path_str).name if temp_path_str else "statement.pdf"),
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
                    "error": str(exc),
                }
            )
        finally:
            if storage_key:
                try:
                    ctx.storage.delete(storage_key)
                except Exception:  # noqa: BLE001
                    pass  # staging cleanup is best-effort
            elif temp_path_str:
                Path(temp_path_str).unlink(missing_ok=True)

        ctx.update_progress(db, job, int((idx + 1) / max(len(uploads), 1) * 90))

    return {"ingested": ingested, "failures": failures}
