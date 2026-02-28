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

---

### EI-1. Enable the feature

Add to your API service environment variables:

```
CCS_PLATFORM_EMAIL_INGESTION_ENABLED=true
```

Without this flag all `/api/v1/email-ingestion/*` endpoints return `404`. Redeploy the API service after adding it.

---

### EI-2. Create a service token

The automation scripts authenticate to the API using a long-lived service token (not a user session). Generate one via the admin UI:

1. Open the app → **Email Ingestion** page → **Service Tokens** panel.
2. Click **Create Token** — give it a descriptive name like `github-actions-ms` or `gmail-relay`.
3. Copy the token value immediately — it is shown only once.

The token requires the scopes `email_ingestion:read`, `email_ingestion:write`, and `email_ingestion:upload` — these are granted automatically when created via the UI.

> Keep the token value as a secret: paste it into GitHub Actions secrets (`CCS_SERVICE_TOKEN`) or GCP Secret Manager, never into source code or env var files.

---

### EI-3. Configure mailboxes and routing

#### 3a. Add a mailbox

In the admin UI → **Email Ingestion** → **Mailboxes** panel:

1. Click **Add Mailbox**.
2. Fill in:
   - **Provider** — `microsoft` or `gmail`
   - **Mailbox email** — the inbox address (e.g. `h_abbasi97@hotmail.com`)
3. Save. Note the mailbox **ID** shown in the table — you need it for the refresh token key below.

#### 3b. Set the OAuth refresh token

The app exchanges a refresh token for short-lived access tokens on each poll cycle. Store the refresh token as a Runtime Setting (encrypted in the DB):

1. Go to **Settings → Runtime Variables**.
2. Add:

   | Key | Value |
   |-----|-------|
   | `EMAIL_MS_CLIENT_ID` | Azure app client ID *(Microsoft only)* |
   | `EMAIL_MS_CLIENT_SECRET` | Azure app client secret *(Microsoft only)* |
   | `EMAIL_MS_REFRESH_TOKEN_MAILBOX_<ID>` | Refresh token for mailbox `<ID>` *(Microsoft)* |
   | `EMAIL_GMAIL_CLIENT_ID` | GCP OAuth client ID *(Gmail only)* |
   | `EMAIL_GMAIL_CLIENT_SECRET` | GCP OAuth client secret *(Gmail only)* |
   | `EMAIL_GMAIL_REFRESH_TOKEN_MAILBOX_<ID>` | Refresh token for mailbox `<ID>` *(Gmail)* |

   Replace `<ID>` with the integer mailbox ID from step 3a. Mark all values as **Secret** so they are Fernet-encrypted in the database.

> See **EI-5** below for how to obtain a refresh token for each provider.

#### 3c. Configure bank routing

Each mailbox route tells the app which bank to associate with emails from a given sender. In the **Email Ingestion** → **Bank Routing** panel:

1. For each enabled bank, set:
   - **Mailbox** — which inbox to watch
   - **Sender allowlist** — comma-separated sender email addresses that carry statements for this bank (e.g. `statements@emiratesnbd.com`). Leave blank to accept any sender.
2. Save. The routing matrix is loaded fresh on every poll cycle — no restart needed.

---

### EI-4a. Microsoft / Hotmail path (GitHub Actions)

The ingestion script (`backend/scripts/email_ingest_microsoft.py`) runs as a GitHub Actions scheduled workflow every 4 hours.

**Step 1 — Add GitHub Actions secrets**

In your repository: **Settings → Secrets and variables → Actions → New repository secret**:

| Secret | Value |
|--------|-------|
| `CCS_API_BASE_URL` | Your API base URL, e.g. `https://ccs-api.onrender.com` |
| `CCS_SERVICE_TOKEN` | The service token from EI-2 |

**Step 2 — The workflow is already wired**

`.github/workflows/email-ingest-microsoft.yml` runs on `schedule: cron: "17 */4 * * *"` (every 4 hours). It checks out the repo, installs Python dependencies, and runs the script. No further configuration is needed beyond the two secrets above.

**Step 3 — Trigger a dry run manually**

In GitHub: **Actions → Email Ingest Microsoft → Run workflow → check "dry run"**. The summary JSON printed in the logs shows what would be uploaded without actually calling the API.

**Step 4 — Verify**

Check the action logs. A successful run prints a JSON report:

```json
{
  "provider": "microsoft",
  "mailboxes_processed": 1,
  "messages_scanned": 12,
  "attachments_seen": 3,
  "uploads_uploaded": 2,
  "uploads_duplicate": 1,
  "uploads_ignored": 0,
  "uploads_failed": 0,
  "mailbox_errors": []
}
```

`mailbox_errors` must be empty. `uploads_duplicate` is normal — statements already ingested are skipped.

**Delta state** — the script stores a Microsoft Graph delta-link per mailbox in the app's `sync_state_json` column so each run only fetches new emails since the last successful sync. The first run after setup will scan the full inbox.

