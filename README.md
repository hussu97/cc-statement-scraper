# Credit Card Statement Platform

DB-first credit card statement system for FAB, ADCB, ENBD, EIB, SIB, and Mashreq with:
- Statement header + line canonical storage
- Deterministic statement replacement on `(bank_code, statement_reference, statement_date)`
- Async queued jobs for scrape, upload, reparse, reclassify, exports, and diagnostics
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
  - idempotency key dedupe and bounded retry metadata per job
  - queue partitioning (`default` vs `scrape`) and cooperative cancellation tokens
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
PYTHONPATH=src python -m ccs_platform.cli api --host 127.0.0.1 --port 8040 --reload
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

Queue partitioning:
- default queue: lightweight jobs (`upload`, `reclassify`, `export_workbook`, `reparse_statement`)
- scrape queue: browser-heavy jobs (`scrape`, `bank_connection_test`)

Example dedicated workers:

```bash
# Default queue worker
CCS_PLATFORM_WORKER_QUEUES=default PYTHONPATH=src python -m ccs_platform.cli worker

# Scrape queue worker
CCS_PLATFORM_WORKER_QUEUES=scrape PYTHONPATH=src python -m ccs_platform.cli worker
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
- `CCS_PLATFORM_BACKUPS_DIR=...`
- `CCS_PLATFORM_DATABASE_URL=...`
- `CCS_PLATFORM_TIMEZONE=Asia/Dubai`
- `CCS_PLATFORM_EMBEDDED_WORKER=true|false`
- `CCS_PLATFORM_JOB_DISPATCH_BACKEND=database|inprocess`
- `CCS_PLATFORM_WORKER_QUEUES=default,scrape`
- `CCS_PLATFORM_JOB_RETRY_BASE_SECONDS=30`
- `CCS_PLATFORM_JOB_RETRY_JITTER_SECONDS=15`
- `CCS_PLATFORM_JOB_RETRY_MAX_DELAY_SECONDS=900`
- `CCS_PLATFORM_JOB_HEARTBEAT_TIMEOUT_SECONDS=1800`
- `CCS_PLATFORM_RETENTION_JOBS_DAYS=90`
- `CCS_PLATFORM_RETENTION_EXPORTS_DAYS=90`
- `CCS_PLATFORM_RETENTION_AUDIT_EVENTS_DAYS=365`
- `CCS_PLATFORM_RETENTION_LOGS_DAYS=30`
- `CCS_PLATFORM_RETENTION_UPLOADS_DAYS=14`
- `CCS_PLATFORM_RETENTION_BACKUPS_DAYS=30`
- `CCS_PLATFORM_ENVIRONMENT=development|production`
- `CCS_PLATFORM_REQUIRE_LOGIN=true|false`
- `CCS_PLATFORM_SESSION_COOKIE_NAME=ccs_session`
- `CCS_PLATFORM_SESSION_MAX_AGE_SECONDS=1209600`
- `CCS_PLATFORM_SESSION_SECRET_KEY=...`
- `CCS_PLATFORM_RUNTIME_SETTINGS_ENCRYPTION_KEY=...` (required in production by default)
- `CCS_PLATFORM_RUNTIME_SETTINGS_REQUIRE_ENCRYPTION=true|false`
- `CCS_PLATFORM_RUNTIME_SETTINGS_SEED_SOURCE=env|env_file|env_file_then_env|none`
- `CCS_PLATFORM_RUNTIME_SETTINGS_ENV_FILE=/path/to/.env`

Admin UI login accounts:
- `h_abbasi97@hotmail.com` (defaults to profile `hussain`)
- `tejasvie.vemuri@gmail.com` (defaults to profile `tejasvie`)
- Password for both accounts: `Apple123!`

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

# Postgres validation (migrations + smoke + Postgres pytest)
CCS_PLATFORM_DATABASE_URL=postgresql+psycopg://... ./scripts/validate_postgres.sh
```

To re-encrypt stored secret runtime settings after setting/rotating `CCS_PLATFORM_RUNTIME_SETTINGS_ENCRYPTION_KEY`:

```bash
PYTHONPATH=src python scripts/reencrypt_runtime_secrets.py

# Rotation drill from old key to new key
CCS_PLATFORM_RUNTIME_SETTINGS_OLD_ENCRYPTION_KEY=... \
CCS_PLATFORM_RUNTIME_SETTINGS_ENCRYPTION_KEY=... \
PYTHONPATH=src python scripts/rotate_runtime_setting_secrets.py --dry-run

# Migration governance preflight
PYTHONPATH=src python scripts/migration_preflight.py

# Backup/restore and monthly drill
PYTHONPATH=src python scripts/backup_platform_state.py --label nightly
PYTHONPATH=src python scripts/backup_restore_drill.py --label monthly

# Retention policy dry-run/apply
PYTHONPATH=src python scripts/enforce_retention.py
PYTHONPATH=src python scripts/enforce_retention.py --apply

# Load/perf budgets and SLO policy evaluation
PYTHONPATH=src python scripts/load_test_api.py --base-url http://127.0.0.1:8040 --duration 60 --concurrency 12
PYTHONPATH=src python scripts/evaluate_slo.py --metrics-url http://127.0.0.1:8040/api/v1/metrics
```

## Notes

- Legacy pipeline modules (`ccs` CLI, workbook pipeline, legacy ledger DB flow) were removed.
- Bank parser and browser automation internals are fully integrated under `src/ccs_platform/adapters/banks/`.
