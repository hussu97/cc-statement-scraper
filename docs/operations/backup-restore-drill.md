# Backup and Restore Drill

> **Legacy (v1).** This describes the frozen FastAPI backend (`backend/`) and is kept only until the Ledger v2 cutover. For v2 see [ARCHITECTURE.md](../../ARCHITECTURE.md) and [PRODUCTION.md](../../PRODUCTION.md).

## Backup command

```bash
PYTHONPATH=src python scripts/backup_platform_state.py --label nightly
```

Outputs a compressed backup archive under `CCS_PLATFORM_BACKUPS_DIR` (or `data/backups` by default) containing:
- DB snapshot (`sqlite` copy or `pg_dump` SQL export)
- storage archive snapshot (`local_storage_dir`)
- cryptographic manifest (`sha256`) for each artifact

## Restore command

```bash
PYTHONPATH=src python scripts/restore_platform_backup.py data/backups/<archive>.tar.gz --force
```

## Non-destructive drill

```bash
PYTHONPATH=src python scripts/backup_restore_drill.py --label monthly-drill
```

Drill actions:
- creates a fresh backup archive,
- verifies manifest checksums,
- runs SQLite `PRAGMA integrity_check` when backend is SQLite.

## Cadence and evidence
- Minimum cadence: monthly.
- Store drill output JSON in incident/change records.
- Treat drill failure as P1 reliability incident.