---

### EI-4b. Gmail path (GCP Cloud Run + Pub/Sub)

Gmail push ingestion delivers new-message notifications in near real-time via Google Cloud Pub/Sub. You need a GCP project for this path (it also works alongside Plan 1 on Render — the relay just needs to be publicly reachable).

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

# Create the push subscription (points to the relay Cloud Run URL — set after deploy)
# You'll update this URL after step 3.
gcloud pubsub subscriptions create gmail-statements-push \
  --topic=gmail-statements \
  --push-endpoint=https://YOUR_RELAY_URL/pubsub/push \
  --ack-deadline=60
```

#### Step 2 — Grant Gmail permission to publish to your topic

```bash
# Allow the Gmail API service account to publish to the topic
gcloud pubsub topics add-iam-policy-binding gmail-statements \
  --member="serviceAccount:gmail-api-push@system.gserviceaccount.com" \
  --role="roles/pubsub.publisher"
```

#### Step 3 — Deploy the relay as a Cloud Run service

The relay (`backend/scripts/gmail_ingest_relay.py`) is a small FastAPI app that receives Pub/Sub push messages and calls `POST /api/v1/email-ingestion/upload`.

```bash
# Build and push relay image (uses the same Dockerfile.api — no Playwright needed)
SHA=$(git rev-parse --short HEAD)
IMAGE_RELAY="europe-west1-docker.pkg.dev/PROJECT_ID/ccs-platform/gmail-relay:$SHA"
docker build -f deploy/Dockerfile.api -t "$IMAGE_RELAY" .
docker push "$IMAGE_RELAY"

# Deploy
gcloud run deploy ccs-gmail-relay \
  --image="$IMAGE_RELAY" \
  --region=europe-west1 \
  --platform=managed \
  --allow-unauthenticated \
  --set-env-vars="CCS_API_BASE_URL=https://YOUR_API_HOST" \
  --set-env-vars="CCS_SERVICE_TOKEN=YOUR_SERVICE_TOKEN" \
  --port=8080 \
  --command="python,backend/scripts/gmail_ingest_relay.py" \
  --min-instances=0 \
  --memory=256Mi \
  --cpu=1
```

Then update the Pub/Sub subscription with the relay URL:

```bash
RELAY_URL=$(gcloud run services describe ccs-gmail-relay \
  --region=europe-west1 --format='value(status.url)')

gcloud pubsub subscriptions modify-push-config gmail-statements-push \
  --push-endpoint="${RELAY_URL}/pubsub/push"
```

#### Step 4 — Register a Gmail watch (and renew it daily)

Gmail push notifications expire after 7 days. The watch-renew script (`backend/scripts/gmail_watch_renew.py`) refreshes it.

```bash
# Deploy the watch-renew script as a Cloud Run job
gcloud run jobs create ccs-gmail-watch-renew \
  --image="$IMAGE_RELAY" \
  --region=europe-west1 \
  --set-env-vars="CCS_API_BASE_URL=https://YOUR_API_HOST" \
  --set-env-vars="CCS_SERVICE_TOKEN=YOUR_SERVICE_TOKEN" \
  --set-env-vars="GMAIL_PUBSUB_TOPIC=projects/PROJECT_ID/topics/gmail-statements" \
  --command="python,backend/scripts/gmail_watch_renew.py" \
  --task-timeout=120

# Schedule it to run daily at 02:00
gcloud scheduler jobs create http ccs-gmail-watch-renew-daily \
  --schedule="0 2 * * *" \
  --uri="https://CLOUD_RUN_JOBS_EXECUTE_URL" \
  --http-method=POST \
  --time-zone="Asia/Dubai"
```

Alternatively, run it once manually first:

```bash
gcloud run jobs execute ccs-gmail-watch-renew --region=europe-west1 --wait
```

#### Step 5 — Verify

Send yourself a test email with a PDF attachment from a sender in your allowlist. Within seconds, the relay should receive the Pub/Sub push, fetch the message from the Gmail API, match the route, and call the upload endpoint. Check the **Email Ingestion → Events** page in the admin UI to confirm a new ingestion event appears.

---

### EI-5. Obtaining OAuth refresh tokens

Both providers require a one-time OAuth authorisation to get a long-lived refresh token. The app does not have a built-in OAuth authorisation flow — you perform this once locally and paste the resulting refresh token into Runtime Settings.

#### Microsoft refresh token

1. **Register an Azure app:**
   - Go to [portal.azure.com](https://portal.azure.com) → **App registrations → New registration**.
   - Name: `ccs-email-ingest` — **Supported account types: Personal Microsoft accounts only**.
   - Redirect URI: `http://localhost` (type: Web).
   - Click **Register**.
   - Copy **Application (client) ID** → this is `EMAIL_MS_CLIENT_ID`.

2. **Add client secret:**
   - In your app → **Certificates & secrets → New client secret**.
   - Copy the **Value** immediately → this is `EMAIL_MS_CLIENT_SECRET`.

