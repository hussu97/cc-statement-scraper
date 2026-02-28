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
python -c "import base64, os; print(base64.urlsafe_b64encode(os.urandom(32)).decode())"
```

> This uses only stdlib — no packages needed. The output is a valid Fernet key (32 random bytes, base64url-encoded).

---

## Plan 1 — Free (Render + Vercel + Neon)

### Services

| Layer | Provider | Free tier limits |
|-------|----------|-----------------|
| Backend API | Render Web Service | 512 MB RAM, spins down after 15 min inactivity |
| Background worker | Render Background Worker | Always-on, 512 MB RAM |
| Database | Neon | 0.5 GB storage, 1 project, shared compute |
| Frontend | Vercel | Hobby plan, unlimited deployments |
| File storage | Google Cloud Storage (GCS) | 5 GB storage + 1 GB/month egress free |

> **Limitations to know upfront:**
> - Render's free Web Service spins down after 15 minutes of inactivity. The first request after a cold-start takes ~30 seconds. The background worker stays always-on, so scheduled scrape jobs run on time — only the API has this latency on first hit.
> - **Render persistent disks are a paid add-on (~$0.25/GB/month) — not available on the free tier.** File storage must be external. This guide uses GCS, which has a generous free tier (5 GB) and requires only a Google account (credit card required by Google but not charged within free limits).

---

### 1.1 Generate secrets (do this first)

Run locally before touching any provider dashboard:

```bash
# Session secret key (required in production)
python -c "import secrets; print(secrets.token_hex(32))"
# → copy output, e.g. a3f9e2c1...

# Fernet encryption key for runtime settings (credentials stored in DB)
python -c "import base64, os; print(base64.urlsafe_b64encode(os.urandom(32)).decode())"
# → copy output, e.g. 3j4k5l...=
```

Save both values — you will paste them into Render and need them later for key rotation.

---

### 1.2 Database — Neon

1. Sign up at <https://neon.tech> (GitHub login works).
2. Click **New project** → choose a region close to your Render region (e.g. `us-east-1` for Render US East).
3. Note the **connection string** shown on the project page. It looks like:
   ```
   postgresql+psycopg://user:password@ep-xxx.us-east-2.aws.neon.tech/neondb?sslmode=require
   ```
   > The default Neon connection string uses the `postgresql://` scheme. Add `+psycopg` after `postgresql` to make it work with the `psycopg` (v3) driver used by this app: `postgresql+psycopg://...`
4. Keep this string — you will paste it as `CCS_PLATFORM_DATABASE_URL` when configuring Render services.

---

### 1.3 Backend API — Render Web Service

1. Sign up / log in at <https://render.com>.

2. Click **New → Web Service**.

3. Connect your GitHub account and select this repo.

4. Configure the service:

   | Setting | Value |
   |---------|-------|
   | **Name** | `ccs-api` (or anything) |
   | **Region** | Match your Neon region (e.g. `US East (Ohio)`) |
   | **Branch** | `main` |
   | **Runtime** | **Docker** |
   | **Dockerfile path** | `deploy/Dockerfile.app` |
   | **Docker context** | *(leave blank — defaults to repo root)* |
   | **Instance type** | Free |
   | **Port** | `8040` |

   Leave the start command blank — the Dockerfile `CMD` handles it:
   ```
   python -m ccs_platform.cli api --host 0.0.0.0 --port 8040
   ```

