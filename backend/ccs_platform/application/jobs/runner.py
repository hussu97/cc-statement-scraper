from __future__ import annotations

import fnmatch
import hashlib
import os
import threading
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from ccs_platform.adapters.banks.browser.downloader import BrowserDownloadError, run_end_to_end_downloads
from ccs_platform.core.bank_config import load_app_config
from ccs_platform.core.metrics import METRICS
from ccs_platform.core.runtime_settings import apply_runtime_settings_to_process_env, get_runtime_settings_as_dict
from ccs_platform.adapters.banks.parsers import parse_adcb_statement, parse_enbd_statement, parse_fab_statement
from ccs_platform.db import models
from ccs_platform.core.settings import PlatformSettings
from ccs_platform.db.session import SessionLocal
from ccs_platform.application.banks.capabilities import (
    build_bank_scrape_config,
    get_enabled_banks,
    is_month_supported,
    resolve_requested_months,
    supports_multi_month,
)
from ccs_platform.domain.categorization.engine import reclassify_statement_lines
from ccs_platform.application.statements.ingestion import ingest_statement_pdf
from ccs_platform.adapters.storage import StorageAdapter
from ccs_platform.application.exports.workbook import build_yearly_workbook_from_statements


EXPECTED_SAMPLE_COUNTS = {
    "FAB": 49,
    "ADCB": 9,
    "ENBD": 8,
}


