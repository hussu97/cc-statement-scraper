# Credit Card Scraper — Production Guide

Two complete production paths:

- **Plan 1 (Free):** Render (API + worker) + Vercel (frontend) + Neon/Supabase (free Postgres)
- **Plan 2 (GCP):** Cloud Run + Cloud SQL + Cloud Storage + Artifact Registry + Secret Manager

---

## Prerequisites (both plans)

| Tool | Min version | Install |
|------|-------------|---------|
| Docker | 24+ | <https://docs.docker.com/get-docker/> |
| Git | any | — |
| Python | 3.12 | — |
| Node | 20 LTS | — |

---

## Environment Variables

All services share the same env-var namespace. Required in production:

| Variable | Description |
|----------|-------------|
| `CCS_PLATFORM_DATABASE_URL` | PostgreSQL DSN (`postgresql+psycopg://user:pass@host/db`) |
| `CCS_PLATFORM_SESSION_SECRET_KEY` | Random 32+ byte hex string — **never the default** |
| `CCS_PLATFORM_RUNTIME_SETTINGS_ENCRYPTION_KEY` | Fernet key for encrypting DB-stored secrets |
| `CCS_PLATFORM_ENVIRONMENT` | `production` |
| `CCS_PLATFORM_REQUIRE_LOGIN` | `true` |
| `CCS_PLATFORM_STORAGE_BACKEND` | `local` (Plan 1) or `gcs` (Plan 2) |

Optional but recommended:

| Variable | Default | Notes |
|----------|---------|-------|
| `CCS_PLATFORM_EMBEDDED_WORKER` | `false` | Keep `false` — run worker as a separate service |
| `CCS_PLATFORM_JOB_DISPATCH_BACKEND` | `database` | Leave as `database` for multi-process setups |
| `CCS_PLATFORM_WORKER_QUEUES` | `default,scrape` | Set `default` for API-side worker, `scrape` for browser worker |
| `CCS_PLATFORM_TIMEZONE` | `Asia/Dubai` | IANA timezone |
| `CCS_PLATFORM_GCS_BUCKET` | — | Required when `STORAGE_BACKEND=gcs` |
| `CCS_PLATFORM_GCS_PROJECT` | — | GCP project ID |
| `CCS_PLATFORM_GCS_CREDENTIALS_FILE` | — | Path to service account JSON (or use Workload Identity) |
| `CCS_PLATFORM_RUNTIME_SETTINGS_REQUIRE_ENCRYPTION` | `true` | Disable only in dev |
| `CCS_PLATFORM_RUNTIME_SETTINGS_SEED_SOURCE` | `env_file_then_env` | Seeds DB from `.env` on first boot |
| `CCS_PLATFORM_RETENTION_JOBS_DAYS` | `90` | — |
| `CCS_PLATFORM_RETENTION_EXPORTS_DAYS` | `90` | — |
| `CCS_PLATFORM_RETENTION_AUDIT_EVENTS_DAYS` | `365` | — |
| `CCS_PLATFORM_RETENTION_LOGS_DAYS` | `30` | — |

Generate secret key:

```bash
python -c "import secrets; print(secrets.token_hex(32))"
```

Generate Fernet key:

```bash
python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
```

---

## Plan 1 — Free (Render + Vercel + Neon)

### Services

| Layer | Provider | Free tier |
|-------|----------|-----------|
| Backend API | Render Web Service | 512 MB RAM, spins down after 15 min inactivity |
| Background worker | Render Background Worker | Always-on |
| Database | Neon (or Supabase) | Free Postgres, 0.5 GB storage |
| Frontend | Vercel | Free hobby plan |
| File storage | Render Persistent Disk | 1 GB free (or use GCS free tier) |

### 1.1 Database — Neon

1. Create account at <https://neon.tech>
2. Create project → copy the PostgreSQL connection string
3. Set `CCS_PLATFORM_DATABASE_URL` to the Neon DSN

### 1.2 Backend — Render

**Dockerfile:** `deploy/Dockerfile.app` (build context: repo root)

1. Connect your GitHub repo in the Render dashboard.
2. Create a **Web Service** (API):
   - **Build command:** *(Docker, automatic from Dockerfile)*
   - **Dockerfile path:** `deploy/Dockerfile.app`
   - **Start command:** `python -m ccs_platform.cli api --host 0.0.0.0 --port 8040`
   - **Port:** `8040`
3. Create a **Background Worker** (worker):
   - Same Dockerfile
   - **Start command:** `python -m ccs_platform.cli worker`
4. Add all env vars from the table above to both services.
5. Mount a **Persistent Disk** at `/app/data` (1 GB) for the API service if using local storage.

### 1.3 Run migrations on first deploy

In the Render dashboard → Shell (or via a one-off job):

```bash
cd /app && alembic upgrade head
```

