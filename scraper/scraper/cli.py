from __future__ import annotations

import logging
import subprocess
import sys
from pathlib import Path
from typing import TYPE_CHECKING, Optional

import typer

if TYPE_CHECKING:
    from scraper.client import ScraperClient

app = typer.Typer(
    name="ccs-scraper",
    help="CCS Scraper — download bank statements and upload to backend API.",
    add_completion=False,
)


@app.command()
def scrape(
    banks: Optional[str] = typer.Option(
        None,
        "--banks",
        help="Comma-separated bank codes to scrape (e.g. FAB,ADCB). Default: all configured banks.",
    ),
    months: Optional[str] = typer.Option(
        None,
        "--months",
        help="Month range YYYY-MM:YYYY-MM or single YYYY-MM. Default: current month.",
    ),
    upload: bool = typer.Option(True, help="Upload downloaded PDFs to backend after scraping."),
    headless: Optional[bool] = typer.Option(None, help="Override CCS_SCRAPER_HEADLESS env var."),
    profile: str = typer.Option(..., "--profile", help="Profile to scrape under (e.g. alice, bob)."),
) -> None:
    """Download PDF statements from bank portals and optionally upload to backend."""
    from scraper.bank_map import BankMap
    from scraper.banks.bank_config import load_app_config
    from scraper.banks.downloader import run_end_to_end_downloads
    from scraper.config import get_config
    from scraper.upload_state import UploadedState

    cfg = get_config(profile=profile)
    if headless is not None:
        cfg.headless = headless

    app_cfg = load_app_config(download_dir=cfg.download_dir)
    cfg.download_dir.mkdir(parents=True, exist_ok=True)
    (cfg.download_dir / "incoming").mkdir(parents=True, exist_ok=True)
    (cfg.download_dir / "state").mkdir(parents=True, exist_ok=True)

    # Filter banks
    requested_banks: list[str] = []
    if banks:
        requested_banks = [b.strip().upper() for b in banks.split(",") if b.strip()]
        for code in requested_banks:
            if code not in app_cfg.banks:
                typer.echo(f"Unknown bank code: {code}. Available: {', '.join(app_cfg.banks)}", err=True)
                raise typer.Exit(1)
        app_cfg.banks = {k: v for k, v in app_cfg.banks.items() if k in requested_banks}

    if not app_cfg.banks:
        typer.echo("No banks configured.", err=True)
        raise typer.Exit(1)

    # Build month list and inject into each bank's config so adapters respect it
    month_list: list[str] = []
    if months:
        if ":" in months:
            from_tok, to_tok = months.split(":", 1)
            month_list = _months_between(from_tok.strip(), to_tok.strip())
        else:
            month_list = [months.strip()]
    if month_list:
        typer.echo(f"Months requested: {month_list}")
        for bank_cfg in app_cfg.banks.values():
            bank_cfg["requested_months"] = month_list

    # Snapshot incoming dir before scraping so we only upload new files
    incoming = cfg.download_dir / "incoming"
    files_before: set[Path] = set(incoming.glob("*.pdf")) | set(incoming.glob("*.PDF"))

    bank_map = BankMap(cfg.download_dir / "state")

    typer.echo(f"Scraping {list(app_cfg.banks)} ...")
    results = run_end_to_end_downloads(
        app_config=app_cfg,
        scheduled=True,
        headless=cfg.headless,
        credentials=cfg.credentials,
        proxy_url=cfg.browser_proxy_url,
        geo_latitude=cfg.browser_geo_latitude,
        geo_longitude=cfg.browser_geo_longitude,
        timezone_id=cfg.browser_timezone_id,
        locale=cfg.browser_locale,
        bank_map=bank_map,
    )

    for bank_code, status in results.items():
        typer.echo(f"  {bank_code}: {status}")

    if upload:
        files_after: set[Path] = set(incoming.glob("*.pdf")) | set(incoming.glob("*.PDF"))
        pdf_files = sorted(files_after - files_before)
        if not pdf_files:
            typer.echo("No new PDFs downloaded this session to upload.")
            return

        client = _make_client(cfg)
        uploaded_state = UploadedState(cfg.download_dir / "state")

        # Group PDFs by the bank that produced them (recorded at download time).
        # Any PDF not in the map falls back to a None key and the backend will
        # detect the bank from PDF content / filename.
        groups: dict[str | None, list[Path]] = {}
        for pdf in pdf_files:
            code = bank_map.get(pdf)
            groups.setdefault(code, []).append(pdf)

        # BankMap entries are kept after upload so `upload-pending` can re-send
        # them later; uploaded.json records what already reached the server.
        failures = _upload_groups(client, groups, uploaded_state)
        _report_failures(failures, profile)


