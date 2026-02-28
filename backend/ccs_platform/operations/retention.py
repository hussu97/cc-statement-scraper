from __future__ import annotations

from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any, Callable

from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from ccs_platform.core.settings import PlatformSettings
from ccs_platform.db import models
from ccs_platform.db.session import get_session_local


SessionFactory = Callable[[], Session]


def _utc_now() -> datetime:
    return datetime.now(UTC)


def _aware_utc(value: datetime) -> datetime:
    if value.tzinfo is None:
        return value.replace(tzinfo=UTC)
    return value.astimezone(UTC)


def _collect_old_ids(db: Session, stmt) -> list[int]:
    return [int(value) for value in db.execute(stmt).scalars().all()]


def _delete_by_ids(db: Session, *, model, ids: list[int], dry_run: bool) -> int:
    if not ids:
        return 0
    if not dry_run:
        db.execute(delete(model).where(model.id.in_(ids)))
    return len(ids)


def _delete_old_files(*, root_dir: Path, cutoff: datetime, dry_run: bool) -> int:
    if not root_dir.exists():
        return 0

    deleted = 0
    for file_path in sorted(path for path in root_dir.rglob("*") if path.is_file()):
        modified_at = _aware_utc(datetime.fromtimestamp(file_path.stat().st_mtime, tz=UTC))
        if modified_at >= cutoff:
            continue
        deleted += 1
        if not dry_run:
            file_path.unlink(missing_ok=True)
    return deleted


def enforce_retention(
    settings: PlatformSettings,
    *,
    dry_run: bool = True,
    now_utc: datetime | None = None,
    session_factory: SessionFactory | None = None,
) -> dict[str, Any]:
    if session_factory is None:
        session_factory = get_session_local()
    now = now_utc or _utc_now()

    jobs_cutoff = now - timedelta(days=max(1, int(settings.retention_jobs_days)))
    exports_cutoff = now - timedelta(days=max(1, int(settings.retention_exports_days)))
    audit_cutoff = now - timedelta(days=max(1, int(settings.retention_audit_events_days)))
    logs_cutoff = now - timedelta(days=max(1, int(settings.retention_logs_days)))
    uploads_cutoff = now - timedelta(days=max(1, int(settings.retention_uploads_days)))
    backups_cutoff = now - timedelta(days=max(1, int(settings.retention_backups_days)))

    terminal_job_statuses = {
        models.JobStatus.SUCCEEDED,
        models.JobStatus.FAILED,
        models.JobStatus.CANCELLED,
    }

    with session_factory() as db:
        old_job_ids = _collect_old_ids(
            db,
            select(models.Job.id)
            .where(models.Job.status.in_(terminal_job_statuses))
            .where(models.Job.finished_at.is_not(None))
            .where(models.Job.finished_at < jobs_cutoff),
        )
        deleted_jobs = _delete_by_ids(db, model=models.Job, ids=old_job_ids, dry_run=dry_run)

        old_export_ids = _collect_old_ids(
            db,
            select(models.Export.id)
            .where(models.Export.status.in_({models.ExportStatus.READY, models.ExportStatus.FAILED}))
            .where(models.Export.created_at < exports_cutoff),
        )
        deleted_exports = _delete_by_ids(db, model=models.Export, ids=old_export_ids, dry_run=dry_run)

        old_audit_ids = _collect_old_ids(
            db,
            select(models.AuditEvent.id).where(models.AuditEvent.created_at < audit_cutoff),
        )
        deleted_audit_events = _delete_by_ids(db, model=models.AuditEvent, ids=old_audit_ids, dry_run=dry_run)

        if not dry_run:
            db.commit()

    deleted_log_files = _delete_old_files(root_dir=settings.logs_dir, cutoff=logs_cutoff, dry_run=dry_run)
    deleted_upload_files = _delete_old_files(root_dir=settings.uploads_temp_dir, cutoff=uploads_cutoff, dry_run=dry_run)
    deleted_backup_files = _delete_old_files(root_dir=settings.backups_dir, cutoff=backups_cutoff, dry_run=dry_run)

    return {
        "dry_run": dry_run,
        "evaluated_at": now.isoformat(),
        "database": {
            "deleted_jobs": deleted_jobs,
            "deleted_exports": deleted_exports,
            "deleted_audit_events": deleted_audit_events,
        },
        "filesystem": {
            "deleted_log_files": deleted_log_files,
            "deleted_upload_files": deleted_upload_files,
            "deleted_backup_files": deleted_backup_files,
        },
    }
