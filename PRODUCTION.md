# Production Deployment Guide

Step-by-step instructions for deploying the full stack. Follow the sections in order — each service depends on values from the previous one.

For the system architecture overview see [ARCHITECTURE.md](ARCHITECTURE.md).

---

## Services overview

| Service | Platform | Notes |
|---------|----------|-------|
| Database | Neon | Free managed PostgreSQL |
| Backend API | Render | `Dockerfile.api`, embedded worker |
| PDF Storage | GCS | Cloud Storage bucket |
| Frontend | Vercel | Static React build |
| Gmail Relay | GCP Cloud Run | `Dockerfile.gmail-relay` — only needed for Gmail ingestion |
| Scraper | Local machine | `scraper/` CLI, run manually when needed |

---

## Prerequisites

| Tool | Purpose |
|------|---------|
| Git | Clone and push |
| Python 3.12+ | Generate secret keys locally |
| Node 20 LTS | Frontend build (Vercel handles this, but useful locally) |
| `gcloud` CLI | GCS bucket + Cloud Run (Gmail relay only) |
| `gsutil` | GCS bucket setup (bundled with `gcloud`) |

Install the `gcloud` CLI: https://cloud.google.com/sdk/docs/install

```bash
gcloud auth login
gcloud config set project YOUR_GCP_PROJECT_ID
```

---

## 1 — Neon (PostgreSQL)

### 1.1 Create a project