5. Under **Environment Variables**, add:

   | Key | Value |
   |-----|-------|
   | `CCS_PLATFORM_ENVIRONMENT` | `production` |
   | `CCS_PLATFORM_REQUIRE_LOGIN` | `true` |
   | `CCS_PLATFORM_DATABASE_URL` | *(Neon DSN from 1.2)* |
   | `CCS_PLATFORM_SESSION_SECRET_KEY` | *(generated in 1.1)* |
   | `CCS_PLATFORM_RUNTIME_SETTINGS_ENCRYPTION_KEY` | *(generated in 1.1)* |
   | `CCS_PLATFORM_STORAGE_BACKEND` | `gcs` |
   | `CCS_PLATFORM_GCS_BUCKET` | *(GCS bucket name from 1.3 below)* |
   | `CCS_PLATFORM_GCS_PROJECT` | *(GCP project ID)* |
   | `CCS_PLATFORM_GCS_CREDENTIALS_FILE` | `/etc/gcs/credentials.json` |
   | `CCS_PLATFORM_EMBEDDED_WORKER` | `false` |
   | `CCS_PLATFORM_WORKER_QUEUES` | `default` |
   | `CCS_PLATFORM_JOB_DISPATCH_BACKEND` | `database` |
   | `CCS_PLATFORM_RUNTIME_SETTINGS_SEED_SOURCE` | `env` |
   | `CCS_PLATFORM_CORS_ALLOW_ORIGINS` | *(your Vercel URL — set after deploying frontend)* |
   | `CCS_PLATFORM_TIMEZONE` | `Asia/Dubai` |

   > **Note:** `CCS_PLATFORM_GCS_CREDENTIALS_FILE` assumes you upload the service account JSON as a Render **Secret File** (see step 1.3). Set the mount path to `/etc/gcs/credentials.json`.

6. Click **Create Web Service**. Render will build the Docker image (5–10 min on first build).

---

### 1.3 File storage — Google Cloud Storage (free tier)

Render's persistent disks are a paid feature. GCS provides 5 GB free and works out of the box with this app.

**a) Create a GCP project and bucket**

1. Go to <https://console.cloud.google.com> → create a new project (e.g. `ccs-platform`).
2. Navigate to **Cloud Storage → Buckets → Create**.
3. Set a globally unique name (e.g. `ccs-platform-yourname`), choose a region matching your Render region, leave all other defaults.
4. Click **Create**.

**b) Create a service account**

1. In GCP Console → **IAM & Admin → Service Accounts → Create Service Account**.
2. Name it `ccs-storage` → click **Create and Continue**.
3. Grant the role **Storage Object Admin** → **Done**.
4. Click the service account → **Keys → Add Key → Create new key → JSON** → download the `.json` file.

**c) Upload credentials to Render as a Secret File**

1. In the Render `ccs-api` service → **Environment → Secret Files → Add Secret File**.
2. **Filename:** `/etc/gcs/credentials.json`
3. **Contents:** paste the full contents of the downloaded JSON key file.
4. Repeat for the `ccs-worker` service.

> Secret Files are injected into the container at runtime and never appear in build logs or env var lists.

---

### 1.4 Background Worker — Render Background Worker

The scraping worker runs Playwright (Chromium) and must be a separate always-on process.

1. Click **New → Background Worker**.

2. Connect the same repo.

3. Configure:

   | Setting | Value |
   |---------|-------|
   | **Name** | `ccs-worker` |
   | **Region** | Same as API |
   | **Branch** | `main` |
   | **Runtime** | **Docker** |
   | **Dockerfile path** | `deploy/Dockerfile.app` |
   | **Instance type** | Free |
   | **Start command** | `python -m ccs_platform.cli worker` |

4. Under **Environment Variables**, add the **same set** as the API service above, **except** change:

   | Key | Value |
   |-----|-------|
   | `CCS_PLATFORM_EMBEDDED_WORKER` | `false` |
   | `CCS_PLATFORM_WORKER_QUEUES` | `scrape` |

   > The API handles `default` queue jobs (uploads, reclassify, export). The worker handles `scrape` queue jobs (browser automation). This split keeps browser processes off the API service.

5. Add the GCS **Secret File** as you did for the API (same file, same mount path `/etc/gcs/credentials.json`).

   > With GCS as the storage backend, the API and worker don't need to share a disk — both read/write the same GCS bucket directly.

6. Click **Create Background Worker**.

---

### 1.5 Run database migrations

Migrations must run before the app serves traffic. Do this from the Render **Shell** tab on the API service:

1. In the Render dashboard, open the `ccs-api` service.
2. Click the **Shell** tab (available once the service has deployed at least once).
3. Run:

   ```bash
   cd /app
   alembic upgrade head
   ```

   Expected output ends with something like:
   ```
   INFO  Running upgrade 20260226_000006 -> 20260228_000007, Drop dead CategoryRule columns
   ```

4. Restart both services after the migration completes (Render dashboard → **Manual Deploy → Deploy latest commit**, or the **Restart** button).

> **Tip:** You can also set `alembic upgrade head` as a **pre-deploy command** in Render so migrations always run before traffic switches to the new version. Under the service settings → **Build & Deploy → Pre-Deploy Command**, enter:
> ```bash
> cd /app && alembic upgrade head
> ```