### 1.4 Frontend — Vercel

```bash
cd frontend
npm install
npm run build
```

1. Import the repo in Vercel.
2. Set **Root Directory** to `frontend`.
3. Set the `VITE_API_BASE_URL` env var to your Render API URL (e.g. `https://ccs-api.onrender.com`).
4. Deploy.

> **Note:** The Vite dev proxy only works locally. In production the frontend calls the API directly; set `VITE_API_BASE_URL` and ensure CORS is configured on the backend.

---

## Plan 2 — GCP (Cloud Run + Cloud SQL + GCS)

### Architecture

```
Internet → Cloud Load Balancer → Cloud Run (API)
                                  ↓
                             Cloud SQL (Postgres)
                             Cloud Storage (GCS)

Cloud Scheduler → Cloud Run (worker / jobs)
```

### 2.1 Prerequisites

```bash
gcloud auth login
gcloud config set project PROJECT_ID
gcloud config set run/region europe-west1
```

Enable APIs:

```bash
gcloud services enable \
  run.googleapis.com \
  sql-component.googleapis.com \
  sqladmin.googleapis.com \
  storage.googleapis.com \
  artifactregistry.googleapis.com \
  secretmanager.googleapis.com \
  cloudscheduler.googleapis.com
```

### 2.2 Artifact Registry

```bash
gcloud artifacts repositories create ccs-platform \
  --repository-format=docker \
  --location=europe-west1 \
  --description="CCS Platform images"

gcloud auth configure-docker europe-west1-docker.pkg.dev
```

### 2.3 Build and push image

```bash
IMAGE=europe-west1-docker.pkg.dev/PROJECT_ID/ccs-platform/app:$(git rev-parse --short HEAD)

docker build -f deploy/Dockerfile.app -t "$IMAGE" .
docker push "$IMAGE"
```

### 2.4 Cloud SQL (PostgreSQL 16)

```bash
gcloud sql instances create ccs-postgres \
  --database-version=POSTGRES_16 \
  --tier=db-f1-micro \
  --region=europe-west1 \
  --storage-auto-increase \
  --backup-start-time=02:00

gcloud sql databases create ccs --instance=ccs-postgres

gcloud sql users create ccs \
  --instance=ccs-postgres \
  --password=STRONG_PASSWORD
```

Connection string for Cloud Run (via Cloud SQL connector):

```
postgresql+psycopg://ccs:STRONG_PASSWORD@/ccs?host=/cloudsql/PROJECT_ID:europe-west1:ccs-postgres
```

### 2.5 Cloud Storage

```bash
gcloud storage buckets create gs://ccs-platform-data \
  --location=europe-west1 \
  --uniform-bucket-level-access
```

### 2.6 Secret Manager

Store each secret:

```bash
echo -n "YOUR_SESSION_SECRET_KEY" | \
  gcloud secrets create ccs-session-secret-key --data-file=-

echo -n "YOUR_FERNET_KEY" | \
  gcloud secrets create ccs-encryption-key --data-file=-
```

Grant Cloud Run service account access:

```bash
SA=SERVICE_ACCOUNT_EMAIL  # e.g. ccs-api@PROJECT_ID.iam.gserviceaccount.com

gcloud secrets add-iam-policy-binding ccs-session-secret-key \
  --member="serviceAccount:$SA" --role="roles/secretmanager.secretAccessor"

gcloud secrets add-iam-policy-binding ccs-encryption-key \
  --member="serviceAccount:$SA" --role="roles/secretmanager.secretAccessor"
```

### 2.7 Deploy API

```bash
gcloud run deploy ccs-api \
  --image="$IMAGE" \
  --region=europe-west1 \
  --platform=managed \
  --allow-unauthenticated \
  --add-cloudsql-instances=PROJECT_ID:europe-west1:ccs-postgres \
  --set-env-vars="CCS_PLATFORM_ENVIRONMENT=production" \
  --set-env-vars="CCS_PLATFORM_REQUIRE_LOGIN=true" \
  --set-env-vars="CCS_PLATFORM_STORAGE_BACKEND=gcs" \
  --set-env-vars="CCS_PLATFORM_GCS_BUCKET=ccs-platform-data" \
  --set-env-vars="CCS_PLATFORM_DATABASE_URL=postgresql+psycopg://ccs:STRONG_PASSWORD@/ccs?host=/cloudsql/PROJECT_ID:europe-west1:ccs-postgres" \
  --set-secrets="CCS_PLATFORM_SESSION_SECRET_KEY=ccs-session-secret-key:latest" \
  --set-secrets="CCS_PLATFORM_RUNTIME_SETTINGS_ENCRYPTION_KEY=ccs-encryption-key:latest" \
  --command="python,-m,ccs_platform.cli,api,--host,0.0.0.0,--port,8040" \
  --port=8040 \
  --min-instances=1 \
  --memory=512Mi \
  --cpu=1
```