@app.command()
def upload(
    files: list[Path] = typer.Argument(..., help="PDF files to upload to backend."),
    profile: str = typer.Option(..., "--profile", help="Profile to upload under (e.g. alice, bob)."),
) -> None:
    """Upload existing local PDF files to backend API."""
    from scraper.config import get_config
    from scraper.upload_state import UploadedState

    cfg = get_config(profile=profile)
    client = _make_client(cfg)
    missing = [f for f in files if not f.exists()]
    if missing:
        typer.echo(f"Files not found: {missing}", err=True)
        raise typer.Exit(1)

    typer.echo(f"Uploading {len(files)} file(s) to {client.upload_url} ...")
    # One group with no bank hint (the server detects it). A partial failure records
    # the requests that succeeded and exits non-zero naming the rest (audit SRV-16r).
    failures = _upload_groups(client, {None: list(files)}, UploadedState(cfg.download_dir / "state"))
    _report_failures(failures, retry=_upload_retry_hint(failures, profile))


@app.command(name="upload-pending")
def upload_pending(
    profile: str = typer.Option(..., "--profile", help="Profile to upload under (e.g. alice, bob)."),
    banks: Optional[str] = typer.Option(
        None,
        "--banks",
        help="Comma-separated bank codes to limit the upload to (e.g. FAB,ADCB). Default: all.",
    ),
    force: bool = typer.Option(False, "--force", help="Re-send files already recorded as uploaded."),
) -> None:
    """Re-send scraped PDFs (recorded in the bank map) that have not been uploaded yet.

    Safe to repeat: the server dedupes by sha256 and reports re-sent files as
    ``duplicate``.
    """
    from scraper.bank_map import BankMap
    from scraper.config import get_config
    from scraper.upload_state import UploadedState

    cfg = get_config(profile=profile)
    state_dir = cfg.download_dir / "state"
    bank_filter = {b.strip().upper() for b in banks.split(",") if b.strip()} if banks else None

    groups, skipped = _collect_pending(
        incoming=cfg.download_dir / "incoming",
        bank_map=BankMap(state_dir),
        uploaded_state=UploadedState(state_dir),
        bank_filter=bank_filter,
        force=force,
    )
    if skipped:
        typer.echo(f"Skipping {skipped} already-uploaded PDF(s) (use --force to re-send).")
    if not groups:
        typer.echo("No pending PDFs to upload.")
        return

    client = _make_client(cfg)
    typer.echo(f"Uploading to {client.upload_url} ...")
    failures = _upload_groups(client, groups, UploadedState(state_dir))
    _report_failures(failures, profile)


@app.command(name="install-browser")
def install_browser() -> None:
    """Install Chromium for Playwright."""
    typer.echo("Installing Chromium ...")
    subprocess.run([sys.executable, "-m", "playwright", "install", "chromium"], check=True)
    typer.echo("Done.")


def _configure_client_logging() -> None:
    """Show the upload client's INFO logs (per-file status) on stderr."""
    client_logger = logging.getLogger("ccs_scraper.client")
    if not client_logger.handlers:
        handler = logging.StreamHandler()
        handler.setFormatter(logging.Formatter("%(asctime)s | %(levelname)s | %(message)s"))
        client_logger.addHandler(handler)
        client_logger.setLevel(logging.INFO)
        client_logger.propagate = False


def _make_client(cfg) -> "ScraperClient":
    from scraper.client import ScraperClient

    _configure_client_logging()
    return ScraperClient(
        base_url=cfg.target_url,
        api_token=cfg.api_token,
        profile_key=cfg.profile_key,
        upload_path=cfg.upload_path,
        publishable_key=cfg.supabase_publishable_key,
    )


def _format_result(result: dict) -> str:
    from scraper.client import parse_upload_response, summarize_uploads

    uploads = parse_upload_response(result)
    if not uploads:
        return f"Upload result: {result}"
    counts = summarize_uploads(uploads)
    parts = [f"queued={counts.pop('queued', 0)}", f"duplicate={counts.pop('duplicate', 0)}"]
    parts += [f"{k}={v}" for k, v in sorted(counts.items())]
    return "Upload result: " + " ".join(parts)


