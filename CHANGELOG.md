# Changelog

## [Unreleased]

### Scraper

- **fix** FAB: after "DOWNLOAD STATEMENTS" modal opens, wait for `select[name='estatementTenure']` to become visible before attempting to select months — previously a fixed 700ms wait was insufficient, causing `_download_requested_months` to see `has_tenure=False` and try to re-open the modal (which fails while the modal is already shown), silently skipping all requested months
- **fix** ADCB: wrap `login_selector_visible` and `is_authenticated_session` in try/except to handle `TargetClosedError` — after clicking "Login" on the concurrent-session gate, ADCB navigates/reloads the page and the old page reference closes, causing a crash on the next auth-poll tick
- **fix** SIB: restructure "Secure Login" polling from 3 × 1400ms (4.2s) to 2 × (7 × 1500ms) = up to 21s; click the button once per outer attempt rather than on every inner poll iteration, preventing unintended re-clicks while the password screen is loading

### Backend

- **chore** Uninstall `pip` from `Dockerfile.api` and `Dockerfile.gmail-relay` after dependencies are installed — pip 26 ships a CycloneDX SBOM of its vendored libraries (`pip/_vendor/bom.cdx.json`) which Trivy reads as installed packages, failing the Security Scan container job on `msgpack` 1.1.2 and `setuptools` 70.3.0 even though nothing in the app imports them; a runtime image needs no package installer, so removing pip clears the findings and trims the attack surface
- **chore** CI: grant the workflow token `pull-requests: read` — `dorny/paths-filter` resolves changed files for `pull_request` events through the PR listFiles API, which failed with "Resource not accessible by integration" under the repo's default token scopes, making the `changes` job (and therefore every downstream job) fail on PRs
- **chore** Bump vulnerable dependencies (pip-audit) — `click` 8.3.1→8.4.2 (PYSEC-2026-2132), `cryptography` 48.0.1→50.0.0 (PYSEC-2026-3552/3553/3554), `pillow` 12.2.0→12.3.0 (PYSEC-2026-2253…2257, 3451…3454, 3493…3496), `pyasn1` 0.6.3→0.6.4 (PYSEC-2026-3455/3456/3457), `pypdf` 6.13.3→6.15.0 (PYSEC-2026-3610…3613, CVE-2026-71852, CVE-2026-71870); lower bounds for the direct dependencies tightened in `pyproject.toml` to prevent re-introduction
- **chore** Bump vulnerable dependencies — `cryptography` 48.0.0→48.0.1 (GHSA-537c-gmf6-5ccf), `pydantic-settings` 2.13.1→2.14.2 (GHSA-4xgf-cpjx-pc3j), `pypdf` 6.13.0→6.13.3 (GHSA-jm82-fx9c-mx94), `starlette` 1.2.1→1.3.1 (PYSEC-2026-248, PYSEC-2026-249); tightened lower bounds in `pyproject.toml` to prevent re-introduction

- **fix** Email ingestion 500 — `save_binary` (GCS upload) was outside the `try/except` block in `POST /email-ingestion/upload`; unhandled exceptions rolled back the DB and returned a generic 500 with no event record; moved `save_binary` inside the block so storage failures produce a FAILED event and a structured error response
- **fix** Email ingestion script: retry on 5xx — `email_ingestion_common.py` now retries HTTP 5xx responses (up to 3 attempts with backoff) instead of raising immediately; 4xx still raises immediately
- **fix** Email ingestion script: per-attachment error isolation — `email_ingest_microsoft.py` now wraps each `api.upload_pdf` call in a try/except; a single failed attachment is counted as `failed` and recorded in `attachment_errors` but no longer aborts the rest of the mailbox; the delta link still advances so future runs do not reprocess messages that already succeeded
- **feat** Sentry error monitoring — `sentry-sdk[fastapi]` added; `init_sentry()` in `ccs_platform/core/sentry.py` wires up FastAPI and SQLAlchemy integrations on startup; controlled via `CCS_PLATFORM_SENTRY_DSN` and `CCS_PLATFORM_SENTRY_TRACES_SAMPLE_RATE` env vars (no-op if DSN is unset)

### Frontend (web)

- **feat** Sentry error monitoring — `@sentry/react` added; initialised in `main.tsx` with browser tracing and session replay (errors only); controlled via `VITE_SENTRY_DSN` and `VITE_ENVIRONMENT` env vars (no-op if DSN is unset)

### Backend

- **chore** Migrate production database from Neon to Supabase — updated PRODUCTION.md setup steps (session pooler DSN, Supabase dashboard instructions), ARCHITECTURE.md provider references, and `.env.example` PostgreSQL DSN example; escape `%` as `%%` in `set_main_option` calls in `session.py` and `alembic/env.py` to fix configparser interpolation error when database password contains percent-encoded characters



