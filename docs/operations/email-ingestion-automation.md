# Email Ingestion Automation

> **Legacy (v1).** This describes the frozen FastAPI backend (`backend/`) and is kept only until the Ledger v2 cutover. For v2 see [ARCHITECTURE.md](../../ARCHITECTURE.md) and [PRODUCTION.md](../../PRODUCTION.md).

This document describes the implemented email-to-upload ingestion paths:

1. Microsoft/Hotmail polling with GitHub Actions.
2. Gmail push ingestion on GCP Cloud Run + Pub/Sub.

Both paths write PDF bytes into `POST /api/v1/email-ingestion/upload` and rely on service-token auth.

## Feature gate

Set:

```bash
CCS_PLATFORM_EMAIL_INGESTION_ENABLED=true
```

When disabled, `/api/v1/email-ingestion/*` returns `404`.

## Data model

Implemented tables:

- `email_mailboxes`
- `email_bank_routes`
- `email_ingestion_events`
- `service_api_tokens`

Migration: `backend/alembic/versions/20260228_000008_email_ingestion_tables.py`.

## Runtime settings keys

Configured through `Runtime Variables` UI (or API):

- `EMAIL_MS_CLIENT_ID`
- `EMAIL_MS_CLIENT_SECRET`
- `EMAIL_MS_REFRESH_TOKEN_MAILBOX_<mailbox_id>`
- `EMAIL_GMAIL_CLIENT_ID`
- `EMAIL_GMAIL_CLIENT_SECRET`
- `EMAIL_GMAIL_REFRESH_TOKEN_MAILBOX_<mailbox_id>`

## API surfaces

UI/config endpoints:

- `GET/POST/PATCH /api/v1/email-ingestion/mailboxes`
- `GET/PUT /api/v1/email-ingestion/routes`
- `GET /api/v1/email-ingestion/events`
- `GET/POST /api/v1/email-ingestion/service-tokens`
- `POST /api/v1/email-ingestion/service-tokens/{token_id}/revoke`

Automation endpoints (service-token auth):

- `GET /api/v1/email-ingestion/automation/mailboxes`
- `GET /api/v1/email-ingestion/automation/routes`
- `POST /api/v1/email-ingestion/oauth/{provider}/access-token`
- `POST /api/v1/email-ingestion/upload`
- `POST /api/v1/email-ingestion/mailboxes/{mailbox_id}/sync-state`

Required scopes:

- `email_ingestion:read`
- `email_ingestion:write`
- `email_ingestion:upload`

## Frontend

New page: `Email Ingestion` (`/email-ingestion`) with:

- mailbox CRUD and per-mailbox refresh token storage
- bank routing matrix (one route per enabled bank)
- ingestion activity table with filters
- service token create/revoke

## Hotmail/Microsoft path (GitHub Actions)

Workflow:

- `.github/workflows/email-ingest-microsoft.yml`
- schedule: every 4 hours (`17 */4 * * *`)

Script:

- `backend/scripts/email_ingest_microsoft.py`

Secrets needed in repository:

- `CCS_API_BASE_URL`
- `CCS_SERVICE_TOKEN`

## Gmail path (GCP)

Cloud Run relay app:

- `backend/scripts/gmail_ingest_relay.py`
- endpoint: `POST /pubsub/push`

Watch renew script (Cloud Scheduler daily):

- `backend/scripts/gmail_watch_renew.py`
- requires `GMAIL_PUBSUB_TOPIC`

Expected environment for both:

- `CCS_API_BASE_URL`
- `CCS_SERVICE_TOKEN`

Optional dry-run flags are available via CLI for local verification.