def _record_uploaded(uploaded_state, files: list[Path], result: dict, bank_code: str | None) -> None:
    """Record successfully uploaded *files* in uploaded.json (keyed by sha256).

    With a v2 response, only files echoed back in ``uploads`` are recorded (with
    their doc_code/status). The server echoes its sanitised filename (trimmed,
    at most 200 characters), so local names are normalised the same way before
    matching; same-named files match the echoed entries in order. A legacy
    response has no per-file detail, so every file in the accepted batch is
    recorded with status ``uploaded``.
    """
    from scraper.client import parse_upload_response
    from scraper.upload_state import server_filename, sha256_file

    uploads = parse_upload_response(result)
    by_name: dict[object, list[dict]] = {}
    for u in uploads:
        by_name.setdefault(u.get("filename"), []).append(u)
    entries: dict[str, dict] = {}
    for pdf in files:
        if uploads:
            matches = by_name.get(server_filename(pdf.name))
            if not matches:
                continue
            item = matches.pop(0)
            info = {"doc_code": item.get("doc_code"), "status": item.get("status")}
        else:
            info = {"doc_code": None, "status": "uploaded"}
        entries[sha256_file(pdf)] = {"filename": pdf.name, "bank_code": bank_code, **info}
    uploaded_state.record_many(entries)


def _upload_groups(client, groups: dict[str | None, list[Path]], uploaded_state) -> list[tuple[str | None, list[Path], str]]:
    """Upload each bank group; a failing group does not stop the others.

    Returns a list of ``(bank_code, files, error)`` for the groups that failed.
    """
    from scraper.client import UploadBatchError

    failures: list[tuple[str | None, list[Path], str]] = []
    for code, group in groups.items():
        typer.echo(f"Uploading {len(group)} PDF(s) for bank {code or '(unknown)'} ...")
        try:
            result = client.upload_pdfs(group, bank_code=code)
        except UploadBatchError as exc:
            # Some batches made it: record them so upload-pending only retries the rest.
            typer.echo(f"  Upload PARTIALLY FAILED for bank {code or '(unknown)'}: {exc}", err=True)
            if exc.uploaded_files:
                typer.echo(f"  {_format_result(exc.result)}")
                _record_uploaded(uploaded_state, exc.uploaded_files, exc.result, code)
            failures.append((code, exc.failed_files, str(exc)))
            continue
        except Exception as exc:  # noqa: BLE001 — report and continue with remaining groups
            typer.echo(f"  Upload FAILED for bank {code or '(unknown)'}: {exc}", err=True)
            failures.append((code, group, str(exc)))
            continue
        typer.echo(f"  {_format_result(result)}")
        _record_uploaded(uploaded_state, group, result, code)
    return failures


def _report_failures(
    failures: list[tuple[str | None, list[Path], str]], profile: str | None = None, *, retry: str | None = None
) -> None:
    """Print a failure summary naming each file that still needs uploading, then exit
    non-zero if any group failed. *retry* overrides the ``upload-pending`` hint."""
    if not failures:
        return
    typer.echo(f"{len(failures)} upload group(s) failed:", err=True)
    for code, group, error in failures:
        typer.echo(f"  {code or '(unknown)'}: {len(group)} file(s) — {error}", err=True)
        for path in group:
            typer.echo(f"    {path}", err=True)
    typer.echo(f"Retry with: {retry or f'ccs-scraper upload-pending --profile {profile}'}", err=True)
    raise typer.Exit(1)


def _upload_retry_hint(failures: list[tuple[str | None, list[Path], str]], profile: str) -> str:
    """``ccs-scraper upload`` command line that re-sends only the failed files."""
    import shlex

    paths = [str(path) for _, group, _ in failures for path in group]
    return shlex.join(["ccs-scraper", "upload", "--profile", profile, *paths])


def _collect_pending(
    incoming: Path,
    bank_map,
    uploaded_state,
    bank_filter: set[str] | None = None,
    force: bool = False,
) -> tuple[dict[str, list[Path]], int]:
    """Group incoming PDFs recorded in *bank_map* by bank code.

    Files already in *uploaded_state* are skipped unless *force*. Returns the
    groups and the number of skipped files.
    """
    from scraper.upload_state import sha256_file

    groups: dict[str, list[Path]] = {}
    skipped = 0
    if not incoming.exists():
        return groups, skipped
    for pdf in sorted(p for p in incoming.iterdir() if p.is_file() and p.suffix.lower() == ".pdf"):
        code = bank_map.get(pdf)
        if code is None:
            continue
        if bank_filter and code not in bank_filter:
            continue
        if not force and uploaded_state.is_uploaded(sha256_file(pdf)):
            skipped += 1
            continue
        groups.setdefault(code, []).append(pdf)
    return groups, skipped


def _months_between(start: str, end: str) -> list[str]:
    from datetime import date

    def _parse(token: str) -> date:
        year, month = int(token[:4]), int(token[5:7])
        return date(year, month, 1)

    s, e = _parse(start), _parse(end)
    tokens: list[str] = []
    current = s
    while current <= e:
        tokens.append(f"{current.year:04d}-{current.month:02d}")
        if current.month == 12:
            current = date(current.year + 1, 1, 1)
        else:
            current = date(current.year, current.month + 1, 1)
    return tokens


if __name__ == "__main__":
    app()