- **feat** SIB transaction history PDF support — `parse_sib_transaction_history()` parses SIB's "Transaction history" export (date format `DD MMM YYYY`, amount format `CUR [-]amount`) and splits transactions into per-billing-cycle statements using the 12th of each month as the statement cutoff date (13th of M through 12th of M+1 → statement dated 12th of M+1); duplicate rows across PDF pages are deduplicated by fingerprint; the `parse_statement_for_bank()` dispatcher auto-detects the PDF type for SIB and returns a list when multiple statements are produced; `ingest_statement_pdf()`, the parser adapter, and the upload handler all support 1 PDF → N statements; bank detection in the upload endpoint recognises "TRANSACTION HISTORY" + "ACCOUNT NO." + "ACCOUNT TYPE" as SIB

- **chore** Remove scraper-only runtime settings from seed catalog — `DEFAULT_RUNTIME_SETTING_SPECS` now only includes PDF-password keys used by backend parsers (`FAB_PDF_PASSWORD`, `ADCB_CID`, `ADCB_PDF_PASSWORD`, `ENBD_PDF_PASSWORD`, `SIB_PDF_PASSWORD`); login credentials and scraper-specific flags (`FAB_USERNAME/PASSWORD`, `ADCB_LOGIN_PASSWORD`, `ADCB_FORCE_VIRTUAL_KEYBOARD`, `ENBD_USERNAME/PASSWORD`, `EIB_USERNAME/PASSWORD`, `SIB_USER_ID/PASSWORD/SECURE_IMAGE_TEMPLATE_BASE64`, `MASHREQ_USERNAME/PASSWORD`) are no longer seeded or shown in the UI; migration `20260304_000015` deletes any existing rows for these keys

- **feat** Statement line category override — users can pin a category on any transaction line via `PUT /api/v1/transactions/{id}/category-override`; the pin is stored in a new `category_overrides` table (keyed by fingerprint) and survives both reclassify (skipped by `reclassify_statement_lines`) and reparse (applied during ingestion); `DELETE /api/v1/transactions/{id}/category-override` clears the pin and restores auto-classification; migration `20260304_000014` adds the `category_overrides` table and `category_override` column on `statement_lines`

### Frontend (web)

- **feat** Category override controls — `RawLinesPage` and `StatementsPage` lines tables now show a category dropdown with Pin/Clear buttons; pinned rows display a ⊘ lock indicator; category list is fetched from `GET /api/v1/categories` on mount

### Frontend (web)

- **fix** Proxy API calls through Vercel to fix session cookies on Safari and Chrome incognito — `vercel.json` now rewrites `/api/:path*` to the Render backend so the session cookie is first-party, bypassing browser third-party cookie blocking (`SameSite=None` cross-site cookies were silently dropped)

### Backend

- **feat** Log security events — login success/failure logged via Python logger and audit table; service token creation/revocation emit `service_token_created` / `service_token_revoked` audit events with actor metadata
- **fix** Clean up orphaned staging objects on upload failure — `POST /jobs/upload` now deletes any storage objects already saved before the exception so storage stays consistent with DB state
- **fix** Rate limit login endpoint — sliding window (5 attempts / 60 s per IP) in `POST /auth/login`; returns 429 on excess; no new dependency
- **fix** Add missing FK indexes via migration `20260302_000012` — `job_items.job_id`, `statements.bank_code`, `statement_lines.statement_id`; also declare them in model `__table_args__`
- **fix** Enforce CORS origin list in production — `model_post_init` raises `RuntimeError` if `CCS_PLATFORM_CORS_ALLOW_ORIGINS` is `"*"` or empty when `ENVIRONMENT=production`; `create_app` disables `allow_credentials` when origins is wildcard (browser spec violation)
- **fix** Log bcrypt failures — `authenticate_credentials` now calls `logger.exception()` before returning `None` on bcrypt error; distinguishes corrupted-hash system errors from wrong-password denials
- **fix** Enforce upload size limit — new setting `CCS_PLATFORM_MAX_UPLOAD_SIZE_MB` (default 50); upload endpoint returns 413 for files exceeding the limit
- **feat** Service token expiry — add optional `expires_at` column to `service_api_tokens` (migration `20260302_000011`); `require_service_token` returns 401 if token is past its expiry; `ServiceApiTokenCreate` accepts `expires_at`; `ServiceApiTokenOut` exposes it

### Scraper

- **fix** Fail fast on missing API token — `get_config()` raises `RuntimeError` if `CCS_SCRAPER_API_TOKEN` is unset; previously the error only surfaced at upload time after a full scrape run
- **fix** Retry uploads with exponential backoff — `ScraperClient.upload_pdfs` retries up to 3 times (delays: 5 s, 15 s, 45 s) on transient server errors (5xx / network); 4xx errors are not retried

