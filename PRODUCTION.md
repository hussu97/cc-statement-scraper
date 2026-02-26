# Credit Card Scraper Production Guide

This document gives you **two complete production paths** for this repo:

- **Plan 1 (Free/Near-Free):** Oracle Always Free VM + Docker Compose + SQLite
- **Plan 2 (Managed GCP):** Cloud Run + Cloud SQL PostgreSQL + Cloud Storage + Artifact Registry + Secret Manager
- **Recommended (Hybrid):** Shared production PostgreSQL + shared production GCS + worker(s) running on server and/or local laptop

Locked decisions used in this guide:

- Region default: `europe-west1`
- Access model: private/admin-only
- Scraping mode: full scraping enabled in production
- DB strategy: Plan 1 uses SQLite; Plan 2 uses Cloud SQL PostgreSQL

---

## 0. Recommended Go-Live Topology (Hybrid Worker, Shared DB+GCS)

Use this as the default go-live model:

- **Single source of truth for state:** one production PostgreSQL database.
- **Single source of truth for document storage:** one production GCS bucket.
- **Multiple workers allowed:** run worker on prod server, local laptop, or both.
- **No duplicate decision by local filesystem path:** statement replacement is driven by DB identity `(profile_id, bank_code, statement_reference, statement_date)`.

### 0.1 Topology

- `api` (production): connected to production Postgres + production GCS.
- `worker` (production): connected to production Postgres + production GCS.
- `worker` (local laptop, optional): connected to same production Postgres + same production GCS.
- `frontend`: talks to production API.

### 0.2 Why this works for idempotency

- PDF archival is persisted in DB (`pdf_files`) with checksum + storage key.
- Statement replacement is DB-transactional by canonical statement identity.
- Re-upload/re-scrape of the same statement key replaces statement rows deterministically.
- Local path names are only transient transport; final dedupe/replacement decision is DB-driven.

### 0.3 Required runtime config for this model

Set these on **all runtimes** (prod API, prod worker, local worker):

- `CCS_PLATFORM_DATABASE_URL=postgresql+psycopg://...` (same prod DB)
- `CCS_PLATFORM_STORAGE_BACKEND=gcs`
- `CCS_PLATFORM_GCS_BUCKET=<prod-bucket>`
- `CCS_PLATFORM_GCS_PROJECT=<project-id>`
- `CCS_PLATFORM_RUNTIME_SETTINGS_SEED_SOURCE=none` (recommended in shared-DB mode; prevents startup env reseeding drift)
- `CCS_PLATFORM_EMBEDDED_WORKER=false` on API process

Local worker only:

- `CCS_PLATFORM_WORKER_QUEUES=scrape` (recommended)
- `CCS_PLATFORM_MAX_WORKER_THREADS=1` (recommended for bank portal stability)
- `CCS_DOWNLOADS_DIR=<local-temp-download-dir>`
- Optional auth for GCS:
  - `CCS_PLATFORM_GCS_CREDENTIALS_FILE=<path-to-sa-json>` **or**
  - `GOOGLE_APPLICATION_CREDENTIALS=<path-to-sa-json>` **or**
  - `gcloud auth application-default login`

### 0.4 Local machine checklist (what must stay local)

Keep these on your laptop:

- Repo checkout and Python virtualenv.
- Playwright Chromium installation.
- A local `.env.local-worker` with non-repo secrets/config.
- If DB is private: Cloud SQL Auth Proxy (or equivalent private-network tunnel) to reach production Postgres.
- Local transient folders for:
  - browser state (`data/state/profiles/...`)
  - temporary incoming/download files (`data/incoming/...`)
  - logs (`logs/...`)
- GCP auth material if not using ADC (service-account JSON file).

You do **not** need local persistent PDF archive in this topology; PDFs are archived to GCS.

### 0.5 Example local worker env file

```bash
# shared production control plane
CCS_PLATFORM_DATABASE_URL=postgresql+psycopg://<user>:<pass>@<host>:5432/<db>
CCS_PLATFORM_STORAGE_BACKEND=gcs
CCS_PLATFORM_GCS_BUCKET=<prod-bucket>
CCS_PLATFORM_GCS_PROJECT=<gcp-project>
CCS_PLATFORM_RUNTIME_SETTINGS_SEED_SOURCE=none
CCS_PLATFORM_TIMEZONE=Asia/Dubai

# worker behavior
CCS_PLATFORM_EMBEDDED_WORKER=false
CCS_PLATFORM_WORKER_QUEUES=scrape
CCS_PLATFORM_MAX_WORKER_THREADS=1
CCS_PLATFORM_JOB_DISPATCH_BACKEND=database
CCS_DOWNLOADS_DIR=/Users/<you>/ccs-downloads

# optional: when not using ADC
# CCS_PLATFORM_GCS_CREDENTIALS_FILE=/Users/<you>/.config/gcp/ccs-storage-sa.json
```

Run local worker:

```bash
cd ~/Documents/GitHub/scrapers/credit-card-scraper
source .venv/bin/activate
export $(grep -v '^#' .env.local-worker | xargs)
python -m ccs_platform.cli worker
```

### 0.6 Queueing guidance when both prod + local workers are active

- If both listen to `scrape`, DB row-claiming coordinates which worker executes a job.
- To avoid concurrent portal pressure, keep each scrape worker at low concurrency (`MAX_WORKER_THREADS=1`).
- If you want strict routing (for example only local machine should scrape), map queue subscriptions accordingly.

---

