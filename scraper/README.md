# CCS Scraper

Standalone CLI tool for downloading bank PDF statements via browser automation and uploading them to the backend — either the legacy CCS Platform FastAPI backend or the Ledger v2 Supabase Edge Function `statements-upload`.

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
| `CCS_SCRAPER_TARGET_URL` | `http://127.0.0.1:8040` | Upload base URL — legacy backend URL, or your `SUPABASE_URL` for Ledger v2 |
| `CCS_SCRAPER_UPLOAD_PATH` | `/api/v1/jobs/upload` | Upload route appended to the target URL — set `/functions/v1/statements-upload` for Ledger v2 |
| `<PROFILE>_CCS_SCRAPER_API_TOKEN` | — | Per-profile service token, e.g. `ALICE_CCS_SCRAPER_API_TOKEN` (profile upper-cased, like the bank credentials). Takes precedence over the global token. Needed for Ledger v2, where each token belongs to one profile |
| `CCS_SCRAPER_API_TOKEN` | — | Global fallback token, used for any profile without its own (`statements:upload` scope for Ledger v2; legacy backend uses `email_ingestion:upload`) |
| `CCS_SCRAPER_SUPABASE_ANON_KEY` | — | Optional Supabase anon/publishable key, sent as the `apikey` header when set |
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
ALICE_FAB_USERNAME=        BOB_FAB_USERNAME=
ALICE_FAB_PASSWORD=        BOB_FAB_PASSWORD=

ALICE_ADCB_CID=            BOB_ADCB_CID=
ALICE_ADCB_LOGIN_PASSWORD= BOB_ADCB_LOGIN_PASSWORD=
ALICE_ADCB_PDF_PASSWORD=   BOB_ADCB_PDF_PASSWORD=

ALICE_ENBD_USERNAME=       BOB_ENBD_USERNAME=
ALICE_ENBD_PASSWORD=       BOB_ENBD_PASSWORD=

ALICE_EIB_USERNAME=        BOB_EIB_USERNAME=
ALICE_EIB_PASSWORD=        BOB_EIB_PASSWORD=

ALICE_SIB_USER_ID=         BOB_SIB_USER_ID=
ALICE_SIB_PASSWORD=        BOB_SIB_PASSWORD=
ALICE_SIB_PDF_PASSWORD=    BOB_SIB_PDF_PASSWORD=

ALICE_MASHREQ_USERNAME=    BOB_MASHREQ_USERNAME=
ALICE_MASHREQ_PASSWORD=    BOB_MASHREQ_PASSWORD=
```

Banks with missing credentials for the selected profile are automatically skipped.

## Usage

```bash
# Scrape all banks (current month)
ccs-scraper scrape --profile alice
ccs-scraper scrape --profile bob

# Scrape specific banks
ccs-scraper scrape --profile alice --banks FAB,ADCB

# Scrape a date range
ccs-scraper scrape --profile alice --months 2024-01:2025-12

# Scrape without uploading (download only)
ccs-scraper scrape --profile alice --no-upload

# Upload existing PDFs under a specific profile
ccs-scraper upload --profile bob statement1.pdf statement2.pdf

# Re-send scraped PDFs that have not been uploaded yet (e.g. after a failed upload)
ccs-scraper upload-pending --profile alice
ccs-scraper upload-pending --profile alice --banks FAB,ADCB
ccs-scraper upload-pending --profile alice --force   # re-send even already-uploaded files

# Install Chromium (one-time)
ccs-scraper install-browser
```

`--profile` is required on every `scrape`, `upload` and `upload-pending` invocation.

### Uploading

Uploads are a multipart `POST {CCS_SCRAPER_TARGET_URL}{CCS_SCRAPER_UPLOAD_PATH}` with repeated `files` parts (`application/pdf`), an optional `bank_code_hint` form field (the bank recorded at download time), and the headers `Authorization: Bearer <token>`, `X-Profile-Key: <profile>` and, if configured, `apikey: <CCS_SCRAPER_SUPABASE_ANON_KEY>`.

- 4xx responses fail immediately; 5xx responses and network errors are retried (after 5s, 15s, 45s).
- The Ledger v2 response lists each file as `queued` or `duplicate` (already ingested, same sha256); the CLI prints the counts and logs each file.
- `scrape` uploads one batch per bank. If one bank's upload fails the others still run; failures are listed at the end and the command exits non-zero.
- Successful uploads are recorded in `<download_dir>/<profile>/state/uploaded.json` (sha256 → filename, bank, doc_code, status). The bank map (`state/bank_map.json`) keeps every scraped PDF's bank, so `upload-pending` can re-send any PDF in `incoming/` with its bank hint. It skips files already in `uploaded.json` unless `--force` is passed. Re-sending is safe because the server dedupes by sha256.

### Pointing at Ledger v2 (Supabase)

```bash
CCS_SCRAPER_TARGET_URL=https://<project-ref>.supabase.co
CCS_SCRAPER_UPLOAD_PATH=/functions/v1/statements-upload
ALICE_CCS_SCRAPER_API_TOKEN=<alice's token, scope statements:upload>
BOB_CCS_SCRAPER_API_TOKEN=<bob's token, scope statements:upload>
CCS_SCRAPER_SUPABASE_ANON_KEY=<anon/publishable key>   # optional
```

v2 tokens are profile-scoped (Settings → Sources → Tokens, one per profile), so
`ccs-scraper scrape --profile bob` picks `BOB_CCS_SCRAPER_API_TOKEN` automatically.

## Auth

Before uploading, create a service API token with the scope the target needs: `statements:upload` for Ledger v2, or `email_ingestion:upload` for the legacy backend (admin UI → **Service API Tokens**). Set `<PROFILE>_CCS_SCRAPER_API_TOKEN` (Ledger v2 tokens belong to one profile) or, for a single token shared by every profile (legacy), `CCS_SCRAPER_API_TOKEN`. The per-profile variable wins when both are set; `get_config` fails fast if neither is.

## Tests

```bash
python -m pytest -q
```