### Frontend (web)

- **refactor** Split `EmailIngestionPage.tsx` (948 lines) into focused sub-components — `MailboxesPanel`, `OAuthTokenPanel`, `BankRoutingMatrix`, `ServiceTokensPanel`, and a shared `types.ts`; main page is now ~230 lines
- **feat** Add `extractErrorMessage` utility — consistent error message extraction from `Error` objects, FastAPI JSON bodies (`{"detail":"…"}`), and strings; available in `lib/errors.ts`
- **feat** Add `ConfirmDialog` component — modal confirmation before destructive actions; used on service token revocation
- **fix** Add `ErrorBoundary` component wrapping the entire app — catches React render errors and shows a "Something went wrong" fallback with a reload button instead of a blank screen

### CI / Infra

- **feat** Add scraper test job to CI pipeline — runs `pytest` on `scraper/**` changes; no browser required (tests mock httpx)
- **fix** Expose `scraper` change-detection output in CI `changes` job — was declared in path filters but not wired to outputs
- **chore** Pin backend dependencies via `pip-compile` — `requirements.txt` now contains fully-pinned transitive versions generated from `requirements.in` / `pyproject.toml`

### Docs

- **docs** Update `ARCHITECTURE.md` — document in-process rate limiter, token expiry/audit, error boundary, and confirm dialog
- **fix** Restore `deploy/nginx/frontend.conf` — standard SPA nginx config (try_files, aggressive cache headers for hashed assets, no-cache for index.html); `Dockerfile.frontend` was broken without it
- **fix** Fix `security.yml` Trivy scan job — update Dockerfile reference from deleted `Dockerfile.app` to `Dockerfile.api`; CI security job was always failing
- **chore** Add non-root `appuser` (uid 1000) to `Dockerfile.api` and `Dockerfile.gmail-relay`; switch `Dockerfile.frontend` to built-in `nginx` user with corrected directory ownership

- **docs** Add Microsoft Outlook / Hotmail ingestion section to `PRODUCTION.md` (section 6) — Azure app registration, API permissions (`Mail.Read`, `offline_access`), client secret, Render env vars (`CCS_PLATFORM_EMAIL_INGESTION_ENABLED`, `CCS_PLATFORM_EMAIL_MS_CLIENT_ID`, `CCS_PLATFORM_EMAIL_MS_CLIENT_SECRET`), OAuth refresh token generation via admin UI, mailbox setup, and verification steps; renumber Scraper CLI section from 6 to 7
- **docs** Remove pre-deploy command from `PRODUCTION.md` — `init_db()` already runs `alembic upgrade head` automatically on startup for PostgreSQL; pre-deploy command is a paid Render feature and is not needed

### Backend

- **fix** Email ingestion `_runtime_setting_value` now falls back to Pydantic settings (`CCS_PLATFORM_EMAIL_MS_CLIENT_ID`, `CCS_PLATFORM_EMAIL_MS_CLIENT_SECRET`, etc.) when the DB row is missing — eliminates the need to duplicate OAuth client credentials as runtime settings when they are already set as env vars on the server

- **fix** MASHREQ parser: parse credit transactions whose amount ends with a trailing ` -` suffix — extend both `_ROW_RE_SHORT` and `_ROW_RE` suffix group to `(?:CR|DR|-)` and treat `-` suffix same as `CR` (negate the amount); credits appearing after the debits sub-total (e.g. inward IPP payments) were previously silently skipped

- **feat** Make service tokens profile-agnostic — drop `profile_id` FK from `service_api_tokens` (migration `20260301_000010`); add global `UNIQUE(name)` constraint; `ServiceTokenContext` no longer carries `profile_id`/`profile_key`; `get_profile_context_or_service_token` now requires `X-Profile-Key` header when using a bearer token; automation entity endpoints (`/oauth/{provider}/access-token`, `PATCH /mailboxes/{mailbox_id}/sync-state`, `POST /upload`) auto-derive profile from the mailbox/route in the request; automation list endpoints (`GET /automation/mailboxes`, `GET /automation/routes`) return data across all profiles; token management endpoints (list, create, revoke) are global and no longer scoped to the active profile

