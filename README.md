# Credit Card Statement Platform

DB-first credit card statement system for FAB, ADCB, ENBD, EIB, SIB, and Mashreq with:
- Statement header + line canonical storage
- Deterministic statement replacement on `(bank_code, statement_reference, statement_date)`
- Async queued jobs for upload, reparse, reclassify, exports, and diagnostics
- FastAPI backend + React admin panel
- Decoupled scraper CLI for one-time historical downloads

See [ARCHITECTURE.md](ARCHITECTURE.md) for the full system design and [PRODUCTION.md](PRODUCTION.md) for deployment.

## Directory Structure

```
credit-card-scraper/
├── backend/                   ← Python API package (no Playwright)
│   ├── ccs_platform/          ← FastAPI app + embedded worker
│   │   ├── main.py            ← FastAPI app
│   │   ├── cli.py             ← Typer CLI entry-point
│   │   ├── api/v1/            ← REST routes + schemas
│   │   ├── application/       ← jobs, ingestion, analytics, exports
│   │   ├── domain/            ← parsing models, categorization engine
│   │   ├── adapters/          ← bank parsers + storage adapters
│   │   └── db/                ← SQLAlchemy models + session
│   ├── alembic/               ← database migrations
│   ├── config/                ← YAML config
│   ├── scripts/               ← ops/maintenance scripts
│   ├── tests/                 ← pytest test suite
│   ├── requirements.txt       ← production pins (pip-compile)
│   ├── requirements-export.txt ← extra pins for the [export] extra
│   ├── requirements-dev.txt
│   └── pyproject.toml
├── scraper/                   ← Standalone browser scraper CLI
│   ├── scraper/
│   │   ├── cli.py             ← Typer CLI: scrape, upload, install-browser
│   │   ├── client.py          ← httpx client for backend /api/v1/jobs/upload
│   │   ├── config.py          ← CCS_SCRAPER_* env settings
│   │   └── banks/             ← browser adapters (Playwright)
│   ├── config/banks.yaml      ← Bank portal URLs + file patterns
│   ├── requirements.txt
│   └── pyproject.toml
├── frontend/                  ← React TypeScript admin panel
├── deploy/                    ← Dockerfiles, Compose, Caddyfile
├── docs/
├── ARCHITECTURE.md
├── PRODUCTION.md
├── ROADMAP.md
└── README.md
```

## Architecture

The platform uses a **decoupled architecture**:

- **Backend API** (Render): slim FastAPI service with embedded worker. Handles PDF parsing, statement storage, analytics, exports, email ingestion. No browser code.
- **Scraper CLI** (local): standalone tool that uses Playwright to download PDFs from bank portals and upload them to the backend via service token.
- **Frontend** (Vercel): React admin panel calling the backend API.
- **Gmail Relay** (GCP Cloud Run): forwards email statement attachments to the backend.

## Key APIs

- `POST /jobs/upload` — upload PDFs (session auth or Bearer service token with `upload` scope)
- `POST /jobs/reclassify`, `POST /jobs/reparse` — reprocess statements
- `GET /statements`, `GET /statements/{id}/lines`, `GET /statements/{id}/pdf`
- `/dashboard/overview`, `/dashboard/timeseries`, `/dashboard/category-breakdown`
- `/runtime-settings` — manage bank credentials and config via admin UI

## Setup — Backend

See [`backend/README.md`](backend/README.md) for full setup instructions.

```bash
cd backend
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
cp .env.example .env  # fill in values
alembic upgrade head
ccs-platform api --host 127.0.0.1 --port 8040 --reload
```

Health check:
```bash
curl http://127.0.0.1:8040/api/v1/health
```

## Setup — Scraper CLI

```bash
cd scraper
python3 -m venv .venv && source .venv/bin/activate
pip install -e ".[dev]"
ccs-scraper install-browser          # downloads Chromium (~200 MB, one-time)
```

Configure `scraper/.env` (copy from `.env.example`):
```bash
cp scraper/.env.example scraper/.env
```

Key settings:

| Variable | Default | Description |
|---|---|---|
| `CCS_SCRAPER_TARGET_URL` | `http://127.0.0.1:8040` | Backend API URL |
| `CCS_SCRAPER_API_TOKEN` | — | Service API token (`upload` scope — create in admin UI → Service API Tokens) |
| `CCS_SCRAPER_HEADLESS` | `true` | `false` to watch the browser session for debugging |
| `CCS_SCRAPER_BROWSER_PROXY_URL` | — | Optional SOCKS5/HTTP proxy for all browser traffic |
| `CCS_SCRAPER_DOWNLOAD_DIR` | `./downloads` | Local directory for downloaded PDFs |

### Multi-profile credentials

Credentials are namespaced by profile using a `{PROFILE}_` prefix. Banks with missing credentials are automatically skipped.

```
ALICE_FAB_USERNAME=           BOB_FAB_USERNAME=
ALICE_FAB_PASSWORD=           BOB_FAB_PASSWORD=

ALICE_ADCB_CID=               BOB_ADCB_CID=
ALICE_ADCB_LOGIN_PASSWORD=    BOB_ADCB_LOGIN_PASSWORD=
ALICE_ADCB_PDF_PASSWORD=      BOB_ADCB_PDF_PASSWORD=

ALICE_ENBD_USERNAME=          BOB_ENBD_USERNAME=
ALICE_ENBD_PASSWORD=          BOB_ENBD_PASSWORD=

ALICE_EIB_USERNAME=           BOB_EIB_USERNAME=
ALICE_EIB_PASSWORD=           BOB_EIB_PASSWORD=

ALICE_SIB_USER_ID=            BOB_SIB_USER_ID=
ALICE_SIB_PASSWORD=           BOB_SIB_PASSWORD=
ALICE_SIB_PDF_PASSWORD=       BOB_SIB_PDF_PASSWORD=

ALICE_MASHREQ_USERNAME=       BOB_MASHREQ_USERNAME=
ALICE_MASHREQ_PASSWORD=       BOB_MASHREQ_PASSWORD=
```

### Commands

`--profile` is required on every `scrape` and `upload` call.

```bash
# Scrape all configured banks for the current month
ccs-scraper scrape --profile alice

# Scrape specific banks only
ccs-scraper scrape --profile alice --banks FAB,ADCB

# Scrape a date range (inclusive)
ccs-scraper scrape --profile alice --months 2024-01:2025-12

# Scrape a single month
ccs-scraper scrape --profile alice --months 2025-03

# Download only — skip upload to backend
ccs-scraper scrape --profile alice --no-upload

# Upload existing local PDFs manually
ccs-scraper upload --profile alice ./downloads/statement.pdf

# Install / reinstall Chromium
ccs-scraper install-browser
```

See [`scraper/README.md`](scraper/README.md) for the full CLI reference and bank-specific notes.

## Setup — Frontend

```bash
cd frontend
npm install
npm run dev
```

Vite dev server proxies `/api` to `http://127.0.0.1:8040`.

## Run Tests

```bash
# Backend
cd backend && python -m pytest -q

# Frontend
cd frontend && npm test
```

## Storage backends

- `CCS_PLATFORM_STORAGE_BACKEND=local|gcs`
- `CCS_PLATFORM_LOCAL_STORAGE_DIR=...`
- `CCS_PLATFORM_DATABASE_URL=...` (SQLite for dev, PostgreSQL for prod)
- `CCS_PLATFORM_GCS_BUCKET=...`

## Migrations

```bash
cd backend && alembic upgrade head
```

Postgres: set `CCS_PLATFORM_DATABASE_URL` first. Migrations run automatically at startup in production.
