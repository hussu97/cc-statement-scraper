from __future__ import annotations

from datetime import UTC, datetime, timedelta
import os
from pathlib import Path

from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker

from ccs_platform.core.settings import PlatformSettings
from ccs_platform.db import Base, models
from ccs_platform.operations.loadtest import evaluate_budget
from ccs_platform.operations.migrations import run_migration_preflight
from ccs_platform.operations.retention import enforce_retention
from ccs_platform.operations.slo import evaluate_slo_policy


def test_enforce_retention_deletes_old_rows_and_files(tmp_path: Path) -> None:
    engine = create_engine("sqlite:///:memory:", future=True)
    Base.metadata.create_all(engine)
    Session = sessionmaker(bind=engine, future=True)

    now = datetime.now(UTC)
    old = now - timedelta(days=120)

    with Session() as db:
        profile = models.Profile(key="retention", name="Retention", is_default=False)
        db.add(profile)
        db.flush()

        old_job = models.Job(
            profile_id=profile.id,
            job_type=models.JobType.RECLASSIFY,
            queue_name="default",
            status=models.JobStatus.SUCCEEDED,
            payload_json={},
            finished_at=old,
        )
        fresh_job = models.Job(
            profile_id=profile.id,
            job_type=models.JobType.RECLASSIFY,
            queue_name="default",
            status=models.JobStatus.SUCCEEDED,
            payload_json={},
            finished_at=now,
        )
        old_export = models.Export(
            profile_id=profile.id,
            export_type="workbook",
            status=models.ExportStatus.READY,
            created_at=old,
        )
        old_audit = models.AuditEvent(
            profile_id=profile.id,
            event_type="old",
            entity_type="test",
            entity_id="1",
            created_at=old,
        )
        db.add_all([old_job, fresh_job, old_export, old_audit])
        db.commit()

    logs_dir = tmp_path / "logs"
    uploads_dir = tmp_path / "incoming"
    backups_dir = tmp_path / "backups"
    logs_dir.mkdir(parents=True, exist_ok=True)
    uploads_dir.mkdir(parents=True, exist_ok=True)
    backups_dir.mkdir(parents=True, exist_ok=True)

    old_file = logs_dir / "old.log"
    old_file.write_text("old", encoding="utf-8")
    fresh_file = logs_dir / "fresh.log"
    fresh_file.write_text("fresh", encoding="utf-8")

    old_mtime = (now - timedelta(days=60)).timestamp()
    fresh_mtime = now.timestamp()
    os.utime(old_file, (old_mtime, old_mtime))
    os.utime(fresh_file, (fresh_mtime, fresh_mtime))

    settings = PlatformSettings(
        database_url="sqlite:///:memory:",
        local_storage_dir=tmp_path / "storage",
        uploads_temp_dir=uploads_dir,
        logs_dir=logs_dir,
        backups_dir=backups_dir,
        retention_jobs_days=90,
        retention_exports_days=90,
        retention_audit_events_days=90,
        retention_logs_days=30,
        retention_uploads_days=30,
        retention_backups_days=30,
    )

    dry_run = enforce_retention(settings, dry_run=True, now_utc=now, session_factory=Session)
    assert dry_run["database"]["deleted_jobs"] == 1
    assert dry_run["filesystem"]["deleted_log_files"] == 1

    applied = enforce_retention(settings, dry_run=False, now_utc=now, session_factory=Session)
    assert applied["database"]["deleted_jobs"] == 1
    assert applied["database"]["deleted_exports"] == 1
    assert applied["database"]["deleted_audit_events"] == 1
    assert applied["filesystem"]["deleted_log_files"] == 1
    assert not old_file.exists()
    assert fresh_file.exists()

    with Session() as db:
        remaining_jobs = db.execute(select(models.Job)).scalars().all()
        assert len(remaining_jobs) == 1


def test_run_migration_preflight_structural_checks(tmp_path: Path) -> None:
    settings = PlatformSettings(database_url=f"sqlite:///{tmp_path / 'preflight.db'}")
    report = run_migration_preflight(settings, check_database_state=False)

    assert report["head_count"] == 1
    assert report["revision_count"] >= 1
    assert isinstance(report["issues"], list)


def test_evaluate_budget_reports_violations() -> None:
    result = {
        "error_rate": 0.05,
        "latency_ms": {"p95": 2100},
        "throughput_rps": 1.0,
    }
    budget = {
        "max_error_rate": 0.02,
        "max_p95_ms": 1500,
        "min_rps": 5.0,
    }

    violations = evaluate_budget(result=result, budget=budget)
    assert len(violations) == 3


def test_evaluate_slo_policy() -> None:
    policy = {
        "objectives": {
            "api_availability": {"target": 0.99, "alert_below": 0.95},
            "api_avg_latency_ms": {"target": 100, "alert_above": 200},
            "job_success_rate": {"target": 0.9, "alert_below": 0.8},
            "queue_backlog_slo": {"required_status": "ok"},
        }
    }
    metrics = {
        "requests": {
            "total": 100,
            "avg_duration_ms": 50,
            "by_status": {"200": 99, "500": 1},
        },
        "jobs": {
            "events": {
                "succeeded": 90,
                "failed": 5,
                "cancelled": 5,
            },
            "queue_backlog": {
                "slo": {
                    "status": "ok",
                }
            },
        },
    }

    report = evaluate_slo_policy(policy=policy, metrics=metrics)
    assert report["overall_status"] == "ok"
    assert report["alerts"] == []