- **fix** Lazy-import `pandas` inside `build_yearly_workbook_from_statements()` — removes ~104 MB (pandas + numpy) from startup memory footprint, fixing OOM crash (exit code 3) on Render 512 MB free tier
- **fix** Lazy-import `pdfplumber` inside `_extract_pdf_text()` in `jobs.py` — consistent with lazy-import pattern; was already loaded transitively via bank parsers but removes the module-level import
- **fix** Lazy-import all bank parsers in `dispatcher.py` and `parser_validate.py` — removes pdfplumber (~15 MB) from startup; parsers are now imported only when a parse job actually runs; cleaned up `parsers/__init__.py` to stop eagerly re-exporting all 6 parsers
- **fix** Add `pool_size=2`, `max_overflow=2`, `pool_recycle=300` for PostgreSQL engine — prevents "SSL connection closed" errors caused by Render managed Postgres dropping idle connections after 5 min; keeps total connections within free tier's 25-connection limit
- **chore** Add `CCS_PLATFORM_REQUEST_LOGGING_ENABLED=false` to Render env vars in `PRODUCTION.md` and document the setting in `backend/.env.example`
- **refactor** Delete `adapters/banks/browser/` — dead browser adapter code (base, downloader, shared, and 6 bank adapters) removed from backend; confirmed zero imports outside that directory after decoupling
- **refactor** Rename package `creditcardstatementscraper` → `ccs-platform` in `pyproject.toml`; remove `playwright>=1.50` dependency
- **fix** Change `ScheduleCreate.job_type` default from `JobType.SCRAPE` to `JobType.UPLOAD` — SCRAPE has no handler and raises `ValueError` at runtime
- **chore** Add deprecation comments to `JobType.SCRAPE` and `JobType.BANK_CONNECTION_TEST` in `enums.py` — no handlers exist; kept in enum for PostgreSQL compatibility only
- **chore** Rewrite `backend/.env.example` — remove browser geo-spoofing section (`BROWSER_PROXY_URL`, `BROWSER_GEO_*`, `BROWSER_TIMEZONE_ID`, `BROWSER_LOCALE`); remove `QUEUE_BACKLOG_SLO_SCRAPE`; update `WORKER_QUEUES` default to `default`; rename "Scraper credentials" section to "Bank credentials (seeded into runtime settings)"; fix timezone comment ("scrape-month" → "billing month")

### Scraper

- **feat** Introduce `BankMap` — persistent JSON map (`state/bank_map.json`) that records each downloaded PDF's origin bank at download time; `scrape` command creates the map before scraping, passes it to `run_end_to_end_downloads`, then groups new PDFs by their recorded bank code and uploads each group with an explicit `bank_code` arg; entries are removed after a successful upload; PDFs not in the map (e.g. pre-existing files or manual downloads) fall through to the existing backend detection logic — eliminates all ambiguity in PDF→bank mapping at upload time
- **feat** Pass `bank_code_hint` from scraper to backend on `/api/v1/jobs/upload` — when the scraper knows the bank (via `BankMap` or filename prefix), it sends `bank_code_hint` as a multipart form field so the backend skips the expensive `pdfplumber` content scan entirely

- **refactor** Make bank adapter system generic and auto-discovering — add `AuthPollAction` enum and `AuthPollState` dataclass to `base.py`; expand `BankAdapter` with optional hook params (`is_authenticated_session`, `is_login_screen`, `is_login_failure`, `on_auth_poll_tick`, `skip_mfa_user_prompt`, `skip_keyword_fallback`, `skip_login_selector_fallback`, `browser_launch_overrides`); add `discover_adapters()` via `pkgutil` auto-discovery; move all bank-specific auth logic (FAB continue gate, ADCB OTP/concurrent session/re-login, MASHREQ anti-bot retry) into per-adapter `on_auth_poll_tick` hooks; replace ~135 lines of `if code ==` branching in `downloader.py` with a generic hook-based polling loop; `_launch_bank_context` now reads `channel_candidates` and `init_scripts` from `adapter.browser_launch_overrides()`; adding a new bank now requires only a new adapter module with an `ADAPTER` constant — no changes to `downloader.py`
- **docs** Add `scraper/ADDING_A_NEW_BANK.md` — step-by-step guide covering the 3 required functions, all optional hook functions with examples, `AuthPollAction`/`AuthPollState` field references, and verification commands

- **refactor** Make `--profile` a required option on `scrape` and `upload` CLI commands — remove `CCS_SCRAPER_PROFILE_KEY` env var support; `get_config(profile: str)` now requires a profile; `ScraperConfig.profile_key` defaults to `""` instead of reading from env

### Scraper