1. Sign up at [neon.tech](https://neon.tech) and create a new project.
2. Name the database `ccs_platform`.
3. Choose a region close to your Render region (e.g. `us-east-1`).

### 1.2 Get the connection string

In the Neon dashboard go to **Connection Details**, select the **psycopg** (not asyncpg) driver, and copy the full DSN. It looks like:

```
postgresql+psycopg://user:password@ep-xxx.us-east-1.aws.neon.tech/ccs_platform?sslmode=require
```

Save this — it becomes `CCS_PLATFORM_DATABASE_URL` on Render.

### 1.3 Note on migrations

Alembic runs automatically on every app startup — `init_db()` calls `alembic upgrade head` before the server begins serving traffic. No pre-deploy command or manual migration step is needed.

---

## 2 — GCS Storage Bucket

### 2.1 Create the bucket

```bash
export PROJECT=your-gcp-project-id
export BUCKET=ccs-platform-pdfs        # must be globally unique
export REGION=us-east1                 # match Render/Neon region

gsutil mb -p $PROJECT -l $REGION -b on gs://$BUCKET
```

`-b on` enables uniform bucket-level access (no per-object ACLs).

### 2.2 Create a service account

```bash
gcloud iam service-accounts create ccs-backend \
  --project $PROJECT \
  --display-name "CCS Backend"
```

### 2.3 Grant bucket access

```bash
gsutil iam ch \
  serviceAccount:ccs-backend@$PROJECT.iam.gserviceaccount.com:roles/storage.objectAdmin \
  gs://$BUCKET
```

### 2.4 Download a JSON key

```bash
gcloud iam service-accounts keys create gcs-key.json \
  --iam-account ccs-backend@$PROJECT.iam.gserviceaccount.com \
  --project $PROJECT
```

Keep `gcs-key.json` — you'll paste its contents into a Render secret file in the next section.

---

## 3 — Render (Backend API)

### 3.1 Generate secrets locally

Run these commands on your local machine and copy the outputs:

```bash
# Session signing key
python -c "import secrets; print(secrets.token_hex(32))"

# Fernet encryption key for runtime settings
python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
```

Also generate bcrypt password hashes for each admin account:

```bash
cd backend && source .venv/bin/activate
ccs-platform hash-password    # enter hussain's password → copy $2b$... output
ccs-platform hash-password    # enter tejasvie's password → copy $2b$... output
```

### 3.2 Create the web service

1. In the Render dashboard click **New → Web Service**.
2. Connect your GitHub repo.
3. Set:
   - **Name**: `ccs-platform`
   - **Runtime**: `Docker`
   - **Dockerfile path**: `deploy/Dockerfile.api`
   - **Docker context**: `.` (repo root)
   - **Instance type**: Free (512 MB RAM)
   - **Region**: Choose one closest to your Neon region

### 3.3 Add the GCS key as a secret file

In the Render service → **Environment → Secret Files**:

- **Filename**: `/etc/secrets/gcs-key.json`
- **Contents**: paste the full contents of `gcs-key.json`

### 3.4 Set environment variables

In the Render service → **Environment → Environment Variables**, add all of the following:

**Required:**

| Key | Value |
|-----|-------|
| `CCS_PLATFORM_ENVIRONMENT` | `production` |
| `CCS_PLATFORM_DATABASE_URL` | The Neon DSN from step 1.2 |
| `CCS_PLATFORM_SESSION_SECRET_KEY` | Output from `secrets.token_hex(32)` |
| `CCS_PLATFORM_RUNTIME_SETTINGS_ENCRYPTION_KEY` | Output from `Fernet.generate_key()` |
| `CCS_PLATFORM_LOGIN_HASH_HUSSAIN` | `$2b$...` hash from `hash-password` |
| `CCS_PLATFORM_LOGIN_HASH_TEJASVIE` | `$2b$...` hash from `hash-password` |
| `CCS_PLATFORM_STORAGE_BACKEND` | `gcs` |
| `CCS_PLATFORM_GCS_BUCKET` | `ccs-platform-pdfs` (your bucket name) |
| `CCS_PLATFORM_GCS_CREDENTIALS_FILE` | `/etc/secrets/gcs-key.json` |

**Recommended:**

| Key | Value |
|-----|-------|
| `CCS_PLATFORM_EMBEDDED_WORKER` | `true` |
| `CCS_PLATFORM_CORS_ALLOW_ORIGINS` | `https://your-vercel-app.vercel.app` |
| `CCS_PLATFORM_TIMEZONE` | `Asia/Dubai` |

### 3.5 Deploy

Click **Deploy** (or push to your connected branch). Watch the build logs — a successful deploy ends with:

```
Uvicorn running on http://0.0.0.0:8040
```

### 3.6 Verify

```bash
curl https://your-service.onrender.com/api/v1/health
# → {"status": "ok", ...}
```

### 3.7 Seed runtime settings (first boot only)

After the first deploy, navigate to the admin UI:

1. Log in with hussain or tejasvie credentials.
2. Go to **Runtime Variables**.
3. For each profile (hussain, tejasvie), set the PDF decryption passwords:
   - `ADCB_PDF_PASSWORD`
   - `ADCB_CID` (fallback)
   - `SIB_PDF_PASSWORD`

Alternatively, add these to the Render environment before the first deploy (they are seeded automatically on startup):

```
HUSSAIN_ADCB_PDF_PASSWORD=...
HUSSAIN_SIB_PDF_PASSWORD=...
TEJASVIE_ADCB_PDF_PASSWORD=...
TEJASVIE_SIB_PDF_PASSWORD=...
```

### 3.8 Create a scraper service token

1. In the admin UI go to **Service API Tokens → New token**.
2. Set scope: `upload`.
3. Copy the token — this becomes `CCS_SCRAPER_API_TOKEN` in the scraper's `.env`.

---

## 4 — Vercel (Frontend)

### 4.1 Import the project

1. Go to [vercel.com](https://vercel.com) and click **Add New → Project**.
2. Import your GitHub repository.

### 4.2 Configure the project

| Setting | Value |
|---------|-------|
| **Root Directory** | `frontend` |
| **Framework Preset** | Vite |
| **Build Command** | `npm run build` |
| **Output Directory** | `dist` |

### 4.3 Set environment variables

| Key | Value |
|-----|-------|
| `VITE_API_BASE_URL` | `https://your-service.onrender.com` |

### 4.4 Deploy

Click **Deploy**. On success, Vercel shows the production URL (e.g. `https://ccs.vercel.app`).

Go back to Render and update `CCS_PLATFORM_CORS_ALLOW_ORIGINS` to the exact Vercel URL.

### 4.5 Verify

Open the Vercel URL in a browser — you should see the login page.

---

## 5 — Gmail Pub/Sub & Relay Worker

This section is only needed if you want automatic Gmail PDF ingestion. Skip it if you use manual scraping only.

### 5.1 Enable required APIs

```bash
gcloud services enable \
  run.googleapis.com \
  pubsub.googleapis.com \
  gmail.googleapis.com \
  cloudscheduler.googleapis.com \
  --project $PROJECT
```

### 5.2 Create the Pub/Sub topic and subscription

```bash
export TOPIC=ccs-gmail-push
export RUN_SERVICE_URL=https://ccs-gmail-relay-xxxx-uc.a.run.app  # placeholder, update after step 5.5

# Create topic
gcloud pubsub topics create $TOPIC --project $PROJECT

# Grant Gmail permission to publish to the topic
gcloud pubsub topics add-iam-policy-binding $TOPIC \
  --member=serviceAccount:gmail-api-push@system.gserviceaccount.com \
  --role=roles/pubsub.publisher \
  --project $PROJECT
```

The subscription is created after the Cloud Run URL is known (step 5.6).

### 5.3 Create an OAuth 2.0 client for Gmail

1. In GCP Console go to **APIs & Services → Credentials → Create Credentials → OAuth 2.0 Client ID**.
2. Application type: **Web application**.
3. Add `https://your-service.onrender.com` as an **Authorized redirect URI**.
4. Copy the **Client ID** and **Client Secret**.

Set these on Render:

```
CCS_PLATFORM_EMAIL_INGESTION_ENABLED=true
CCS_PLATFORM_EMAIL_GMAIL_CLIENT_ID=<client-id>
CCS_PLATFORM_EMAIL_GMAIL_CLIENT_SECRET=<client-secret>
```

### 5.4 Generate the Gmail OAuth refresh token

In the admin UI:

1. Go to **Email Ingestion → Mailboxes → Add mailbox** (provider: Gmail).
2. Click **OAuth Token Setup** and follow the browser flow to authorize.
3. The refresh token is stored automatically in runtime settings.

### 5.5 Create a service account for the relay

```bash
gcloud iam service-accounts create ccs-gmail-relay \
  --display-name "CCS Gmail Relay" \
  --project $PROJECT
```

### 5.6 Create a service API token for the relay

In the admin UI go to **Service API Tokens → New token**. Set scope: `email_ingestion:upload`. Copy the token.

### 5.7 Build and deploy the Cloud Run relay

```bash
# Build and push
gcloud builds submit \
  --tag gcr.io/$PROJECT/ccs-gmail-relay \
  --dockerfile deploy/Dockerfile.gmail-relay \
  . \
  --project $PROJECT

# Deploy
gcloud run deploy ccs-gmail-relay \
  --image gcr.io/$PROJECT/ccs-gmail-relay \
  --region us-central1 \
  --platform managed \
  --no-allow-unauthenticated \
  --service-account ccs-gmail-relay@$PROJECT.iam.gserviceaccount.com \
  --set-env-vars "CCS_API_BASE_URL=https://your-service.onrender.com,CCS_SERVICE_TOKEN=<relay-service-token>" \
  --project $PROJECT
```

Copy the Cloud Run service URL from the output.

### 5.8 Create the push subscription

```bash
export RUN_SERVICE_URL=https://ccs-gmail-relay-xxxx-uc.a.run.app  # from step 5.7 output

# Allow Pub/Sub to invoke the Cloud Run service
gcloud run services add-iam-policy-binding ccs-gmail-relay \
  --region us-central1 \
  --member=serviceAccount:service-$(gcloud projects describe $PROJECT --format='value(projectNumber)')@gcp-sa-pubsub.iam.gserviceaccount.com \
  --role=roles/run.invoker \
  --project $PROJECT

# Create push subscription pointing at the relay
gcloud pubsub subscriptions create ccs-gmail-push-sub \
  --topic $TOPIC \
  --push-endpoint="$RUN_SERVICE_URL/pubsub/push" \
  --push-auth-service-account=ccs-gmail-relay@$PROJECT.iam.gserviceaccount.com \
  --ack-deadline=60 \
  --project $PROJECT
```

### 5.9 Schedule daily Gmail watch renewal

Gmail push watches expire after 7 days. A Cloud Scheduler job renews them daily.

```bash
# Create the scheduler job
gcloud scheduler jobs create http ccs-gmail-watch-renew \
  --schedule="0 6 * * *" \
  --uri="$RUN_SERVICE_URL/watch/renew" \
  --http-method=POST \
  --oidc-service-account-email=ccs-gmail-relay@$PROJECT.iam.gserviceaccount.com \
  --location=us-central1 \
  --project $PROJECT
```

### 5.10 Verify

```bash
# Trigger a manual watch renewal to confirm end-to-end connectivity
gcloud scheduler jobs run ccs-gmail-watch-renew \
  --location=us-central1 \
  --project $PROJECT
```

Check Cloud Run logs:

```bash
gcloud run services logs read ccs-gmail-relay \
  --region us-central1 \
  --project $PROJECT \
  --limit 50
```

---

## 6 — Scraper CLI (local)

The scraper runs on your local machine to download bank statements and upload them to the deployed backend.

### 6.1 Install

```bash
cd scraper
python3 -m venv .venv && source .venv/bin/activate
pip install -e .
ccs-scraper install-browser
```

### 6.2 Configure

```bash
cp .env.example .env
```

Minimum `.env` for production use:

```env
CCS_SCRAPER_TARGET_URL=https://your-service.onrender.com
CCS_SCRAPER_API_TOKEN=<service token from step 3.9>
CCS_SCRAPER_HEADLESS=true

HUSSAIN_FAB_USERNAME=...
HUSSAIN_FAB_PASSWORD=...
HUSSAIN_ADCB_CID=...
HUSSAIN_ADCB_LOGIN_PASSWORD=...
HUSSAIN_ADCB_PDF_PASSWORD=...
# ... add other banks as needed

TEJASVIE_FAB_USERNAME=...
# ... tejasvie credentials
```

### 6.3 Run

```bash
# Scrape all configured banks for hussain (current month)
ccs-scraper scrape --profile hussain

# Backfill a date range
ccs-scraper scrape --profile hussain --months 2024-01:2025-12

# Scrape tejasvie
ccs-scraper scrape --profile tejasvie --months 2025-01:2025-12

# Upload existing PDFs manually
ccs-scraper upload --profile hussain ~/Downloads/statement.pdf
```

---

## Operations

### Key rotation

```bash
# Rotate runtime settings encryption key
CCS_PLATFORM_RUNTIME_SETTINGS_OLD_ENCRYPTION_KEY=<old-key> \
CCS_PLATFORM_RUNTIME_SETTINGS_ENCRYPTION_KEY=<new-key> \
PYTHONPATH=backend python backend/scripts/rotate_runtime_setting_secrets.py --dry-run

# Remove --dry-run once output looks correct
```

### Migration preflight

Run before deploying a version that includes DB migrations:

```bash
cd backend && python scripts/migration_preflight.py
```

### Retention enforcement

```bash
# Dry-run (shows what would be deleted)
PYTHONPATH=backend python backend/scripts/enforce_retention.py

# Apply
PYTHONPATH=backend python backend/scripts/enforce_retention.py --apply
```

### Backup / restore drill

```bash
PYTHONPATH=backend python backend/scripts/backup_platform_state.py --label nightly
PYTHONPATH=backend python backend/scripts/backup_restore_drill.py --label monthly
```

---

## docker-compose (self-hosted alternative)

For self-hosted deployments (not Render/Vercel):

```bash
cp .env.example .env.production
# Edit .env.production with your secrets
docker-compose -f deploy/docker-compose.prod.yml up -d
```
