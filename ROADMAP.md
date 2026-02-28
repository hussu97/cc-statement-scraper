# Credit Card Scraper — Audit & Improvement Roadmap

> Last updated: 2026-02-28
> Scope: full codebase audit covering security, architecture, code quality, frontend, DevOps, and repo layout.

---

## Priority Legend

| Label | Meaning |
|-------|---------|
| `CRITICAL` | Must fix before any production exposure |
| `HIGH` | Fix in the next sprint; degrades reliability or security at scale |
| `MEDIUM` | Important tech-debt; fix before adding more features on top |
| `LOW` | Polish / nice-to-have |

---

## 1. Critical / Security

### 1.1 Hardcoded fallback password `CRITICAL`
**Status:** ✅ Resolved — hardcoded fallback removed; `RuntimeError` raised at startup when credential env var is absent in production.
**File:** `backend/ccs_platform/application/auth/service.py`

### 1.2 `get_db` doesn't rollback on exception `CRITICAL`
**Status:** ✅ Resolved — `session.rollback()` added in `except` block before `finally`.
**File:** `backend/ccs_platform/db/session.py`

### 1.3 Weak default `session_secret_key` `CRITICAL`
**Status:** ✅ Resolved — `model_post_init` raises `RuntimeError` in production if the key is the default or shorter than 32 bytes.
**File:** `backend/ccs_platform/core/settings.py`

### 1.4 Thread-unsafe `os.environ` mutation `HIGH`
**Status:** ✅ Resolved — `get_runtime_settings_as_dict` added; credentials fetched as a per-job dict and passed explicitly through `run_end_to_end_downloads` → all six bank adapter `login()` functions; `require_env` accepts an `env` dict so `os.environ` is never mutated per-job.
**Files:** `backend/ccs_platform/core/runtime_settings.py`, `backend/ccs_platform/adapters/banks/browser/shared.py`, all six bank adapters, `downloader.py`, `runner.py`

### 1.5 PDF upload endpoint bypasses runtime settings `HIGH`
**Status:** ✅ Resolved — ADCB PDF passwords now queried from `runtime_settings` table per profile; `os.getenv` calls removed from the upload handler.
**File:** `backend/ccs_platform/api/v1/endpoints/jobs.py`

---

## 2. Architecture

### 2.1 `JobRunner` God class `HIGH`
**Status:** ✅ Resolved — `runner.py` reduced from 1,068 lines to 237 lines. All seven job-type implementations extracted into `application/jobs/handlers/`: `upload.py`, `scrape.py`, `reclassify.py`, `export_workbook.py`, `parser_validate.py`, `bank_connection_test.py`, `reparse.py`. A `JobContext` dataclass in `handlers/context.py` groups `settings`, `storage`, and the two runner callbacks (`assert_not_cancelled`, `update_progress`) so handlers have no dependency on `JobRunner` itself.
**Files:** `backend/ccs_platform/application/jobs/runner.py`, `backend/ccs_platform/application/jobs/handlers/`

### 2.2 No repository layer `HIGH`
**Status:** ✅ Resolved — `StatementRepository`, `JobRepository`, and `CategoryRepository` introduced in `backend/ccs_platform/db/repositories/`. All SELECT/COUNT query logic moved into repository methods; `statements.py`, `jobs.py`, and `categories.py` endpoint files updated to use them instead of calling `db.execute(select(...))` directly.

### 2.3 Bank adapters lack a shared base class `MEDIUM`
**Status:** ✅ Resolved — `BankAdapter` dataclass and `LoginFn` / `LoginSelectorVisibleFn` / `DownloadLatestStatementFn` `Protocol` types defined in `backend/ccs_platform/adapters/banks/browser/base.py`. `downloader.py` replaced its three separate `dict[str, Callable]` maps with a single `BANK_ADAPTERS: dict[str, BankAdapter]` registry; internal dispatch functions now delegate through the adapter struct.