- **chore** Add `scraper/.env.example` — documents all `CCS_SCRAPER_*` settings and bank credential keys with inline comments
- **test** Add scraper test suite (`tests/`): `test_config.py` (env var parsing, profile isolation, credential filtering), `test_month_utils.py` (month name/abbreviation mapping), `test_bank_config.py` (YAML loading, path structure), `test_shared.py` (MFA/failure pattern detection, PDF snapshot utilities, `require_env`), `test_client.py` (HTTP upload request structure, headers, multipart); no browser automation required — 86 tests, all pure logic
- **chore** Add `[project.optional-dependencies] dev = ["pytest>=8.0"]` and pytest config (`testpaths`, `pythonpath`) to `scraper/pyproject.toml`; fix build backend to `setuptools.build_meta`
- **chore** Add scraper test step to `scripts/hooks/pre-commit` — runs `pytest -q` via `scraper/.venv/bin/pytest` when scraper files are staged; skips gracefully if scraper venv not found; update `scraper/README.md` to show `pip install -e ".[dev]"`

### Docs

- **docs** Create `backend/README.md` — setup, database, run commands, test instructions, key env vars, password hash generation
- **docs** Update `scraper/README.md` — expand setup section with explanation of `pip install -e .`, add `cp .env.example .env` step
- **docs** Update root `README.md` — reference `backend/README.md` in backend setup section; reference scraper `.env.example`

### Backend

- **refactor** Remove browser scraping from backend: delete `handlers/scrape.py`, `handlers/bank_connection_test.py`, `adapters/banks/browser/` (browser code moved to `scraper/`); remove `POST /jobs/scrape` and `POST /diagnostics/bank-connection-test` endpoints; remove `ScrapeJobRequest` schema; remove `SCRAPE` and `BANK_CONNECTION_TEST` from job dispatcher and service defaults; remove `browser_proxy_url`, `browser_geo_*`, `browser_timezone_id`, `browser_locale`, `queue_backlog_slo_scrape` from settings; change `worker_queues` default to `default`; remove `playwright>=1.50` from `requirements.txt`
- **feat** Add `require_operator_or_service_token` and `get_profile_context_or_service_token` dependencies in `api/deps.py`; `POST /jobs/upload` now accepts either a session (operator+) or a Bearer service token with `upload` scope — enables the scraper CLI to upload directly

### Scraper

- **feat** Add `scraper/` — standalone Python CLI package for browser-based bank statement downloads; Playwright + Chromium bank adapters (FAB, ADCB, ENBD, EIB, SIB, Mashreq) moved verbatim from backend with updated import paths; `ccs-scraper scrape` downloads PDFs and uploads to backend; `ccs-scraper upload` sends local PDFs; `ccs-scraper install-browser` installs Chromium; all config via `CCS_SCRAPER_*` env vars

### DevOps

- **chore** Delete `deploy/Dockerfile.app` (Playwright image no longer needed); update `Dockerfile.api` comment; simplify `docker-compose.prod.yml` — remove `worker` service and `edge_public` on `app_internal` containers; API service gets `CCS_PLATFORM_EMBEDDED_WORKER=true` and `edge_public` for outbound GCS/email connectivity
- **ci** Remove `deploy/Dockerfile.app` from backend path filter in `ci.yml`; add `scraper/**` filter; update `deploy-backend.yml` to remove `Dockerfile.app` from change detection pattern

### Docs

- **docs** Create `ARCHITECTURE.md` — system overview, component boundaries, data flows, auth model, technology stack, design decisions
- **docs** Rewrite `PRODUCTION.md` — single deployment plan covering Render (API), Vercel (frontend), Neon (PostgreSQL), GCS (storage), Cloud Run (Gmail relay), and local Scraper CLI; remove Plan 2 (GCP full), standalone worker, and all browser-related env vars
- **docs** Update `README.md` — add `scraper/` to directory structure, describe decoupled architecture, add Scraper CLI quick-start, remove Dockerfile.app and worker service references

### Backend

