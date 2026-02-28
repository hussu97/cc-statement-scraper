# Changelog

## [Unreleased]

### Backend

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

### Frontend (web)

- **testing** Configure Vitest 3 + `@testing-library/react` + `jsdom` as the frontend test framework; add `npm test` and `npm run test:watch` scripts (ROADMAP 4.1)
- **testing** Extract duplicated inline utilities to `src/lib/`: `format.ts` (`formatAmount`), `errors.ts` (`isAbortError`), `useDebounce.ts` (`useDebouncedValue`); update imports in `DashboardPage`, `RawLinesPage`, `RuntimeSettingsPage` (ROADMAP 4.1 / 4.3 partial)
- **testing** Add 25 unit tests across 4 test files: `format.test.ts`, `errors.test.ts`, `useDebounce.test.ts`, `datetime.test.ts`

### Docs

- **ci** Add `Run frontend tests` step to `frontend-gates` job in `release-cicd.yml`; runs `npm test -- --run` before the build on every PR and push (ROADMAP 5.3)
- **docs** Expand PRODUCTION.md Plan 1 (Free) from a stub into a full step-by-step guide covering secret generation, Neon DB setup, Render Web Service and Background Worker configuration (env vars, persistent disk, queue split), Alembic migration strategy (pre-deploy command), credential seeding via admin UI, Vercel frontend deploy, CORS wiring, health-check verification, and ongoing operations (log access, storage upgrade, key rotation)