## 1. Current Architecture Snapshot

Current repo architecture:

- **Backend API:** FastAPI (`src/ccs_platform/main.py`), routes under `/api/v1`
- **Background worker:** polling worker loop (`src/ccs_platform/worker/main.py` + `application/jobs/worker_loop.py`)
- **Frontend:** React/Vite admin panel (`frontend/`)
- **Storage adapters:** local filesystem or native GCS object storage
- **DB layer:** SQLAlchemy + Alembic, profile-scoped data model
- **Runtime settings behavior:** app seeds runtime settings from process env on startup and stores them in DB (`runtime_settings` table)

Important runtime contract:

- If API and worker run as separate containers/processes, set:
  - `CCS_PLATFORM_EMBEDDED_WORKER=false`
  - In shared-production DB mode, set `CCS_PLATFORM_RUNTIME_SETTINGS_SEED_SOURCE=none` on all runtimes

---

## 2. Prerequisites

Install tools on your local machine (or CI runner):

```bash
# Required for both plans
docker --version
docker compose version
openssl version

# Required for GCP plan
gcloud --version
psql --version
```

Accounts and prerequisites:

- Plan 1:
  - Oracle Cloud account (Always Free eligible)
  - Domain name (optional but strongly recommended)
- Plan 2:
  - GCP project with billing enabled
  - Domain name
  - IAM permissions for Cloud Run, Cloud SQL, Artifact Registry, Secret Manager, Compute/LB, IAP

---

## 3. Shared Docker Baseline

This repo includes production-oriented Docker artifacts under `deploy/`. The following snippets show a reusable baseline.

### 3.1 Create deployment scaffolding

```bash
cd ~/Documents/GitHub/scrapers/credit-card-scraper
mkdir -p deploy/nginx
```

### 3.2 App image (API + Worker)

```bash
cat > deploy/Dockerfile.app <<'DOCKERFILE'
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PYTHONPATH=/app/src

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates build-essential libpq-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt requirements-dev.txt pyproject.toml README.md ./
COPY alembic.ini ./
COPY alembic ./alembic
COPY config ./config
COPY src ./src

RUN pip install --upgrade pip \
    && pip install -r requirements.txt \
    && pip install "psycopg[binary]>=3.2"

# Playwright + Chromium for scraping
RUN python -m playwright install --with-deps chromium

EXPOSE 8040

CMD ["python", "-m", "ccs_platform.cli", "api", "--host", "0.0.0.0", "--port", "8040"]
DOCKERFILE
```

### 3.3 Frontend image (static)

```bash
cat > deploy/Dockerfile.frontend <<'DOCKERFILE'
FROM node:20-alpine AS build
WORKDIR /frontend
COPY frontend/package*.json ./
RUN npm ci
COPY frontend ./
RUN npm run build

FROM nginx:1.27-alpine
COPY deploy/nginx/frontend.conf /etc/nginx/conf.d/default.conf
COPY --from=build /frontend/dist /usr/share/nginx/html
EXPOSE 8080
CMD ["nginx", "-g", "daemon off;"]
DOCKERFILE
```

```bash
cat > deploy/nginx/frontend.conf <<'NGINX'
server {
  listen 8080;
  server_name _;

  root /usr/share/nginx/html;
  index index.html;

  location / {
    try_files $uri /index.html;
  }
}
NGINX
```

### 3.4 Optional reverse-proxy for Plan 1 (TLS + auth)

```bash
cat > deploy/Caddyfile <<'CADDY'
{$APP_DOMAIN} {
  encode gzip

  basicauth {
    {$ADMIN_USER} {$ADMIN_PASSWORD_BCRYPT}
  }

  @api path /api/*
  reverse_proxy @api api:8040
  reverse_proxy frontend:8080
}
CADDY
```

### 3.5 Service contract

These are the runtime services used by this guide:

- `api`: FastAPI backend + DB access
- `worker`: background job runner
- `frontend`: static admin UI
- `reverse-proxy` (optional in architecture, used in Plan 1): TLS + auth gateway + path routing

---

## 4. Environment Variables

Configure envs in:

- **Plan 1:** `/opt/ccs/.env.production` (used by Docker Compose)
- **Plan 2:** Cloud Run env + Secret Manager secret bindings