- **feat** Add `job_logs` table and `JobDBLogHandler` — captures all `ccs_platform.*` and `playwright.*` INFO+ log records emitted during a job run into `job_logs` via thread-local job ID; retention cleans up entries older than 7 days (`retention_job_logs_days=7`); `GET /jobs/{id}/logs` endpoint returns the log stream; alembic migration `20260301_000009`
- **feat** Add `JobLogOut` response schema; `GET /jobs/{job_id}/logs` endpoint (limit up to 2000)
- **feat** Statements list: rename "Date" column to "Statement Date"; add "Upload Date" column showing `ingested_at` (already in DB/API, no migration needed)
- **feat** Add `deploy-gmail-relay.yml` GitHub Actions workflow — automatically rebuilds and redeploys the `ccs-gmail-relay` Cloud Run service on changes to `gmail_ingest_relay.py`, `email_ingestion_common.py`, `requirements.txt`, or `deploy/Dockerfile.api`; uses `GCP_SA_KEY`, `GCP_PROJECT_ID`, `CCS_API_BASE_URL`, and `CCS_GMAIL_RELAY_SERVICE_TOKEN` secrets
- **fix** Eliminate temp-dir cross-process dependency in the upload pipeline: PDF uploads (manual UI and email ingestion) are now saved directly to the storage backend (GCS in prod, local `StorageAdapter` in dev) and a `storage_key` is stored in the job payload instead of a local file path; the upload job handler reads from storage and deletes the staging object after processing; backward-compatible with queued jobs that still carry `temp_path`; export workbook handler now writes to `io.BytesIO` instead of a temp file; `build_yearly_workbook_from_statements` accepts `Path | BinaryIO`; `delete(key)` added to all storage adapters (`StorageAdapter` base, `GCSStorageAdapter`, `LocalStorageAdapter`)
- **fix** Use `/consumers/` endpoint for Microsoft token refresh in `TOKEN_ENDPOINT_BY_PROVIDER`; was incorrectly using `/common/`, causing `AADSTS9002331` errors for personal-account-only app registrations
- **fix** Use `mailFolders/Inbox/messages/delta` instead of `messages/delta` in `email_ingest_microsoft.py`; Graph API does not support change tracking on the top-level messages collection, only on specific folders
- **feat** Scan `Inbox`, `DeletedItems`, and `Archive` folders per mailbox in `email_ingest_microsoft.py`; each folder tracks its own delta link in sync_state (`microsoft_delta_link_inbox`, `microsoft_delta_link_deleteditems`, `microsoft_delta_link_archive`); missing folders (e.g. no Archive) are silently skipped (HTTP 404); backwards-compatible with old single `microsoft_delta_link` key
- **fix** Handle permanently-deleted Gmail messages in `gmail_ingest_relay.py`; `get_message` 404 (message hard-deleted before relay processed the push) now skips silently instead of crashing the notification handler
- **feat** Add four optional env-var-backed settings fields (`email_ms_client_id`, `email_ms_client_secret`, `email_gmail_client_id`, `email_gmail_client_secret`) to `PlatformSettings`; sourced from `CCS_PLATFORM_EMAIL_MS_*` / `CCS_PLATFORM_EMAIL_GMAIL_*` env vars; profile-agnostic, no DB table
- **feat** Add `OAuthConfigOut`, `OAuthCodeExchangeRequest`, `OAuthCodeExchangeOut` schemas to `email_ingestion.py`
- **feat** Add `GET /api/v1/email-ingestion/oauth/config` — returns auth URLs and `configured` status for Microsoft and Gmail; auth URLs built from the new settings fields
- **feat** Add `POST /api/v1/email-ingestion/oauth/exchange-code` — exchanges an OAuth authorisation code for a refresh token entirely server-side; reads client credentials from settings; returns `OAuthCodeExchangeOut`; never persists the token

### Frontend (web)

- **feat** Remove `profile_id` from `ServiceApiTokenOut` type in `EmailIngestionPage.tsx` — tokens are now global; field no longer returned by the API

- **feat** Add **OAuth Token Setup** panel to `EmailIngestionPage.tsx` between Mailboxes and Bank Routing Matrix; one card per provider with Authorize link, code input, server-side exchange, token copy button, mailbox dropdown, and Save to Mailbox action; code input accepts raw code or full redirect URL

### Docs

- **docs** Update `PRODUCTION.md` EI-4: replace multi-step manual curl workflow with new in-UI OAuth flow (6 steps, no terminal)
- **docs** Update `backend/.env.example`: document the four `CCS_PLATFORM_EMAIL_*` OAuth credential env vars