### 2.8 Deploy Worker

```bash
gcloud run deploy ccs-worker \
  --image="$IMAGE" \
  --region=europe-west1 \
  --platform=managed \
  --no-allow-unauthenticated \
  --add-cloudsql-instances=PROJECT_ID:europe-west1:ccs-postgres \
  --set-env-vars="CCS_PLATFORM_ENVIRONMENT=production" \
  --set-env-vars="CCS_PLATFORM_STORAGE_BACKEND=gcs" \
  --set-env-vars="CCS_PLATFORM_GCS_BUCKET=ccs-platform-data" \
  --set-env-vars="CCS_PLATFORM_DATABASE_URL=postgresql+psycopg://ccs:STRONG_PASSWORD@/ccs?host=/cloudsql/PROJECT_ID:europe-west1:ccs-postgres" \
  --set-secrets="CCS_PLATFORM_SESSION_SECRET_KEY=ccs-session-secret-key:latest" \
  --set-secrets="CCS_PLATFORM_RUNTIME_SETTINGS_ENCRYPTION_KEY=ccs-encryption-key:latest" \
  --command="python,-m,ccs_platform.cli,worker" \
  --min-instances=1 \
  --memory=2Gi \
  --cpu=2 \
  --timeout=3600
```

### 2.9 Run migrations (one-off Cloud Run job)

```bash
gcloud run jobs create ccs-migrate \
  --image="$IMAGE" \
  --region=europe-west1 \
  --add-cloudsql-instances=PROJECT_ID:europe-west1:ccs-postgres \
  --set-env-vars="CCS_PLATFORM_DATABASE_URL=postgresql+psycopg://ccs:STRONG_PASSWORD@/ccs?host=/cloudsql/PROJECT_ID:europe-west1:ccs-postgres" \
  --command="alembic" \
  --args="upgrade,head" \
  --task-timeout=300

gcloud run jobs execute ccs-migrate --region=europe-west1 --wait
```

### 2.10 Frontend — Vercel (same as Plan 1)

Deploy the `frontend/` directory to Vercel with `VITE_API_BASE_URL` pointing to the Cloud Run API URL.

---

## Operations Runbook

### Health checks

```bash
# API liveness
curl https://YOUR_API_HOST/api/v1/health

# API readiness
curl https://YOUR_API_HOST/api/v1/health/ready

# Metrics
curl https://YOUR_API_HOST/api/v1/metrics
```

### Manual migrations

```bash
# Local (development)
cd backend && alembic upgrade head

# Production (Plan 2 — Cloud Run job)
gcloud run jobs execute ccs-migrate --region=europe-west1 --wait
```

### Re-encrypt runtime secrets after key rotation

```bash
# From inside the running container or local with correct env vars
PYTHONPATH=backend python backend/scripts/rotate_runtime_setting_secrets.py \
  --old-key OLD_KEY --new-key NEW_KEY --dry-run

# Apply
PYTHONPATH=backend python backend/scripts/rotate_runtime_setting_secrets.py \
  --old-key OLD_KEY --new-key NEW_KEY
```

### Backup / restore

```bash
# Create backup
PYTHONPATH=backend python backend/scripts/backup_platform_state.py --label nightly

# Drill restore
PYTHONPATH=backend python backend/scripts/backup_restore_drill.py --label monthly
```

### Retention enforcement

```bash
# Dry-run
PYTHONPATH=backend python backend/scripts/enforce_retention.py

# Apply
PYTHONPATH=backend python backend/scripts/enforce_retention.py --apply
```

### Migration governance preflight

```bash
PYTHONPATH=backend python backend/scripts/migration_preflight.py
```

---

## Go-Live Checklist

- [ ] `CCS_PLATFORM_SESSION_SECRET_KEY` is a random 32+ byte value (not the default)
- [ ] `CCS_PLATFORM_RUNTIME_SETTINGS_ENCRYPTION_KEY` is set and backed up securely
- [ ] `CCS_PLATFORM_ENVIRONMENT=production`
- [ ] `CCS_PLATFORM_REQUIRE_LOGIN=true`
- [ ] `alembic upgrade head` completed successfully
- [ ] `/api/v1/health/ready` returns HTTP 200
- [ ] Worker process is running and polling the job queue
- [ ] GCS bucket (Plan 2) or persistent disk (Plan 1) is mounted and writable
- [ ] Frontend `VITE_API_BASE_URL` points to the live API host
- [ ] CORS configured on the API to allow the frontend origin
- [ ] Scraper credentials seeded into `runtime_settings` via admin UI
- [ ] At least one scrape job completed end-to-end in staging
- [ ] Backup schedule confirmed and first backup verified