### 2.4 `MONTH_INDEX` dict duplicated across 5 files `MEDIUM`
**Status:** ✅ Resolved — `MONTH_INDEX` defined once in `backend/ccs_platform/domain/parsing/month_utils.py`; all five bank adapters (ADCB, EIB, ENBD, FAB, SIB) import from there.

### 2.5 Custom RRULE parser only handles HOURLY/WEEKLY `MEDIUM`
**Status:** ✅ Resolved — bespoke parser replaced with `dateutil.rrule.rrulestr` in `backend/ccs_platform/application/jobs/scheduler.py`; `python-dateutil>=2.9` added to both `pyproject.toml` and `requirements.txt`. All RFC 5545 frequencies (HOURLY, DAILY, WEEKLY, MONTHLY, YEARLY) now work correctly.

---

## 3. Code Quality

### 3.1 223 bare `except Exception` clauses `HIGH`
**Status:** ✅ Partially resolved — `runner.py` heartbeat loop and `_run_job` handler now log tracebacks via `_log.exception()` before continuing/failing. Remaining `# noqa: BLE001` clauses in adapters are intentional catch-alls; full replacement deferred to future sprint.
**Pattern:** `except Exception:  # noqa: BLE001` throughout the codebase.

### 3.2 Hardcoded profile key `"hussain"` `HIGH`
**Status:** ✅ Resolved — `deps.py` default changed from `"hussain"` to `""` (falls through to `get_default_profile(db)`); `ProfileContext` enriched with `is_default: bool`; `runtime_settings.py` guard uses `not profile.is_default` instead of key comparison.
**Files:** `backend/ccs_platform/api/deps.py`, `backend/ccs_platform/api/v1/endpoints/runtime_settings.py`

### 3.3 Dead database columns `MEDIUM`
**Status:** ✅ Resolved — `CategoryRule.priority`, `bank_code`, `card_last4` removed from model and all callers; Alembic migration `20260228_000007` drops the columns and `ix_category_rules_priority` index.
**Files:** `backend/ccs_platform/db/models/taxonomy.py`, `backend/alembic/versions/20260228_000007_drop_dead_category_rule_columns.py`

### 3.4 `EXPECTED_SAMPLE_COUNTS` in production code `MEDIUM`
**Status:** ✅ Resolved — constant moved to `backend/ccs_platform/domain/parsing/bank_samples.py` as `PARSER_SAMPLE_EXPECTED_COUNTS`; `parser_validate.py` imports from there.
**Files:** `backend/ccs_platform/domain/parsing/bank_samples.py`, `backend/ccs_platform/application/jobs/handlers/parser_validate.py`

### 3.5 `requirements.txt` duplicates `pyproject.toml` `MEDIUM`
**Status:** ✅ Resolved — `backend/requirements.in` created as source-of-truth; `requirements.txt` header updated; `pip-tools>=7.0` added to `requirements-dev.txt`. Run `pip-compile requirements.in` to regenerate lock file.
**Files:** `backend/requirements.in`, `backend/requirements.txt`, `backend/requirements-dev.txt`

### 3.6 No `conftest.py` — fixtures recreated manually `MEDIUM`
**Status:** ✅ Resolved — `backend/tests/conftest.py` created with shared `sqlite_engine`, `db_session`, `sample_profile`, `sample_banks`, and `dev_settings` fixtures.
**File:** `backend/tests/conftest.py`

### 3.7 `_UTCAwareDateTime` not used `MEDIUM`
**Status:** ✅ N/A — `_UTCAwareDateTime` / `_TSTZ` do not exist in this codebase; CLAUDE.md rule 8 is specific to a different project using SQLModel. All 34 datetime columns already use `DateTime(timezone=True)` directly, which is correct for both PostgreSQL (`TIMESTAMPTZ`) and SQLite. No action required.

### 3.8 N+1 query in `reclassify_statement_lines` `MEDIUM`
**Status:** ✅ Resolved — `_fetch_active_rules(db)` fetches all rules once; `find_best_rule(rules, merchant)` is a pure in-memory function; `reclassify_statement_lines` calls both once before the loop. Dead `bank_code`/`card_last4` params removed from `categorize()` and `find_matching_rule()`.
**Files:** `backend/ccs_platform/domain/categorization/engine.py`

