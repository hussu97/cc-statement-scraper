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

### Scraper settings

| Variable | Default | Description |
|---|---|---|
| `CCS_SCRAPER_TARGET_URL` | `http://127.0.0.1:8000` | Backend API URL |
| `CCS_SCRAPER_API_TOKEN` | — | Service API token (`upload` scope — create in admin UI) |
| `CCS_SCRAPER_PROFILE_KEY` | `hussain` | Default profile when `--profile` is not passed |
| `CCS_SCRAPER_HEADLESS` | `true` | Run browser headless (`false` to watch the session) |
| `CCS_SCRAPER_BROWSER_PROXY_URL` | — | Optional SOCKS5/HTTP proxy for all browser traffic |
| `CCS_SCRAPER_BROWSER_GEO_LATITUDE` | `25.2048` | Geolocation spoof latitude (Dubai) |
| `CCS_SCRAPER_BROWSER_GEO_LONGITUDE` | `55.2708` | Geolocation spoof longitude (Dubai) |
| `CCS_SCRAPER_BROWSER_TIMEZONE_ID` | `Asia/Dubai` | Timezone the browser reports |
| `CCS_SCRAPER_BROWSER_LOCALE` | `en-AE` | Locale the browser reports |
| `CCS_SCRAPER_DOWNLOAD_DIR` | `./downloads` | Local directory for downloaded PDFs |

### Bank credentials — multi-profile

Credentials are stored per-profile in the `.env` file using a `{PROFILE}_` prefix. Each profile holds a full independent set of bank credentials.

```
HUSSAIN_FAB_USERNAME=        TEJASVIE_FAB_USERNAME=
HUSSAIN_FAB_PASSWORD=        TEJASVIE_FAB_PASSWORD=

HUSSAIN_ADCB_CID=            TEJASVIE_ADCB_CID=
HUSSAIN_ADCB_LOGIN_PASSWORD= TEJASVIE_ADCB_LOGIN_PASSWORD=
HUSSAIN_ADCB_PDF_PASSWORD=   TEJASVIE_ADCB_PDF_PASSWORD=

HUSSAIN_ENBD_USERNAME=       TEJASVIE_ENBD_USERNAME=
HUSSAIN_ENBD_PASSWORD=       TEJASVIE_ENBD_PASSWORD=

HUSSAIN_EIB_USERNAME=        TEJASVIE_EIB_USERNAME=
HUSSAIN_EIB_PASSWORD=        TEJASVIE_EIB_PASSWORD=

HUSSAIN_SIB_USER_ID=         TEJASVIE_SIB_USER_ID=
HUSSAIN_SIB_PASSWORD=        TEJASVIE_SIB_PASSWORD=
HUSSAIN_SIB_PDF_PASSWORD=    TEJASVIE_SIB_PDF_PASSWORD=

HUSSAIN_MASHREQ_USERNAME=    TEJASVIE_MASHREQ_USERNAME=
HUSSAIN_MASHREQ_PASSWORD=    TEJASVIE_MASHREQ_PASSWORD=
```

Banks with missing credentials for the selected profile are automatically skipped.

## Usage

```bash
# Scrape all banks (current month) for the default profile
ccs-scraper scrape

# Scrape for a specific profile
ccs-scraper scrape --profile hussain
ccs-scraper scrape --profile tejasvie

# Scrape specific banks
ccs-scraper scrape --profile hussain --banks FAB,ADCB

# Scrape a date range
ccs-scraper scrape --profile hussain --months 2024-01:2025-12

# Scrape without uploading (download only)
ccs-scraper scrape --profile hussain --no-upload

# Upload existing PDFs under a specific profile
ccs-scraper upload --profile tejasvie statement1.pdf statement2.pdf

# Install Chromium (one-time)
ccs-scraper install-browser
```

The `--profile` flag overrides `CCS_SCRAPER_PROFILE_KEY`. If neither is set the scraper defaults to `hussain`.

## Auth

Before uploading, create a service API token in the admin UI under **Service API Tokens** with the `upload` scope. Set `CCS_SCRAPER_API_TOKEN` to the generated token.

## Tests

```bash
python -m pytest -q
```
