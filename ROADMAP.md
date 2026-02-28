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
**File:** `src/ccs_platform/auth/service.py`
**Issue:** Password `"Apple123!"` is hardcoded as a fallback credential. If the env var is missing the application starts with a known password. The same credential appears in plaintext in `README.md`.
**Fix:** Raise a `RuntimeError` at startup when `CCS_PLATFORM_AUTH_PASSWORD` is absent in production. Remove the hardcoded value entirely.

### 1.2 `get_db` doesn't rollback on exception `CRITICAL`
**File:** `src/ccs_platform/db/session.py` (FastAPI dependency)
**Issue:** The `get_db` generator yields a session and closes it in `finally`, but does not call `session.rollback()` when an exception propagates. Partial writes can be flushed and committed if an outer context commits before the exception surfaces, risking data corruption.
**Fix:** Add `except: session.rollback(); raise` between the `yield` and the `finally` block.

### 1.3 Weak default `session_secret_key` `CRITICAL`
**File:** `src/ccs_platform/config/settings.py`
**Issue:** `session_secret_key` defaults to `"change-this-in-production"`. Nothing prevents the app from running in production with this value.
**Fix:** In `model_post_init`, detect `environment == "production"` and raise if the key equals the default or is shorter than 32 bytes.

### 1.4 Thread-unsafe `os.environ` mutation `HIGH`
**File:** `src/ccs_platform/application/jobs/runner.py`
**Issue:** The `JobRunner` worker thread writes scraper credentials into `os.environ` (`os.environ["..."] = ...`) before launching Playwright. Under concurrent job execution (multiple worker threads or `asyncio.to_thread` calls), two threads can interleave their writes into the shared process environment, causing one job to use another profile's credentials.
**Fix:** Pass credentials as explicit constructor/function arguments to the browser adapters instead of via `os.environ`.

### 1.5 PDF upload endpoint bypasses runtime settings `HIGH`
**File:** `src/ccs_platform/api/v1/upload.py`
**Issue:** The upload endpoint reads bank-specific parser configuration directly from `os.environ` instead of the `runtime_settings` table. If credentials/configs have been updated through the admin UI they won't be reflected.
**Fix:** Load parser config from the `RuntimeSettingsRepository` the same way the job runner does.

---

## 2. Architecture

### 2.1 `JobRunner` God class `HIGH`
**File:** `src/ccs_platform/application/jobs/runner.py` (~1,064 lines)
**Issue:** A single class owns job dispatch, cancellation, heartbeat, retry logic, schedule polling, and the concrete implementation of every job type (scrape, upload, reclassify, export, diagnostics, bank connection test). Changes to any job type require editing the same file, and the class is untestable in isolation.
**Fix:** Extract each job type into its own module under `application/jobs/handlers/`. `JobRunner` becomes a thin dispatcher that delegates to handlers. Each handler can be unit-tested independently.

### 2.2 No repository layer `HIGH`
**Issue:** SQLAlchemy queries are scattered across route handlers, service functions, and domain utilities — no consistent abstraction over data access.
**Fix:** Introduce a repository per aggregate root (`StatementRepository`, `JobRepository`, `CategoryRepository`, etc.). Routes interact with repositories, not with `Session` directly.

### 2.3 Bank adapters lack a shared base class `MEDIUM`
**Files:** `src/ccs_platform/adapters/banks/adcb.py` (1,563 lines), `src/ccs_platform/adapters/banks/enbd.py` (1,399 lines), and others.
**Issue:** Each bank adapter re-implements the same lifecycle (launch browser, navigate, handle OTP, download, close). No shared contract makes it hard to add a new bank or write adapter-level tests.
**Fix:** Define a `BaseBankAdapter` abstract class with lifecycle hooks. Move shared Playwright setup/teardown there.

### 2.4 `MONTH_INDEX` dict duplicated across 5 files `MEDIUM`
**Files:** Multiple bank adapter files.
**Issue:** The same month-name → month-number dictionary is copy-pasted. Any discrepancy causes silent parsing errors.
**Fix:** Define once in `domain/parsing/month_utils.py` and import everywhere.

### 2.5 Custom RRULE parser only handles HOURLY/WEEKLY `MEDIUM`
**File:** `src/ccs_platform/application/schedules/rrule_parser.py`
**Issue:** A bespoke RRULE parser supports only two frequencies. Users who configure DAILY or MONTHLY schedules will get silent failures or wrong next-run times.
**Fix:** Replace with `python-dateutil` (`dateutil.rrule`), which covers the full RFC 5545 subset.

---

## 3. Code Quality

### 3.1 223 bare `except Exception` clauses `HIGH`
**Pattern:** `except Exception:  # noqa: BLE001` throughout the codebase.
**Issue:** Swallowing broad exceptions hides bugs. The `# noqa` suppresses the linter warning instead of fixing the root cause.
**Fix:** Replace with specific exception types. Where a catch-all is genuinely needed (top-level job runner loop), log the traceback and re-raise or set the job to `FAILED`.

### 3.2 Hardcoded profile key `"hussain"` `HIGH`
**Files:** 3 backend files.
**Issue:** Profile routing logic falls back to a specific user's profile key. This is a personal assumption baked into business logic.
**Fix:** Remove the hardcoded fallback. Require the profile key to be explicitly provided by the caller.

### 3.3 Dead database columns `MEDIUM`
- `CategoryRule.priority` — queried nowhere.
- `bank_code` and `card_last4` on a secondary table — not surfaced in any API or report.
**Fix:** Add Alembic migrations to drop these columns, reducing schema noise.

