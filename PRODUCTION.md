# Credit Card Scraper — Production Guide

Two complete production paths:

- **Plan 1 (Free):** Render (API + worker) + Vercel (frontend) + Neon/Supabase (free Postgres)
- **Plan 2 (GCP):** Cloud Run + Cloud SQL + Cloud Storage + Artifact Registry + Secret Manager

Email-driven statement ingestion (no browser scraping for future months) is documented in:

- `docs/operations/email-ingestion-automation.md`

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
| `CCS_PLATFORM_JOB_MAX_DURATION_SECONDS` | `1800` | Wall-clock timeout per job; job is auto-cancelled after this many seconds. Set to `0` to disable. |
| `CCS_PLATFORM_BROWSER_PROXY_URL` | — | HTTP or SOCKS5 proxy for all browser traffic — route through a UAE IP to avoid fraud flags. Format: `socks5://host:port` or `http://user:pass@host:port`. Leave blank in dev. |
| `CCS_PLATFORM_BROWSER_GEO_LATITUDE` | `25.2048` | Latitude reported by the browser's Geolocation API (central Dubai). |
| `CCS_PLATFORM_BROWSER_GEO_LONGITUDE` | `55.2708` | Longitude reported by the browser's Geolocation API (central Dubai). |
| `CCS_PLATFORM_BROWSER_TIMEZONE_ID` | `Asia/Dubai` | IANA timezone the browser advertises (affects `Intl` API and `Date` behaviour). |
| `CCS_PLATFORM_BROWSER_LOCALE` | `en-AE` | Browser locale — sets `navigator.language` and the `Accept-Language` request header. |
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
| Background worker | Embedded in API process | Shares the API's 512 MB RAM |
| Database | Neon | 0.5 GB storage, 1 project, shared compute |
| Frontend | Vercel | Hobby plan, unlimited deployments |
| File storage | Google Cloud Storage (GCS) | 5 GB storage + 1 GB/month egress free |

> **Limitations to know upfront:**
> - Render's free Web Service spins down after 15 minutes of inactivity. The first request after a cold-start takes ~30 seconds. **Scheduled scrape jobs will not fire while the service is spun down** — a scheduled job will only run if something woke the service up first, or if you're on a paid plan. For manual on-demand scraping this is fine.
> - **Render Background Worker is a paid tier (~$7/month) — not free.** This guide runs the worker embedded inside the single API process using `CCS_PLATFORM_EMBEDDED_WORKER=true`, which is free but means Playwright shares the API's 512 MB RAM.
> - **Render persistent disks are a paid add-on — not available on the free tier.** File storage must be external. This guide uses GCS, which has a generous free tier (5 GB) and requires only a Google account (credit card required by Google but not charged within free limits).

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

### 1.3 Backend API — Render Web Service (single service)

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
   | `CCS_PLATFORM_GCS_BUCKET` | *(GCS bucket name from step 1.4 below)* |
   | `CCS_PLATFORM_GCS_PROJECT` | *(GCP project ID)* |
   | `CCS_PLATFORM_GCS_CREDENTIALS_FILE` | `/etc/gcs/credentials.json` |
   | `CCS_PLATFORM_EMBEDDED_WORKER` | `true` |
   | `CCS_PLATFORM_WORKER_QUEUES` | `default,scrape` |
   | `CCS_PLATFORM_MAX_WORKER_THREADS` | `1` |
   | `CCS_PLATFORM_JOB_DISPATCH_BACKEND` | `database` |
   | `CCS_PLATFORM_RUNTIME_SETTINGS_SEED_SOURCE` | `env` |
   | `CCS_PLATFORM_CORS_ALLOW_ORIGINS` | *(your Vercel URL — set after deploying frontend)* |
   | `CCS_PLATFORM_TIMEZONE` | `Asia/Dubai` |

   > **Note:** `CCS_PLATFORM_GCS_CREDENTIALS_FILE` assumes you upload the service account JSON as a Render **Secret File** (see step 1.3). Set the mount path to `/etc/gcs/credentials.json`.
   >
   > `EMBEDDED_WORKER=true` runs the background job worker as a thread inside the same process. `MAX_WORKER_THREADS=1` limits it to one concurrent job at a time, which keeps memory usage manageable on the free 512 MB instance.

