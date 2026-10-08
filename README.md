# Ledger

A personal credit-card ledger for FAB, ADCB, ENBD, EIB, SIB and Mashreq cards:

- **Real time from bank SMS.** An iPhone Shortcuts automation hands each alert to the Ledger
  app's App Intent.
- **Reconciled against statements.** Statement PDFs come from the scraper, uploads, Gmail and
  Outlook.
- **Evidence-based.** Each transaction is linked to its SMS and statement lines, so nothing is
  double-counted or lost on re-ingest.
- **Dynamic categorisation.** Manual > merchant > rule > LLM, recomputed automatically.
- **Server-side analytics.** Rendered by a React web app and a SwiftUI iPhone app.

Docs:
- [ARCHITECTURE.md](ARCHITECTURE.md): design, data model, matching, auth
- [PRODUCTION.md](PRODUCTION.md): deployment and cutover runbook
- [CHANGELOG.md](CHANGELOG.md)
- [ROADMAP.md](ROADMAP.md)
- [docs/contracts/parse-v1.md](docs/contracts/parse-v1.md): parser contract (limits, output validation, error codes)
- [docs/audit/](docs/audit/): pre-cutover audit reports (01 database … 06 cross-cutting) and
  [BACKLOG.md](docs/audit/BACKLOG.md), the list of findings not yet fixed
- [CLAUDE.md](CLAUDE.md): coding rules

## Repository structure

| Path | What | Stack |
|---|---|---|
| `supabase/` | `config.toml`, `migrations/` (schema + all business logic), `functions/` (Edge Functions), `tests/` (pgTAP), `seed.sql` (local demo data) | Postgres 17, Deno 2 |
| `services/parser/` | Stateless statement parser `POST /parse` for Cloud Run ([README](services/parser/README.md)) | Python 3.12, FastAPI, pdfplumber |
| `apps/web/` | Web app | Vite, React 19, TanStack Router/Query, supabase-js, Tailwind v4, Recharts |
| `apps/ios/` | iPhone app, `LedgerKit` package, share extension ([README](apps/ios/README.md)) | SwiftUI, iOS 18, XcodeGen |
| `packages/tokens/` | Design tokens → CSS variables, chart palette, `Tokens.swift` | Node |
| `packages/db-types/` | Generated Supabase TypeScript types (never hand-written) | TS |
| `scraper/` | Local Playwright scraper CLI `ccs-scraper` ([README](scraper/README.md)) | Python 3.12 |
| `scripts/` | `migrate_legacy.py` (cutover data move), `cutover/` (production Edge and Vault secret helpers), git `hooks/` + `install-hooks.sh` | Python, sh, SQL |
| `docs/` | `contracts/` (parse-v1), `audit/` (audit reports + backlog), legacy `operations/` and `security/` notes | Markdown |
| `.github/workflows/` | CI (path-filtered) and manual deploy workflows | GitHub Actions |
| `backend/`, `frontend/`, `deploy/` | **Legacy v1**, frozen until cutover (see below) | FastAPI, React 18 |

## Prerequisites

