from __future__ import annotations

import subprocess
import sys
from pathlib import Path
from typing import Optional

import typer

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
    profile: str = typer.Option(..., "--profile", help="Profile to scrape under (e.g. hussain, tejasvie)."),
) -> None:
    """Download PDF statements from bank portals and optionally upload to backend."""
    from scraper.bank_map import BankMap
    from scraper.banks.bank_config import load_app_config
    from scraper.banks.downloader import run_end_to_end_downloads
    from scraper.config import get_config
    from scraper.client import ScraperClient

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

        client = ScraperClient(
            base_url=cfg.target_url,
            api_token=cfg.api_token,
            profile_key=cfg.profile_key,
        )

        # Group PDFs by the bank that produced them (recorded at download time).
        # Any PDF not in the map falls back to a None key and the backend will
        # detect the bank from PDF content / filename.
        groups: dict[str | None, list[Path]] = {}
        for pdf in pdf_files:
            code = bank_map.get(pdf)
            groups.setdefault(code, []).append(pdf)

        for code, group in groups.items():
            typer.echo(f"Uploading {len(group)} PDF(s) for bank {code or '(unknown)'} ...")
            result = client.upload_pdfs(group, bank_code=code)
            typer.echo(f"Upload result: {result}")
            bank_map.remove(group)


@app.command()
def upload(
    files: list[Path] = typer.Argument(..., help="PDF files to upload to backend."),
    profile: str = typer.Option(..., "--profile", help="Profile to upload under (e.g. hussain, tejasvie)."),
) -> None:
    """Upload existing local PDF files to backend API."""
    from scraper.config import get_config
    from scraper.client import ScraperClient

    cfg = get_config(profile=profile)
    client = ScraperClient(
        base_url=cfg.target_url,
        api_token=cfg.api_token,
        profile_key=cfg.profile_key,
    )
    missing = [f for f in files if not f.exists()]
    if missing:
        typer.echo(f"Files not found: {missing}", err=True)
        raise typer.Exit(1)

    typer.echo(f"Uploading {len(files)} file(s) to {cfg.target_url} ...")
    result = client.upload_pdfs(files)
    typer.echo(f"Upload result: {result}")


@app.command(name="install-browser")
def install_browser() -> None:
    """Install Chromium for Playwright."""
    typer.echo("Installing Chromium ...")
    subprocess.run([sys.executable, "-m", "playwright", "install", "chromium"], check=True)
    typer.echo("Done.")


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