| Variable | Required in Plan 1 | Required in Plan 2 | Secret? | Example | Where configured |
|---|---:|---:|---:|---|---|
| `CCS_PLATFORM_DATABASE_URL` | Yes | Yes | Yes | `sqlite:////app/data/state/platform.db` (Plan 1) / `postgresql+psycopg://...` (Plan 2) | Plan 1 `.env.production`; Plan 2 Secret Manager -> Cloud Run |
| `CCS_PLATFORM_STORAGE_BACKEND` | Yes | Yes | No | `local` (Plan 1), `gcs` (Plan 2) | env |
| `CCS_PLATFORM_LOCAL_STORAGE_DIR` | Yes if local storage | No | No | `/app/data/archive/platform` | env |
| `CCS_PLATFORM_GCS_BUCKET` | No | Yes (if `gcs`) | No | `ccs-prod-archive` | env |
| `CCS_PLATFORM_GCS_PROJECT` | No | Optional | No | `<your-gcp-project-id>` | env |
| `CCS_PLATFORM_GCS_CREDENTIALS_FILE` | No | Optional (local/non-GCP runtimes) | No | `/var/secrets/google/storage-sa.json` | env |
| `CCS_PLATFORM_TIMEZONE` | Yes | Yes | No | `Asia/Dubai` | env |
| `CCS_PLATFORM_EMBEDDED_WORKER` | Yes | Yes | No | `false` | env |
| `CCS_PLATFORM_JOB_DISPATCH_BACKEND` | Yes | Yes | No | `database` | env |
| `CCS_PLATFORM_WORKER_QUEUES` | Optional | Optional | No | `default,scrape` | env |
| `CCS_PLATFORM_JOB_RETRY_BASE_SECONDS` | Optional | Optional | No | `30` | env |
| `CCS_PLATFORM_JOB_RETRY_JITTER_SECONDS` | Optional | Optional | No | `15` | env |
| `CCS_PLATFORM_JOB_RETRY_MAX_DELAY_SECONDS` | Optional | Optional | No | `900` | env |
| `CCS_PLATFORM_JOB_HEARTBEAT_TIMEOUT_SECONDS` | Optional | Optional | No | `1800` | env |
| `CCS_PLATFORM_CORS_ALLOW_ORIGINS` | Yes | Yes | No | `https://admin.example.com` | env |
| `CCS_PLATFORM_RUNTIME_SETTINGS_ENCRYPTION_KEY` | Yes (prod) | Yes (prod) | Yes | `<FERNET_KEY>` | Secret Manager / env |
| `CCS_PLATFORM_RUNTIME_SETTINGS_REQUIRE_ENCRYPTION` | Optional | Optional | No | `true` | env |
| `CCS_PLATFORM_RUNTIME_SETTINGS_SEED_SOURCE` | Optional | Optional | No | `none` (recommended in shared-DB mode) | env |
| `CCS_PLATFORM_RUNTIME_SETTINGS_ENV_FILE` | Optional | Optional | No | `/app/.env` | env |
| `CCS_DOWNLOADS_DIR` | Yes | Yes | No | `/app/data/incoming/downloads` (Plan 1), `/tmp/downloads` (Plan 2) | env |
| `FAB_USERNAME` | Yes | Yes | Yes | `fab_user` | Secret Manager / env |
| `FAB_PASSWORD` | Yes | Yes | Yes | `***` | Secret Manager / env |
| `ADCB_CID` | Yes | Yes | Yes | `12345678` | Secret Manager / env |
| `ADCB_LOGIN_PASSWORD` | Yes | Yes | Yes | `***` | Secret Manager / env |
| `ADCB_PDF_PASSWORD` | Optional (fallback is CID) | Optional | Yes | `***` | Secret Manager / env |
| `ADCB_FORCE_VIRTUAL_KEYBOARD` | Optional | Optional | No | `1` | env |
| `ENBD_USERNAME` | Yes | Yes | Yes | `enbd_user` | Secret Manager / env |
| `ENBD_PASSWORD` | Yes | Yes | Yes | `***` | Secret Manager / env |
| `SIB_USER_ID` | Yes | Yes | Yes | `sib_user` | Secret Manager / env |
| `SIB_PASSWORD` | Yes | Yes | Yes | `***` | Secret Manager / env |
| `SIB_PDF_PASSWORD` | Yes | Yes | Yes | `***` | Secret Manager / env |
| `SIB_SECURE_IMAGE_TEMPLATE_BASE64` | Optional | Optional | Yes | `iVBORw0...` | Secret Manager / env |
| `APP_DOMAIN` | Yes (Plan 1 Caddy) | Yes (DNS/LB) | No | `admin.example.com` | Plan 1 `.env.production`; Plan 2 shell vars |
| `ADMIN_USER` | Yes (Plan 1 Caddy) | No | Yes-ish | `admin` | Plan 1 `.env.production` |
| `ADMIN_PASSWORD_BCRYPT` | Yes (Plan 1 Caddy) | No | Yes | `$2a$14$...` | Plan 1 `.env.production` |

---

## 5. Plan 1 (Free/Near-Free): Oracle Always Free VM + Docker Compose + SQLite

## 5.1 Provision VM (Oracle Cloud)

In Oracle Console, create an Always Free eligible VM in your **home region**.

Recommended shape strategy:

- Ampere A1 flexible shape within Always Free limits
- Keep total within Always Free tenancy limits

Reference:

- Oracle Always Free resource limits include Ampere A1 (up to Always Free equivalent of 4 OCPUs / 24 GB), and 200 GB total block volume in home region.

## 5.2 SSH and harden host

```bash
ssh ubuntu@<VM_PUBLIC_IP>

sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg lsb-release git ufw

# Docker engine
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker $USER
newgrp docker
```

Firewall (example: allow SSH + HTTPS only):

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow OpenSSH
sudo ufw allow 443/tcp
sudo ufw enable
sudo ufw status
```

For stricter admin-only access, allow 443 only from your office/home static IP CIDR.

## 5.3 Prepare app directory and env

```bash
sudo mkdir -p /opt/ccs
sudo chown -R $USER:$USER /opt/ccs
cd /opt/ccs

git clone https://github.com/<YOUR_ORG>/credit-card-scraper.git
cd credit-card-scraper

mkdir -p /opt/ccs/data/state /opt/ccs/data/archive/platform /opt/ccs/data/incoming/downloads /opt/ccs/logs /opt/ccs/backups
```

Generate Caddy bcrypt password hash:

```bash
docker run --rm caddy:2 caddy hash-password --plaintext 'ChangeThisPasswordNow!'
```

Create `.env.production`:

```bash
cat > /opt/ccs/.env.production <<'ENVFILE'
APP_DOMAIN=admin.example.com
ADMIN_USER=admin
ADMIN_PASSWORD_BCRYPT=<PASTE_BCRYPT_HASH>