- **refactor** Comprehensive env-var config redesign: `session.py` engine/SessionLocal creation is now lazy (`@lru_cache` `get_engine()`/`get_session_local()`); `auth/service.py` `_ACCOUNTS` replaced with lazy `_build_accounts()`; login hashes moved from raw `os.getenv()` to pydantic-settings fields (`login_hash_hussain`, `login_hash_bob`); `_SUPPRESS_ENV_FILE` hack replaced with `PYTEST_CURRENT_TEST` detection in `_resolve_env_file()`; `load_dotenv()` bridge removed; `clear_settings_caches()` centralises cache-clearing for tests; `conftest.py` simplified to a clean autouse fixture
- **fix** `get_settings()` now calls `load_dotenv()` alongside pydantic-settings so that values in `backend/.env` (e.g. `CCS_PLATFORM_LOGIN_HASH_*`) are visible to `os.getenv()` calls made at module-import time (fixes HTTP 401 on local backend when hashes are set only in `.env`)
- **fix** `conftest.py` sets `_SUPPRESS_ENV_FILE=True` before importing `ccs_platform.db` so the real encryption key is never loaded into `os.environ` during pytest — encryption-related tests that use `monkeypatch` work correctly again
- **security** Remove hardcoded fallback password in `auth/service.py`; raise `RuntimeError` at startup if a login credential env var is absent in production (ROADMAP 1.1)
- **security** Add `session.rollback()` on exception in `get_db` FastAPI dependency so partial writes are never committed on error (ROADMAP 1.2)
- **security** Validate `CCS_PLATFORM_SESSION_SECRET_KEY` at startup in production — raises `RuntimeError` if the value is the insecure default or shorter than 32 bytes (ROADMAP 1.3)
- **security** Eliminate thread-unsafe `os.environ` mutation for bank credential injection; credentials are now fetched as a plain dict and passed explicitly through the adapter call chain so concurrent worker threads cannot corrupt each other's credentials (ROADMAP 1.4)
- **security** Upload endpoint (`POST /jobs/upload`) now loads ADCB PDF passwords from the `runtime_settings` table instead of `os.environ`, so credentials updated via the admin UI are reflected without a restart (ROADMAP 1.5)
- **architecture** Extract `JobRunner` God-class (1,068 lines) into `application/jobs/handlers/` package — one module per job type (`upload`, `scrape`, `reclassify`, `export_workbook`, `parser_validate`, `bank_connection_test`, `reparse`); `JobContext` dataclass decouples handlers from the runner; `runner.py` reduced to 237-line thin dispatcher (ROADMAP 2.1)
- **architecture** Introduce repository layer (`StatementRepository`, `JobRepository`, `CategoryRepository`) in `db/repositories/`; all SELECT/COUNT query logic moved out of route handlers (ROADMAP 2.2)
- **architecture** Add `BankAdapter` dataclass and `LoginFn` / `LoginSelectorVisibleFn` / `DownloadLatestStatementFn` Protocol types in `adapters/banks/browser/base.py`; `downloader.py` now registers all adapters in a single `BANK_ADAPTERS` dict instead of three separate Callable maps (ROADMAP 2.3)
- **architecture** Consolidate `MONTH_INDEX` into `domain/parsing/month_utils.py`; all five bank adapters import from the single source of truth (ROADMAP 2.4)
- **architecture** Replace bespoke RRULE parser with `dateutil.rrule.rrulestr` in `application/jobs/scheduler.py`; DAILY, MONTHLY, and YEARLY schedules now work correctly (ROADMAP 2.5)
- **testing** Add `backend/tests/conftest.py` with shared `sqlite_engine`, `db_session`, `sample_profile`, `sample_banks`, and `dev_settings` fixtures; eliminates per-file boilerplate (ROADMAP 3.6)
- **fix** Correct `ROOT_DIR` resolution in `core/bank_config.py` (`parents[2]` → points to `backend/`) so `config/banks.yaml` is found when running from the project root with `PYTHONPATH=backend`
- **refactor** Remove hardcoded `"alice"` profile key fallback from `deps.py`; default now falls through to `get_default_profile(db)`; `ProfileContext` enriched with `is_default` field; `runtime_settings.py` guard uses `not profile.is_default` (ROADMAP 3.2)
- **refactor** Drop dead `CategoryRule` columns `priority`, `bank_code`, `card_last4` from model and all callers; Alembic migration `20260228_000007` removes the columns and `ix_category_rules_priority` index (ROADMAP 3.3)
- **refactor** Move `EXPECTED_SAMPLE_COUNTS` out of `parser_validate.py` into `domain/parsing/bank_samples.py` as `PARSER_SAMPLE_EXPECTED_COUNTS` (ROADMAP 3.4)
- **refactor** Add `backend/requirements.in` as pip-tools source-of-truth; `requirements-dev.txt` gains `pip-tools>=7.0`; run `pip-compile requirements.in` to regenerate the lock file (ROADMAP 3.5)
- **perf** Fix N+1 query in `reclassify_statement_lines`: active rules fetched once via `_fetch_active_rules(db)`; per-line matching done by pure `find_best_rule(rules, merchant)` function; dead `bank_code`/`card_last4` params removed from `categorize()` (ROADMAP 3.8)
- **fix** Log heartbeat thread errors in `runner.py` via `_log.exception()` before exiting; `_run_job` unhandled exceptions also logged; jobs now surface failures rather than silently hanging (ROADMAP 3.1 / 3.9)
- **feat** Run `alembic upgrade head` automatically at startup for non-SQLite (PostgreSQL) databases; removes need for any manual migration step or paid Render feature in production (`db/session.py` `init_db()`)
- **fix** `test_email_ingestion_api.py` tests now use an isolated per-test temp SQLite file instead of the default `platform.db`; prevents test mailboxes, tokens, and routes from leaking into the development database; deleted 64 leaked test mailboxes and related rows from `platform.db`
- **fix** `test_platform_api.py` CI failures: add `_test_platform_env` autouse fixture that sets a per-test temp SQLite DB, a precomputed bcrypt hash, and explicitly calls `init_db()` + `seed_defaults()` before the test body; all 28 tests now pass without any secrets configured in CI

