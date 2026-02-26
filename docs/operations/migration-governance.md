# Migration Governance and Release Safety

## Preflight checks

```bash
PYTHONPATH=src python scripts/migration_preflight.py
```

Checks include:
- each migration file has non-empty `upgrade()` and `downgrade()` paths,
- alembic revision graph has a single head,
- optional DB revision state matches alembic head.

## Upgrade/Downgrade smoke
Run for every release candidate:
1. `alembic upgrade head`
2. `alembic downgrade base`
3. `alembic upgrade head`

## Rollback policy
- Every migration must maintain a tested downgrade path.
- Breaking DDL requires staged rollout with explicit rollback SQL/runbook.
- No production deploy if preflight checks fail.
