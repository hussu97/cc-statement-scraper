# Changelog

## [Unreleased]

### Backend

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

- **feat** Add **OAuth Token Setup** panel to `EmailIngestionPage.tsx` between Mailboxes and Bank Routing Matrix; one card per provider with Authorize link, code input, server-side exchange, token copy button, mailbox dropdown, and Save to Mailbox action; code input accepts raw code or full redirect URL

### Docs

- **docs** Update `PRODUCTION.md` EI-4: replace multi-step manual curl workflow with new in-UI OAuth flow (6 steps, no terminal)
- **docs** Update `backend/.env.example`: document the four `CCS_PLATFORM_EMAIL_*` OAuth credential env vars

- **refactor** Comprehensive env-var config redesign: `session.py` engine/SessionLocal creation is now lazy (`@lru_cache` `get_engine()`/`get_session_local()`); `auth/service.py` `_ACCOUNTS` replaced with lazy `_build_accounts()`; login hashes moved from raw `os.getenv()` to pydantic-settings fields (`login_hash_hussain`, `login_hash_tejasvie`); `_SUPPRESS_ENV_FILE` hack replaced with `PYTEST_CURRENT_TEST` detection in `_resolve_env_file()`; `load_dotenv()` bridge removed; `clear_settings_caches()` centralises cache-clearing for tests; `conftest.py` simplified to a clean autouse fixture
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
- **refactor** Remove hardcoded `"hussain"` profile key fallback from `deps.py`; default now falls through to `get_default_profile(db)`; `ProfileContext` enriched with `is_default` field; `runtime_settings.py` guard uses `not profile.is_default` (ROADMAP 3.2)
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
