from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime
import hashlib
import json
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import tarfile
import tempfile
from typing import Any

from ccs_platform.core.settings import ROOT_DIR, PlatformSettings


MANIFEST_VERSION = 1


@dataclass(frozen=True)
class BackupPlan:
    archive_path: Path
    manifest: dict[str, Any]


def _utc_now() -> datetime:
    return datetime.now(UTC)


def _normalized_database_url(settings: PlatformSettings) -> str:
    return settings.resolved_database_url().strip()


def _database_backend(settings: PlatformSettings) -> str:
    url = _normalized_database_url(settings)
    if url.startswith("sqlite"):
        return "sqlite"
    if url.startswith("postgresql") or url.startswith("postgres"):
        return "postgresql"
    raise ValueError(f"Unsupported database backend URL: {url}")


def _sqlite_path_from_url(database_url: str) -> Path:
    prefixes = ("sqlite:///", "sqlite+pysqlite:///")
    for prefix in prefixes:
        if database_url.startswith(prefix):
            raw_path = database_url[len(prefix):]
            if raw_path == ":memory:":
                raise ValueError("In-memory SQLite is not supported for backup/restore")
            path = Path(raw_path)
            if not path.is_absolute():
                path = ROOT_DIR / path
            return path
    raise ValueError(f"Could not resolve sqlite file path from URL: {database_url}")


def _pg_cli_database_url(database_url: str) -> str:
    if database_url.startswith("postgresql+psycopg://"):
        return f"postgresql://{database_url[len('postgresql+psycopg://'):]}"
    return database_url


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _sanitize_label(label: str | None) -> str:
    if not label:
        return ""
    cleaned = re.sub(r"[^a-zA-Z0-9._-]+", "-", label.strip())
    cleaned = cleaned.strip("-_.")
    return cleaned[:64]


def _run_command(cmd: list[str]) -> None:
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        stderr = (result.stderr or "").strip()
        raise RuntimeError(f"Command failed ({' '.join(cmd[:2])}): {stderr or 'unknown error'}")


def _build_manifest(staging_dir: Path, *, database_backend: str, database_artifact: str) -> dict[str, Any]:
    artifacts: list[dict[str, Any]] = []
    for file_path in sorted(path for path in staging_dir.rglob("*") if path.is_file()):
        rel_path = str(file_path.relative_to(staging_dir))
        if rel_path == "manifest.json":
            continue
        artifacts.append(
            {
                "path": rel_path,
                "size_bytes": file_path.stat().st_size,
                "sha256": _sha256(file_path),
            }
        )

    return {
        "version": MANIFEST_VERSION,
        "created_at": _utc_now().isoformat(),
        "database_backend": database_backend,
        "database_artifact": database_artifact,
        "artifacts": artifacts,
    }


def _snapshot_database(settings: PlatformSettings, payload_dir: Path) -> str:
    backend = _database_backend(settings)
    database_url = _normalized_database_url(settings)

    db_dir = payload_dir / "database"
    db_dir.mkdir(parents=True, exist_ok=True)

    if backend == "sqlite":
        source_db = _sqlite_path_from_url(database_url)
        if not source_db.exists():
            raise FileNotFoundError(f"SQLite DB file not found: {source_db}")
        target = db_dir / "platform.sqlite3"
        shutil.copy2(source_db, target)
        return "payload/database/platform.sqlite3"

    target_sql = db_dir / "platform.sql"
    pg_url = _pg_cli_database_url(database_url)
    _run_command([
        "pg_dump",
        "--no-owner",
        "--no-privileges",
        "--file",
        str(target_sql),
        pg_url,
    ])
    return "payload/database/platform.sql"


def _snapshot_directory(source: Path, destination: Path) -> None:
    if not source.exists():
        return
    shutil.copytree(source, destination, dirs_exist_ok=True)


