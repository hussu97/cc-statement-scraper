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

## Key environment variables

See `.env.example` for the full list. Minimum required:

| Variable | Dev default | Description |
|---|---|---|
| `CCS_PLATFORM_DATABASE_URL` | `sqlite:///data/state/platform.db` | DB connection |
| `CCS_PLATFORM_SESSION_SECRET_KEY` | `change-this-in-production` | Cookie signing key |
| `CCS_PLATFORM_RUNTIME_SETTINGS_ENCRYPTION_KEY` | *(blank = no encryption)* | Fernet key for secrets |
| `CCS_PLATFORM_EMBEDDED_WORKER` | `true` | Run worker in same process |

## Generate password hash

```bash
ccs-platform hash-password
```

Paste the `$2b$...` output into `CCS_PLATFORM_LOGIN_HASH_<USERNAME>` in your `.env`.
