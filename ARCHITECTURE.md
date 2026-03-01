# Architecture

## System Overview

The Credit Card Statement Platform is composed of four independent components:

| Component | Purpose | Runtime |
|-----------|---------|---------|
| **Backend API** (`backend/`) | REST API + embedded job worker | Render (cloud) |
| **Scraper CLI** (`scraper/`) | Browser automation for statement downloads | Local machine (manual) |
| **Frontend** (`frontend/`) | React admin panel | Vercel (cloud) |
| **Gmail Relay** (`deploy/Dockerfile.gmail-relay`) | Gmail push-notification → upload relay | GCP Cloud Run |

---

## Component Boundaries

### Backend API

- FastAPI application serving `/api/v1/*`
- Embedded job worker (`CCS_PLATFORM_EMBEDDED_WORKER=true`) processes upload, reclassify, export, parser-validate, and reparse jobs in-process using a thread pool
- **No browser code** — Playwright is not a dependency; the API never launches a browser
- Stores PDFs in GCS (production) or local filesystem (development)
- PostgreSQL (Neon) database for all state
- In-process sliding-window rate limiter on `/auth/login` (5 req/min per IP)
- Service API tokens support optional `expires_at` and are logged as audit events on creation and revocation

### Scraper CLI

- Standalone Python package in `scraper/`
- Runs locally when historical statement downloads are needed
- Uses Playwright + Chromium to log into bank portals and download PDF statements
- Uploads downloaded PDFs to the backend via `POST /api/v1/jobs/upload` using a service API token
- All credentials and config come from environment variables / `.env` file
- No shared code with the backend — browser adapters live entirely within `scraper/`

### Frontend

- React + TypeScript admin panel
- Calls backend REST API via `/api`
- Deployed to Vercel as a static build
- Top-level `<ErrorBoundary>` catches render errors and shows a recovery fallback
- Confirmation dialog guards destructive actions (e.g. service token revocation)

### Gmail Relay

- Lightweight Cloud Run service
- Receives Gmail push notifications → calls backend `POST /api/v1/email-ingestion/upload`
- Used for ongoing statement ingestion via email forwarding

---

## Data Flows

### Scraper → Backend (historical)

```
Scraper CLI (local)
  └─ Playwright downloads PDF from bank portal
       └─ POST /api/v1/jobs/upload (Bearer service token + X-Profile-Key)
            └─ Backend: detect bank, parse PDF, ingest statement
```

### Email → Backend (ongoing)

```
Bank portal sends email statement
  └─ Gmail → Gmail Relay (Cloud Run)
       └─ POST /api/v1/email-ingestion/upload (Bearer service token)
            └─ Backend: detect bank, parse PDF, ingest statement
```

### Admin → Backend (manual upload)

```
User uploads PDF via admin panel
  └─ POST /api/v1/jobs/upload (session auth)
       └─ Backend: detect bank, parse PDF, ingest statement
```

---

## Auth Model

| Caller | Auth method | Scopes |
|--------|------------|--------|
| Admin panel (browser) | Session cookie | Role-based (viewer/operator/admin) |
| Scraper CLI | Bearer service token | `upload` |
| Gmail Relay | Bearer service token | (email ingestion scope) |

Service tokens are created in the admin UI under **Service API Tokens**.

---

## Technology Stack

| Layer | Technology |
|-------|-----------|
| Backend | Python 3.12, FastAPI, SQLAlchemy 2, Alembic, Pydantic v2 |
| Database | PostgreSQL (Neon, free tier) |
| Storage | GCS bucket (PDFs) |
| Frontend | React 18, TypeScript, Vite |
| Scraper | Python 3.12, Playwright, Chromium, httpx, Typer |
| Relay | Python 3.12, Flask, httpx |
| Deploy | Docker, Render (API), Vercel (frontend), GCP Cloud Run (relay) |

---

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| Scraper decoupled from backend | Render free tier (512 MB) cannot run Playwright+Chromium; scraping is one-time historical work |
| SCRAPE/BANK_CONNECTION_TEST remain in DB enum | Postgres cannot drop enum values; existing job rows reference them |
| Parsers stay in backend only | Scraper just downloads PDFs; backend does all parsing on upload |
| Embedded worker in API process | Simplifies Render deployment; no separate worker service needed for non-browser jobs |
| Service token auth on upload | Consistent with email ingestion pattern; created via admin UI |
