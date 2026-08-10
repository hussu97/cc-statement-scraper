# CCS Platform — Backend

FastAPI service with embedded background worker. Handles PDF parsing, statement storage, analytics, exports, and email ingestion. No browser automation.

## Prerequisites

- Python 3.12+
- PostgreSQL (production) or SQLite (development, auto-created)

## Setup

```bash
cd backend
python3 -m venv .venv
source .venv/bin/activate           # Windows: .venv\Scripts\activate
pip install -r requirements-dev.txt  # includes dev/test extras
```

> **Why `requirements-dev.txt` and not `pip install -e .`?**
> The backend is run directly (not as an installed CLI tool), so editable-install is unnecessary.
> `requirements.txt` pins all production dependencies. `requirements-dev.txt` extends it with pytest + httpx.

### Lock files

| File | Contents | Regenerate with |
|------|----------|-----------------|
| `requirements.txt` | Production runtime pins, compiled from `pyproject.toml` `[project.dependencies]` | `pip-compile requirements.in --output-file requirements.txt` |
| `requirements-export.txt` | Extra pins for the optional `[export]` extra (pandas/openpyxl), installed on top of `requirements.txt` | `pip-compile requirements-export.in --output-file requirements-export.txt` |
| `requirements-dev.txt` | Hand-maintained; extends `requirements.txt` with pytest, httpx, pip-tools, bandit | — |

`deploy/Dockerfile.api` installs from both lock files, so the production image ships
exactly the versions CI tests and `pip-audit` scans. Regenerate the lock files after
changing dependencies in `pyproject.toml`, and commit the result.

## Database

```bash
cp .env.example .env  # fill in values
alembic upgrade head  # creates tables / runs migrations
```

SQLite is used by default (development). To use PostgreSQL, set `CCS_PLATFORM_DATABASE_URL`.

## Run

```bash
# API server (embedded worker thread on by default)
ccs-platform api --host 127.0.0.1 --port 8040 --reload

# Health check
curl http://127.0.0.1:8040/api/v1/health

# Standalone worker (if CCS_PLATFORM_EMBEDDED_WORKER=false)
ccs-platform worker
```

`ccs-platform` is installed as a CLI command by `pip install -r requirements-dev.txt` (via `pyproject.toml` entry point). If it's not found, run `pip install -e .` once inside the venv.

## Tests

```bash
python -m pytest -q
```

## Generate password hash

```bash
ccs-platform hash-password
```

Paste the `$2b$...` output into `CCS_PLATFORM_LOGIN_HASH_<USERNAME>` in your `.env`.

---

## Environment variables

### Required in production

| Variable | Description |
|---|---|
| `CCS_PLATFORM_DATABASE_URL` | PostgreSQL DSN — `postgresql+psycopg://user:pass@host:5432/db` |
| `CCS_PLATFORM_SESSION_SECRET_KEY` | Random 32-byte hex — `python -c "import secrets; print(secrets.token_hex(32))"` |
| `CCS_PLATFORM_RUNTIME_SETTINGS_ENCRYPTION_KEY` | Fernet key — `python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"` |
| `CCS_PLATFORM_LOGIN_HASH_HUSSAIN` | bcrypt hash of alice's login password — `ccs-platform hash-password` |
| `CCS_PLATFORM_LOGIN_HASH_BOB` | bcrypt hash of bob's login password — `ccs-platform hash-password` |
| `CCS_PLATFORM_ENVIRONMENT` | `production` |
| `CCS_PLATFORM_STORAGE_BACKEND` | `gcs` (or `local` for self-hosted) |
| `CCS_PLATFORM_GCS_BUCKET` | GCS bucket name (when `STORAGE_BACKEND=gcs`) |

### Optional — core

| Variable | Default | Description |
|---|---|---|
| `CCS_PLATFORM_TIMEZONE` | `Asia/Dubai` | IANA timezone for billing month display |
| `CCS_PLATFORM_CORS_ALLOW_ORIGINS` | `*` | Comma-separated allowed origins (lock down in production) |
| `CCS_PLATFORM_LOG_LEVEL` | `INFO` | Log verbosity (`DEBUG`, `INFO`, `WARNING`, `ERROR`) |
| `CCS_PLATFORM_REQUEST_LOGGING_ENABLED` | `true` | Log every HTTP request |
| `CCS_PLATFORM_REQUIRE_LOGIN` | `true` | Require authenticated session |
| `CCS_PLATFORM_SESSION_COOKIE_NAME` | `ccs_session` | Cookie name |
| `CCS_PLATFORM_SESSION_MAX_AGE_SECONDS` | `1209600` | Session lifetime (14 days) |
| `CCS_PLATFORM_SESSION_COOKIE_SECURE` | `true` in production | Set `false` for local HTTP development |
| `CCS_PLATFORM_RBAC_ENABLED` | `true` in production | Role-based access control |

### Optional — storage

| Variable | Default | Description |
|---|---|---|
| `CCS_PLATFORM_LOCAL_STORAGE_DIR` | `data/archive/platform` | PDF storage path when `STORAGE_BACKEND=local` |
| `CCS_PLATFORM_BACKUPS_DIR` | `data/backups` | Local backup output path |
| `CCS_PLATFORM_GCS_PROJECT` | — | GCP project ID (optional; inferred from credentials if omitted) |
| `CCS_PLATFORM_GCS_CREDENTIALS_FILE` | — | Path to service account JSON (omit to use Application Default Credentials) |

### Optional — worker

