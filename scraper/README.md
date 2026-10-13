# CCS Scraper

Standalone CLI tool for downloading bank PDF statements via browser automation and uploading them to the backend — either the legacy CCS Platform FastAPI backend or the Ledger v2 Supabase Edge Function `statements-upload`.

## Setup

```bash
cd scraper
uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python -e ".[dev]"   # ccs-scraper CLI + dependencies + pytest
source .venv/bin/activate           # or call .venv/bin/ccs-scraper directly
ccs-scraper install-browser          # downloads Chromium (~200 MB, one-time)
```

> **What does `-e .` do?**
> `-e` (editable) installs the package linked to the source files in this directory.
> `.` means "use `pyproject.toml` in the current directory." This registers the
> `ccs-scraper` terminal command and installs all dependencies listed in
> `pyproject.toml`. Changes to source files take effect immediately without reinstalling.
> Never `pip install` into the system Python.

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
| `CCS_SCRAPER_SUPABASE_PUBLISHABLE_KEY` | — | Optional Supabase publishable key (`sb_publishable_…`), sent as the `apikey` header when set. The old `CCS_SCRAPER_SUPABASE_ANON_KEY` name still works (deprecated, warns) |
| `CCS_SCRAPER_UPLOAD_MAX_FILES` | `20` | Files per upload request (see [Uploading](#uploading)). Can only lower the default: values above 20 are clamped to 20 (the server's limit); empty, zero, negative or non-numeric values use the default |
| `CCS_SCRAPER_UPLOAD_MAX_MB` | `32` | MB of PDF per upload request. Can only lower the default: values above 32 are clamped to 32 (the server accepts 40 MB per request; the rest is headroom); empty, zero, negative or non-numeric values use the default |
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

Uploads are a multipart `POST {CCS_SCRAPER_TARGET_URL}{CCS_SCRAPER_UPLOAD_PATH}` with repeated `files` parts (`application/pdf`), an optional `bank_code_hint` form field (the bank recorded at download time), and the headers `Authorization: Bearer <token>`, `X-Profile-Key: <profile>` and, if configured, `apikey: <CCS_SCRAPER_SUPABASE_PUBLISHABLE_KEY>`.

- `scrape` and `upload-pending` upload one group per bank. If one bank's upload fails the others still run; failures are listed at the end with a `ccs-scraper upload-pending --profile <profile>` hint, and the command exits non-zero.
- Each group is split into requests of at most `CCS_SCRAPER_UPLOAD_MAX_FILES` files (default 20) and `CCS_SCRAPER_UPLOAD_MAX_MB` MB of PDF (default 32), the Ledger v2 server's per-request limits with headroom. A single PDF bigger than the byte limit goes in a request of its own and the server decides (it rejects PDFs over 25 MB).
- Each request is retried on its own: 4xx responses fail immediately; 5xx responses and network errors are retried after 5s, 15s and 45s (four attempts). A `413` splits the request in half and sends each half, recursively; a single file that still gets `413` fails.
- A failed request does not stop the group's later requests. With `scrape` and `upload-pending`, the files in requests that succeeded are recorded in `uploaded.json` and only the rest are reported as failed, so `upload-pending` re-sends just those. (`upload` records successes only when every request succeeds; re-running it is safe because the server dedupes.)
- The Ledger v2 response lists each file as `queued` or `duplicate` (already ingested, same sha256); responses from several requests are merged, and the CLI prints the counts and logs each file.
- Successful uploads are recorded in `<download_dir>/<profile>/state/uploaded.json` (sha256 → filename, bank, doc_code, status). The bank map (`state/bank_map.json`) keeps every scraped PDF's bank, so `upload-pending` can re-send any PDF in `incoming/` with its bank hint. It skips files already in `uploaded.json` unless `--force` is passed. Re-sending is safe because the server dedupes by sha256.
- Both state files are written atomically (temp file + rename). A file that no longer parses is moved aside to `<name>.<timestamp>.corrupt` with a warning, and the state starts empty, so the next `upload-pending` may re-send files the server already has (reported as `duplicate`). Files are matched to the server's response by the name it echoes back (trimmed, last 200 characters), so long or padded filenames are recorded too.

### Pointing at Ledger v2 (Supabase)

```bash
CCS_SCRAPER_TARGET_URL=https://<project-ref>.supabase.co
CCS_SCRAPER_UPLOAD_PATH=/functions/v1/statements-upload
ALICE_CCS_SCRAPER_API_TOKEN=<alice's token, scope statements:upload>
BOB_CCS_SCRAPER_API_TOKEN=<bob's token, scope statements:upload>
CCS_SCRAPER_SUPABASE_PUBLISHABLE_KEY=<sb_publishable_… key>   # optional
```

v2 tokens are profile-scoped (Settings → Sources → Tokens, one per profile), so
`ccs-scraper scrape --profile bob` picks `BOB_CCS_SCRAPER_API_TOKEN` automatically.

## Auth

Before uploading, create a service API token with the scope the target needs: `statements:upload` for Ledger v2, or `email_ingestion:upload` for the legacy backend (admin UI → **Service API Tokens**). Set `<PROFILE>_CCS_SCRAPER_API_TOKEN` (Ledger v2 tokens belong to one profile) or, for a single token shared by every profile (legacy), `CCS_SCRAPER_API_TOKEN`. The per-profile variable wins when both are set; `get_config` fails fast if neither is.

## Tests

```bash
.venv/bin/pytest -q
```
