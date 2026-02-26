# Credit Card Statement Platform

DB-first credit card statement system for FAB, ADCB, ENBD, EIB, SIB, and Mashreq with:
- Statement header + line canonical storage
- Deterministic statement replacement on `(bank_code, statement_reference, statement_date)`
- Async jobs for scrape, upload, reparse, reclassify, exports, and diagnostics
- FastAPI backend + React admin panel + optional standalone worker

## Architecture

- `src/ccs_platform/main.py`: FastAPI backend (`/api/v1`)
- `src/ccs_platform/worker/main.py`: queue + schedule worker loop
- `src/ccs_platform/api/v1/*`: REST endpoints + request/response schemas
- `src/ccs_platform/application/*`: jobs, ingestion, analytics, exports, bank capability orchestration
- `src/ccs_platform/domain/*`: parsing models/utilities, statement identity/types, categorization engine
- `src/ccs_platform/adapters/*`: bank parser/browser adapters + storage adapters
- `src/ccs_platform/db/models/*`: SQLAlchemy relational schema split by concern
- `frontend/`: React TypeScript admin panel

## Key capabilities

- Hard replace semantics for duplicate statement identity:
  - parse PDF
  - resolve identity (`explicit` or deterministic `AUTO-*` fallback)
  - delete old statement + lines if identity already exists
  - insert new statement + lines
- Job APIs:
  - `POST /jobs/scrape` with `month_from` + `month_to` (`YYYY-MM`) range
  - `POST /jobs/upload`
  - `POST /jobs/reclassify`
  - `GET /jobs`, `GET /jobs/{id}`, `POST /jobs/{id}/cancel`
- Statement APIs:
  - `GET /statements`, `GET /statements/{id}`, `GET /statements/{id}/lines`, `GET /statements/{id}/pdf`
  - `POST /statements/{id}/reparse`, `DELETE /statements/{id}`
- Analytics APIs:
  - `/dashboard/overview`, `/dashboard/timeseries`, `/dashboard/category-breakdown`, `/dashboard/top-merchants`, `/dashboard/bank-breakdown`
- Rules/schedules/exports/diagnostics APIs
- Runtime settings APIs for scraper credentials and bank-specific env-style values:
  - `GET /runtime-settings`
  - `POST /runtime-settings`
  - `PATCH /runtime-settings/{key}`
  - `POST /runtime-settings/seed-from-env`

## Data model

Core tables:
- `banks`
- `pdf_files`
- `statements`
- `statement_lines`
- `categories`
- `category_rules`
- `jobs`
- `job_items`
- `schedules`
- `exports`
- `audit_events`
- `runtime_settings`

## Setup

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements-dev.txt
playwright install chromium
```

## Run backend API

```bash
PYTHONPATH=src python -m ccs_platform.cli api --host 127.0.0.1 --port 8040
```

Health check:

```bash
curl http://127.0.0.1:8040/api/v1/health
```

Readiness + metrics:

```bash
curl http://127.0.0.1:8040/api/v1/health/ready
curl http://127.0.0.1:8040/api/v1/metrics
```

## Run standalone worker

Use this when you want schedule/job processing outside API process.

```bash
PYTHONPATH=src python -m ccs_platform.cli worker
```

If dashboard calls return 404 for new endpoints like `/api/v1/dashboard/filter-meta`, restart the API process.
This usually means an older server process is still running without the latest router code.

## Run frontend admin panel

```bash
cd frontend
npm install
npm run dev
```

Vite dev server proxies `/api` to `http://127.0.0.1:8040`.

Runtime variables are now DB-backed and editable in admin UI (`Runtime Variables` page in sidebar).
On startup, a seed routine imports missing values from the local `.env` file into `runtime_settings`.
After seeding, scraper/parser credentials are loaded from DB into process env for job execution.

Scrape month selection in admin is range-based:
- minimum: `2024-01`
- maximum: current month in `Asia/Dubai`
- unsupported historical bank/month combinations are marked `MANUAL_REQUIRED`.
- ENBD, EIB, FAB, ADCB, SIB, and Mashreq multi-month scrape run in one browser session and iterate statement period controls sequentially.
  unavailable periods are marked `SKIPPED_UNAVAILABLE` with per-month diagnostics in job items.

## Storage backends

Environment variables:
- `CCS_PLATFORM_STORAGE_BACKEND=local|gcs`
- `CCS_PLATFORM_LOCAL_STORAGE_DIR=...`
- `CCS_PLATFORM_DATABASE_URL=...`
- `CCS_PLATFORM_TIMEZONE=Asia/Dubai`
- `CCS_PLATFORM_ENVIRONMENT=development|production`
- `CCS_PLATFORM_REQUIRE_API_AUTH=true|false`
- `CCS_PLATFORM_API_AUTH_TOKEN=...` (required when auth is enabled)
- `CCS_PLATFORM_RUNTIME_SETTINGS_ENCRYPTION_KEY=...` (recommended in production)

GCS mode also needs:
- `CCS_PLATFORM_GCS_BUCKET`
- optional: `CCS_PLATFORM_GCS_PROJECT`, `CCS_PLATFORM_GCS_CREDENTIALS_FILE`

## Migrations

Alembic files are included:

```bash
alembic upgrade head
```

Or run the helper:

```bash
CCS_PLATFORM_DATABASE_URL=postgresql+psycopg://... ./scripts/migrate_db.sh
```

To re-encrypt stored secret runtime settings after setting/rotating `CCS_PLATFORM_RUNTIME_SETTINGS_ENCRYPTION_KEY`:

```bash
PYTHONPATH=src python scripts/reencrypt_runtime_secrets.py
```

## Notes

- Legacy pipeline modules (`ccs` CLI, workbook pipeline, legacy ledger DB flow) were removed.
- Bank parser and browser automation internals are fully integrated under `src/ccs_platform/adapters/banks/`.