### Frontend (web)

- **feat** Move Ingestion Activity out of Email Ingestion config page into its own dedicated page (`/email-ingestion/activity`) under the Operations nav section — prevents the event log from crowding configuration panels as it grows over time
- **docs** Rewrite `PRODUCTION.md` email ingestion section: full step-by-step setup guide for Azure OAuth app registration, GCP OAuth client setup, mailbox creation, refresh token flow, bank routing matrix field reference, service token creation; clarify that all OAuth credentials live in Runtime Settings (not deployment env vars); add test-data cleanup note and routing troubleshooting table

- **testing** Configure Vitest 3 + `@testing-library/react` + `jsdom` as the frontend test framework; add `npm test` and `npm run test:watch` scripts (ROADMAP 4.1)
- **testing** Extract duplicated inline utilities to `src/lib/`: `format.ts` (`formatAmount`), `errors.ts` (`isAbortError`), `useDebounce.ts` (`useDebouncedValue`); update imports in `DashboardPage`, `RawLinesPage`, `RuntimeSettingsPage` (ROADMAP 4.1 / 4.3 partial)
- **testing** Add 25 unit tests across 4 test files: `format.test.ts`, `errors.test.ts`, `useDebounce.test.ts`, `datetime.test.ts`
- **security** Remove hardcoded personal email `h_abbasi97@hotmail.com` from `LoginPage.tsx`; email field starts empty (ROADMAP 4.5)
- **fix** Add `2000` to `PAGE_SIZE_OPTIONS` in `TablePagination.tsx`; options are now `[100, 200, 500, 1000, 2000]` per CLAUDE.md rule 12 (ROADMAP 4.6)
- **refactor** Deduplicate `LoginResponse` type: defined once in `src/types/auth.ts`, imported by `App.tsx` and `LoginPage.tsx` (ROADMAP 4.7)
- **feat** `ExportsDiagnosticsPage` now fetches bank list from `GET /api/v1/banks` on mount instead of hardcoding bank codes; shows loading state; auto-selects first bank (ROADMAP 4.8)
- **refactor** Extract all data-fetching logic from `DashboardPage` into `src/lib/useDashboardData.ts` hook; `DashboardPage` reduced from 408 to ~195 lines (ROADMAP 4.9)
- **types** Eliminate all `any` typings across the frontend: new types in `src/types/statements.ts` (`Statement`, `StatementLine`, `PagedResponse`, `Schedule`, `Job`, `Bank`, `Category`, `CategoryRule`, `RuleTestResult`, `RawLine`) cover all API response shapes (ROADMAP 4.4)
- **tooling** Add ESLint 9 (flat config), `@typescript-eslint/eslint-plugin`, `eslint-plugin-react-hooks`, `prettier`, `eslint-config-prettier`; `eslint.config.js` and `.prettierrc` configured; `npm run lint` and `npm run format` scripts added; lint passes with `--max-warnings 0` (ROADMAP 4.2)

### DevOps

- **infra** Add `deploy/Dockerfile.api` — slim image with no Playwright (~500 MB smaller); docker-compose `api` service now builds from it; `Dockerfile.app` (with Playwright) retained for the `worker` service and Render embedded-worker deployments (ROADMAP 5.1)
- **fix** Add `edge_public` network to the `worker` service in `docker-compose.prod.yml` so browser scraping can reach bank websites; all other internal services remain on `app_internal` (ROADMAP 5.2)
- **chore** Remove dead `deploy/nginx/` directory; Caddy is the only reverse proxy in use (ROADMAP 5.5)
- **docs** Update PRODUCTION.md GCP section: build and push `$IMAGE_API` (Dockerfile.api) and `$IMAGE_WORKER` (Dockerfile.app) separately; deploy API and migration job from `$IMAGE_API`, worker from `$IMAGE_WORKER`

### Docs

- **ci** Add `Run frontend tests` step to `frontend-gates` job in `release-cicd.yml`; runs `npm test -- --run` before the build on every PR and push (ROADMAP 5.3)
- **docs** Expand PRODUCTION.md Plan 1 (Free) from a stub into a full step-by-step guide covering secret generation, Neon DB setup, Render Web Service and Background Worker configuration (env vars, persistent disk, queue split), Alembic migration strategy (pre-deploy command), credential seeding via admin UI, Vercel frontend deploy, CORS wiring, health-check verification, and ongoing operations (log access, storage upgrade, key rotation)