3. **Add API permissions:**
   - **API permissions → Add a permission → Microsoft Graph → Delegated permissions**.
   - Add: `Mail.Read`, `offline_access`.
   - Click **Grant admin consent** (or the account owner must consent during the OAuth flow).

4. **Authorise and capture the refresh token** (one-time, run locally):

   ```bash
   # Step 1 — open this URL in a browser, sign in with the mailbox account
   # Replace CLIENT_ID with your app's Application ID
   echo "https://login.microsoftonline.com/consumers/oauth2/v2.0/authorize?\
   client_id=CLIENT_ID\
   &response_type=code\
   &redirect_uri=http%3A%2F%2Flocalhost\
   &scope=Mail.Read+offline_access\
   &response_mode=query"

   # Step 2 — after redirect, copy the `code` param from the browser address bar
   # Step 3 — exchange it for tokens
   curl -X POST https://login.microsoftonline.com/consumers/oauth2/v2.0/token \
     -d "client_id=CLIENT_ID" \
     -d "client_secret=CLIENT_SECRET" \
     -d "code=PASTE_CODE_HERE" \
     -d "redirect_uri=http://localhost" \
     -d "grant_type=authorization_code" \
     -d "scope=Mail.Read offline_access"
   ```

   The response contains `"refresh_token"`. Copy it.

5. Paste into Runtime Settings as `EMAIL_MS_REFRESH_TOKEN_MAILBOX_<ID>`.

#### Gmail refresh token

1. **Create a GCP OAuth 2.0 client:**
   - In GCP Console → **APIs & Services → Credentials → Create Credentials → OAuth client ID**.
   - Application type: **Web application**.
   - Authorised redirect URIs: `http://localhost`.
   - Click **Create**. Copy **Client ID** and **Client Secret**.

2. **Add to Runtime Settings** now: `EMAIL_GMAIL_CLIENT_ID`, `EMAIL_GMAIL_CLIENT_SECRET`.

3. **Authorise and capture the refresh token** (one-time, run locally):

   ```bash
   # Step 1 — open this URL in a browser, sign in with the Gmail account
   echo "https://accounts.google.com/o/oauth2/v2/auth?\
   client_id=CLIENT_ID\
   &redirect_uri=http%3A%2F%2Flocalhost\
   &response_type=code\
   &scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fgmail.readonly\
   &access_type=offline\
   &prompt=consent"

   # Step 2 — after redirect, copy the `code` param from the browser address bar
   # Step 3 — exchange for tokens
   curl -X POST https://oauth2.googleapis.com/token \
     -d "client_id=CLIENT_ID" \
     -d "client_secret=CLIENT_SECRET" \
     -d "code=PASTE_CODE_HERE" \
     -d "redirect_uri=http://localhost" \
     -d "grant_type=authorization_code"
   ```

   The response contains `"refresh_token"`. Copy it. **`prompt=consent` is required** — without it Google will not return a refresh token if the account has previously authorised this client.

4. Paste into Runtime Settings as `EMAIL_GMAIL_REFRESH_TOKEN_MAILBOX_<ID>`.

---

### EI-6. Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `mailbox_errors` contains entries | OAuth token expired or invalid | Re-run the authorisation flow in EI-5 to get a fresh refresh token |
| `uploads_failed > 0` | Service token revoked or wrong `CCS_API_BASE_URL` | Verify secrets; check API logs for the specific HTTP error |
| Route not matching — `uploads_ignored` is high | Sender not in allowlist | Check sender email in Events table; update allowlist in routing matrix |
| GitHub Actions run shows `404` on API calls | `EMAIL_INGESTION_ENABLED` not set | Set `CCS_PLATFORM_EMAIL_INGESTION_ENABLED=true` and redeploy API |
| Gmail push not arriving | Pub/Sub watch expired | Run `ccs-gmail-watch-renew` job manually; ensure daily scheduler is configured |
| `HTTP 410` from Microsoft Graph delta | Delta link is stale (> 30 days) | The script automatically retries from scratch when it receives a 410 — no action needed |

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
- [ ] Service token created and stored as `CCS_SERVICE_TOKEN` secret
- [ ] Mailbox(es) added in the Email Ingestion UI
- [ ] OAuth refresh token(s) stored as Runtime Settings (`EMAIL_MS_REFRESH_TOKEN_MAILBOX_<ID>` / `EMAIL_GMAIL_REFRESH_TOKEN_MAILBOX_<ID>`)
- [ ] Bank routing matrix configured with correct sender allowlist per bank
- [ ] Microsoft: `CCS_API_BASE_URL` and `CCS_SERVICE_TOKEN` GitHub Actions secrets set; dry-run passes
- [ ] Gmail: Pub/Sub topic and subscription created; relay deployed; watch registered; daily renew scheduler active
- [ ] At least one test email ingested end-to-end (visible in Events table)