CCS_PLATFORM_DATABASE_URL=sqlite:////app/data/state/platform.db
CCS_PLATFORM_STORAGE_BACKEND=local
CCS_PLATFORM_LOCAL_STORAGE_DIR=/app/data/archive/platform
CCS_PLATFORM_TIMEZONE=Asia/Dubai
CCS_PLATFORM_EMBEDDED_WORKER=false
CCS_PLATFORM_CORS_ALLOW_ORIGINS=https://admin.example.com
CCS_DOWNLOADS_DIR=/app/data/incoming/downloads

FAB_USERNAME=<FAB_USERNAME>
FAB_PASSWORD=<FAB_PASSWORD>
ADCB_CID=<ADCB_CID>
ADCB_LOGIN_PASSWORD=<ADCB_LOGIN_PASSWORD>
ADCB_PDF_PASSWORD=<ADCB_PDF_PASSWORD>
ADCB_FORCE_VIRTUAL_KEYBOARD=1
ENBD_USERNAME=<ENBD_USERNAME>
ENBD_PASSWORD=<ENBD_PASSWORD>
SIB_USER_ID=<SIB_USER_ID>
SIB_PASSWORD=<SIB_PASSWORD>
SIB_PDF_PASSWORD=<SIB_PDF_PASSWORD>
SIB_SECURE_IMAGE_TEMPLATE_BASE64=
ENVFILE
```

## 5.4 Create Docker Compose file

```bash
cat > /opt/ccs/credit-card-scraper/deploy/docker-compose.prod.yml <<'YAML'
services:
  api:
    build:
      context: ..
      dockerfile: deploy/Dockerfile.app
    env_file:
      - /opt/ccs/.env.production
    environment:
      CCS_PLATFORM_EMBEDDED_WORKER: "false"
    command: ["python", "-m", "ccs_platform.cli", "api", "--host", "0.0.0.0", "--port", "8040"]
    volumes:
      - /opt/ccs/data:/app/data
      - /opt/ccs/logs:/app/logs
    expose:
      - "8040"
    restart: unless-stopped

  worker:
    build:
      context: ..
      dockerfile: deploy/Dockerfile.app
    env_file:
      - /opt/ccs/.env.production
    environment:
      CCS_PLATFORM_EMBEDDED_WORKER: "false"
    command: ["python", "-m", "ccs_platform.cli", "worker"]
    volumes:
      - /opt/ccs/data:/app/data
      - /opt/ccs/logs:/app/logs
    restart: unless-stopped

  frontend:
    build:
      context: ..
      dockerfile: deploy/Dockerfile.frontend
    expose:
      - "8080"
    restart: unless-stopped

  reverse-proxy:
    image: caddy:2
    env_file:
      - /opt/ccs/.env.production
    depends_on:
      - api
      - frontend
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ../deploy/Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    restart: unless-stopped

volumes:
  caddy_data:
  caddy_config:
YAML
```

## 5.5 Build and run

```bash
cd /opt/ccs/credit-card-scraper/deploy
docker compose --env-file /opt/ccs/.env.production -f docker-compose.prod.yml up -d --build
```

## 5.6 Run DB migration

```bash
docker compose --env-file /opt/ccs/.env.production -f docker-compose.prod.yml exec api sh -lc 'PYTHONPATH=/app/src alembic upgrade head'
```

## 5.7 Smoke checks

```bash
# API health
curl -fsS https://admin.example.com/api/v1/health

# Jobs list (default profile)
curl -fsS -u admin:ChangeThisPasswordNow! https://admin.example.com/api/v1/jobs?page=1&page_size=10

# Frontend response
curl -I https://admin.example.com/
```

## 5.8 Seed runtime settings (optional explicit run)

The app already seeds runtime settings at startup. If you rotate env values and want to re-sync:

```bash
curl -sS -u admin:ChangeThisPasswordNow! \
  -H 'Content-Type: application/json' \
  -X POST \
  https://admin.example.com/api/v1/runtime-settings/seed-from-env \
  -d '{"overwrite_existing": true, "source_mode": "env"}'
```

## 5.9 Backup and restore (SQLite + archive)

Backup:

```bash
cd /opt/ccs/credit-card-scraper
PYTHONPATH=src python scripts/backup_platform_state.py --label nightly
```

Restore:

```bash
# stop services first
cd /opt/ccs/credit-card-scraper/deploy
docker compose --env-file /opt/ccs/.env.production -f docker-compose.prod.yml down

# restore DB + archive (force required for overwrite)
cd /opt/ccs/credit-card-scraper
PYTHONPATH=src python scripts/restore_platform_backup.py /opt/ccs/backups/<ARCHIVE_NAME>.tar.gz --force

# restart

docker compose --env-file /opt/ccs/.env.production -f docker-compose.prod.yml up -d
```

Monthly drill:

```bash
cd /opt/ccs/credit-card-scraper
PYTHONPATH=src python scripts/backup_restore_drill.py --label monthly
```

---

## 6. Plan 2 (Managed GCP): Cloud Run + Cloud SQL PostgreSQL + Cloud Storage + Artifact Registry + Secret Manager

This plan uses managed services in `europe-west1` and keeps private/admin-only access.

## 6.1 Set variables

```bash
export PROJECT_ID="<your-gcp-project-id>"
export REGION="europe-west1"
export REPO="ccs"
export APP_DOMAIN="admin.example.com"

