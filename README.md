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
│   ├── requirements.txt
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

```bash
cd backend
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
alembic upgrade head
```

Run API:
```bash
PYTHONPATH=backend python -m ccs_platform.cli api --host 127.0.0.1 --port 8040 --reload
```

Health check:
```bash
curl http://127.0.0.1:8040/api/v1/health
```

## Setup — Scraper CLI

```bash
cd scraper
python3 -m venv .venv && source .venv/bin/activate
pip install -e .
ccs-scraper install-browser
```

Configure `scraper/.env`:
```env
CCS_SCRAPER_TARGET_URL=http://127.0.0.1:8040
CCS_SCRAPER_API_TOKEN=<service token with upload scope>
FAB_USERNAME=...
FAB_PASSWORD=...
```

Run:
```bash
ccs-scraper scrape --months 2024-01:2025-12
ccs-scraper upload ./downloads/statement.pdf
```

See [`scraper/README.md`](scraper/README.md) for full CLI reference.

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