6. Click **Create Web Service**. Render will build the Docker image (5–10 min on first build).

---

### 1.4 File storage — Google Cloud Storage (free tier)

Render's persistent disks are a paid feature. GCS provides 5 GB free and works out of the box with this app.

**a) Create a GCP project and bucket**

1. Go to <https://console.cloud.google.com> → create a new project (e.g. `ccs-platform`).
2. Navigate to **Cloud Storage → Buckets → Create**.
3. Set a globally unique name (e.g. `ccs-platform-yourname`), pick any region geographically close to your Render region for lower latency (GCS and Render are on different cloud providers so they'll never share infrastructure — the choice only affects network distance), leave all other defaults.
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

> Secret Files are injected into the container at runtime and never appear in build logs or env var lists. Since the worker runs embedded in the API process, only one service needs this file.

---

### 1.5 Seed scraper credentials



On first boot the app looks for runtime settings (scraper usernames/passwords) in the database. Seed them via the admin UI:

1. Navigate to `https://ccs-api.onrender.com` (replace with your Render URL).
2. Log in with the default account (credentials are set via `CCS_PLATFORM_LOGIN_*` env vars — see `.env.example`).
3. Go to **Settings → Runtime Variables**.
4. Add each credential for your banks using the format `<PROFILE_KEY>_<BANK>_<SETTING>`:

   ```
   HUSSAIN_FAB_USERNAME        → your FAB online banking username
   HUSSAIN_FAB_PASSWORD        → your FAB online banking password
   HUSSAIN_ENBD_USERNAME       → ...
   HUSSAIN_ENBD_PASSWORD       → ...
   HUSSAIN_ADCB_CID            → ...
   HUSSAIN_ADCB_LOGIN_PASSWORD → ...
   HUSSAIN_ADCB_PDF_PASSWORD   → ...
   # etc. — see .env.example for full list
   ```

   Mark each as **Secret** (encrypted in DB via Fernet key set in step 1.3).

> Alternatively, set `CCS_PLATFORM_RUNTIME_SETTINGS_SEED_SOURCE=env_file_then_env` and add the credential env vars directly to the Render service. They will be seeded into the DB on startup and can then be managed via the UI.

---

### 1.6 Frontend — Vercel

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

### 1.7 Verify the deployment

```bash
# Health check (liveness)
curl https://ccs-api.onrender.com/api/v1/health

# Readiness (checks DB connection and worker queue)
curl https://ccs-api.onrender.com/api/v1/health/ready

# Should return {"status": "ok", ...} for both
```

Open `https://ccs-xyz.vercel.app` in a browser — you should see the login page.

---

### 1.8 Email ingestion (optional)

See the **Email Ingestion Automation** section below. For Plan 1:
- Use the **Microsoft / Hotmail path** (GitHub Actions) — no extra infrastructure required.
- The **Gmail path** requires a GCP project regardless of which plan you use for the backend.

### 1.9 Ongoing operations

**Redeploy after code changes:**
The service auto-deploys when you push to `main`. Migrations run automatically at startup — nothing extra to do.

**Check worker logs:**
Render dashboard → `ccs-api` → **Logs** tab. Scrape job output (Playwright, bank login steps) appears here alongside API logs since the worker runs embedded in the same process.

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

### 2.3 Build and push images

Two images are built — a slim API image (no Playwright) and a full worker image (with Playwright).

```bash
SHA=$(git rev-parse --short HEAD)
REPO=europe-west1-docker.pkg.dev/PROJECT_ID/ccs-platform

# Slim image for the API service (~500 MB smaller — no browser runtime)
IMAGE_API="$REPO/api:$SHA"
docker build -f deploy/Dockerfile.api -t "$IMAGE_API" .
docker push "$IMAGE_API"

# Full image for the scraping worker (includes Playwright + Chromium)
IMAGE_WORKER="$REPO/worker:$SHA"
docker build -f deploy/Dockerfile.app -t "$IMAGE_WORKER" .
docker push "$IMAGE_WORKER"
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
  --image="$IMAGE_API" \
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
  --image="$IMAGE_WORKER" \
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
  --image="$IMAGE_API" \
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

### 2.11 Email ingestion (optional)

See the **Email Ingestion Automation** section below. For Plan 2, both paths work:
- **Microsoft path** — GitHub Actions (no extra GCP resources).
- **Gmail path** — Cloud Run relay + Pub/Sub + Cloud Scheduler (all already available in your GCP project).

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

## Email Ingestion Automation

> This section applies to both Plan 1 and Plan 2. The feature is provider-agnostic at the API level — the only difference between plans is _where_ the automation scripts run (GitHub Actions vs GCP Cloud Run / Cloud Scheduler).

Email ingestion lets the app automatically pick up statement PDFs delivered to your email inbox and ingest them without any manual upload. Two providers are supported:

| Provider | Trigger | Automation mechanism |
|----------|---------|---------------------|
| **Microsoft / Hotmail** | Polling (every 4 h) | GitHub Actions workflow |
| **Gmail** | Push (real-time) | GCP Cloud Run + Pub/Sub |

You can enable one, both, or neither. The core app API is the same for both.

### Where credentials live

> **All OAuth credentials and refresh tokens are stored in Runtime Settings (encrypted in the database), not as service environment variables.** The **Email Ingestion** configuration page in the admin UI has dedicated panels for entering and saving them — you do not need to touch deployment env vars for this.

The only env var you set at the infrastructure level is the feature flag:

```
CCS_PLATFORM_EMAIL_INGESTION_ENABLED=true
```

Everything else — client IDs, client secrets, refresh tokens — goes through the UI into Runtime Settings.

---

### About the Ingestion Activity log

Every email the automation script processes creates a record in the **Ingestion Activity** log (Operations → Ingestion Activity). The log is append-only — events are never deleted automatically. In a fresh deployment you will only see events from real ingestion runs. Any records you see from development or test runs on a shared database are expected if the DB was used during testing; they can be cleared by deleting rows from `email_ingestion_events` directly in the database (use `psql` or the Render/GCP SQL console).

---

### EI-1. Enable the feature

In your API service environment variables (Render / Cloud Run / `.env`), add:

```
CCS_PLATFORM_EMAIL_INGESTION_ENABLED=true
```

Without this flag all `/api/v1/email-ingestion/*` endpoints return `404`. Redeploy the API service after adding it. Once enabled, the **Email Ingestion** configuration page and **Ingestion Activity** page become visible in the admin UI.

---

### EI-2. Register an Azure or GCP OAuth app and save credentials

Before adding a mailbox you need OAuth credentials from your email provider. These are saved to Runtime Settings via the admin UI — **not** as deployment env vars.

#### 2a. Microsoft / Hotmail — register an Azure app

1. Go to [portal.azure.com](https://portal.azure.com) and sign in with any Microsoft account (doesn't have to be the mailbox account).

2. Navigate to **Azure Active Directory → App registrations → New registration**.
   - **Name:** `ccs-email-ingest` (or any name you like)
   - **Supported account types:** Select **"Accounts in any organizational directory and personal Microsoft accounts"** (the third option). This is required for personal Hotmail/Outlook accounts.
   - **Redirect URI:** Select type **Web**, value `http://localhost`
   - Click **Register**

3. On the app overview page:
   - Copy **Application (client) ID** — you will need this shortly.

4. Go to **Certificates & secrets → Client secrets → New client secret**.
   - Set an expiry (24 months is fine for personal use).
   - Click **Add**, then immediately copy the **Value** (not the Secret ID). It is only shown once.

5. Go to **API permissions → Add a permission → Microsoft Graph → Delegated permissions**.
   - Search for and add: `Mail.Read` and `offline_access`
   - Click **Grant admin consent for [your tenant]** (or the mailbox account owner will consent during the OAuth flow).

6. In the admin UI → **Email Ingestion** → **Microsoft OAuth** panel:
   - Paste the **Application (client) ID** into the `EMAIL_MS_CLIENT_ID` field.
   - Paste the **client secret value** into the `EMAIL_MS_CLIENT_SECRET` field.
   - Click **Save Microsoft Keys** — these are encrypted and stored in Runtime Settings. The secret is never shown again.

#### 2b. Gmail — create a GCP OAuth 2.0 client

1. Go to [console.cloud.google.com](https://console.cloud.google.com). Use any GCP project (or create one).

2. Navigate to **APIs & Services → Library** and enable **Gmail API**.

3. Go to **APIs & Services → OAuth consent screen**.
   - **User type:** External (unless you have a Google Workspace org).
   - Fill in app name (e.g. `ccs-email-ingest`), support email, and developer email.
   - Under **Scopes**, add `https://www.googleapis.com/auth/gmail.readonly`.
   - Add the Gmail account(s) you will use as **Test users** (required while the app is in testing mode).
   - Save.

4. Go to **APIs & Services → Credentials → Create Credentials → OAuth client ID**.
   - **Application type:** Web application
   - **Authorised redirect URIs:** `http://localhost`
   - Click **Create**. Copy the **Client ID** and **Client Secret** shown.

5. In the admin UI → **Email Ingestion** → **Gmail OAuth** panel:
   - Paste the Client ID into `EMAIL_GMAIL_CLIENT_ID`.
   - Paste the Client Secret into `EMAIL_GMAIL_CLIENT_SECRET`.
   - Click **Save Gmail Keys** — stored encrypted in Runtime Settings.

---

### EI-3. Add a mailbox

In the admin UI → **Email Ingestion** → **Mailboxes** panel:

1. In the **Add Mailbox** row at the top:
   - **Provider dropdown:** Select `Microsoft` or `Gmail`.
   - **Mailbox email:** The inbox address where statements arrive (e.g. `h_abbasi97@hotmail.com`).
   - **Display name (optional):** A human-readable label (e.g. `Hussain Hotmail`).
   - **Active checkbox:** Leave checked.
   - Click **Add Mailbox**.

2. The new mailbox appears in the table below. Note its **ID** column value — you will need the number when pasting refresh tokens.

**Table columns explained:**

| Column | Meaning |
|--------|---------|
| **ID** | Integer ID assigned by the database. Used in the refresh token Runtime Setting key (e.g. `EMAIL_MS_REFRESH_TOKEN_MAILBOX_1`). |
| **Provider** | Microsoft or Gmail |
| **Mailbox** | The inbox email address (editable inline) |
| **Display** | Optional friendly name (editable inline) |
| **Active** | Uncheck to pause ingestion for this mailbox without deleting it |
| **Watch Expiry** | Gmail only — shows when the Pub/Sub push watch expires (must be renewed every 7 days) |
| **Last Sync** | Timestamp of the last successful sync run |
| **Last Error** | Most recent error message from the automation script, if any |
| **Refresh Token** | Password field — paste a new refresh token here and click **Save Token** to store it encrypted in Runtime Settings |

---

### EI-4. Obtain and store a refresh token

The app uses a long-lived refresh token to request short-lived access tokens on each poll cycle. The token is obtained entirely in the admin UI — no terminal commands required.

**Prerequisites:** Set the four OAuth app credential env vars and restart the API server (see [EI-2](#ei-2) for where to register the OAuth apps):

```
CCS_PLATFORM_EMAIL_MS_CLIENT_ID=<your Azure app client ID>
CCS_PLATFORM_EMAIL_MS_CLIENT_SECRET=<your Azure app client secret>
CCS_PLATFORM_EMAIL_GMAIL_CLIENT_ID=<your GCP OAuth client ID>
CCS_PLATFORM_EMAIL_GMAIL_CLIENT_SECRET=<your GCP OAuth client secret>
```

**Steps (same flow for Microsoft and Gmail):**

1. Open the admin UI → **Email Ingestion** → **OAuth Token Setup** panel.
2. Click **Authorize Microsoft** (or **Authorize Google**). A new tab opens with the provider's sign-in page.
3. Sign in with the **mailbox account** whose inbox you want to watch. Accept the permission prompt.
4. The browser redirects to `http://localhost/?code=XXXXX...`. The page will fail to load — that is expected. **Copy the full redirect URL** (or just the `code=...` value) from the address bar.
5. Paste it into the **Auth code** field in the panel (the UI accepts either the raw code or the full URL).
6. Click **Get Refresh Token**. The server exchanges the code and displays the token.
7. Select the target mailbox from the dropdown and click **Save to Mailbox**. The status in the Mailboxes table changes from `Missing` to `Stored`.

> **Microsoft:** Refresh tokens for personal accounts do not expire as long as they are used at least once every 90 days. Repeat steps 2–7 if the token expires.
>
> **Gmail:** Refresh tokens do not expire unless the OAuth consent screen is in testing mode (7-day limit). Publish the consent screen to remove this restriction for personal use.

---

### EI-5. Configure the bank routing matrix

In the admin UI → **Email Ingestion** → **Bank Routing Matrix** panel. One row is shown per bank. Fill in the routing rules for each bank you want to ingest from email.

**Field-by-field guide:**

| Field | What it does | Example |
|-------|-------------|---------|
| **Bank** | Read-only. The bank code. | `ENBD` |
| **Mailbox** | Which inbox to watch for this bank. Select from the mailboxes you created in EI-3. | `Microsoft \| h_abbasi97@hotmail.com` |
| **Sender Allowlist** | Comma-separated email addresses. Only emails **from** these addresses will be matched for this bank. Leave blank to accept mail from any sender (not recommended). | `statements@emiratesnbd.com, no-reply@enbd.com` |
| **Subject Keywords** | Comma-separated keywords. At least one must appear in the email subject for the email to match. Leave blank to skip subject filtering. | `statement, e-statement, credit card` |
| **Filename Regex** | A Python regex tested against the PDF attachment filename. Only attachments whose filename matches are picked up. Leave blank to accept any PDF. | `.*statement.*\.pdf` or `ENBD.*\.pdf` |
| **Gmail Label Filter (JSON)** | Gmail only. Filter by label. Set to `{"label_ids": ["INBOX"], "mode": "any"}` to restrict to inbox, or use a custom label ID. Leave blank for Gmail to accept all messages. | `{"label_ids": ["Label_1234"], "mode": "all"}` |
| **Active** | Uncheck to disable this bank's route without deleting it. | — |

An email must pass **all** non-empty filters to be routed to a bank. If an email passes no bank's filters it is recorded as `ignored` in the Ingestion Activity log.

Click **Save** on each row after editing. Changes take effect on the next poll cycle — no restart is needed.

---

### EI-6. Create a service token

Automation scripts (GitHub Actions, Cloud Run) authenticate to the API using a long-lived machine token — not a user password. The token is created in the admin UI and stored only as a secret in the CI/CD system.

In the admin UI → **Email Ingestion** → **Service Tokens** panel:

1. Enter a **token name** that identifies its purpose (e.g. `github-actions-ms`, `gmail-relay-gcp`).
2. Leave all three **scope checkboxes** checked:
   - `email_ingestion:read` — allows listing mailboxes and routes
   - `email_ingestion:write` — allows updating sync state
   - `email_ingestion:upload` — allows uploading PDFs
3. Click **Create Service Token**.
4. The token value appears once in a text area. **Copy it immediately** — it will not be shown again.

Store the token value:
- **Microsoft (GitHub Actions):** Paste into your repo's **Settings → Secrets and variables → Actions** as `CCS_SERVICE_TOKEN`.
- **Gmail relay (GitHub Actions → Cloud Run):** Create a **separate** token named `gmail-relay-gcp` and paste it as `CCS_GMAIL_RELAY_SERVICE_TOKEN` in GitHub Actions secrets. Using a distinct token means you can revoke the relay's access independently.

The token table shows all created tokens. Click **Revoke** to immediately invalidate a token if it is compromised.

---

### EI-7. Microsoft / Hotmail automation (GitHub Actions)

The ingestion script (`backend/scripts/email_ingest_microsoft.py`) polls Microsoft Graph for new emails every 4 hours.

**Step 1 — Add GitHub Actions secrets**

In your repository: **Settings → Secrets and variables → Actions → New repository secret**:

| Secret | Value |
|--------|-------|
| `CCS_API_BASE_URL` | Your API base URL (e.g. `https://ccs-api.onrender.com`) — no trailing slash |
| `CCS_SERVICE_TOKEN` | The service token value from EI-6 |

**Step 2 — The workflow is already wired**

`.github/workflows/email-ingest-microsoft.yml` runs on `cron: "17 */4 * * *"` (every 4 hours at :17 past). It installs Python dependencies and calls the ingestion script. No further configuration is needed.

**Step 3 — Trigger a dry run**

In GitHub: **Actions → Email Ingest Microsoft → Run workflow → enable "dry run"**. The workflow prints a JSON summary of what it found — no PDFs are actually uploaded.

**Step 4 — Check the results**

A successful run prints:

```json
{
  "provider": "microsoft",
  "mailboxes_processed": 1,
  "messages_scanned": 40,
  "attachments_seen": 3,
  "uploads_uploaded": 2,
  "uploads_duplicate": 1,
  "uploads_ignored": 0,
  "uploads_failed": 0,
  "mailbox_errors": []
}
```

- `mailbox_errors` must be empty — any entry here means the OAuth token failed.
- `uploads_duplicate` is normal — previously ingested statements are skipped.
- `uploads_ignored` means attachments were found but no bank route matched — check your sender allowlist and filename regex.

**Delta sync** — the script stores a Microsoft Graph delta-link per mailbox so each run only fetches new emails since the last successful run. The very first run scans the full inbox.

---

### EI-8. Gmail automation (GCP Cloud Run + Pub/Sub)

Gmail push ingestion delivers new-email notifications in near real-time via Google Cloud Pub/Sub. This requires a GCP project (it also works alongside Plan 1 on Render — the relay Cloud Run service just needs to be reachable publicly).

#### Step 1 — GCP prerequisites

```bash
# Enable required APIs
gcloud services enable \
  gmail.googleapis.com \
  pubsub.googleapis.com \
  run.googleapis.com \
  cloudscheduler.googleapis.com

# Create the Pub/Sub topic
gcloud pubsub topics create gmail-statements

# Create a push subscription (URL will be updated after the relay is deployed)
gcloud pubsub subscriptions create gmail-statements-push \
  --topic=gmail-statements \
  --push-endpoint=https://placeholder.example.com/pubsub/push \
  --ack-deadline=60
```

#### Step 2 — Allow Gmail to publish to your topic

```bash
gcloud pubsub topics add-iam-policy-binding gmail-statements \
  --member="serviceAccount:gmail-api-push@system.gserviceaccount.com" \
  --role="roles/pubsub.publisher"
```

#### Step 3 — Deploy the relay

The relay (`backend/scripts/gmail_ingest_relay.py`) is a small FastAPI service that receives Pub/Sub push notifications and uploads matching PDFs via the API.

**First-time manual deploy** (run from the repo root):

```bash
SHA=$(git rev-parse --short HEAD)
IMAGE_RELAY="europe-west1-docker.pkg.dev/PROJECT_ID/ccs-platform/gmail-relay:$SHA"
docker build --platform linux/amd64 -f deploy/Dockerfile.gmail-relay -t "$IMAGE_RELAY" .
docker push "$IMAGE_RELAY"

gcloud run deploy ccs-gmail-relay \
  --image="$IMAGE_RELAY" \
  --region=europe-west1 \
  --platform=managed \
  --allow-unauthenticated \
  --set-env-vars="CCS_API_BASE_URL=https://YOUR_API_HOST" \
  --set-env-vars="CCS_SERVICE_TOKEN=YOUR_SERVICE_TOKEN" \
  --port=8080 \
  --min-instances=0 \
  --memory=256Mi \
  --cpu=1
```

**Subsequent deploys — GitHub Actions** (`.github/workflows/deploy-gmail-relay.yml`):

The relay is automatically rebuilt and redeployed whenever any of these files change on `main`:
- `backend/scripts/gmail_ingest_relay.py`
- `backend/scripts/email_ingestion_common.py`
- `backend/requirements.txt`
- `deploy/Dockerfile.api`

Add these secrets to your repo (**Settings → Secrets and variables → Actions**):

| Secret | Value |
|--------|-------|
| `GCP_PROJECT_ID` | Your GCP project ID (e.g. `credit-card-scraper-488614`) |
| `GCP_SA_KEY` | JSON key for a service account with **Artifact Registry Writer** and **Cloud Run Admin** roles |
| `CCS_API_BASE_URL` | Your API base URL — same value used in EI-7 |
| `CCS_GMAIL_RELAY_SERVICE_TOKEN` | The service token created for the Gmail relay in EI-6 (keep separate from the Microsoft token) |

To create the service account and grant the required roles:

```bash
gcloud iam service-accounts create ccs-github-deploy \
  --display-name="CCS GitHub Actions deployer"

SA=ccs-github-deploy@PROJECT_ID.iam.gserviceaccount.com

gcloud projects add-iam-policy-binding PROJECT_ID \
  --member="serviceAccount:$SA" \
  --role="roles/run.admin"

gcloud projects add-iam-policy-binding PROJECT_ID \
  --member="serviceAccount:$SA" \
  --role="roles/artifactregistry.writer"

gcloud iam service-accounts add-iam-policy-binding \
  PROJECT_ID-compute@developer.gserviceaccount.com \
  --member="serviceAccount:$SA" \
  --role="roles/iam.serviceAccountUser"

gcloud iam service-accounts keys create gcp-sa-key.json --iam-account="$SA"
# Paste the contents of gcp-sa-key.json into the GCP_SA_KEY secret, then delete the file.
rm gcp-sa-key.json
```

Then point the Pub/Sub subscription at the relay:

```bash
RELAY_URL=$(gcloud run services describe ccs-gmail-relay \
  --region=europe-west1 --format='value(status.url)')

gcloud pubsub subscriptions modify-push-config gmail-statements-push \
  --push-endpoint="${RELAY_URL}/pubsub/push"
```

#### Step 4 — Register and renew the Gmail watch

Gmail push notifications require a watch registration that expires every 7 days.

```bash
# Deploy the renew job
gcloud run jobs create ccs-gmail-watch-renew \
  --image="$IMAGE_RELAY" \
  --region=europe-west1 \
  --set-env-vars="CCS_API_BASE_URL=https://YOUR_API_HOST" \
  --set-env-vars="CCS_SERVICE_TOKEN=YOUR_SERVICE_TOKEN" \
  --set-env-vars="GMAIL_PUBSUB_TOPIC=projects/PROJECT_ID/topics/gmail-statements" \
  --command="python,backend/scripts/gmail_watch_renew.py" \
  --task-timeout=120

# Run it once now to register the watch
gcloud run jobs execute ccs-gmail-watch-renew --region=europe-west1 --wait

# Schedule daily renewal at 02:00
gcloud scheduler jobs create http ccs-gmail-watch-renew-daily \
  --schedule="0 2 * * *" \
  --uri="https://CLOUD_RUN_JOBS_EXECUTE_URL" \
  --http-method=POST \
  --time-zone="Asia/Dubai"
```

#### Step 5 — Verify

Send yourself a test email with a PDF attachment from a sender in your allowlist. Within a few seconds the relay should receive the Pub/Sub notification, download the attachment, and call the upload endpoint. Check **Operations → Ingestion Activity** to confirm the event appears with status `uploaded` or `duplicate`.

---

### EI-9. Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Email Ingestion page shows "feature disabled" | `CCS_PLATFORM_EMAIL_INGESTION_ENABLED` not set | Add the env var and redeploy the API |
| `mailbox_errors` contains entries in the summary | OAuth token expired or refresh token is wrong | Re-run the authorisation flow in EI-4 and save a fresh token via the UI |
| `uploads_failed > 0` | Service token revoked, or `CCS_API_BASE_URL` is wrong | Verify secrets; check API logs for the HTTP status returned |
| `uploads_ignored` is high — no bank matched | Sender not in allowlist, or subject/filename regex doesn't match | Check the actual sender address in the Ingestion Activity log; update allowlist or regex in EI-5 |
| GitHub Actions shows `HTTP 404` on API calls | Feature flag not set, or wrong base URL | Confirm `CCS_PLATFORM_EMAIL_INGESTION_ENABLED=true`; check `CCS_API_BASE_URL` has no trailing slash |
| Gmail push notifications stop arriving | Pub/Sub watch expired after 7 days | Run `ccs-gmail-watch-renew` manually; verify the daily Cloud Scheduler job is active |
| `HTTP 410` from Microsoft Graph | Delta link is stale (> 30 days without a successful run) | The script automatically retries from scratch on 410 — no action needed |
| Ingestion Activity has old test data | DB was shared during development / test runs | Delete rows from `email_ingestion_events` directly via `psql` or the DB console |

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

**Email ingestion (if enabled):**
- [ ] `CCS_PLATFORM_EMAIL_INGESTION_ENABLED=true` set on API service
- [ ] Azure or GCP OAuth app registered; Client ID and Client Secret saved via Email Ingestion → OAuth panels (stored in Runtime Settings)
- [ ] Mailbox(es) added in the Email Ingestion UI with correct provider and email
- [ ] Refresh token obtained via browser OAuth flow and saved via the mailbox row's Refresh Token field (status shows "Stored")
- [ ] Bank routing matrix configured — Mailbox, Sender Allowlist, and Filename Regex set per bank; all rows saved
- [ ] Service token created; value stored as `CCS_SERVICE_TOKEN` in GitHub Actions secrets or GCP Secret Manager
- [ ] Microsoft: `CCS_API_BASE_URL` and `CCS_SERVICE_TOKEN` GitHub Actions secrets set; dry-run passes with `mailbox_errors: []`
- [ ] Gmail: Pub/Sub topic and subscription created; relay deployed and subscription push URL updated; watch registered via `ccs-gmail-watch-renew`; daily Cloud Scheduler job active
- [ ] Gmail: `GCP_PROJECT_ID`, `GCP_SA_KEY`, `CCS_API_BASE_URL`, `CCS_GMAIL_RELAY_SERVICE_TOKEN` secrets set in GitHub Actions so future relay code changes auto-redeploy
- [ ] At least one real email ingested end-to-end — event visible in Operations → Ingestion Activity with status `uploaded`