export DB_INSTANCE="ccs-pg"
export DB_NAME="ccs_platform"
export DB_USER="ccs_app"

export BUCKET="${PROJECT_ID}-ccs-archive"

# safe URL-friendly password
export DB_PASSWORD="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)"
export CLOUDSQL_CONN="${PROJECT_ID}:${REGION}:${DB_INSTANCE}"
export DB_URL="postgresql+psycopg://${DB_USER}:${DB_PASSWORD}@/${DB_NAME}?host=/cloudsql/${CLOUDSQL_CONN}"
```

## 6.2 Authenticate and enable APIs

```bash
gcloud auth login
gcloud config set project "$PROJECT_ID"

gcloud services enable \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  sqladmin.googleapis.com \
  secretmanager.googleapis.com \
  compute.googleapis.com \
  iap.googleapis.com
```

## 6.3 Create Artifact Registry and build images

```bash
gcloud artifacts repositories create "$REPO" \
  --repository-format=docker \
  --location="$REGION" \
  --description="CCS production images"

export GIT_SHA="$(git rev-parse --short HEAD)"
export APP_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}/ccs-app:${GIT_SHA}"
export FRONTEND_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}/ccs-frontend:${GIT_SHA}"

gcloud builds submit --tag "$APP_IMAGE" --file deploy/Dockerfile.app .
gcloud builds submit --tag "$FRONTEND_IMAGE" --file deploy/Dockerfile.frontend .
```

## 6.4 Create Cloud SQL PostgreSQL

```bash
gcloud sql instances create "$DB_INSTANCE" \
  --database-version=POSTGRES_16 \
  --cpu=1 \
  --memory=3840MiB \
  --region="$REGION" \
  --storage-size=20 \
  --storage-type=SSD \
  --availability-type=ZONAL \
  --backup-start-time=02:00

gcloud sql databases create "$DB_NAME" --instance="$DB_INSTANCE"
gcloud sql users create "$DB_USER" --instance="$DB_INSTANCE" --password="$DB_PASSWORD"
```

## 6.5 Create Cloud Storage bucket

```bash
gsutil mb -l "$REGION" "gs://${BUCKET}"
gsutil uniformbucketlevelaccess set on "gs://${BUCKET}"

# Grant Cloud Run runtime service account access to the bucket.
# If you deploy with a custom service account, use that email instead.
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
RUN_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" \
  --member="serviceAccount:${RUN_SA}" \
  --role="roles/storage.objectAdmin"
```

## 6.6 Create secrets

```bash
# helper (create or add version)
upsert_secret () {
  local name="$1"
  local value="$2"
  if gcloud secrets describe "$name" >/dev/null 2>&1; then
    printf '%s' "$value" | gcloud secrets versions add "$name" --data-file=- >/dev/null
  else
    printf '%s' "$value" | gcloud secrets create "$name" --data-file=- --replication-policy=automatic >/dev/null
  fi
}

upsert_secret CCS_PLATFORM_DATABASE_URL "$DB_URL"
upsert_secret FAB_USERNAME "<FAB_USERNAME>"
upsert_secret FAB_PASSWORD "<FAB_PASSWORD>"
upsert_secret ADCB_CID "<ADCB_CID>"
upsert_secret ADCB_LOGIN_PASSWORD "<ADCB_LOGIN_PASSWORD>"
upsert_secret ADCB_PDF_PASSWORD "<ADCB_PDF_PASSWORD>"
upsert_secret ENBD_USERNAME "<ENBD_USERNAME>"
upsert_secret ENBD_PASSWORD "<ENBD_PASSWORD>"
upsert_secret SIB_USER_ID "<SIB_USER_ID>"
upsert_secret SIB_PASSWORD "<SIB_PASSWORD>"
upsert_secret SIB_PDF_PASSWORD "<SIB_PDF_PASSWORD>"
upsert_secret SIB_SECURE_IMAGE_TEMPLATE_BASE64 ""
upsert_secret CCS_PLATFORM_RUNTIME_SETTINGS_ENCRYPTION_KEY "<FERNET_KEY>"
```

## 6.7 Deploy API service

```bash
gcloud run deploy ccs-api \
  --image "$APP_IMAGE" \
  --region "$REGION" \
  --platform managed \
  --port 8080 \
  --ingress internal-and-cloud-load-balancing \
  --no-allow-unauthenticated \
  --add-cloudsql-instances "$CLOUDSQL_CONN" \
  --set-env-vars "PYTHONPATH=/app/src,CCS_PLATFORM_STORAGE_BACKEND=gcs,CCS_PLATFORM_GCS_BUCKET=${BUCKET},CCS_PLATFORM_GCS_PROJECT=${PROJECT_ID},CCS_PLATFORM_TIMEZONE=Asia/Dubai,CCS_PLATFORM_EMBEDDED_WORKER=false,CCS_PLATFORM_CORS_ALLOW_ORIGINS=https://${APP_DOMAIN},CCS_PLATFORM_RUNTIME_SETTINGS_SEED_SOURCE=none,CCS_DOWNLOADS_DIR=/tmp/downloads" \
  --set-secrets "CCS_PLATFORM_DATABASE_URL=CCS_PLATFORM_DATABASE_URL:latest,CCS_PLATFORM_RUNTIME_SETTINGS_ENCRYPTION_KEY=CCS_PLATFORM_RUNTIME_SETTINGS_ENCRYPTION_KEY:latest,FAB_USERNAME=FAB_USERNAME:latest,FAB_PASSWORD=FAB_PASSWORD:latest,ADCB_CID=ADCB_CID:latest,ADCB_LOGIN_PASSWORD=ADCB_LOGIN_PASSWORD:latest,ADCB_PDF_PASSWORD=ADCB_PDF_PASSWORD:latest,ENBD_USERNAME=ENBD_USERNAME:latest,ENBD_PASSWORD=ENBD_PASSWORD:latest,SIB_USER_ID=SIB_USER_ID:latest,SIB_PASSWORD=SIB_PASSWORD:latest,SIB_PDF_PASSWORD=SIB_PDF_PASSWORD:latest,SIB_SECURE_IMAGE_TEMPLATE_BASE64=SIB_SECURE_IMAGE_TEMPLATE_BASE64:latest" \
  --command python \
  --args "-m,ccs_platform.cli,api,--host,0.0.0.0,--port,8080"
