# Data Retention and Lifecycle Policy

> **Legacy (v1).** This describes the frozen FastAPI backend (`backend/`) and is kept only until the Ledger v2 cutover. For v2 see [ARCHITECTURE.md](../../ARCHITECTURE.md) and [PRODUCTION.md](../../PRODUCTION.md).

## Default retention windows
- Terminal jobs: 90 days
- Export records: 90 days
- Audit events: 365 days
- Logs: 30 days
- Upload temp files: 14 days
- Backup archives: 30 days

## Config knobs
Set via `CCS_PLATFORM_*` env vars:
- `CCS_PLATFORM_RETENTION_JOBS_DAYS`
- `CCS_PLATFORM_RETENTION_EXPORTS_DAYS`
- `CCS_PLATFORM_RETENTION_AUDIT_EVENTS_DAYS`
- `CCS_PLATFORM_RETENTION_LOGS_DAYS`
- `CCS_PLATFORM_RETENTION_UPLOADS_DAYS`
- `CCS_PLATFORM_RETENTION_BACKUPS_DAYS`

## Dry-run and apply

```bash
# preview
PYTHONPATH=src python scripts/enforce_retention.py

# apply
PYTHONPATH=src python scripts/enforce_retention.py --apply
```

Retention runs emit structured deletion counts for DB and filesystem scopes.