| Variable | Default | Description |
|---|---|---|
| `CCS_PLATFORM_EMBEDDED_WORKER` | `true` | `true` = worker runs in the API process; `false` = separate `ccs-platform worker` process |
| `CCS_PLATFORM_MAX_WORKER_THREADS` | `1` | Concurrent worker threads |
| `CCS_PLATFORM_WORKER_MAX_ACTIVE_JOBS` | *(= MAX_WORKER_THREADS)* | Cap on simultaneously active jobs |
| `CCS_PLATFORM_WORKER_QUEUES` | `default` | Comma-separated queue names this process consumes |
| `CCS_PLATFORM_JOB_DISPATCH_BACKEND` | `database` | `database` = DB-polled queue; `inprocess` = inline (dev only) |

### Optional — job timeouts & retry

| Variable | Default | Description |
|---|---|---|
| `CCS_PLATFORM_JOB_RETRY_BASE_SECONDS` | `30` | Base retry back-off |
| `CCS_PLATFORM_JOB_RETRY_JITTER_SECONDS` | `15` | Added random jitter |
| `CCS_PLATFORM_JOB_RETRY_MAX_DELAY_SECONDS` | `900` | Maximum back-off cap |
| `CCS_PLATFORM_JOB_HEARTBEAT_INTERVAL_SECONDS` | `15` | How often running jobs update their heartbeat |
| `CCS_PLATFORM_JOB_HEARTBEAT_TIMEOUT_SECONDS` | `1800` | Stale heartbeat threshold; job is recovered |
| `CCS_PLATFORM_JOB_MAX_DURATION_SECONDS` | `1800` | Hard wall-clock limit per job (0 = disabled) |

### Optional — queue SLOs

| Variable | Default | Description |
|---|---|---|
| `CCS_PLATFORM_QUEUE_BACKLOG_SLO_DEFAULT` | `100` | Max pending jobs before `/health/ready` degrades |
| `CCS_PLATFORM_QUEUE_OLDEST_AGE_SLO_SECONDS` | `900` | Max age of oldest pending job before health degrades |

### Optional — retention policy

| Variable | Default | Description |
|---|---|---|
| `CCS_PLATFORM_RETENTION_JOBS_DAYS` | `90` | Completed job records |
| `CCS_PLATFORM_RETENTION_EXPORTS_DAYS` | `90` | Exported workbook files |
| `CCS_PLATFORM_RETENTION_AUDIT_EVENTS_DAYS` | `365` | Audit log entries |
| `CCS_PLATFORM_RETENTION_LOGS_DAYS` | `30` | Request/event logs |
| `CCS_PLATFORM_RETENTION_UPLOADS_DAYS` | `14` | Raw uploaded PDF files |
| `CCS_PLATFORM_RETENTION_BACKUPS_DAYS` | `30` | Local backup archives |

### Optional — runtime settings seeding

| Variable | Default | Description |
|---|---|---|
| `CCS_PLATFORM_RUNTIME_SETTINGS_SEED_SOURCE` | `env_file_then_env` (dev) / `env` (prod) | Where to read seed values from on startup |
| `CCS_PLATFORM_RUNTIME_SETTINGS_ENV_FILE` | — | Override `.env` path for `env_file*` seed modes |
| `CCS_PLATFORM_RUNTIME_SETTINGS_REQUIRE_ENCRYPTION` | `true` in production | Require Fernet encryption for stored secrets |
| `CCS_PLATFORM_RUNTIME_SETTINGS_EXPOSE_SECRETS` | `false` | Return secret values in API responses (dev only) |

### Optional — PDF decryption (seeded into runtime settings)

The backend PDF parser reads these from runtime settings (seeded from env on startup). Set here or enter them via admin UI → Runtime Variables.

| Variable | Description |
|---|---|
| `ALICE_ADCB_PDF_PASSWORD` | ADCB statement PDF password for alice |
| `ALICE_ADCB_CID` | Fallback if `ALICE_ADCB_PDF_PASSWORD` is blank |
| `ALICE_SIB_PDF_PASSWORD` | SIB statement PDF password for alice |
| `BOB_ADCB_PDF_PASSWORD` | ADCB statement PDF password for bob |
| `BOB_ADCB_CID` | Fallback if `BOB_ADCB_PDF_PASSWORD` is blank |
| `BOB_SIB_PDF_PASSWORD` | SIB statement PDF password for bob |

### Optional — email ingestion

| Variable | Default | Description |
|---|---|---|
| `CCS_PLATFORM_EMAIL_INGESTION_ENABLED` | `false` | Enable email-to-upload ingestion APIs and UI |
| `CCS_PLATFORM_EMAIL_GMAIL_CLIENT_ID` | — | GCP OAuth 2.0 client ID for Gmail |
| `CCS_PLATFORM_EMAIL_GMAIL_CLIENT_SECRET` | — | GCP OAuth 2.0 client secret for Gmail |
| `CCS_PLATFORM_EMAIL_MS_CLIENT_ID` | — | Azure OAuth 2.0 client ID for Outlook/Hotmail |
| `CCS_PLATFORM_EMAIL_MS_CLIENT_SECRET` | — | Azure OAuth 2.0 client secret for Outlook/Hotmail |

### Development-only

| Variable | Default | Description |
|---|---|---|
| `CCS_PLATFORM_ALLOW_LEGACY_SQLITE_RESET` | `false` | Wipe SQLite DB on schema mismatch. **Never enable in production.** |