```

## 6.8 Run migrations as Cloud Run Job

```bash
gcloud run jobs create ccs-migrate \
  --image "$APP_IMAGE" \
  --region "$REGION" \
  --add-cloudsql-instances "$CLOUDSQL_CONN" \
  --set-env-vars "PYTHONPATH=/app/src,CCS_PLATFORM_STORAGE_BACKEND=gcs,CCS_PLATFORM_GCS_BUCKET=${BUCKET},CCS_PLATFORM_GCS_PROJECT=${PROJECT_ID},CCS_PLATFORM_TIMEZONE=Asia/Dubai,CCS_PLATFORM_EMBEDDED_WORKER=false" \
  --set-secrets "CCS_PLATFORM_DATABASE_URL=CCS_PLATFORM_DATABASE_URL:latest" \
  --command sh \
  --args "-c,PYTHONPATH=/app/src alembic upgrade head"

gcloud run jobs execute ccs-migrate --region "$REGION" --wait
```

## 6.9 Deploy worker pools (Cloud Run worker pool)

Deploy a default queue worker (`CCS_PLATFORM_WORKER_QUEUES=default`):

```bash
gcloud beta run worker-pools deploy ccs-worker-default \
  --image "$APP_IMAGE" \
  --region "$REGION" \
  --set-env-vars "PYTHONPATH=/app/src,CCS_PLATFORM_STORAGE_BACKEND=gcs,CCS_PLATFORM_GCS_BUCKET=${BUCKET},CCS_PLATFORM_GCS_PROJECT=${PROJECT_ID},CCS_PLATFORM_TIMEZONE=Asia/Dubai,CCS_PLATFORM_EMBEDDED_WORKER=false,CCS_PLATFORM_RUNTIME_SETTINGS_SEED_SOURCE=none,CCS_PLATFORM_WORKER_QUEUES=default,CCS_DOWNLOADS_DIR=/tmp/downloads" \
  --set-secrets "CCS_PLATFORM_DATABASE_URL=CCS_PLATFORM_DATABASE_URL:latest,CCS_PLATFORM_RUNTIME_SETTINGS_ENCRYPTION_KEY=CCS_PLATFORM_RUNTIME_SETTINGS_ENCRYPTION_KEY:latest,FAB_USERNAME=FAB_USERNAME:latest,FAB_PASSWORD=FAB_PASSWORD:latest,ADCB_CID=ADCB_CID:latest,ADCB_LOGIN_PASSWORD=ADCB_LOGIN_PASSWORD:latest,ADCB_PDF_PASSWORD=ADCB_PDF_PASSWORD:latest,ENBD_USERNAME=ENBD_USERNAME:latest,ENBD_PASSWORD=ENBD_PASSWORD:latest,SIB_USER_ID=SIB_USER_ID:latest,SIB_PASSWORD=SIB_PASSWORD:latest,SIB_PDF_PASSWORD=SIB_PDF_PASSWORD:latest,SIB_SECURE_IMAGE_TEMPLATE_BASE64=SIB_SECURE_IMAGE_TEMPLATE_BASE64:latest" \
  --command python \
  --args "-m,ccs_platform.cli,worker"
```

Deploy a scrape queue worker (`CCS_PLATFORM_WORKER_QUEUES=scrape`):

```bash
gcloud beta run worker-pools deploy ccs-worker-scrape \
  --image "$APP_IMAGE" \
  --region "$REGION" \
  --set-env-vars "PYTHONPATH=/app/src,CCS_PLATFORM_STORAGE_BACKEND=gcs,CCS_PLATFORM_GCS_BUCKET=${BUCKET},CCS_PLATFORM_GCS_PROJECT=${PROJECT_ID},CCS_PLATFORM_TIMEZONE=Asia/Dubai,CCS_PLATFORM_EMBEDDED_WORKER=false,CCS_PLATFORM_RUNTIME_SETTINGS_SEED_SOURCE=none,CCS_PLATFORM_WORKER_QUEUES=scrape,CCS_DOWNLOADS_DIR=/tmp/downloads" \
  --set-secrets "CCS_PLATFORM_DATABASE_URL=CCS_PLATFORM_DATABASE_URL:latest,CCS_PLATFORM_RUNTIME_SETTINGS_ENCRYPTION_KEY=CCS_PLATFORM_RUNTIME_SETTINGS_ENCRYPTION_KEY:latest,FAB_USERNAME=FAB_USERNAME:latest,FAB_PASSWORD=FAB_PASSWORD:latest,ADCB_CID=ADCB_CID:latest,ADCB_LOGIN_PASSWORD=ADCB_LOGIN_PASSWORD:latest,ADCB_PDF_PASSWORD=ADCB_PDF_PASSWORD:latest,ENBD_USERNAME=ENBD_USERNAME:latest,ENBD_PASSWORD=ENBD_PASSWORD:latest,SIB_USER_ID=SIB_USER_ID:latest,SIB_PASSWORD=SIB_PASSWORD:latest,SIB_PDF_PASSWORD=SIB_PDF_PASSWORD:latest,SIB_SECURE_IMAGE_TEMPLATE_BASE64=SIB_SECURE_IMAGE_TEMPLATE_BASE64:latest" \
  --command python \
  --args "-m,ccs_platform.cli,worker"
