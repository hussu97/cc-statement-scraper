# Secret Rotation Playbook

> **Legacy (v1).** This describes the frozen FastAPI backend (`backend/`) and is kept only until the Ledger v2 cutover. For v2 see [ARCHITECTURE.md](../../ARCHITECTURE.md) and [PRODUCTION.md](../../PRODUCTION.md).

## Scope
This playbook covers all high-risk credentials used by the platform API, scraping workers, storage backends, and CI/CD release flows.

## Secret Inventory
- Session signing secret (`CCS_PLATFORM_SESSION_SECRET_KEY`).
- Runtime setting credentials persisted in `runtime_settings` (encrypted at rest).
- Storage credentials (`CCS_PLATFORM_GCS_*`).
- CI/CD publishing/signing credentials (GitHub OIDC identity and package registry access).

## Rotation Policy
- Standard cadence: rotate all high-risk credentials every 90 days.
- Emergency cadence: rotate within 1 hour of suspected exposure.
- Dual-control: one operator performs the change, one reviewer verifies completion.

## Standard Rotation Procedure
1. Create new secret value in the secret manager (or equivalent managed source).
2. Update deployment/runtime environment references to point to the new value.
3. Restart API and worker processes in a rolling manner.
4. Validate `/api/v1/health/ready` and run one smoke scrape + upload + export job.
5. Revoke old secret value after validation succeeds.
6. Record evidence in the change ticket:
   - timestamp,
   - rotated key(s),
   - validator,
   - verification outputs.

## Emergency Rotation Procedure
1. Immediately disable/revoke the suspected secret.
2. Generate replacement secret and roll out to runtime.
3. Confirm auth failures for old credentials and success for new credentials.
4. Review audit events and access logs from the exposure window.
5. Open a post-incident report with blast-radius analysis.

## Validation Checklist
- No plaintext credentials in tracked files.
- Runtime settings secret readback is disabled in production.
- Encryption key is present in production (`CCS_PLATFORM_RUNTIME_SETTINGS_ENCRYPTION_KEY`).
- Audit trail includes credential mutation events and actor metadata.

## Rollback
- Keep previous credential value disabled but recoverable for up to 24 hours.
- If new credential fails validation, rollback to previous value, re-enable access, and repeat with a fresh replacement.
