# Production Deployment Guide

Single deployment plan covering all services.

For the system architecture overview see [ARCHITECTURE.md](ARCHITECTURE.md).

---

## Services

| Service | Platform | Notes |
|---------|----------|-------|
| Backend API | Render (free tier) | `Dockerfile.api`, embedded worker, no Playwright |
| Frontend | Vercel | Static React build |
| Database | Neon | Free managed PostgreSQL |
| PDF Storage | GCS | Cloud Storage bucket |
| Gmail Relay | GCP Cloud Run | `Dockerfile.gmail-relay` |
| Scraper | Local machine | `scraper/` CLI, run manually when needed |

---

## Prerequisites

| Tool | Min version |
|------|-------------|
| Docker | 24+ |
| Git | any |
| Python | 3.12 |
| Node | 20 LTS |
| gcloud CLI | any (for GCS / Cloud Run) |

---

## Environment Variables

### Backend API (Render)

Required:

| Variable | Description |
|----------|-------------|
| `CCS_PLATFORM_DATABASE_URL` | Neon PostgreSQL DSN (`postgresql+psycopg://user:pass@host/db`) |
| `CCS_PLATFORM_SESSION_SECRET_KEY` | Random 32+ byte hex string |
| `CCS_PLATFORM_RUNTIME_SETTINGS_ENCRYPTION_KEY` | Fernet key for DB-stored secrets |
| `CCS_PLATFORM_ENVIRONMENT` | `production` |
| `CCS_PLATFORM_STORAGE_BACKEND` | `gcs` |
| `CCS_PLATFORM_GCS_BUCKET` | GCS bucket name |
| `CCS_PLATFORM_GCS_CREDENTIALS_FILE` | Path to service account JSON (or use Workload Identity) |

Optional:

| Variable | Default | Notes |
|----------|---------|-------|
| `CCS_PLATFORM_EMBEDDED_WORKER` | `true` | Keep `true` — runs job worker in same process |
| `CCS_PLATFORM_WORKER_QUEUES` | `default` | Only lightweight jobs; no browser scraping |
| `CCS_PLATFORM_GCS_PROJECT` | — | Optional GCP project ID |
| `CCS_PLATFORM_EMAIL_INGESTION_ENABLED` | `false` | Set `true` to enable email ingestion |
| `CCS_PLATFORM_EMAIL_MS_CLIENT_ID` | — | Azure OAuth client ID |
| `CCS_PLATFORM_EMAIL_MS_CLIENT_SECRET` | — | Azure OAuth client secret |
| `CCS_PLATFORM_EMAIL_GMAIL_CLIENT_ID` | — | GCP OAuth client ID |
| `CCS_PLATFORM_EMAIL_GMAIL_CLIENT_SECRET` | — | GCP OAuth client secret |
| `CCS_PLATFORM_REQUIRE_LOGIN` | `true` | |
| `CCS_PLATFORM_TIMEZONE` | `Asia/Dubai` | |

---

## Render — Backend API

1. Create a **Web Service** in Render:
   - **Runtime**: Docker
   - **Dockerfile path**: `deploy/Dockerfile.api`
   - **Docker context**: repo root
   - **Instance type**: Free (512 MB)

2. Set environment variables from the table above.

3. Add a **Persistent Disk** (required for SQLite in dev, optional with Neon):
   - Mount path: `/app/data`

4. **Pre-deploy command** (runs Alembic before each deploy):
   ```
   cd /app && alembic upgrade head
   ```

5. **Start command** (already in Dockerfile CMD):
   ```
   python -m ccs_platform.cli api --host 0.0.0.0 --port 8040
   ```

6. After first deploy, seed runtime settings via admin UI:
   - Navigate to **Runtime Variables** → click **Seed from env**

7. Health check:
   ```bash
   curl https://your-render-url.onrender.com/api/v1/health
   ```

---

## Vercel — Frontend

1. Import the GitHub repo in Vercel.
2. Set **Root Directory**: `frontend`
3. Set **Build Command**: `npm run build`
4. Set **Output Directory**: `dist`
5. Set environment variable:
   - `VITE_API_BASE_URL` = `https://your-render-url.onrender.com`
6. Add a `vercel.json` rewrite rule (already in `frontend/vercel.json` if present) to proxy `/api` to the backend.

---

## Neon — PostgreSQL

1. Create a free project at [neon.tech](https://neon.tech).
2. Copy the connection string (use the **psycopg** format).
3. Set `CCS_PLATFORM_DATABASE_URL` on Render.
4. Alembic runs automatically at startup (`alembic upgrade head`).

---

## GCS — PDF Storage

1. Create a GCS bucket (single-region, standard storage).
2. Create a service account with **Storage Object Admin** on the bucket.
3. Download the JSON key file and mount it into the Render service (or use Workload Identity).
4. Set `CCS_PLATFORM_GCS_BUCKET` and `CCS_PLATFORM_GCS_CREDENTIALS_FILE`.

---

## GCP Cloud Run — Gmail Relay

See `docs/operations/email-ingestion-automation.md` for the full OAuth + relay setup.

Quick start:
```bash
# Build and push
gcloud builds submit --tag gcr.io/$PROJECT/ccs-gmail-relay \
  --dockerfile deploy/Dockerfile.gmail-relay .

# Deploy
gcloud run deploy ccs-gmail-relay \
  --image gcr.io/$PROJECT/ccs-gmail-relay \
  --region us-central1 \
  --set-env-vars CCS_API_BASE_URL=https://your-render-url.onrender.com,CCS_GMAIL_RELAY_SERVICE_TOKEN=...
```

---

## Scraper CLI — Local

The scraper runs on your local machine to download historical bank statements and upload them to the backend.

```bash
cd scraper
python3 -m venv .venv && source .venv/bin/activate
pip install -e .
ccs-scraper install-browser
```

Create a `.env` file in `scraper/`:
```env
CCS_SCRAPER_TARGET_URL=https://your-render-url.onrender.com
CCS_SCRAPER_API_TOKEN=<service token with upload scope>
CCS_SCRAPER_PROFILE_KEY=alice
CCS_SCRAPER_HEADLESS=true

FAB_USERNAME=...
FAB_PASSWORD=...
# ... other bank credentials
```

Run:
```bash
ccs-scraper scrape --months 2024-01:2025-12
```

Create the service token in the admin UI under **Service API Tokens** with `upload` scope before running.

---

## docker-compose (self-hosted alternative)

For self-hosted deployments (not Render/Vercel):

```bash
cp .env.example .env.production
# Edit .env.production with your secrets
docker-compose -f deploy/docker-compose.prod.yml up -d
```

---

## Operations

### Key rotation

```bash
# Rotate runtime settings encryption key
CCS_PLATFORM_RUNTIME_SETTINGS_OLD_ENCRYPTION_KEY=... \
CCS_PLATFORM_RUNTIME_SETTINGS_ENCRYPTION_KEY=... \
PYTHONPATH=backend python backend/scripts/rotate_runtime_setting_secrets.py --dry-run
```

### Migration preflight

```bash
cd backend && python scripts/migration_preflight.py
```

### Retention

```bash
# Dry-run
PYTHONPATH=backend python backend/scripts/enforce_retention.py
# Apply
PYTHONPATH=backend python backend/scripts/enforce_retention.py --apply
```

### Backup/restore

```bash
PYTHONPATH=backend python backend/scripts/backup_platform_state.py --label nightly
PYTHONPATH=backend python backend/scripts/backup_restore_drill.py --label monthly
```