### 3.9 Heartbeat thread dies silently `MEDIUM`
**Status:** ✅ Resolved — `runner.py` heartbeat loop now wraps body in `try/except Exception`, calls `_log.exception(...)` with job ID before returning; `_run_job` exception handler also logs via `_log.exception()`.
**Files:** `backend/ccs_platform/application/jobs/runner.py`

---

## 4. Frontend

### 4.1 Zero tests, no test framework configured `HIGH`
**Status:** ✅ Resolved — Vitest 3 + `@testing-library/react` + `jsdom` configured; `vite.config.ts` updated with `test` block; `npm test` script added; 25 unit tests passing across `format.test.ts`, `errors.test.ts`, `useDebounce.test.ts`, `datetime.test.ts`.
**Files:** `frontend/vite.config.ts`, `frontend/src/lib/__tests__/`, `frontend/src/utils/__tests__/`

### 4.2 No ESLint / Prettier `MEDIUM`
**Status:** ✅ Resolved — ESLint 9 (flat config), `@typescript-eslint/eslint-plugin`, `eslint-plugin-react-hooks`, `prettier`, and `eslint-config-prettier` installed. `eslint.config.js` and `.prettierrc` added. `npm run lint` and `npm run format` scripts added. `@typescript-eslint/no-explicit-any` enforced as error; `rules-of-hooks` enforced. Passes with `--max-warnings 0`.
**Files:** `frontend/eslint.config.js`, `frontend/.prettierrc`, `frontend/package.json`

### 4.3 Utility duplication `MEDIUM`
**Status:** ✅ Resolved (partial — completed as part of S3/4.1) — `useDebouncedValue`, `formatAmount`, and `isAbortError` consolidated into `src/lib/useDebounce.ts`, `src/lib/format.ts`, and `src/lib/errors.ts`; `DashboardPage`, `RawLinesPage`, and `RuntimeSettingsPage` updated to import from lib.
**Files:** `frontend/src/lib/`

### 4.4 Pervasive `any` typing `MEDIUM`
**Status:** ✅ Resolved — `"strict": true` was already enabled. All `any` usages eliminated across all pages: proper types defined in `src/types/statements.ts` (`Statement`, `StatementLine`, `PagedResponse`, `Schedule`, `Job`, `Bank`, `Category`, `CategoryRule`, `RuleTestResult`, `RawLine`, `RuntimeSetting`) and `src/types/auth.ts` (`LoginResponse`). ESLint `no-explicit-any: error` now enforces this going forward.
**Files:** `frontend/src/types/statements.ts`, `frontend/src/pages/`

### 4.5 Personal email hardcoded in `LoginPage.tsx` `HIGH`
**Status:** ✅ Resolved — `DEFAULT_LOGIN_EMAIL` constant and its use removed; email field now starts as empty string.
**File:** `frontend/src/pages/LoginPage.tsx`

### 4.6 `TablePagination` missing `2000` option `MEDIUM`
**Status:** ✅ Resolved — `2000` added to `PAGE_SIZE_OPTIONS` in `TablePagination.tsx`; options are now `[100, 200, 500, 1000, 2000]`.
**File:** `frontend/src/components/TablePagination.tsx`

### 4.7 `LoginResponse` type defined twice `LOW`
**Status:** ✅ Resolved — `LoginResponse` defined once in `src/types/auth.ts`; both `App.tsx` and `LoginPage.tsx` import it from there.
**Files:** `frontend/src/types/auth.ts`, `frontend/src/App.tsx`, `frontend/src/pages/LoginPage.tsx`

### 4.8 `ExportsDiagnosticsPage` hardcodes bank list `MEDIUM`
**Status:** ✅ Resolved — bank list now fetched from `GET /api/v1/banks` on mount; loading state shown while fetching; first bank selected as default; connection-test button disabled until banks load.
**File:** `frontend/src/pages/ExportsDiagnosticsPage.tsx`

