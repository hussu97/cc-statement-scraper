from __future__ import annotations

import fnmatch
from pathlib import Path
from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from ccs_platform.adapters.banks.browser.downloader import BrowserDownloadError, run_end_to_end_downloads
from ccs_platform.core.bank_config import load_app_config
from ccs_platform.db import models
from ccs_platform.application.banks.capabilities import (
    build_bank_scrape_config,
    get_enabled_banks,
    is_month_supported,
    resolve_requested_months,
    supports_multi_month,
)
from ccs_platform.application.statements.ingestion import ingest_statement_pdf
from .context import JobContext


def _find_latest_matching_pdf(app_config: Any, bank_code: str) -> Path | None:
    bank_cfg = app_config.banks[bank_code]
    patterns = bank_cfg.get("file_glob_patterns", [])
    candidates: list[Path] = []
    for directory in [app_config.paths.incoming_dir]:
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


def handle_scrape_job(
    db: Session,
    job: models.Job,
    ctx: JobContext,
    *,
    profile_key: str,
    credentials: dict[str, str] | None = None,
) -> dict[str, Any]:
    payload = job.payload_json or {}
    banks = sorted({token.upper().strip() for token in payload.get("banks", []) if token and token.strip()})
    months = resolve_requested_months(
        months=payload.get("months", []),
        month_from=payload.get("month_from"),
        month_to=payload.get("month_to"),
        timezone=ctx.settings.timezone,
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
                ctx.assert_not_cancelled(db, job.id)
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

                if not is_month_supported(bank, month, timezone=ctx.settings.timezone):
                    job_item.status = "MANUAL_REQUIRED"
                    job_item.message = (
                        f"{bank_code} does not support automated scrape for month {month}; upload PDF manually"
                    )
                    db.commit()
                    results.append({"bank_code": bank_code, "month": month, "status": "MANUAL_REQUIRED"})
                    done += 1
                    ctx.update_progress(db, job, int(done / total_items * 90))
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
                downloaded_by_month = {
                    str(item.get("month") or ""): item
                    for item in diagnostics.get("downloaded", [])
                    if str(item.get("month") or "").strip()
                }
                skipped_by_month = {
                    str(item.get("month") or ""): item
                    for item in diagnostics.get("skipped_unavailable", [])
                    if str(item.get("month") or "").strip()
                }
                failed_by_month = {
                    str(item.get("month") or ""): item
                    for item in diagnostics.get("failed", [])
                    if str(item.get("month") or "").strip()
                }

                for month, _ in supported_items:
                    ctx.assert_not_cancelled(db, job.id)
                    job_item = month_index[month]

                    skipped = skipped_by_month.get(month)
                    if skipped is not None:
                        reason = str(skipped.get("reason") or "statement_period_not_available")
                        job_item.status = "SKIPPED_UNAVAILABLE"
                        job_item.message = f"Skipped month {month}: {reason}"
                        job_item.metadata_json = {"diagnostic": skipped}
                        db.commit()
                        results.append({"bank_code": bank_code, "month": month, "status": "SKIPPED_UNAVAILABLE", "diagnostic": skipped})
                        done += 1
                        ctx.update_progress(db, job, int(done / total_items * 90))
                        continue

                    downloaded = downloaded_by_month.get(month)
                    if downloaded is None:
                        failed = failed_by_month.get(month) or {"month": month, "reason": "no_download_record_for_month"}
                        reason = str(failed.get("reason") or "download_failed")
                        job_item.status = "failed"
                        job_item.message = f"Failed month {month}: {reason}"
                        job_item.metadata_json = {"diagnostic": failed}
                        db.commit()
                        results.append({"bank_code": bank_code, "month": month, "status": "failed", "error": reason, "diagnostic": failed})
                        done += 1
                        ctx.update_progress(db, job, int(done / total_items * 90))
                        continue

                    path_value = str(downloaded.get("path") or "").strip()
                    if not path_value:
                        failed = {"month": month, "reason": "download_path_missing"}
                        job_item.status = "failed"
                        job_item.message = f"Failed month {month}: download path missing"
                        job_item.metadata_json = {"diagnostic": failed}
                        db.commit()
                        results.append({"bank_code": bank_code, "month": month, "status": "failed", "error": "download_path_missing", "diagnostic": failed})
                        done += 1
                        ctx.update_progress(db, job, int(done / total_items * 90))
                        continue

                    month_pdf = Path(path_value)
                    if not month_pdf.exists():
                        failed = {"month": month, "reason": "download_file_not_found", "path": path_value}
                        job_item.status = "failed"
                        job_item.message = f"Failed month {month}: downloaded file not found"
                        job_item.metadata_json = {"diagnostic": failed}
                        db.commit()
                        results.append({"bank_code": bank_code, "month": month, "status": "failed", "error": "download_file_not_found", "diagnostic": failed})
                        done += 1
                        ctx.update_progress(db, job, int(done / total_items * 90))
                        continue

                    try:
                        summary = ingest_statement_pdf(
                            db,
                            settings=ctx.settings,
                            storage=ctx.storage,
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
                        results.append({"bank_code": bank_code, "month": month, "status": "succeeded", "summary": summary, "diagnostic": downloaded})
                    except Exception as exc:  # noqa: BLE001
                        db.rollback()
                        job_item = db.get(models.JobItem, job_item.id)
                        if job_item:
                            job_item.status = "failed"
                            job_item.message = str(exc)
                            job_item.metadata_json = {"diagnostic": downloaded}
                            db.commit()
                        results.append({"bank_code": bank_code, "month": month, "status": "failed", "error": str(exc), "diagnostic": downloaded})

                    done += 1
                    ctx.update_progress(db, job, int(done / total_items * 90))

            except BrowserDownloadError as exc:
                db.rollback()
                for month, item in supported_items:
                    refreshed = db.get(models.JobItem, item.id)
                    if refreshed:
                        refreshed.status = "failed"
                        refreshed.message = str(exc)
                        db.commit()
                    results.append({"bank_code": bank_code, "month": month, "status": "failed", "error": str(exc)})
                    done += 1
                    ctx.update_progress(db, job, int(done / total_items * 90))
            except Exception as exc:  # noqa: BLE001
                db.rollback()
                for month, item in supported_items:
                    refreshed = db.get(models.JobItem, item.id)
                    if refreshed:
                        refreshed.status = "failed"
                        refreshed.message = str(exc)
                        db.commit()
                    results.append({"bank_code": bank_code, "month": month, "status": "failed", "error": str(exc)})
                    done += 1
                    ctx.update_progress(db, job, int(done / total_items * 90))
            continue

        for month in months:
            ctx.assert_not_cancelled(db, job.id)

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

            if not is_month_supported(bank, month, timezone=ctx.settings.timezone):
                job_item.status = "MANUAL_REQUIRED"
                job_item.message = (
                    f"{bank_code} does not support automated scrape for month {month}; upload PDF manually"
                )
                db.commit()
                results.append({"bank_code": bank_code, "month": month, "status": "MANUAL_REQUIRED"})
                done += 1
                ctx.update_progress(db, job, int(done / total_items * 90))
                continue

            bank_cfg_copy = {bank_code: dict(app_cfg.banks[bank_code])}
            bank_cfg_copy[bank_code].update(build_bank_scrape_config(bank_code, month))

            scoped_cfg = load_app_config()
            scoped_cfg.banks = bank_cfg_copy
            scoped_cfg.paths.incoming_dir = app_cfg.paths.incoming_dir
            scoped_cfg.paths.state_dir = app_cfg.paths.state_dir
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

                latest_pdf, diagnostic = _resolve_downloaded_pdf_from_diagnostics(
                    bank_cfg=bank_cfg_copy[bank_code],
                    requested_month=month,
                )
                if latest_pdf is None:
                    if diagnostic is None:
                        latest_pdf = _find_latest_matching_pdf(scoped_cfg, bank_code)
                    if latest_pdf is None:
                        raise RuntimeError(
                            f"No downloadable PDF resolved for {bank_code} month {month}; diagnostic={diagnostic}"
                        )

                summary = ingest_statement_pdf(
                    db,
                    settings=ctx.settings,
                    storage=ctx.storage,
                    profile_id=job.profile_id,
                    profile_key=profile_key,
                    bank_code=bank_code,
                    filename=latest_pdf.name,
                    content=latest_pdf.read_bytes(),
                    source=models.SourceType.SCRAPE,
                )
                db.commit()

                job_item.status = "succeeded"
                job_item.message = f"Ingested statement {summary['statement_reference']}"
                job_item.metadata_json = (
                    {"summary": summary, "diagnostic": diagnostic}
                    if diagnostic is not None
                    else summary
                )
                db.commit()

                results.append({"bank_code": bank_code, "month": month, "status": "succeeded", "summary": summary})
            except BrowserDownloadError as exc:
                db.rollback()
                job_item = db.get(models.JobItem, job_item.id)
                if job_item:
                    job_item.status = "failed"
                    job_item.message = str(exc)
                    db.commit()
                results.append({"bank_code": bank_code, "month": month, "status": "failed", "error": str(exc)})
            except Exception as exc:  # noqa: BLE001
                db.rollback()
                job_item = db.get(models.JobItem, job_item.id)
                if job_item:
                    job_item.status = "failed"
                    job_item.message = str(exc)
                    db.commit()
                results.append({"bank_code": bank_code, "month": month, "status": "failed", "error": str(exc)})

            done += 1
            ctx.update_progress(db, job, int(done / total_items * 90))

    return {"items": results}