### 3.4 `EXPECTED_SAMPLE_COUNTS` in production code `MEDIUM`
**File:** `src/ccs_platform/adapters/banks/` (one or more files)
**Issue:** A constant named `EXPECTED_SAMPLE_COUNTS` lives in production source code. This is test/QA data that belongs in the test suite.
**Fix:** Move to `tests/fixtures/` or a bank-specific test file.

### 3.5 `requirements.txt` duplicates `pyproject.toml` `MEDIUM`
**Issue:** The project maintains both `requirements.txt` (pinned) and `pyproject.toml` (version-ranged). They can drift, creating `pip install` discrepancies between dev and CI.
**Fix:** Generate `requirements.txt` from `pyproject.toml` via `pip-compile` (pip-tools) and check the lock file in. Remove hand-maintained duplication.

### 3.6 No `conftest.py` — fixtures recreated manually `MEDIUM`
**File:** `tests/`
**Issue:** Each test file manually sets up database sessions, settings, and test data. Shared setup belongs in `conftest.py` fixtures.
**Fix:** Create `tests/conftest.py` with shared `db_session`, `settings`, and sample-data fixtures.

### 3.7 `_UTCAwareDateTime` not used `MEDIUM`
**Issue:** `CLAUDE.md` rule 8 mandates `_UTCAwareDateTime` for all datetime columns. The TypeDecorator exists in `db/models.py` but is not applied to the model fields.
**Fix:** Audit all `datetime` columns and apply `_TSTZ()` (or equivalent), then generate the corresponding Alembic migration with `DateTime(timezone=True)`.

### 3.8 N+1 query in `reclassify_statement_lines` `MEDIUM`
**File:** `src/ccs_platform/application/jobs/handlers/` (or equivalent service)
**Issue:** The function fetches active category rules once per statement line in a loop rather than once per batch.
**Fix:** Fetch all active rules once before the loop and apply them in memory.

### 3.9 Heartbeat thread dies silently `MEDIUM`
**File:** `src/ccs_platform/application/jobs/runner.py`
**Issue:** If the heartbeat thread raises an unhandled exception it terminates silently. Jobs then appear "stuck" until the 30-minute `JOB_HEARTBEAT_TIMEOUT_SECONDS` window expires.
**Fix:** Wrap the heartbeat loop body in `try/except`, log the error, and restart the thread (or surface the failure to a monitoring endpoint).

---

## 4. Frontend

### 4.1 Zero tests, no test framework configured `HIGH`
**Issue:** Violates `CLAUDE.md` rule 11. The `frontend/` directory has no test runner configured (`vitest`, `jest`, or equivalent). There are no test files.
**Fix:**
1. Add `vitest` + `@testing-library/react` as dev dependencies.
2. Configure `vite.config.ts` with a `test` block.
3. Write tests for pure utilities: `formatAmount`, `useDebouncedValue`, `isAbortError`, date helpers.

### 4.2 No ESLint / Prettier `MEDIUM`
**Issue:** No linting or formatting enforced. Code style is inconsistent and type-safety gaps go undetected at save time.
**Fix:** Add `eslint`, `@typescript-eslint/eslint-plugin`, `eslint-plugin-react-hooks`, and `prettier`. Add `lint` and `format` npm scripts. Run `eslint --max-warnings 0` in CI.

### 4.3 Utility duplication `MEDIUM`
- `useDebouncedValue` — defined in 3 files.
- `formatAmount` — defined in 2 files.
- `isAbortError` — defined in 2 files.
**Fix:** Consolidate each into `src/lib/` (`useDebounce.ts`, `format.ts`, `errors.ts`) and update all imports.

### 4.4 Pervasive `any` typing `MEDIUM`
**Issue:** The TypeScript type system is effectively bypassed across much of the frontend. Runtime type errors surface only in the UI.
**Fix:** Enable `"strict": true` in `tsconfig.json`. Resolve `any` usages incrementally, starting with API response types.

### 4.5 Personal email hardcoded in `LoginPage.tsx` `HIGH`
**File:** `frontend/src/pages/LoginPage.tsx`
**Issue:** `h_abbasi97@hotmail.com` is hardcoded as a placeholder/default in a UI component. This leaks PII and breaks multi-tenant deployments.
**Fix:** Remove the hardcoded email. Use an empty placeholder string.

### 4.6 `TablePagination` missing `2000` option `MEDIUM`
**Issue:** Violates `CLAUDE.md` rule 12. The pagination component is missing the 2000/page option.
**Fix:** Add `2000` to `pageSizeOptions` in the shared `Pagination` component.

### 4.7 `LoginResponse` type defined twice `LOW`
**Issue:** Two files define `LoginResponse` with slightly different shapes. The duplicate creates a risk of divergence.
**Fix:** Define once in `src/types/auth.ts` and import everywhere.

### 4.8 `ExportsDiagnosticsPage` hardcodes bank list `MEDIUM`
**File:** `frontend/src/pages/ExportsDiagnosticsPage.tsx`
**Issue:** The bank list is hardcoded in JSX instead of fetched from `GET /api/v1/banks`. Adding a new bank requires a frontend code change.
**Fix:** Fetch from the API on mount. Display a loading state while fetching.

### 4.9 `DashboardPage` is 427 lines `MEDIUM`
**File:** `frontend/src/pages/DashboardPage.tsx`
**Issue:** One component handles data fetching, charting, date-range logic, and layout. It violates single-responsibility and is hard to test or reuse.
**Fix:** Extract: `useDashboardData` hook (data fetching), `<DashboardFilters>` component, `<DashboardCharts>` component.

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
**Issue:** The CI pipeline has no step to run frontend tests (because none exist yet). After fixing 4.1, add a CI step to run `npm test -- --run` in `frontend/`.

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