```

Note: Cloud Run worker pools are currently Preview; include this in your production risk register.

## 6.10 Deploy frontend service

```bash
gcloud run deploy ccs-frontend \
  --image "$FRONTEND_IMAGE" \
  --region "$REGION" \
  --platform managed \
  --port 8080 \
  --ingress internal-and-cloud-load-balancing \
  --no-allow-unauthenticated
```

## 6.11 Configure HTTPS Load Balancer + path routing + IAP (private/admin-only)

Create serverless NEGs and backend services:

```bash
gcloud compute network-endpoint-groups create ccs-frontend-neg \
  --region="$REGION" \
  --network-endpoint-type=serverless \
  --cloud-run-service=ccs-frontend

gcloud compute network-endpoint-groups create ccs-api-neg \
  --region="$REGION" \
  --network-endpoint-type=serverless \
  --cloud-run-service=ccs-api

gcloud compute backend-services create ccs-frontend-bes --global --load-balancing-scheme=EXTERNAL_MANAGED
gcloud compute backend-services create ccs-api-bes --global --load-balancing-scheme=EXTERNAL_MANAGED

gcloud compute backend-services add-backend ccs-frontend-bes \
  --global \
  --network-endpoint-group=ccs-frontend-neg \
  --network-endpoint-group-region="$REGION"

gcloud compute backend-services add-backend ccs-api-bes \
  --global \
  --network-endpoint-group=ccs-api-neg \
  --network-endpoint-group-region="$REGION"
```

Create URL map and HTTPS frontend:

```bash
gcloud compute url-maps create ccs-url-map --default-service=ccs-frontend-bes

gcloud compute url-maps add-path-matcher ccs-url-map \
  --path-matcher-name=ccs-paths \
  --default-service=ccs-frontend-bes \
  --new-hosts="$APP_DOMAIN" \
  --path-rules="/api/*=ccs-api-bes"

gcloud compute ssl-certificates create ccs-cert --domains="$APP_DOMAIN" --global
gcloud compute target-https-proxies create ccs-https-proxy --url-map=ccs-url-map --ssl-certificates=ccs-cert

gcloud compute addresses create ccs-lb-ip --global

gcloud compute forwarding-rules create ccs-https-fr \
  --global \
  --target-https-proxy=ccs-https-proxy \
  --ports=443 \
  --address=ccs-lb-ip
```

Get LB IP and point DNS A record:

```bash
gcloud compute addresses describe ccs-lb-ip --global --format='value(address)'
```

Enable IAP (Google-authenticated admin access):

```bash
# Create OAuth brand/client once per project (if not already created)

gcloud iap oauth-brands create \
  --application_title="CCS Admin" \
  --support_email="<YOUR_EMAIL>"

BRAND_NAME="$(gcloud iap oauth-brands list --format='value(name)' --limit=1)"

gcloud iap oauth-clients create "$BRAND_NAME" --display_name="ccs-iap"

# Copy client_id and client_secret from output, then apply:

gcloud compute backend-services update ccs-frontend-bes --global \
  --iap=enabled,oauth2-client-id=<IAP_CLIENT_ID>,oauth2-client-secret=<IAP_CLIENT_SECRET>

gcloud compute backend-services update ccs-api-bes --global \
  --iap=enabled,oauth2-client-id=<IAP_CLIENT_ID>,oauth2-client-secret=<IAP_CLIENT_SECRET>

# Grant access to admin users/group

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="user:<ADMIN_EMAIL>" \
  --role="roles/iap.httpsResourceAccessor"
```

## 6.12 Smoke checks

```bash
# API (through LB)
curl -I "https://${APP_DOMAIN}/api/v1/health"

# Frontend
curl -I "https://${APP_DOMAIN}/"

# Cloud Run statuses
gcloud run services list --region "$REGION"
gcloud beta run worker-pools list --region "$REGION"
```

## 6.13 Rollback commands

Cloud Run API rollback to previous revision:

```bash
gcloud run services describe ccs-api --region "$REGION"
# then shift traffic to prior revision

gcloud run services update-traffic ccs-api \
  --region "$REGION" \
  --to-revisions <OLD_REVISION>=100
```

Frontend rollback:

```bash
gcloud run services update-traffic ccs-frontend \
  --region "$REGION" \
  --to-revisions <OLD_REVISION>=100