class JobRunner:
    def __init__(self, *, settings: PlatformSettings, storage: StorageAdapter) -> None:
        self.settings = settings
        self.storage = storage
        self.executor = ThreadPoolExecutor(max_workers=settings.max_worker_threads)

    def shutdown(self) -> None:
        self.executor.shutdown(wait=False, cancel_futures=True)

    def enqueue(self, job_id: int) -> None:
        METRICS.record_job_event("enqueued")
        self.executor.submit(self._run_job, job_id)

    def _is_cancel_requested(self, job: models.Job) -> bool:
        return job.status == models.JobStatus.CANCELLED or job.cancel_requested_at is not None

    def _compute_retry_delay_seconds(self, *, job_id: int, attempt_count: int) -> int:
        base_seconds = max(1, int(self.settings.job_retry_base_seconds))
        max_seconds = max(base_seconds, int(self.settings.job_retry_max_delay_seconds))
        jitter_seconds = max(0, int(self.settings.job_retry_jitter_seconds))

        exponent = max(0, attempt_count - 1)
        delay = min(max_seconds, base_seconds * (2**exponent))
        if jitter_seconds <= 0:
            return delay

        digest = hashlib.sha256(f"{job_id}:{attempt_count}".encode("utf-8")).digest()
        jitter = int.from_bytes(digest[:4], "big") % (jitter_seconds + 1)
        return min(max_seconds, delay + jitter)

    def _heartbeat_loop(self, *, job_id: int, stop_event: threading.Event) -> None:
        interval_seconds = max(1, int(self.settings.job_heartbeat_interval_seconds))
        terminal_states = {
            models.JobStatus.SUCCEEDED,
            models.JobStatus.FAILED,
            models.JobStatus.CANCELLED,
        }

        while not stop_event.wait(interval_seconds):
            try:
                with SessionLocal() as hb_db:
                    row = hb_db.get(models.Job, job_id)
                    if row is None:
                        return
                    if row.status in terminal_states:
                        return
                    row.last_heartbeat_at = datetime.now(UTC)
                    hb_db.commit()
            except Exception:  # noqa: BLE001
                METRICS.record_job_event("heartbeat_error")
                return

    def _schedule_retry(self, db: Session, job: models.Job, *, error_message: str) -> bool:
        max_attempts = max(1, int(job.max_attempts or 1))
        if int(job.attempt_count or 0) >= max_attempts:
            return False

        now = datetime.now(UTC)
        delay_seconds = self._compute_retry_delay_seconds(
            job_id=job.id,
            attempt_count=int(job.attempt_count or 1),
        )
        job.status = models.JobStatus.QUEUED
        job.next_retry_at = now + timedelta(seconds=delay_seconds)
        job.error_message = error_message
        job.progress_percent = 0
        job.finished_at = None
        job.last_heartbeat_at = now
        db.commit()

        METRICS.record_job_event("retry_scheduled")
        return True

    def _run_job(self, job_id: int) -> None:
        with SessionLocal() as db:
            job = db.get(models.Job, job_id)
            if not job:
                METRICS.record_job_event("missing")
                return
            if self._is_cancel_requested(job):
                if job.status != models.JobStatus.CANCELLED:
                    job.status = models.JobStatus.CANCELLED
                    job.finished_at = datetime.now(UTC)
                    job.last_heartbeat_at = datetime.now(UTC)
                    db.commit()
                METRICS.record_job_event("cancelled_before_start")
                return
            if job.status not in {models.JobStatus.QUEUED, models.JobStatus.RUNNING}:
                METRICS.record_job_event("skip_not_runnable")
                return

            now = datetime.now(UTC)
            if job.next_retry_at is not None:
                retry_at = job.next_retry_at
                if retry_at.tzinfo is None:
                    retry_at = retry_at.replace(tzinfo=UTC)
                if retry_at > now:
                    METRICS.record_job_event("retry_not_due")
                    return

            if job.status == models.JobStatus.QUEUED:
                job.status = models.JobStatus.RUNNING
            job.started_at = now
            job.next_retry_at = None
            job.progress_percent = max(1, int(job.progress_percent or 0))
            job.attempt_count = int(job.attempt_count or 0) + 1
            job.last_heartbeat_at = now
            db.commit()
            METRICS.record_job_event("started")

            heartbeat_stop = threading.Event()
            heartbeat_thread = threading.Thread(
                target=self._heartbeat_loop,
                kwargs={"job_id": job_id, "stop_event": heartbeat_stop},
                daemon=True,
            )
            heartbeat_thread.start()

            try:
                result = self._dispatch_job(db, job)
                db.refresh(job)
                outcome = "succeeded"
                if not self._is_cancel_requested(job):
                    job.status = models.JobStatus.SUCCEEDED
                else:
                    job.status = models.JobStatus.CANCELLED
                    outcome = "cancelled"
                job.progress_percent = 100
                job.result_json = result
                job.finished_at = datetime.now(UTC)
                job.next_retry_at = None
                job.error_message = None
                job.last_heartbeat_at = datetime.now(UTC)
                db.commit()
                METRICS.record_job_event(outcome)
            except Exception as exc:  # noqa: BLE001
                db.rollback()
                job = db.get(models.Job, job_id)
                if not job:
                    METRICS.record_job_event("missing_after_error")
                    return
                if self._is_cancel_requested(job):
                    job.status = models.JobStatus.CANCELLED
                    job.finished_at = datetime.now(UTC)
                    job.last_heartbeat_at = datetime.now(UTC)
                    db.commit()
                    METRICS.record_job_event("cancelled")
                    return
                if self._schedule_retry(db, job, error_message=str(exc)):
                    return
                job.status = models.JobStatus.FAILED
                job.error_message = str(exc)
                job.result_json = {
                    "poison_job": True,
                    "attempt_count": int(job.attempt_count or 0),
                    "max_attempts": int(job.max_attempts or 0),
                }
                job.finished_at = datetime.now(UTC)
                job.last_heartbeat_at = datetime.now(UTC)
                db.commit()
                METRICS.record_job_event("failed")
            finally:
                heartbeat_stop.set()
                heartbeat_thread.join(timeout=2)

    def _dispatch_job(self, db: Session, job: models.Job) -> dict[str, Any]:
        profile = db.get(models.Profile, job.profile_id)
        if profile is None:
            raise RuntimeError(f"Profile not found for job {job.id}: {job.profile_id}")

        # TODO: apply_runtime_settings_to_process_env is still needed for parsers that read env vars directly.
        apply_runtime_settings_to_process_env(db, profile_id=job.profile_id)
        if job.job_type == models.JobType.UPLOAD:
            return self._process_upload_job(db, job, profile_key=profile.key)
        if job.job_type == models.JobType.SCRAPE:
            credentials = get_runtime_settings_as_dict(db, profile_id=job.profile_id)
            return self._process_scrape_job(db, job, profile_key=profile.key, credentials=credentials)
        if job.job_type == models.JobType.RECLASSIFY:
            return self._process_reclassify_job(db, job)
        if job.job_type == models.JobType.EXPORT_WORKBOOK:
            return self._process_export_workbook_job(db, job, profile_key=profile.key)
        if job.job_type == models.JobType.PARSER_VALIDATE:
            return self._process_parser_validate_job(db, job)
        if job.job_type == models.JobType.BANK_CONNECTION_TEST:
            return self._process_bank_connection_test_job(db, job)
        if job.job_type == models.JobType.REPARSE_STATEMENT:
            return self._process_reparse_statement_job(db, job, profile_key=profile.key)
        raise ValueError(f"Unsupported job_type: {job.job_type}")

    def _assert_not_cancelled(self, db: Session, job_id: int) -> None:
        row = db.execute(
            select(models.Job.status, models.Job.cancel_requested_at).where(models.Job.id == job_id)
        ).one()
        status, cancel_requested_at = row
        if status == models.JobStatus.CANCELLED or cancel_requested_at is not None:
            raise RuntimeError(f"Job {job_id} cancelled")

    def _update_progress(self, db: Session, job: models.Job, progress: int) -> None:
        job.progress_percent = max(0, min(progress, 99))
        job.last_heartbeat_at = datetime.now(UTC)
        db.commit()

    def _find_latest_matching_pdf(self, app_config, bank_code: str) -> Path | None:
        bank_cfg = app_config.banks[bank_code]
        patterns = bank_cfg.get("file_glob_patterns", [])
        candidates: list[Path] = []
        for directory in [app_config.paths.incoming_dir, app_config.paths.downloads_dir]:
            if not directory.exists():
                continue
            for path in directory.iterdir():
                if not path.is_file() or path.suffix.lower() != ".pdf":
                    continue
                if any(fnmatch.fnmatch(path.name.lower(), pattern.lower()) for pattern in patterns):
                    candidates.append(path)

        if not candidates:
            return None
        return max(candidates, key=lambda p: p.stat().st_mtime)

    def _resolve_downloaded_pdf_from_diagnostics(
        self,
        *,
        bank_cfg: dict[str, Any],
        requested_month: str,
    ) -> tuple[Path | None, dict[str, Any] | None]:
        diagnostics = bank_cfg.get("download_diagnostics")
        if not isinstance(diagnostics, dict):
            return None, None

        requested_token = str(requested_month or "").strip()

        def _pick_by_month(entries: Any) -> dict[str, Any] | None:
            if not isinstance(entries, list):
                return None
            normalized: list[dict[str, Any]] = [row for row in entries if isinstance(row, dict)]
            for row in normalized:
                if str(row.get("month") or "").strip() == requested_token:
                    return row
            for row in normalized:
                if str(row.get("month") or "").strip().lower() == "latest":
                    return row
            if len(normalized) == 1:
                return normalized[0]
            return None

        skipped = _pick_by_month(diagnostics.get("skipped_unavailable"))
        if skipped is not None:
            return None, skipped

        failed = _pick_by_month(diagnostics.get("failed"))
        if failed is not None:
            return None, failed

        downloaded = _pick_by_month(diagnostics.get("downloaded"))
        if downloaded is None:
            return None, diagnostics

        path_value = str(downloaded.get("path") or "").strip()
        if not path_value:
            return None, downloaded

        resolved = Path(path_value)
        if not resolved.exists():
            return None, {
                "month": str(downloaded.get("month") or requested_token),
                "reason": "download_file_not_found",
                "path": path_value,
            }

        return resolved, downloaded

    def _process_upload_job(self, db: Session, job: models.Job, *, profile_key: str) -> dict[str, Any]:
        payload = job.payload_json or {}
        uploads: list[dict[str, str]] = payload.get("uploads", [])
        ingested: list[dict[str, Any]] = []
        failures: list[dict[str, Any]] = []

        for idx, item in enumerate(uploads):
            self._assert_not_cancelled(db, job.id)
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
                    settings=self.settings,
                    storage=self.storage,
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

            self._update_progress(db, job, int((idx + 1) / max(len(uploads), 1) * 90))

        return {"ingested": ingested, "failures": failures}

    def _process_scrape_job(self, db: Session, job: models.Job, *, profile_key: str, credentials: dict[str, str] | None = None) -> dict[str, Any]:
        payload = job.payload_json or {}
        banks = sorted({token.upper().strip() for token in payload.get("banks", []) if token and token.strip()})
        months = resolve_requested_months(
            months=payload.get("months", []),
            month_from=payload.get("month_from"),
            month_to=payload.get("month_to"),
            timezone=self.settings.timezone,
        )
        download = bool(payload.get("download", True))
        headless = bool(payload.get("headless", False))
        login_timeout_minutes = int(payload.get("login_timeout_minutes", 20))

        available_banks = get_enabled_banks(db, banks if banks else None, profile_id=job.profile_id)
        if banks:
            found_codes = {bank.code for bank in available_banks}
            denied = [bank_code for bank_code in banks if bank_code not in found_codes]
            if denied:
                raise RuntimeError(f"Banks not enabled for profile: {', '.join(denied)}")
        bank_map = {bank.code: bank for bank in available_banks}

        app_cfg = load_app_config()
        app_cfg.paths.incoming_dir = app_cfg.paths.data_dir / "incoming" / profile_key
        app_cfg.paths.state_dir = app_cfg.paths.data_dir / "state" / "profiles" / profile_key
        app_cfg.paths.downloads_dir = app_cfg.paths.incoming_dir
        app_cfg.paths.incoming_dir.mkdir(parents=True, exist_ok=True)
        app_cfg.paths.state_dir.mkdir(parents=True, exist_ok=True)

        results: list[dict[str, Any]] = []
        total_items = max(len(available_banks) * len(months), 1)
        done = 0

        for bank_code, bank in bank_map.items():
            if supports_multi_month(bank) and len(months) > 1 and download:
                supported_items: list[tuple[str, models.JobItem]] = []
                month_index: dict[str, models.JobItem] = {}

                for month in months:
                    self._assert_not_cancelled(db, job.id)
                    job_item = db.execute(
                        select(models.JobItem).where(
                            models.JobItem.job_id == job.id,
                            models.JobItem.bank_code == bank_code,
                            models.JobItem.target_month == month,
                        )
                    ).scalar_one_or_none()

                    if job_item is None:
                        job_item = models.JobItem(
                            job_id=job.id,
                            bank_code=bank_code,
                            target_month=month,
                            status="queued",
                        )
                        db.add(job_item)
                        db.flush()
                    month_index[month] = job_item

                    if not is_month_supported(bank, month, timezone=self.settings.timezone):
                        job_item.status = "MANUAL_REQUIRED"
                        job_item.message = (
                            f"{bank_code} does not support automated scrape for month {month}; upload PDF manually"
                        )
                        db.commit()
                        results.append(
                            {
                                "bank_code": bank_code,
                                "month": month,
                                "status": "MANUAL_REQUIRED",
                            }
                        )
                        done += 1
                        self._update_progress(db, job, int(done / total_items * 90))
                        continue

                    supported_items.append((month, job_item))

                if not supported_items:
                    continue

                for _, item in supported_items:
                    item.status = "running"
                    item.message = "Running multi-month scrape in one browser session"
                db.commit()

                bank_cfg_copy = {bank_code: dict(app_cfg.banks[bank_code])}
                last_month = supported_items[-1][0]
                bank_cfg_copy[bank_code].update(build_bank_scrape_config(bank_code, last_month))
                bank_cfg_copy[bank_code]["requested_months"] = [month for month, _ in supported_items]

                scoped_cfg = load_app_config()
                scoped_cfg.banks = bank_cfg_copy
                scoped_cfg.paths.incoming_dir = app_cfg.paths.incoming_dir
                scoped_cfg.paths.state_dir = app_cfg.paths.state_dir
                scoped_cfg.paths.downloads_dir = app_cfg.paths.downloads_dir
                scoped_cfg.paths.incoming_dir.mkdir(parents=True, exist_ok=True)
                scoped_cfg.paths.state_dir.mkdir(parents=True, exist_ok=True)

                try:
                    run_end_to_end_downloads(
                        app_config=scoped_cfg,
                        scheduled=False,
                        login_timeout_minutes=login_timeout_minutes,
                        headless=headless,
                        credentials=credentials,
                    )

                    diagnostics = bank_cfg_copy[bank_code].get("download_diagnostics") or {}
                    downloaded_entries = diagnostics.get("downloaded", [])
                    skipped_entries = diagnostics.get("skipped_unavailable", [])
                    failed_entries = diagnostics.get("failed", [])

                    downloaded_by_month = {
                        str(item.get("month") or ""): item
                        for item in downloaded_entries
                        if str(item.get("month") or "").strip()
                    }
                    skipped_by_month = {
                        str(item.get("month") or ""): item
                        for item in skipped_entries
                        if str(item.get("month") or "").strip()
                    }
                    failed_by_month = {
                        str(item.get("month") or ""): item
                        for item in failed_entries
                        if str(item.get("month") or "").strip()
                    }

                    for month, _ in supported_items:
                        self._assert_not_cancelled(db, job.id)
                        job_item = month_index[month]

                        skipped = skipped_by_month.get(month)
                        if skipped is not None:
                            reason = str(skipped.get("reason") or "statement_period_not_available")
                            job_item.status = "SKIPPED_UNAVAILABLE"
                            job_item.message = f"Skipped month {month}: {reason}"
                            job_item.metadata_json = {"diagnostic": skipped}
                            db.commit()
                            results.append(
                                {
                                    "bank_code": bank_code,
                                    "month": month,
                                    "status": "SKIPPED_UNAVAILABLE",
                                    "diagnostic": skipped,
                                }
                            )
                            done += 1
                            self._update_progress(db, job, int(done / total_items * 90))
                            continue

                        downloaded = downloaded_by_month.get(month)
                        if downloaded is None:
                            failed = failed_by_month.get(month) or {
                                "month": month,
                                "reason": "no_download_record_for_month",
                            }
                            reason = str(failed.get("reason") or "download_failed")
                            job_item.status = "failed"
                            job_item.message = f"Failed month {month}: {reason}"
                            job_item.metadata_json = {"diagnostic": failed}
                            db.commit()
                            results.append(
                                {
                                    "bank_code": bank_code,
                                    "month": month,
                                    "status": "failed",
                                    "error": reason,
                                    "diagnostic": failed,
                                }
                            )
                            done += 1
                            self._update_progress(db, job, int(done / total_items * 90))
                            continue

                        path_value = str(downloaded.get("path") or "").strip()
                        if not path_value:
                            failed = {
                                "month": month,
                                "reason": "download_path_missing",
                            }
                            job_item.status = "failed"
                            job_item.message = f"Failed month {month}: download path missing"
                            job_item.metadata_json = {"diagnostic": failed}
                            db.commit()
                            results.append(
                                {
                                    "bank_code": bank_code,
                                    "month": month,
                                    "status": "failed",
                                    "error": "download_path_missing",
                                    "diagnostic": failed,
                                }
                            )
                            done += 1
                            self._update_progress(db, job, int(done / total_items * 90))
                            continue

                        month_pdf = Path(path_value)
                        if not month_pdf.exists():
                            failed = {
                                "month": month,
                                "reason": "download_file_not_found",
                                "path": path_value,
                            }
                            job_item.status = "failed"
                            job_item.message = f"Failed month {month}: downloaded file not found"
                            job_item.metadata_json = {"diagnostic": failed}
                            db.commit()
                            results.append(
                                {
                                    "bank_code": bank_code,
                                    "month": month,
                                    "status": "failed",
                                    "error": "download_file_not_found",
                                    "diagnostic": failed,
                                }
                            )
                            done += 1
                            self._update_progress(db, job, int(done / total_items * 90))
                            continue

                        try:
                            summary = ingest_statement_pdf(
                                db,
                                settings=self.settings,
                                storage=self.storage,
                                profile_id=job.profile_id,
                                profile_key=profile_key,
                                bank_code=bank_code,
                                filename=month_pdf.name,
                                content=month_pdf.read_bytes(),
                                source=models.SourceType.SCRAPE,
                            )
                            db.commit()

                            job_item.status = "succeeded"
                            job_item.message = f"Ingested statement {summary['statement_reference']}"
                            job_item.metadata_json = {"summary": summary, "diagnostic": downloaded}
                            db.commit()

                            results.append(
                                {
                                    "bank_code": bank_code,
                                    "month": month,
                                    "status": "succeeded",
                                    "summary": summary,
                                    "diagnostic": downloaded,
                                }
                            )
                        except Exception as exc:  # noqa: BLE001
                            db.rollback()
                            job_item = db.get(models.JobItem, job_item.id)
                            if job_item:
                                job_item.status = "failed"
                                job_item.message = str(exc)
                                job_item.metadata_json = {"diagnostic": downloaded}
                                db.commit()
                            results.append(
                                {
                                    "bank_code": bank_code,
                                    "month": month,
                                    "status": "failed",
                                    "error": str(exc),
                                    "diagnostic": downloaded,
                                }
                            )

                        done += 1
                        self._update_progress(db, job, int(done / total_items * 90))

                except BrowserDownloadError as exc:
                    db.rollback()
                    for month, item in supported_items:
                        refreshed = db.get(models.JobItem, item.id)
                        if refreshed:
                            refreshed.status = "failed"
                            refreshed.message = str(exc)
                            db.commit()
                        results.append(
                            {
                                "bank_code": bank_code,
                                "month": month,
                                "status": "failed",
                                "error": str(exc),
                            }
                        )
                        done += 1
                        self._update_progress(db, job, int(done / total_items * 90))
                except Exception as exc:  # noqa: BLE001
                    db.rollback()
                    for month, item in supported_items:
                        refreshed = db.get(models.JobItem, item.id)
                        if refreshed:
                            refreshed.status = "failed"
                            refreshed.message = str(exc)
                            db.commit()
                        results.append(
                            {
                                "bank_code": bank_code,
                                "month": month,
                                "status": "failed",
                                "error": str(exc),
                            }
                        )
                        done += 1
                        self._update_progress(db, job, int(done / total_items * 90))
                continue

            for month in months:
                self._assert_not_cancelled(db, job.id)

                job_item = db.execute(
                    select(models.JobItem).where(
                        models.JobItem.job_id == job.id,
                        models.JobItem.bank_code == bank_code,
                        models.JobItem.target_month == month,
                    )
                ).scalar_one_or_none()

                if job_item is None:
                    job_item = models.JobItem(
                        job_id=job.id,
                        bank_code=bank_code,
                        target_month=month,
                        status="queued",
                    )
                    db.add(job_item)
                    db.flush()

                if not is_month_supported(bank, month, timezone=self.settings.timezone):
                    job_item.status = "MANUAL_REQUIRED"
                    job_item.message = (
                        f"{bank_code} does not support automated scrape for month {month}; upload PDF manually"
                    )
                    db.commit()
                    results.append(
                        {
                            "bank_code": bank_code,
                            "month": month,
                            "status": "MANUAL_REQUIRED",
                        }
                    )
                    done += 1
                    self._update_progress(db, job, int(done / total_items * 90))
                    continue

                # Run bank automation in isolated config.
                bank_cfg_copy = {bank_code: dict(app_cfg.banks[bank_code])}
                bank_cfg_copy[bank_code].update(build_bank_scrape_config(bank_code, month))

                scoped_cfg = load_app_config()
                scoped_cfg.banks = bank_cfg_copy
                scoped_cfg.paths.incoming_dir = app_cfg.paths.incoming_dir
                scoped_cfg.paths.state_dir = app_cfg.paths.state_dir
                scoped_cfg.paths.downloads_dir = app_cfg.paths.downloads_dir
                scoped_cfg.paths.incoming_dir.mkdir(parents=True, exist_ok=True)
                scoped_cfg.paths.state_dir.mkdir(parents=True, exist_ok=True)

                try:
                    job_item.status = "running"
                    db.commit()

                    if download:
                        run_end_to_end_downloads(
                            app_config=scoped_cfg,
                            scheduled=False,
                            login_timeout_minutes=login_timeout_minutes,
                            headless=headless,
                            credentials=credentials,
                        )

                    latest_pdf, diagnostic = self._resolve_downloaded_pdf_from_diagnostics(
                        bank_cfg=bank_cfg_copy[bank_code],
                        requested_month=month,
                    )
                    if latest_pdf is None:
                        # Backward-compatible fallback for adapters that don't yet emit diagnostics.
                        if diagnostic is None:
                            latest_pdf = self._find_latest_matching_pdf(scoped_cfg, bank_code)
                        if latest_pdf is None:
                            raise RuntimeError(
                                f"No downloadable PDF resolved for {bank_code} month {month}; diagnostic={diagnostic}"
                            )

                    summary = ingest_statement_pdf(
                        db,
                        settings=self.settings,
                        storage=self.storage,
                        profile_id=job.profile_id,
                        profile_key=profile_key,
                        bank_code=bank_code,
                        filename=latest_pdf.name,
                        content=latest_pdf.read_bytes(),
                        source=models.SourceType.SCRAPE,
                    )
                    db.commit()

                    job_item.status = "succeeded"
                    job_item.message = (
                        f"Ingested statement {summary['statement_reference']}"
                    )
                    job_item.metadata_json = (
                        {"summary": summary, "diagnostic": diagnostic}
                        if diagnostic is not None
                        else summary
                    )
                    db.commit()

                    results.append(
                        {
                            "bank_code": bank_code,
                            "month": month,
                            "status": "succeeded",
                            "summary": summary,
                        }
                    )
                except BrowserDownloadError as exc:
                    db.rollback()
                    job_item = db.get(models.JobItem, job_item.id)
                    if job_item:
                        job_item.status = "failed"
                        job_item.message = str(exc)
                        db.commit()
                    results.append(
                        {
                            "bank_code": bank_code,
                            "month": month,
                            "status": "failed",
                            "error": str(exc),
                        }
                    )
                except Exception as exc:  # noqa: BLE001
                    db.rollback()
                    job_item = db.get(models.JobItem, job_item.id)
                    if job_item:
                        job_item.status = "failed"
                        job_item.message = str(exc)
                        db.commit()
                    results.append(
                        {
                            "bank_code": bank_code,
                            "month": month,
                            "status": "failed",
                            "error": str(exc),
                        }
                    )

                done += 1
                self._update_progress(db, job, int(done / total_items * 90))

        return {"items": results}

    def _process_reclassify_job(self, db: Session, job: models.Job) -> dict[str, Any]:
        payload = job.payload_json or {}
        statement_ids = payload.get("statement_ids")
        updated = reclassify_statement_lines(db, statement_ids=statement_ids, profile_id=job.profile_id)
        db.commit()
        return {"updated_line_count": updated}

    def _process_export_workbook_job(self, db: Session, job: models.Job, *, profile_key: str) -> dict[str, Any]:
        payload = job.payload_json or {}
        year = int(payload.get("year", datetime.now().year))
        export_id = payload.get("export_id")

        out_dir = self.settings.uploads_temp_dir / profile_key
        out_dir.mkdir(parents=True, exist_ok=True)
        out_file = out_dir / f"workbook_{year}_{job.id}.xlsx"
        build_yearly_workbook_from_statements(db, out_file, year, profile_id=job.profile_id)

        content = out_file.read_bytes()
        stored = self.storage.save_binary(
            content=content,
            filename=f"credit-card-tracker-{year}.xlsx",
            folder="exports/workbooks",
            profile_key=profile_key,
        )

        export_row = None
        if export_id:
            export_row = db.execute(
                select(models.Export).where(
                    models.Export.id == int(export_id),
                    models.Export.profile_id == job.profile_id,
                )
            ).scalar_one_or_none()
        if not export_row:
            export_row = models.Export(
                profile_id=job.profile_id,
                export_type="workbook",
                status=models.ExportStatus.QUEUED,
            )
            db.add(export_row)
            db.flush()

        export_row.status = models.ExportStatus.READY
        export_row.storage_backend = stored.backend
        export_row.storage_key = stored.key
        export_row.filename = f"credit-card-tracker-{year}.xlsx"
        export_row.ready_at = datetime.now(UTC)
        db.commit()

        out_file.unlink(missing_ok=True)

        return {
            "export_id": export_row.id,
            "storage_backend": stored.backend,
            "storage_key": stored.key,
            "filename": export_row.filename,
        }

    def _process_parser_validate_job(self, db: Session, job: models.Job) -> dict[str, Any]:
        payload = job.payload_json or {}
        samples_dir = Path(payload.get("samples_dir", "")).expanduser()
        strict = bool(payload.get("strict", True))

        if not samples_dir.exists():
            raise RuntimeError(f"samples_dir does not exist: {samples_dir}")

        app_cfg = load_app_config()

        def latest_for(bank_code: str) -> Path | None:
            patterns = app_cfg.banks[bank_code].get("file_glob_patterns", [])
            candidates = [p for p in samples_dir.iterdir() if p.is_file() and p.suffix.lower() == ".pdf"]
            matched = [
                p for p in candidates if any(fnmatch.fnmatch(p.name.lower(), pt.lower()) for pt in patterns)
            ]
            if not matched:
                return None
            return max(matched, key=lambda p: p.stat().st_mtime)

        fab_file = latest_for("FAB")
        adcb_file = latest_for("ADCB")
        enbd_file = latest_for("ENBD")

        missing = [
            code
            for code, file_path in [("FAB", fab_file), ("ADCB", adcb_file), ("ENBD", enbd_file)]
            if file_path is None
        ]
        if missing:
            if strict:
                raise RuntimeError(f"Missing sample files for: {', '.join(missing)}")
            return {"missing": missing}

        adcb_password = os.getenv("ADCB_PDF_PASSWORD") or os.getenv("ADCB_CID")
        if not adcb_password:
            raise RuntimeError("ADCB_PDF_PASSWORD or ADCB_CID must be set for parser validation")

        counts = {
            "FAB": len(parse_fab_statement(fab_file).transactions),
            "ADCB": len(parse_adcb_statement(adcb_file, adcb_password).transactions),
            "ENBD": len(parse_enbd_statement(enbd_file).transactions),
        }

        mismatches = {
            bank_code: {"expected": EXPECTED_SAMPLE_COUNTS[bank_code], "actual": actual}
            for bank_code, actual in counts.items()
            if actual != EXPECTED_SAMPLE_COUNTS[bank_code]
        }

        if strict and mismatches:
            raise RuntimeError(f"Parser count mismatch: {mismatches}")

        return {
            "counts": counts,
            "expected": EXPECTED_SAMPLE_COUNTS,
            "mismatches": mismatches,
        }

    def _process_bank_connection_test_job(self, db: Session, job: models.Job) -> dict[str, Any]:
        payload = job.payload_json or {}
        bank_code = str(payload.get("bank_code", "")).upper()
        mapping = db.execute(
            select(models.ProfileBank).where(
                models.ProfileBank.profile_id == job.profile_id,
                models.ProfileBank.bank_code == bank_code,
            )
        ).scalar_one_or_none()
        if mapping is None:
            raise RuntimeError(f"Bank {bank_code} is not enabled for this profile")

        required_env_map = {
            "FAB": ["FAB_USERNAME", "FAB_PASSWORD"],
            "ADCB": ["ADCB_CID", "ADCB_LOGIN_PASSWORD"],
            "ENBD": ["ENBD_USERNAME", "ENBD_PASSWORD"],
            "EIB": ["EIB_USERNAME", "EIB_PASSWORD"],
            "SIB": ["SIB_USER_ID", "SIB_PASSWORD", "SIB_PDF_PASSWORD"],
            "MASHREQ": ["MASHREQ_USERNAME", "MASHREQ_PASSWORD"],
        }
        required_env = required_env_map.get(bank_code)
        if not required_env:
            raise RuntimeError(f"Unsupported bank_code: {bank_code}")

        missing = [env for env in required_env if not os.getenv(env)]
        status = "ok" if not missing else "missing_env"
        return {
            "bank_code": bank_code,
            "status": status,
            "missing_env": missing,
        }

    def _process_reparse_statement_job(self, db: Session, job: models.Job, *, profile_key: str) -> dict[str, Any]:
        payload = job.payload_json or {}
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
                self._assert_not_cancelled(db, job.id)
                try:
                    summary = self._reparse_single_statement(
                        db,
                        statement_id=int(statement_id),
                        profile_id=job.profile_id,
                        profile_key=profile_key,
                    )
                    reparsed.append(
                        {
                            "statement_id": int(statement_id),
                            "new_summary": summary,
                        }
                    )
                except Exception as exc:  # noqa: BLE001
                    db.rollback()
                    failures.append(
                        {
                            "statement_id": int(statement_id),
                            "error": str(exc),
                        }
                    )

                self._update_progress(db, job, int((idx + 1) / max(total, 1) * 90))

            return {
                "total_statements": total,
                "reparsed": reparsed,
                "failures": failures,
            }

        if payload.get("statement_id") is None:
            raise RuntimeError("Reparse job payload must include 'statement_id' or 'all_statements=true'")

        statement_id = int(payload.get("statement_id"))
        summary = self._reparse_single_statement(
            db,
            statement_id=statement_id,
            profile_id=job.profile_id,
            profile_key=profile_key,
        )

        return {"reparsed_statement_id": statement_id, "new_summary": summary}

    def _reparse_single_statement(
        self,
        db: Session,
        *,
        statement_id: int,
        profile_id: int,
        profile_key: str,
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

        content = self.storage.read_bytes(pdf_file.storage_key)

        summary = ingest_statement_pdf(
            db,
            settings=self.settings,
            storage=self.storage,
            profile_id=profile_id,
            profile_key=profile_key,
            bank_code=statement.bank_code,
            filename=pdf_file.original_filename,
            content=content,
            source=models.SourceType.UPLOAD,
        )
        db.commit()

        return summary