def create_backup_archive(
    settings: PlatformSettings,
    *,
    output_dir: Path | None = None,
    label: str | None = None,
    include_archive: bool = True,
    include_uploads: bool = False,
    include_logs: bool = False,
) -> BackupPlan:
    backup_root = output_dir or settings.backups_dir
    backup_root.mkdir(parents=True, exist_ok=True)

    ts = _utc_now().strftime("%Y%m%dT%H%M%SZ")
    label_suffix = _sanitize_label(label)
    name = f"ccs-backup-{ts}" + (f"-{label_suffix}" if label_suffix else "")
    archive_path = backup_root / f"{name}.tar.gz"

    staging_dir = Path(tempfile.mkdtemp(prefix=f"{name}-", dir=str(backup_root)))
    payload_dir = staging_dir / "payload"
    payload_dir.mkdir(parents=True, exist_ok=True)

    try:
        db_artifact = _snapshot_database(settings, payload_dir)

        if include_archive:
            _snapshot_directory(settings.local_storage_dir, payload_dir / "storage")
        if include_uploads:
            _snapshot_directory(settings.uploads_temp_dir, payload_dir / "incoming")
        if include_logs:
            _snapshot_directory(settings.logs_dir, payload_dir / "logs")

        manifest = _build_manifest(
            staging_dir,
            database_backend=_database_backend(settings),
            database_artifact=db_artifact,
        )
        (staging_dir / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")

        with tarfile.open(archive_path, "w:gz") as tar:
            tar.add(staging_dir / "manifest.json", arcname="manifest.json")
            tar.add(payload_dir, arcname="payload")

        return BackupPlan(archive_path=archive_path, manifest=manifest)
    finally:
        shutil.rmtree(staging_dir, ignore_errors=True)


def _load_manifest(extracted_dir: Path) -> dict[str, Any]:
    manifest_path = extracted_dir / "manifest.json"
    if not manifest_path.exists():
        raise FileNotFoundError("Backup archive missing manifest.json")
    return json.loads(manifest_path.read_text(encoding="utf-8"))


def _verify_manifest(extracted_dir: Path, manifest: dict[str, Any]) -> None:
    for artifact in manifest.get("artifacts", []):
        rel_path = artifact["path"]
        expected_hash = artifact["sha256"]
        abs_path = extracted_dir / rel_path
        if not abs_path.exists():
            raise FileNotFoundError(f"Backup artifact missing: {rel_path}")
        if _sha256(abs_path) != expected_hash:
            raise RuntimeError(f"Backup artifact checksum mismatch: {rel_path}")


def _restore_sqlite_database(*, source_file: Path, target_file: Path, force: bool) -> None:
    if target_file.exists() and not force:
        raise RuntimeError(f"Target DB exists ({target_file}); pass force=True to overwrite")
    target_file.parent.mkdir(parents=True, exist_ok=True)
    if target_file.exists():
        target_file.unlink()
    shutil.copy2(source_file, target_file)


def _restore_postgres_database(*, source_file: Path, database_url: str, force: bool) -> None:
    if not force:
        raise RuntimeError("Postgres restore requires force=True")
    pg_url = _pg_cli_database_url(database_url)
    _run_command([
        "psql",
        "-v",
        "ON_ERROR_STOP=1",
        "--file",
        str(source_file),
        pg_url,
    ])


def _restore_directory(*, source_dir: Path, target_dir: Path, force: bool) -> None:
    if not source_dir.exists():
        return
    if target_dir.exists() and any(target_dir.iterdir()) and not force:
        raise RuntimeError(f"Target directory not empty ({target_dir}); pass force=True to overwrite")
    if target_dir.exists() and force:
        shutil.rmtree(target_dir)
    target_dir.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source_dir, target_dir, dirs_exist_ok=True)


def restore_backup_archive(
    settings: PlatformSettings,
    *,
    archive_path: Path,
    force: bool = False,
    restore_archive: bool = True,
    restore_uploads: bool = False,
    restore_logs: bool = False,
) -> dict[str, Any]:
    if not archive_path.exists():
        raise FileNotFoundError(f"Backup archive not found: {archive_path}")

    extracted_dir = Path(tempfile.mkdtemp(prefix="ccs-restore-"))
    try:
        with tarfile.open(archive_path, "r:gz") as tar:
            tar.extractall(path=extracted_dir)

        manifest = _load_manifest(extracted_dir)
        _verify_manifest(extracted_dir, manifest)

        database_backend = manifest.get("database_backend")
        database_artifact = extracted_dir / str(manifest.get("database_artifact", ""))
        if not database_artifact.exists():
            raise FileNotFoundError(f"Database artifact not found: {database_artifact}")

        database_url = _normalized_database_url(settings)
        if database_backend == "sqlite":
            target_db = _sqlite_path_from_url(database_url)
            _restore_sqlite_database(source_file=database_artifact, target_file=target_db, force=force)
        elif database_backend == "postgresql":
            _restore_postgres_database(source_file=database_artifact, database_url=database_url, force=force)
        else:
            raise RuntimeError(f"Unsupported database backend in backup: {database_backend}")

        payload = extracted_dir / "payload"
        if restore_archive:
            _restore_directory(source_dir=payload / "storage", target_dir=settings.local_storage_dir, force=force)
        if restore_uploads:
            _restore_directory(source_dir=payload / "incoming", target_dir=settings.uploads_temp_dir, force=force)
        if restore_logs:
            _restore_directory(source_dir=payload / "logs", target_dir=settings.logs_dir, force=force)

        return {
            "restored": True,
            "archive_path": str(archive_path),
            "database_backend": database_backend,
            "artifact_count": len(manifest.get("artifacts", [])),
        }
    finally:
        shutil.rmtree(extracted_dir, ignore_errors=True)


def run_backup_restore_drill(
    settings: PlatformSettings,
    *,
    output_dir: Path | None = None,
    label: str | None = "drill",
) -> dict[str, Any]:
    plan = create_backup_archive(
        settings,
        output_dir=output_dir,
        label=label,
        include_archive=True,
        include_uploads=False,
        include_logs=False,
    )

    extracted_dir = Path(tempfile.mkdtemp(prefix="ccs-drill-"))
    try:
        with tarfile.open(plan.archive_path, "r:gz") as tar:
            tar.extractall(path=extracted_dir)

        manifest = _load_manifest(extracted_dir)
        _verify_manifest(extracted_dir, manifest)

        db_check = "skipped"
        db_artifact = extracted_dir / str(manifest.get("database_artifact", ""))
        if manifest.get("database_backend") == "sqlite" and db_artifact.exists():
            with sqlite3.connect(str(db_artifact)) as conn:
                row = conn.execute("PRAGMA integrity_check").fetchone()
                if not row or str(row[0]).lower() != "ok":
                    raise RuntimeError(f"SQLite integrity check failed: {row}")
            db_check = "ok"

        return {
            "drill_passed": True,
            "backup_archive": str(plan.archive_path),
            "artifact_count": len(manifest.get("artifacts", [])),
            "db_integrity": db_check,
        }
    finally:
        shutil.rmtree(extracted_dir, ignore_errors=True)