```

Worker rollback: redeploy previous image tag to worker pool.

---

## 7. Approximate Monthly Cost (USD)

These are approximate ranges for small production usage. Always validate with current pricing calculator before go-live.

### 7.1 Plan 1 (Oracle Always Free VM)

| Component | Approx monthly |
|---|---:|
| OCI Always Free compute + block volume (within limits) | `$0` |
| Optional domain (annualized) | `$1–$2` |
| Optional paid add-ons/egress over free limits | `$0–$5` |
| **Estimated total** | **`$0–$7`** |

### 7.2 Plan 2 (Managed GCP in `europe-west1`)

Assumptions used:

- Cloud SQL single-zone, small production footprint
- Worker pool continuously running (1 worker instance)
- Moderate archive/image storage
- HTTPS Load Balancer + IAP for private/admin-only access

| Component | Low | Typical |
|---|---:|---:|
| Cloud SQL PostgreSQL + storage/backups | `$12–$20` (shared-core/no SLA) | `$55–$90` (SLA-oriented sizing) |
| Cloud Run API | `$0–$8` | `$5–$20` |
| Cloud Run worker pool | `$25–$35` | `$25–$45` |
| Cloud Storage (archive PDFs) | `$1–$5` | `$3–$15` |
| Artifact Registry | `$0–$2` | `$1–$5` |
| HTTPS LB + routing + IAP path | `$18–$30` | `$25–$45` |
| Secret Manager + misc | `$0–$3` | `$1–$6` |
| **Estimated total** | **`$56–$103`** | **`$115–$226`** |

Notes:

- Cloud Run and Cloud Storage free tiers have regional/usage constraints.
- Cloud SQL shared-core (`db-f1-micro`, `db-g1-small`) is cheaper but not covered by Cloud SQL SLA.
- Worker pools are Preview and pricing/behavior may change.

---

## 8. Operations Runbook

## 8.1 Daily checks

Plan 1:

```bash
cd /opt/ccs/credit-card-scraper/deploy
docker compose --env-file /opt/ccs/.env.production -f docker-compose.prod.yml ps
docker compose --env-file /opt/ccs/.env.production -f docker-compose.prod.yml logs --tail=100 api worker
curl -fsS https://admin.example.com/api/v1/health
```

Plan 2:

```bash
gcloud run services list --region europe-west1
gcloud beta run worker-pools list --region europe-west1
gcloud sql instances describe ccs-pg
```

## 8.2 Weekly tasks

- Verify backups and perform one restore drill in non-prod
- Review failed jobs in `/api/v1/jobs`
- Review runtime settings for stale/rotated credentials
- Run retention dry-run and apply if counts are expected:
  - `PYTHONPATH=src python scripts/enforce_retention.py`
  - `PYTHONPATH=src python scripts/enforce_retention.py --apply`
- Run staging load/perf budget check:
  - `PYTHONPATH=src python scripts/load_test_api.py --base-url <STAGING_URL> --duration 60 --concurrency 12`
- Evaluate SLO policy against metrics:
  - `PYTHONPATH=src python scripts/evaluate_slo.py --metrics-url <STAGING_URL>/api/v1/metrics`

## 8.3 Credential rotation

- Rotate bank credentials in secret store
- Run runtime secret rotation drill (dry run then apply):
  - `CCS_PLATFORM_RUNTIME_SETTINGS_OLD_ENCRYPTION_KEY=... CCS_PLATFORM_RUNTIME_SETTINGS_ENCRYPTION_KEY=... PYTHONPATH=src python scripts/rotate_runtime_setting_secrets.py --dry-run`
  - `CCS_PLATFORM_RUNTIME_SETTINGS_OLD_ENCRYPTION_KEY=... CCS_PLATFORM_RUNTIME_SETTINGS_ENCRYPTION_KEY=... PYTHONPATH=src python scripts/rotate_runtime_setting_secrets.py`
- Re-seed runtime settings (`/runtime-settings/seed-from-env` with overwrite and `source_mode=env`)
- Restart API and worker

## 8.4 Incident triage flow

1. Check `GET /api/v1/health`
2. Check DB availability
3. Check worker status and queue growth
4. Check storage read/write failures
5. Roll back latest deployment revision/image if needed

## 8.5 Disaster recovery checklist

- Confirm latest successful backup timestamp
- Restore DB first, then archive storage metadata/files
- Bring up API only and validate read paths
- Bring up worker and validate new jobs
- Re-run smoke tests

---

## 9. Go-Live Checklist

- [ ] Domain and TLS configured
- [ ] Private/admin-only access verified
- [ ] `CCS_PLATFORM_EMBEDDED_WORKER=false` verified
- [ ] DB migrations applied (`alembic upgrade head`)
- [ ] Migration preflight passed (`PYTHONPATH=src python scripts/migration_preflight.py`)
- [ ] Runtime settings seeded and verified
- [ ] API + worker + frontend healthy
- [ ] Upload, scrape, reparse, reclassify smoke-tested
- [ ] Dashboard loads with expected data
- [ ] Backup job configured and restore tested
- [ ] Retention enforcement job scheduled and validated
- [ ] Load budget and SLO evaluation completed on staging
- [ ] Log access and alerting path verified
- [ ] Rollback command tested once

---

## 10. Pricing References (Official)

- Oracle Always Free resources:
  - https://docs.oracle.com/iaas/Content/FreeTier/resourceref.htm
  - https://www.oracle.com/cloud/free/faq/
- Cloud Run pricing:
  - https://cloud.google.com/run/pricing
- Cloud SQL PostgreSQL pricing:
  - https://cloud.google.com/sql/docs/postgres/pricing-examples
- Cloud Storage pricing:
  - https://cloud.google.com/storage/pricing
- Artifact Registry pricing:
  - https://cloud.google.com/artifact-registry/pricing
- Network/LB related pricing references:
  - https://cloud.google.com/vpc/network-pricing