### 4.9 `DashboardPage` is 427 lines `MEDIUM`
**Status:** ✅ Resolved — all data-fetching state and effects extracted into `src/lib/useDashboardData.ts` hook; `DashboardPage` reduced to ~195 lines of pure layout/interaction logic. (`DashboardFilters` component was already extracted previously.)
**Files:** `frontend/src/lib/useDashboardData.ts`, `frontend/src/pages/DashboardPage.tsx`

---

## 5. DevOps / Deployment

### 5.1 Playwright installed in API image `HIGH`
**File:** `deploy/Dockerfile.app`
**Issue:** Playwright Chromium + dependencies adds ~500 MB to the API image even though the API process never launches a browser. Only the worker needs Playwright.
**Fix:** Split into two Dockerfiles: `Dockerfile.api` (no Playwright) and `Dockerfile.worker` (with Playwright). Reference the correct image per service in `docker-compose.prod.yml`.

### 5.2 `app_internal` network may block worker outbound access `HIGH`
**File:** `deploy/docker-compose.prod.yml`
**Issue:** The `app_internal` network is `internal: true`, which blocks all outbound internet traffic. The scraping worker requires outbound internet (to reach bank websites).
**Fix:** Add `edge_public` network to the `worker` service, or change the `app_internal` network to not be internal and put only the reverse proxy on `edge_public`.

### 5.3 No `npm test` in CI `HIGH`
**Status:** ✅ Resolved — `Run frontend tests` step added to `frontend-gates` job; runs `npm test -- --run` before the build on every PR and push.
**File:** `.github/workflows/release-cicd.yml`

### 5.4 Stale `tmp_ci_migration.db` artifact at repo root `LOW`
**Issue:** `tmp_ci_migration.db` is a CI artifact that should be ephemeral but is committed/left at the repo root.
**Fix:** Add `tmp_ci_migration.db` to `.gitignore`. The CI workflow already uses a separate db path (`ci_release.db`); remove any reference to the old path.

### 5.5 Redundant Caddy + Nginx configs `LOW`
**File:** `deploy/`
**Issue:** Both a `Caddyfile` and an `nginx/` directory exist. Only Caddy is used in `docker-compose.prod.yml`. The Nginx config is dead.
**Fix:** Remove `deploy/nginx/` and any associated documentation.

---

## 6. Repo Structure

### 6.1 Backend at repo root — no clean separation `MEDIUM`
**Issue:** Backend source (`src/`, `alembic/`, `config/`, `scripts/`, `tests/`) lives at the same level as `frontend/`. This makes it hard to set different CI paths, Docker build contexts, and lint configs per layer.
**Status:** ✅ Resolved in this commit — backend moved to `backend/`. See directory tree below.

```
credit-card-scraper/
├── backend/
│   ├── ccs_platform/      ← package source (was src/ccs_platform/)
│   ├── alembic/
│   ├── config/
│   ├── scripts/
│   ├── tests/
│   ├── requirements.txt
│   ├── requirements-dev.txt
│   ├── pyproject.toml
│   └── alembic.ini
├── frontend/
├── deploy/
├── docs/
├── CLAUDE.md
├── PRODUCTION.md
├── ROADMAP.md
└── README.md
```

---

## Suggested Sprint Ordering

| Sprint | Items |
|--------|-------|
| **S1 (Security)** | 1.1, 1.2, 1.3, 1.4, 1.5, 4.5 |
| **S2 (Reliability)** | 2.1 (extract handlers), 3.1 (bare excepts), 3.8 (N+1), 3.9 (heartbeat), 5.1, 5.2 |
| **S3 (Testing)** | 4.1 (frontend tests), 3.6 (conftest), 5.3 (CI npm test) |
| **S4 (Architecture)** | 2.2 (repo layer), 2.3 (base adapter), 2.4 (MONTH_INDEX), 2.5 (RRULE) |
| **S5 (Code quality)** | 3.2, 3.3, 3.4, 3.5, 3.7, 4.2, 4.3, 4.4, 4.6, 4.7, 4.8, 4.9 |
| **S6 (Polish)** | 5.4, 5.5 |