| Tool | Version | Used for |
|---|---|---|
| Docker Desktop | recent | local Supabase stack |
| Supabase CLI | ≥ 2.100 | `supabase start / db reset / test db / functions serve / gen types` |
| Node + pnpm | Node ≥ 20, pnpm 10 (`corepack enable`) | web app, tokens, workspace scripts |
| Deno | 2.x | Edge Function tests |
| Python + uv | 3.12, [uv](https://docs.astral.sh/uv/) | parser, scraper, cutover script |
| Xcode + XcodeGen | Xcode with the iOS 18+ SDK, `brew install xcodegen` | iPhone app, `swift test` |

## Local setup

### 1. Database and demo data

```bash
pnpm install                      # workspace deps (apps/web, packages/*)
supabase start                    # Postgres, Auth, Storage, Realtime, Edge runtime, Studio
supabase db reset                 # applies supabase/migrations + supabase/seed.sql
supabase status -o json           # API_URL, ANON_KEY, SERVICE_ROLE_KEY
```

Local ports:

| Service | Address |
|---|---|
| API / Edge Functions | `http://127.0.0.1:54321` |
| Postgres | `127.0.0.1:54322` (`postgres`/`postgres`) |
| Studio | `http://127.0.0.1:54323` |
| Inbucket (auth emails) | `http://127.0.0.1:54324` |

The seed creates synthetic ledgers with statements, SMS, reviews, budgets, recurring charges and
insights:

| User | Password | Access |
|---|---|---|
| `demo@ledger.local` | `ledger-demo-pass` | Owner of "Demo ledger" and "Household" |
| `viewer@ledger.local` | `ledger-demo-pass` | Viewer of "Demo ledger" |

Self sign-up is off (`[auth] enable_signup = false`), as in production. To add a local user,
add the email as a member in web Settings → Members (a pending invite), then create the user
from Studio → Authentication → Invite user (the invite email lands in Inbucket).

pg_cron reaches Edge Functions through two Vault secrets, which you set once after every
`db reset`. Without them, cron calls are skipped with a notice. The secret must match
`CRON_SECRET` in `supabase/functions/.env`:

```bash
psql postgresql://postgres:postgres@127.0.0.1:54322/postgres <<'SQL'
select vault.create_secret('http://host.docker.internal:54321', 'project_url');
select vault.create_secret('<same value as CRON_SECRET>', 'edge_cron_secret');
SQL
```

### 2. Parser (needed for statement uploads to parse)

```bash
cd services/parser
uv venv --python 3.12 .venv
uv pip sync --python .venv/bin/python requirements.txt
uv pip install --python .venv/bin/python --no-deps -e .
uv pip install --python .venv/bin/python pytest ruff
cp .env.example .env              # set PARSER_SECRET; for local dev also:
#   PARSER_ALLOW_HTTP=true        (local Storage URLs are plain http)
#   PARSER_ALLOWED_HOSTS=127.0.0.1
set -a && source .env && set +a
.venv/bin/uvicorn ccs_parser.app:app --host 127.0.0.1 --port 8080
curl -s http://127.0.0.1:8080/health
```

Docker Desktop forwards `host.docker.internal` to the Mac's loopback. On Linux, run uvicorn with
`--host 0.0.0.0`.

### 3. Edge Functions

Create `supabase/functions/.env` (gitignored):

```dotenv
CRON_SECRET=<random string, same as the edge_cron_secret Vault value>
PARSER_URL=http://host.docker.internal:8080
PARSER_SECRET=<same as services/parser/.env>
# The worker signs Storage URLs with SUPABASE_URL (http://kong:8000 inside Docker).
# This rewrites their origin so the parser on the host can fetch them.
PARSER_DOCUMENT_BASE_URL=http://127.0.0.1:54321
SENTRY_DSN=
SENTRY_ENVIRONMENT=local          # local/development/test never report, even with a DSN
# Optional: ANTHROPIC_API_KEY=… enables LLM categorisation and the SMS fallback
```

```bash
supabase functions serve --env-file supabase/functions/.env
# Upload a statement as the demo user (or with a ccs_ service token + X-Profile-Key):
curl -s -X POST http://127.0.0.1:54321/functions/v1/statements-upload \
  -H "Authorization: Bearer $USER_JWT" -F profile_code=prf_… -F files=@statement.pdf
```

The worker runs every minute through pg_cron once the Vault secrets are set. To run it by hand:

```bash
curl -s -X POST http://127.0.0.1:54321/functions/v1/worker \
  -H "x-cron-secret: $CRON_SECRET" -d '{"sync":true}'
```

### 4. Web app

```bash
cp apps/web/.env.example apps/web/.env.local   # VITE_SUPABASE_ANON_KEY from `supabase status`
pnpm web:dev                                   # http://127.0.0.1:5173
```

Sign in with the demo password, or request an email code and read it in Inbucket.

### 5. iPhone app

```bash
cp apps/ios/Config/Secrets.example.xcconfig apps/ios/Config/Secrets.xcconfig   # paste ANON_KEY
cd apps/ios && xcodegen generate && open Ledger.xcodeproj
```

Simulator builds can sign in as the demo user through `SIMCTL_CHILD_LEDGER_DEV_EMAIL` and
`SIMCTL_CHILD_LEDGER_DEV_PASSWORD`. SMS capture needs a real device; see
[apps/ios/README.md](apps/ios/README.md).

### 6. Scraper

```bash
cd scraper && uv venv --python 3.12 .venv && uv pip install --python .venv/bin/python -e ".[dev]"
.venv/bin/ccs-scraper install-browser
cp .env.example .env    # v2: CCS_SCRAPER_TARGET_URL=<SUPABASE_URL>,
                        #     CCS_SCRAPER_UPLOAD_PATH=/functions/v1/statements-upload,
                        #     HUSSAIN_CCS_SCRAPER_API_TOKEN=ccs_… (one per profile, scope statements:upload)
.venv/bin/ccs-scraper scrape --profile hussain --months 2026-09
.venv/bin/ccs-scraper upload-pending --profile hussain   # re-send recorded PDFs (server dedups)
```

Create a service token in web Settings → Sources & health → Tokens, or with
`select create_service_token('<prf_…>', 'scraper', array['statements:upload'])`.

## Tests

| Component | Command |
|---|---|
| Database (pgTAP: RLS guards, matching, categorisation, recon, analytics, SMS templates, FX, legacy import, cross-profile isolation, ingest robustness, review actions; hermetic, so they also pass on a non-empty local DB) | `supabase db reset && supabase test db` |
| DB types drift | `pnpm db:types:check` (regenerate with `pnpm db:types`) |
| Edge Functions | `cd supabase/functions && deno test -A .` (the local e2e runs only with `LEDGER_E2E=1` and a served stack) |
| Parser | `cd services/parser && .venv/bin/ruff check . && .venv/bin/pytest -q` (golden parity needs private PDFs; skipped otherwise) |
| Web | `pnpm web:test`, `pnpm --filter @ledger/web lint`, `pnpm web:build` |
| Tokens | `pnpm --filter @ledger/tokens check` (fails if the committed `Tokens.swift` drifts from `tokens.json`; the gitignored `dist/` is regenerated in memory only, so it works from a clean clone) |
| iOS | `cd apps/ios/LedgerKit && swift test` |
| Scraper | `cd scraper && .venv/bin/pytest -q` |
| Cutover script | `backend/.venv/bin/python -m pytest -q scripts/tests` |

`scripts/install-hooks.sh` installs the git hooks:
- **pre-commit:** web lint and tests when `apps/web` files are staged, scraper tests when
  `scraper/` is staged, and legacy backend syntax/bandit checks while `backend/` exists.
- **pre-push:** `deno test`, parser ruff and pytest, tokens check, web lint and tests, DB types
  drift (only when the local stack is running), scraper tests, plus the legacy suites while
  `backend/` and `frontend/` exist. Each check skips when its directory or tool is missing.
- **prepare-commit-msg / commit-msg:** enforce the commit author and reject `Co-Authored-By`
  trailers.

## Environment variables

### Web (`apps/web/.env.local`; Vercel project env)

| Variable | Purpose |
|---|---|
| `VITE_SUPABASE_URL` | Supabase API URL (`http://127.0.0.1:54321` locally) |
| `VITE_SUPABASE_ANON_KEY` | Anon/publishable key |
| `VITE_SENTRY_DSN` | Sentry `ledger-apps` DSN (empty disables Sentry) |
| `VITE_SENTRY_ENVIRONMENT` | `local` / `preview` / `production`. Empty, `local`, `development`, `test` or `vite dev` never report, even with a DSN |
| `VITE_SENTRY_RELEASE` | Release name (defaults to `VERCEL_GIT_COMMIT_SHA` for source maps) |
| `SENTRY_AUTH_TOKEN`, `SENTRY_ORG`, `SENTRY_PROJECT` | Build-time only: uploads source maps when the token is set. `SENTRY_PROJECT` defaults to `ledger-apps`. |

### Edge Functions (`supabase/functions/.env` locally; production: `supabase/functions/.env.production` pushed with `scripts/cutover/set-edge-secrets.sh`)

`SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY` are injected by Supabase.

| Variable | Used by | Default | Purpose |
|---|---|---|---|
| `CRON_SECRET` | worker, gmail-watch-renew, outlook-poll, ops-monitor, fx-rates | required | Must equal Vault `edge_cron_secret` (`x-cron-secret` header) |
| `PARSER_URL` | worker | required | Cloud Run parser base URL |
| `PARSER_SECRET` | worker | required | Sent as `X-Parser-Secret` |
| `PARSER_DOCUMENT_BASE_URL` | worker | — | Rewrites the signed Storage URL origin (local only) |
| `PARSER_TIMEOUT_MS` | worker | `75000` | Parser call timeout. Keep above the parser's 60 s kill and below Cloud Run's 120 s timeout |
| `WORKER_BUDGET_MS` | worker | `50000` | Stop starting new rounds after this long |
| `EDGE_WALL_CLOCK_MS` | worker | `150000` | Edge Function wall clock (free plan; 400000 on paid). A round starts only if it can finish before it (parse: `PARSER_TIMEOUT_MS` + 20 s; LLM: 65 s) |
| `ANTHROPIC_API_KEY` | worker | — | Enables LLM categorisation and the SMS fallback (queues wait while unset) |
| `LLM_MODEL` | worker | `claude-haiku-5-5` | Claude model id |
| `GMAIL_PUSH_AUDIENCE` | gmail-push | required | Expected OIDC audience of Pub/Sub push tokens |
| `GMAIL_PUSH_SA_EMAIL` | gmail-push | required | Service account the push token must be issued to |
| `GMAIL_PUBSUB_TOPIC` | gmail-watch-renew | required | `projects/<p>/topics/<t>` |
| `GMAIL_OAUTH_CLIENT_ID`, `GMAIL_OAUTH_CLIENT_SECRET` | gmail-* | required for Gmail | Google OAuth client (refresh tokens live in Vault) |
| `MS_OAUTH_CLIENT_ID`, `MS_OAUTH_CLIENT_SECRET` | outlook-poll | required for Outlook | Azure app credentials |
| `MS_OAUTH_TENANT` | outlook-poll | `consumers` | Azure tenant |
| `OUTLOOK_LOOKBACK_DAYS` | outlook-poll | `90` | First delta window |
| `OUTLOOK_BUDGET_MS` | outlook-poll | `100000` | Time budget per run (resumes next run) |
| `OPS_SMS_UNPARSED_THRESHOLD` | ops-monitor | `5` | Unparsed SMS per 24 h before an issue |
| `OPS_OPEN_REVIEWS_THRESHOLD` | ops-monitor | `50` | Open reviews before an issue |
| `ALLOWED_ORIGINS` | all (CORS) | any | Comma-separated allowed origins |
| `SENTRY_DSN` | all | — | Sentry `ledger-backend` DSN (empty disables Sentry) |
| `SENTRY_ENVIRONMENT`, `SENTRY_RELEASE` | all | `local`, — | Sentry environment and release. Unset, `local`, `development` and `test` disable Sentry even with a DSN; production sets `production` |
| `SENTRY_TRACES_SAMPLE_RATE` | all | `0.1` | Trace sampling |

### Parser (`services/parser/.env`; Cloud Run)

| Variable | Default | Purpose |
|---|---|---|
| `PARSER_SECRET` | required | Shared secret expected in `X-Parser-Secret` (fails closed) |
| `PARSER_ALLOWED_HOSTS` | any | Allowed `document_url` hostnames, e.g. `<ref>.supabase.co` (`127.0.0.1` locally) |
| `PARSER_ALLOW_HTTP` | `false` | Allow `http://` document URLs (local only) |
| `PARSER_MAX_DOWNLOAD_MB` | `25` | Max download size |
| `PARSER_MAX_PDF_MB`, `PARSER_MAX_PAGES`, `PARSER_MAX_INFLATE_MB` | `15`, `30`, `32` | Rejected before extraction / while inflating: `PDF_TOO_LARGE` |
| `PARSER_CPU_LIMIT_SECONDS`, `PARSER_PARSE_TIMEOUT_SECONDS`, `PARSER_MEMORY_LIMIT_MB` | `30`, `60`, `768` | Per-parse child process limits: `PARSE_TIMEOUT` / `PDF_TOO_LARGE` (memory cap Linux only) |
| `PARSER_ISOLATION` | `process` | `inline` parses in-process (tests and debugging only; CPU, wall and memory limits off) |
| `SENTRY_DSN`, `SENTRY_ENVIRONMENT`, `SENTRY_RELEASE`, `SENTRY_TRACES_SAMPLE_RATE` | —, `local`, —, `0.2` | Sentry `ledger-backend`. Unset, `local`, `development` and `test` never report; `production` also disables `/debug-sentry` and the OpenAPI docs |
| `LOG_LEVEL`, `PORT` | `INFO`, `8080` | Logging and listen port (Cloud Run sets `PORT`) |

### iOS (`apps/ios/Config/Secrets.xcconfig`; `Secrets.Release.xcconfig` for TestFlight; both gitignored)

| Key | Purpose |
|---|---|
| `LEDGER_SUPABASE_URL` | `http:/$()/127.0.0.1:54321` locally, `https:/$()/<ref>.supabase.co` in release |
| `LEDGER_SUPABASE_ANON_KEY` | Anon/publishable key |
| `LEDGER_SENTRY_DSN` | Sentry `ledger-apps` DSN (empty disables Sentry) |
| `LEDGER_ENVIRONMENT` | `local` / `production`. Sentry starts only in Release builds with an environment other than local/development/dev/test |

`apps/ios/scripts/publish-build.sh` also reads these:
- `SENTRY_AUTH_TOKEN`, `SENTRY_ORG` and `SENTRY_PROJECT` (set `ledger-apps`) for dSYM upload,
  from the environment or else `Secrets.Release.xcconfig`; the token is never printed
- `ASC_KEY_ID` and `ASC_ISSUER_ID` (with the AuthKey `.p8`) for the TestFlight upload

### Scraper (`scraper/.env`)

| Variable | Default | Purpose |
|---|---|---|
| `CCS_SCRAPER_TARGET_URL` | `http://127.0.0.1:8040` | Upload base URL. For v2, the Supabase URL. |
| `CCS_SCRAPER_UPLOAD_PATH` | `/api/v1/jobs/upload` | For v2: `/functions/v1/statements-upload` |
| `{PROFILE}_CCS_SCRAPER_API_TOKEN` | — | Per-profile service token (v2 tokens are profile-scoped; scope `statements:upload`). Wins over the global token |
| `CCS_SCRAPER_API_TOKEN` | — | Global fallback token for profiles without their own (legacy) |
| `CCS_SCRAPER_SUPABASE_ANON_KEY` | — | Optional, sent as `apikey` |
| `CCS_SCRAPER_UPLOAD_MAX_FILES`, `CCS_SCRAPER_UPLOAD_MAX_MB` | `20`, `32` | Upload batching: files and MB of PDF per request, clamped to the server's limits (20 files, 40 MB). A 413 halves the batch; batches that succeeded are recorded, so `upload-pending` retries only the rest |
| `CCS_SCRAPER_HEADLESS`, `CCS_SCRAPER_DOWNLOAD_DIR`, `CCS_SCRAPER_BROWSER_*` | `true`, `./downloads`, Dubai | Browser settings |
| `{PROFILE}_{BANK}_*` | — | Bank portal credentials per profile (see `scraper/.env.example`) |

### Cutover script (`scripts/migrate_legacy.py`)

`--target local|prod` is required and checked against the environment: `local` needs
`LEDGER_DB_URL` / `SUPABASE_URL` on 127.0.0.1, `prod` needs both to name
`nkmylznisjcnmqbxosey`. Every step is a dry run unless `--apply`; `--apply` against prod also
needs `--yes-i-mean-prod nkmylznisjcnmqbxosey` (or the ref typed at the prompt). Tests:
`backend/.venv/bin/python -m pytest -q scripts/tests`.

`LEDGER_DB_URL`, `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `LEGACY_FERNET_KEY`,
`LEGACY_STORAGE` (`gcs`|`local`), `LEGACY_GCS_BUCKET`, `GOOGLE_APPLICATION_CREDENTIALS`,
`LEGACY_LOCAL_ROOT`. They live in the gitignored repo-root `.env.cutover`
(`set -a; source .env.cutover; set +a`). See [PRODUCTION.md → Cutover](PRODUCTION.md#10-cutover-runbook).

Production secret helpers (`scripts/cutover/`):
- `set-edge-secrets.sh [--dry-run] [--sentry-release SHA]`: validates
  `supabase/functions/.env.production` (no empty or `<placeholder>` values, required keys
  present, no local-only keys) and pushes exactly its keys with `supabase secrets set`. Prints
  key names only.
- `set-vault-secrets.sql`: psql template for Vault `project_url` and `edge_cron_secret`
  (`-v project_url=… -v edge_cron_secret="$CRON_SECRET"`); no values are committed.

## Screens

**Web** (`apps/web/src/routes`)

| Route | Screen |
|---|---|
| `/signin`, `/welcome` | Sign-in (email code, magic link or password; existing users only) and first-profile setup |
| `/` | **Overview**: month hero with pace rule, live pending SMS, category ring, cards and dues, utilisation, insights |
| `/activity` | **Activity**: unified ledger with URL-synced filters, evidence badges, drawer with evidence timeline, inline, bulk and "apply to merchant" categorisation, notes |
| `/insights` | **Insights**: trends, categories, merchants, subscriptions, FX, calendar heatmap, time of day, YoY, anomalies |
| `/budgets` | **Budgets**: total and per category, with progress |
| `/cards` | **Cards & Statements**: accounts, cards, statements with recon status, upload, documents |
| `/review` | **Review inbox**: match reviews, unknown cards, unparsed SMS ("not a card transaction") and LLM template proposals. On mobile it is a bottom tab with a count |
| `/rules` | **Rules**: categories, merchants, rules with live impact preview |
| `/settings` | **Settings**: ledger, members (and invites), sources and health (queues, DLQ, mailboxes, tokens, PDF passwords), SMS setup guide |

**iPhone** (`apps/ios/Ledger`)

| Screen | Contents |
|---|---|
| Sign in / Profile picker | Email one-time code (Sign in with Apple stubbed), choose a ledger |
| Overview | Month spend posted so far (server comparisons), pending SMS, categories, dues ("Was due …"), Needs attention (reviews, uncategorised) (Realtime refresh) |
| Activity | Ledger list, filters, transaction detail and categorisation |
| Insights | Swift Charts views over the same RPCs |
| Statements | Statements, recon, PDF upload (document picker) |
| Review | Open match reviews: link, keep as new, dismiss, register an unknown card (read-only for viewers) |
| Settings | "SMS go to" ledger, SMS capture guide (one "Card" automation, Last captured, Send test), "Not sent" outbox list (Retry / Delete), profile |
| **Log Bank SMS** (App Intent) | Called by the Shortcuts automation, with no UI |
| **Add to Ledger** (share extension) | Sends shared PDFs to `statements-upload` |

## API surface

### Edge Functions (`<SUPABASE_URL>/functions/v1/<name>`)

| Function | Method | Auth | Purpose |
|---|---|---|---|
| `statements-upload` | POST multipart (`files`, `bank_code_hint`, `profile_code`); ≤ 20 files and ≤ 40 MB per request | Service token `statements:upload` (+ `X-Profile-Key`) or user JWT (owner) | Store PDFs, dedup, queue parsing |
| `sms-ingest` | POST JSON `{profile_code?, messages[≤200]}` | User JWT or service token `sms:ingest` | Batch SMS ingest (idempotent on `client_msg_id`) |
| `gmail-push` | POST (Pub/Sub envelope) | Google OIDC token | Gmail notifications → documents |
| `worker`, `gmail-watch-renew`, `outlook-poll`, `ops-monitor`, `fx-rates` | POST | `x-cron-secret` | pg_cron-driven jobs |

### RPCs (`supabase.rpc(...)`, PostgREST)

| Group | RPCs (callable by signed-in members; owner-only marked *) |
|---|---|
| Profiles and members | `create_profile`, `add_profile_member`*, `list_profile_members`, `remove_profile_member`*, `cancel_profile_invite`* |
| Tokens and secrets | `create_service_token`*, `revoke_service_token`*, `set_profile_secret`*, `list_profile_secrets`, `set_mailbox_secret`* |
| Ingest and review | `ingest_sms`* (per-message statuses), `resolve_review`* (`link`, `create_new`, `dismiss`, `card`, `supersede`, `not_a_transaction`), `retry_sms_fallback`*, `requeue_documents`*, `set_sms_template_active`* |
| Categorisation | `set_transaction_category`*, `set_transactions_category`*, `preview_rule`, `merchant_search` |
| Analytics | `overview`, `spend_series`, `category_breakdown`, `merchant_leaderboard`, `daily_spend`, `hour_weekday_pattern`, `fx_spend`, `statement_cycles`, `yoy_compare`, `anomalies`, `filter_meta`, `budget_status`, `recurring_list` |
| Service-role only (Edge Functions) | `authenticate_service_token`, `ingest_parsed_document`, `fail_document`, `queue_read`, `queue_delete`, `queue_send`, `queue_to_dlq`, `worker_document_context`, `worker_llm_context`, `worker_sms_context`, `worker_mailbox_secret`, `apply_llm_suggestions`, `propose_sms_template`, `ops_health`, `upsert_fx_rates` |

Views: `v_spend` (the single spend definition) and `v_transactions` (the Activity read model).
Tables are readable by members under RLS. Owners edit categories, rules, budgets, accounts,
cards and transaction user fields directly.

## Legacy (until cutover)

`backend/` (FastAPI + embedded worker on Render, PDFs in GCS), `frontend/` (React admin on
Vercel), `deploy/` (Dockerfiles, Gmail relay on Cloud Run) and the `email-ingest-microsoft`
GitHub Actions cron are v1. They are **frozen**: don't extend them. Their tables are in `public`
of the same Supabase project until the cutover's first migration moves them into the `legacy`
schema. The legacy workflows run only while the repository variable `LEGACY_DEPLOYS_ENABLED`
is `true` (PRODUCTION.md §9). Setup notes stay in [`backend/README.md`](backend/README.md)
and `frontend/`; `docs/operations/` and `docs/security/` describe v1 operations. Everything
here is removed by the cutover in [PRODUCTION.md](PRODUCTION.md#10-cutover-runbook).
