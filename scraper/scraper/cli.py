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
) -> None:
    """Download PDF statements from bank portals and optionally upload to backend."""
    from scraper.banks.bank_config import load_app_config
    from scraper.banks.downloader import run_end_to_end_downloads
    from scraper.config import get_config
    from scraper.client import ScraperClient

    cfg = get_config()
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

    # Build month list
    month_list: list[str] = []
    if months:
        if ":" in months:
            from_tok, to_tok = months.split(":", 1)
            month_list = _months_between(from_tok.strip(), to_tok.strip())
        else:
            month_list = [months.strip()]

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
    )

    for bank_code, status in results.items():
        typer.echo(f"  {bank_code}: {status}")

    if upload:
        incoming = cfg.download_dir / "incoming"
        pdf_files = sorted(incoming.glob("*.pdf")) + sorted(incoming.glob("*.PDF"))
        if not pdf_files:
            typer.echo("No PDFs found to upload.")
            return
        typer.echo(f"Uploading {len(pdf_files)} PDF(s) ...")
        client = ScraperClient(
            base_url=cfg.target_url,
            api_token=cfg.api_token,
            profile_key=cfg.profile_key,
        )
        result = client.upload_pdfs(pdf_files)
        typer.echo(f"Upload result: {result}")


@app.command()
def upload(
    files: list[Path] = typer.Argument(..., help="PDF files to upload to backend."),
) -> None:
    """Upload existing local PDF files to backend API."""
    from scraper.config import get_config
    from scraper.client import ScraperClient

    cfg = get_config()
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
