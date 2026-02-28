# CCS Scraper

Standalone CLI tool for downloading bank PDF statements via browser automation and uploading them to the CCS Platform backend API.

## Setup

```bash
cd scraper
python3 -m venv .venv
source .venv/bin/activate           # Windows: .venv\Scripts\activate
pip install -e ".[dev]"              # installs ccs-scraper CLI + dependencies + pytest
ccs-scraper install-browser          # downloads Chromium (~200 MB, one-time)
```

> **What does `pip install -e .` do?**
> `-e` (editable) installs the package linked to the source files in this directory.
> `.` means "use `pyproject.toml` in the current directory." This registers the
> `ccs-scraper` terminal command and installs all dependencies listed in
> `pyproject.toml`. Changes to source files take effect immediately without reinstalling.

## Configuration

Copy `.env.example` to `.env` and fill in your values:

```bash
cp .env.example .env
```

All settings come from environment variables (or a `.env` file in the `scraper/` directory):

| Variable | Default | Description |
|---|---|---|
| `CCS_SCRAPER_TARGET_URL` | `http://127.0.0.1:8000` | Backend API URL |
| `CCS_SCRAPER_API_TOKEN` | — | Service API token (create in admin UI with `upload` scope) |
| `CCS_SCRAPER_PROFILE_KEY` | `hussain` | Profile to upload under |
| `CCS_SCRAPER_HEADLESS` | `true` | Run browser headless |
| `CCS_SCRAPER_BROWSER_PROXY_URL` | — | Optional SOCKS5/HTTP proxy |
| `CCS_SCRAPER_BROWSER_GEO_LATITUDE` | `25.2048` | Geolocation spoof (Dubai) |
| `CCS_SCRAPER_BROWSER_GEO_LONGITUDE` | `55.2708` | Geolocation spoof (Dubai) |
| `CCS_SCRAPER_BROWSER_TIMEZONE_ID` | `Asia/Dubai` | Timezone spoof |
| `CCS_SCRAPER_BROWSER_LOCALE` | `en-AE` | Browser locale |
| `CCS_SCRAPER_DOWNLOAD_DIR` | `./downloads` | Local download directory |

Bank credentials (same keys as backend):

```
FAB_USERNAME, FAB_PASSWORD
ADCB_CID, ADCB_LOGIN_PASSWORD, ADCB_PDF_PASSWORD
ENBD_USERNAME, ENBD_PASSWORD
EIB_USERNAME, EIB_PASSWORD
SIB_USER_ID, SIB_PASSWORD, SIB_PDF_PASSWORD
MASHREQ_USERNAME, MASHREQ_PASSWORD
```

## Usage

```bash
# Scrape all banks (current month) and upload
ccs-scraper scrape

# Scrape specific banks
ccs-scraper scrape --banks FAB,ADCB

# Scrape a date range
ccs-scraper scrape --months 2024-01:2025-12

# Scrape without uploading (download only)
ccs-scraper scrape --no-upload

# Upload existing PDFs
ccs-scraper upload statement1.pdf statement2.pdf

# Install Chromium
ccs-scraper install-browser
```

## Auth

Before uploading, create a service API token in the admin UI under **Service API Tokens** with the `upload` scope. Set `CCS_SCRAPER_API_TOKEN` to the generated token.