---

### 1.6 Seed scraper credentials

On first boot the app looks for runtime settings (scraper usernames/passwords) in the database. Seed them via the admin UI:

1. Navigate to `https://ccs-api.onrender.com` (replace with your Render URL).
2. Log in with the default account (credentials are set via `CCS_PLATFORM_LOGIN_*` env vars — see `.env.example`).
3. Go to **Settings → Runtime Variables**.
4. Add each credential for your banks using the format `<PROFILE_KEY>_<BANK>_<SETTING>`:

   ```
   ALICE_FAB_USERNAME        → your FAB online banking username
   ALICE_FAB_PASSWORD        → your FAB online banking password
   ALICE_ENBD_USERNAME       → ...
   ALICE_ENBD_PASSWORD       → ...
   ALICE_ADCB_CID            → ...
   ALICE_ADCB_LOGIN_PASSWORD → ...
   ALICE_ADCB_PDF_PASSWORD   → ...
   # etc. — see .env.example for full list
   ```

   Mark each as **Secret** (encrypted in DB via Fernet key set in step 1.3).

> Alternatively, set `CCS_PLATFORM_RUNTIME_SETTINGS_SEED_SOURCE=env_file_then_env` and add the credential env vars directly to the Render service. They will be seeded into the DB on startup and can then be managed via the UI.

---

### 1.7 Frontend — Vercel

1. Sign up / log in at <https://vercel.com> (GitHub login works).

2. Click **Add New → Project** → import this GitHub repo.

3. Configure the project:

   | Setting | Value |
   |---------|-------|
   | **Framework preset** | Vite |
   | **Root directory** | `frontend` |
   | **Build command** | `npm run build` |
   | **Output directory** | `dist` |
   | **Install command** | `npm ci` |

4. Under **Environment Variables**, add:

   | Key | Value |
   |-----|-------|
   | `VITE_API_BASE_URL` | `https://ccs-api.onrender.com` *(your Render API URL)* |

5. Click **Deploy**. Vercel builds and hosts the static files.

6. Once deployed, copy the Vercel URL (e.g. `https://ccs-xyz.vercel.app`).

7. Go back to the Render `ccs-api` service → **Environment** → update `CCS_PLATFORM_CORS_ALLOW_ORIGINS` to your Vercel URL:
   ```
   https://ccs-xyz.vercel.app
   ```
   Then redeploy the API service so the CORS header takes effect.

> **Custom domain:** In Vercel → **Settings → Domains**, add your own domain. Update `CCS_PLATFORM_CORS_ALLOW_ORIGINS` on Render to match.

---

### 1.8 Verify the deployment

```bash
# Health check (liveness)
curl https://ccs-api.onrender.com/api/v1/health

# Readiness (checks DB connection and worker queue)
curl https://ccs-api.onrender.com/api/v1/health/ready

# Should return {"status": "ok", ...} for both
```

Open `https://ccs-xyz.vercel.app` in a browser — you should see the login page.

---

### 1.9 Ongoing operations

**Redeploy after code changes:**
Both Render services auto-deploy when you push to `main`. Migrations run via the pre-deploy command (step 1.5 tip) or manually via the Shell.

**Check worker logs:**
Render dashboard → `ccs-worker` → **Logs** tab. Scrape job output (Playwright, bank login steps) appears here.

**Monitor GCS usage:**
The GCS free tier covers 5 GB. To check current usage, go to GCP Console → Cloud Storage → your bucket → **Monitoring** tab. If you exceed 5 GB, GCS charges ~$0.02/GB/month for additional storage.

**Rotate encryption key:**
If you need to rotate `CCS_PLATFORM_RUNTIME_SETTINGS_ENCRYPTION_KEY`, use the re-encryption script before changing the env var:
```bash
# From the Render Shell on the API service
PYTHONPATH=/app python /app/scripts/rotate_runtime_setting_secrets.py \
  --old-key OLD_KEY --new-key NEW_KEY --dry-run

# Then apply:
PYTHONPATH=/app python /app/scripts/rotate_runtime_setting_secrets.py \
  --old-key OLD_KEY --new-key NEW_KEY
```
Then update the env var on both Render services and redeploy.

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
