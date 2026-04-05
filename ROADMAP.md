# Production Hardening Audit — Maintenance Week Plan

## Context

The platform (backend, frontend, scraper, gmail-relay) is deployed to production. Before entering maintenance mode, this audit identified **actionable issues** across security, reliability, scalability, and correctness. Items are triaged into what to fix **this week** vs. backlog.

---

## Priority 1 — Fix This Week (Broken / Security)

### 1. ~~Broken: `Dockerfile.frontend` references missing nginx config~~ ✅ DONE
- **File**: `deploy/Dockerfile.frontend:11`
- **Fix**: `deploy/nginx/frontend.conf` recreated with SPA config (try_files, listen 8080).

### 2. ~~Broken: `security.yml` references deleted `Dockerfile.app`~~ ✅ DONE
- **File**: `.github/workflows/security.yml:32`
- **Fix**: Changed to `deploy/Dockerfile.api`.

### 3. ~~Security: CORS defaults to `["*"]` when env var is empty~~ ✅ DONE
- **File**: `backend/ccs_platform/core/settings.py` (`model_post_init`)
- **Fix**: In production mode, app refuses to start if CORS origins are empty/wildcard. Dev allows wildcard without credentials.

### 4. ~~Security: Bcrypt exceptions silently swallowed~~ ✅ DONE
- **File**: `backend/ccs_platform/application/auth/service.py:74`
- **Fix**: `logger.exception(...)` added in the except block before returning None.

### 5. ~~Security: No file upload size limit~~ ✅ DONE
- **File**: `backend/ccs_platform/api/v1/endpoints/jobs.py` (upload endpoint)
- **Fix**: `max_upload_size_mb` setting (default 50) enforced; returns 413 on oversize files.

### 6. ~~Security: Service tokens never expire~~ ✅ DONE
- **File**: `backend/ccs_platform/db/models/email_ingestion.py` (ServiceApiToken model)
- **Fix**: Added optional `expires_at` column (`20260405_000016` migration). `require_service_token` in `deps.py` rejects tokens where `expires_at` is in the past. NULL = no expiry.

### 7. ~~Security: Docker images run as root~~ ✅ DONE
- **Files**: `deploy/Dockerfile.api`, `deploy/Dockerfile.gmail-relay`, `deploy/Dockerfile.frontend`
- **Fix**: All images now run as non-root (`appuser` uid 1000 / `nginx` user).

### 8. ~~Reliability: No React Error Boundary~~ ✅ DONE
- **File**: `frontend/src/components/ErrorBoundary.tsx`, `frontend/src/main.tsx`
- **Fix**: `<ErrorBoundary>` wraps entire app in `main.tsx`; shows "Something went wrong" fallback with reload button.

---

## Priority 2 — Fix This Week (Robustness)

### 9. Reliability: Scraper upload has no retry logic
- **File**: `scraper/scraper/client.py:63-74`
- **Issue**: Single upload attempt. If backend is briefly down after a 30-min scrape, all PDFs are lost.
- **Fix**: Add exponential backoff retry (3 attempts, 5s/15s/45s).

### 10. Reliability: Scraper doesn't validate API token at startup
- **File**: `scraper/scraper/client.py:42`
- **Issue**: Token check only happens at upload time, not at scrape start.
- **Fix**: Validate `CCS_SCRAPER_API_TOKEN` in `get_config()` or at CLI startup. Fail fast.

### 11. Scalability: Missing DB indexes on FK columns
- **Files**: `backend/ccs_platform/db/models/` — `operations.py`, `statements.py`, `email_ingestion.py`
- **Columns needing indexes**: `JobItem.job_id`, `Statement.bank_code`, `StatementLine.statement_id`, `EmailIngestionEvent.route_id`
- **Fix**: Add Alembic migration with `CREATE INDEX` for each.

### 12. Reliability: Rate limiting on login endpoint
- **File**: `backend/ccs_platform/api/v1/endpoints/auth.py`
- **Issue**: Bcrypt is CPU-expensive. No rate limit on `/auth/login` = easy DoS.
- **Fix**: Add `slowapi` rate limiter — 5 attempts/minute per IP on login. Optionally on other write endpoints.

---

## Priority 3 — Backlog (Nice to Have)

### 13. Frontend: Split `EmailIngestionPage.tsx` (947 lines) into sub-components
### 14. Frontend: Add consistent error message extraction utility
### 15. Frontend: Confirmation dialog before destructive actions (revoke token, delete)
### 16. Backend: Orphaned storage objects on upload job failure (add cleanup in except block)
### 17. Backend: Log security events (token creation, login attempts, runtime setting changes)
### 18. Scraper: Extract embedded JS from Python strings into `.js` files
### 19. Docs: Update ARCHITECTURE.md references to removed components
### 20. CI: Add scraper test job to CI pipeline
### 21. Dependencies: Pin exact versions via `pip-compile`

---

## Implementation Order

```
Day 1: Items 1-2 (broken CI/Docker), 7 (non-root Docker)
Day 2: Items 3-4 (CORS, bcrypt logging), 5 (upload limit)
Day 3: Items 8 (error boundary), 6 (token expiry), 11 (DB indexes)
Day 4: Items 9-10 (scraper retry + early validation), 12 (rate limiting)
Day 5: Buffer / start on Priority 3 items
```

## Verification

- After items 1-2: CI green, `docker build -f deploy/Dockerfile.frontend .` succeeds, security.yml passes
- After item 3: App refuses to start with empty CORS in production mode
- After item 5: Upload of >50MB file returns 413
- After item 6: Creating a token with expiry, then waiting for expiry, returns 401
- After item 8: Trigger a JS error in a component — error boundary catches it, shows fallback
- After item 9: Kill backend mid-scrape, scraper retries upload 3 times
- After item 11: `EXPLAIN ANALYZE` on FK join queries shows index scans
- After item 12: >5 login attempts in 1 minute returns 429
- Run full backend test suite: `cd backend && source .venv/bin/activate && python -m pytest -q`
- Run frontend tests: `cd frontend && npm test -- --run`
