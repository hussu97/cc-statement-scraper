from __future__ import annotations

from datetime import UTC, datetime, timedelta
import os
from pathlib import Path
import sqlite3

from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker

from ccs_platform.core.settings import PlatformSettings
from ccs_platform.db import Base, models
from ccs_platform.operations.backups import create_backup_archive, restore_backup_archive, run_backup_restore_drill
from ccs_platform.operations.loadtest import evaluate_budget
from ccs_platform.operations.migrations import run_migration_preflight
from ccs_platform.operations.retention import enforce_retention
from ccs_platform.operations.slo import evaluate_slo_policy


def test_create_backup_archive_and_restore_sqlite(tmp_path: Path) -> None:
    source_db = tmp_path / "source.db"
    with sqlite3.connect(source_db) as conn:
        conn.execute("CREATE TABLE sample (id INTEGER PRIMARY KEY, name TEXT)")
        conn.execute("INSERT INTO sample (name) VALUES ('alice')")
        conn.commit()

    source_storage = tmp_path / "source-storage"
    source_storage.mkdir(parents=True, exist_ok=True)
    (source_storage / "statement.pdf").write_text("sample", encoding="utf-8")

    source_settings = PlatformSettings(
        database_url=f"sqlite:///{source_db}",
        local_storage_dir=source_storage,
        uploads_temp_dir=tmp_path / "source-incoming",
        logs_dir=tmp_path / "source-logs",
        backups_dir=tmp_path / "backups",
    )

    plan = create_backup_archive(source_settings, label="unit")
    assert plan.archive_path.exists()
    assert plan.manifest["database_backend"] == "sqlite"

    target_db = tmp_path / "target.db"
    target_storage = tmp_path / "target-storage"
    target_settings = PlatformSettings(
        database_url=f"sqlite:///{target_db}",
        local_storage_dir=target_storage,
        uploads_temp_dir=tmp_path / "target-incoming",
        logs_dir=tmp_path / "target-logs",
        backups_dir=tmp_path / "backups",
    )

    summary = restore_backup_archive(
        target_settings,
        archive_path=plan.archive_path,
        force=True,
        restore_archive=True,
    )
    assert summary["restored"] is True

    with sqlite3.connect(target_db) as conn:
        row = conn.execute("SELECT name FROM sample").fetchone()
        assert row is not None
        assert row[0] == "alice"

    assert (target_storage / "statement.pdf").exists()


def test_run_backup_restore_drill_for_sqlite(tmp_path: Path) -> None:
    db_path = tmp_path / "platform.db"
    with sqlite3.connect(db_path) as conn:
        conn.execute("CREATE TABLE sample (id INTEGER PRIMARY KEY, value TEXT)")
        conn.execute("INSERT INTO sample (value) VALUES ('ok')")
        conn.commit()

    settings = PlatformSettings(
        database_url=f"sqlite:///{db_path}",
        local_storage_dir=tmp_path / "storage",
        uploads_temp_dir=tmp_path / "incoming",
        logs_dir=tmp_path / "logs",
        backups_dir=tmp_path / "backups",
    )
    settings.local_storage_dir.mkdir(parents=True, exist_ok=True)

    result = run_backup_restore_drill(settings, output_dir=tmp_path / "backups", label="drill")
    assert result["drill_passed"] is True
    assert result["db_integrity"] in {"ok", "skipped"}


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


def test_run_migration_preflight_structural_checks() -> None:
    settings = PlatformSettings(database_url="sqlite:///./tmp_preflight.db")
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
