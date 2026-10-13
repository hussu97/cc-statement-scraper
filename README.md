# Bank Ledger

A personal credit-card ledger for FAB, ADCB, ENBD, EIB, SIB, Mashreq and Wio cards:

- **Real time from bank SMS.** An iPhone Shortcuts automation hands each alert to the Bank Ledger
  app's App Intent.
- **Reconciled against statements.** Statement PDFs come from the scraper, uploads, Gmail and
  Outlook.
- **Evidence-based.** Each transaction is linked to its SMS and statement lines, so nothing is
  double-counted or lost on re-ingest.
- **Dynamic categorisation.** Manual > merchant > rule > LLM, recomputed automatically.
- **Server-side analytics.** Rendered by a React web app and a SwiftUI iPhone app.

Docs:
- [ARCHITECTURE.md](ARCHITECTURE.md): design, data model, matching, auth
- [PRODUCTION.md](PRODUCTION.md): deployment, operations and the cutover record
- [docs/ci-cd.md](docs/ci-cd.md): CI, deploy workflows, git hooks, release flows
- [CHANGELOG.md](CHANGELOG.md)
- [ROADMAP.md](ROADMAP.md)
- [docs/contracts/parse-v1.md](docs/contracts/parse-v1.md): parser contract (limits, output validation, error codes)
- [docs/audit/](docs/audit/): pre-cutover audit reports (01 database … 06 cross-cutting) and
  [BACKLOG.md](docs/audit/BACKLOG.md), the list of findings not yet fixed
- [CLAUDE.md](CLAUDE.md): coding and workflow rules (area detail in [supabase/CLAUDE.md](supabase/CLAUDE.md)
  and [apps/ios/CLAUDE.md](apps/ios/CLAUDE.md); [AGENTS.md](AGENTS.md) points other agents there)
- [tasks/lessons.md](tasks/lessons.md): lessons learned, read at the start of a session

## Repository structure

| Path | What | Stack |
|---|---|---|
| `supabase/` | `config.toml`, `migrations/` (schema + all business logic), `functions/` (Edge Functions), `tests/` (pgTAP), `seed.sql` (local demo data) | Postgres 17, Deno 2 |
| `services/parser/` | Stateless statement parser `POST /parse` for Cloud Run ([README](services/parser/README.md)) | Python 3.12, FastAPI, pdfplumber |
| `apps/web/` | Web app | Vite, React 19, TanStack Router/Query, supabase-js, Tailwind v4, Recharts |
| `apps/ios/` | iPhone app, `LedgerKit` package, share extension ([README](apps/ios/README.md)) | SwiftUI, iOS 18, XcodeGen |
| `packages/tokens/` | Design tokens → CSS variables, chart palette, `Tokens.swift` | Node |
| `assets/brand/` | Bank Ledger mark (`bank-ledger-mark.svg`); `pnpm brand:icons` renders the web favicons, PWA icons, `site.webmanifest` and `ios/AppIcon-1024.png` from it (`scripts/brand/generate-icons.mjs`, `--check` for drift) | Node (`@resvg/resvg-js`) |
| `packages/db-types/` | Generated Supabase TypeScript types (never hand-written) | TS |
| `scraper/` | Local Playwright scraper CLI `ccs-scraper` ([README](scraper/README.md)) | Python 3.12 |
| `scripts/` | `cutover/` (production Edge and Vault secret helpers), `ci/` (migration history check, web smoke test), git `hooks/` + `install-hooks.sh` | sh, SQL |
| `docs/` | `ci-cd.md`, `contracts/` (parse-v1), `audit/` (audit reports + backlog) | Markdown |
| `.github/workflows/` | `ci.yml` (path-filtered, `ci-ok` gate), `deploy-supabase`, `deploy-parser`, `web-smoke`, `ios-testflight`, `security` ([docs/ci-cd.md](docs/ci-cd.md)) | GitHub Actions |
| `.claude/` | Claude Code `settings.json` and `hooks/guard.py` (PreToolUse guard for staging, secrets and production actions; `python3 .claude/hooks/guard_test.py`) | Python |
| `tasks/` | `lessons.md`, `todo.md` (plans) | Markdown |

## Prerequisites

| Tool | Version | Used for |
|---|---|---|
| Docker Desktop | recent | local Supabase stack |
| Supabase CLI | ≥ 2.100 | `supabase start / db reset / test db / functions serve / gen types` |
| Node + pnpm | Node ≥ 20, pnpm 10 (`corepack enable`) | web app, tokens, workspace scripts |
| Deno | 2.x | Edge Function tests |
| Python + uv | 3.12, [uv](https://docs.astral.sh/uv/) | parser, scraper |
| Xcode + XcodeGen | Xcode with the iOS 18+ SDK, `brew install xcodegen` | iPhone app, `swift test` |

## Local setup

### 1. Database and demo data

```bash
pnpm install                      # workspace deps (apps/web, packages/*)
supabase start                    # Postgres, Auth, Storage, Realtime, Edge runtime, Studio
supabase db reset                 # applies supabase/migrations + supabase/seed.sql
supabase status -o json           # API_URL, PUBLISHABLE_KEY, SECRET_KEY (legacy ANON_KEY/SERVICE_ROLE_KEY too)
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

Create `supabase/functions/.env` (gitignored; `supabase/functions/.env.example` lists every key, names only):

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
cp apps/web/.env.example apps/web/.env.local   # VITE_SUPABASE_PUBLISHABLE_KEY = PUBLISHABLE_KEY from `supabase status`
pnpm web:dev                                   # http://127.0.0.1:5173
```

Request an email code for `demo@ledger.local` and read it in Inbucket
(http://127.0.0.1:54324). To try passkeys locally open http://localhost:5173 (the local RP ID is
`localhost`; browsers refuse an IP address as an RP ID).

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
                        #     ALICE_CCS_SCRAPER_API_TOKEN=ccs_… (one per profile, scope statements:upload)
.venv/bin/ccs-scraper scrape --profile alice --months 2026-09
.venv/bin/ccs-scraper upload-pending --profile alice   # re-send recorded PDFs (server dedups)
```

Create a service token in web Settings → Sources & health → Tokens, or with
`select create_service_token('<prf_…>', 'scraper', array['statements:upload'])`.

## Tests

| Component | Command |
|---|---|
| Database (pgTAP: RLS guards, matching, categorisation, recon, analytics, SMS templates, FX, legacy import, cross-profile isolation, ingest robustness, review actions, client privilege matrix, re-parse relink, the 2026-10-09 P2/P3 fixes (`13`–`19`); hermetic, so they also pass on a non-empty local DB) | `supabase db reset && supabase test db` |
| DB types drift | `pnpm db:types:check` (regenerate with `pnpm db:types`; both stable-sort each `Relationships` array so the output is deterministic, tested by `pnpm db:types:test`) |
| Edge Functions | `cd supabase/functions && deno lint && deno fmt --check && deno check . && deno test -A .` (the lock `deno.lock` is frozen; the local e2e runs only with `LEDGER_E2E=1` and a served stack) |
| Parser | `cd services/parser && .venv/bin/ruff check . && .venv/bin/pytest -q` (golden parity needs private PDFs; skipped otherwise) |
| Web | `pnpm web:test`, `pnpm --filter @ledger/web lint`, `pnpm web:build` |
| Tokens | `pnpm --filter @ledger/tokens check` (fails if the committed `Tokens.swift` drifts from `tokens.json`; the gitignored `dist/` is regenerated in memory only, so it works from a clean clone) |
| iOS | `cd apps/ios/LedgerKit && swift test`; app + share extension compile: `cd apps/ios && xcodegen generate && xcodebuild build -project Ledger.xcodeproj -scheme Ledger -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO` (no CI job: the pre-push hook runs both on the Mac) |
| Scraper | `cd scraper && .venv/bin/pytest -q` |

`bash scripts/install-hooks.sh` (or `pnpm hooks:install`) installs the git hooks; details in
[docs/ci-cd.md](docs/ci-cd.md) §3:
- **pre-commit (fast, staged files only):** secrets guard (`.env*`, `*.p8`, provisioning
  profiles), append-only migrations, eslint / `deno lint` / ruff / shellcheck / actionlint on
  the staged files.
- **pre-push (full CI mirror for the changed areas):** the same lint, typecheck, test and build
  steps as `ci.yml` (incl. `deno fmt --check` and `deno check`; pgTAP only when the local stack runs), then on a
  `main` push that changes the iOS app it builds and stages the TestFlight IPA.
  `SKIP_PRE_PUSH=1 git push` skips it; `SKIP_RELEASE=1 git push` skips only the iOS release.
  By hand: `pnpm check`, `pnpm check:all`, `pnpm check:plan`.
- **prepare-commit-msg / commit-msg:** enforce the commit author and reject `Co-Authored-By`
  trailers.

CI (`ci.yml`) runs the same checks per changed area; its `ci-ok` job is the single required
check. Deploys: `deploy-supabase.yml`, `deploy-parser.yml` (push to `main` + `production`
approval), Vercel's Git integration + `web-smoke.yml`, and `ios-testflight.yml`.

## Environment variables

### Web (`apps/web/.env.local`; Vercel project env)

| Variable | Purpose |
|---|---|
| `VITE_SUPABASE_URL` | Supabase API URL (`http://127.0.0.1:54321` locally) |
| `VITE_SUPABASE_PUBLISHABLE_KEY` | Publishable key (`sb_publishable_…`). Never a secret key: an `sb_secret_…` value is ignored and the app shows the setup error |
| `VITE_SENTRY_DSN` | Sentry `credit-card-ledger-apps` DSN (empty disables Sentry) |
| `VITE_SENTRY_ENVIRONMENT` | `local` / `preview` / `production`. Empty, `local`, `development`, `test` or `vite dev` never report, even with a DSN |
| `VITE_SENTRY_RELEASE` | Release name (defaults to `VERCEL_GIT_COMMIT_SHA` for source maps) |
| `VITE_TESTFLIGHT_URL` | Optional public TestFlight link (`https://testflight.apple.com/join/…`). Shows *Get the Bank Ledger app (TestFlight)* in Settings → iPhone SMS; hidden when unset or not a TestFlight URL |
| `SENTRY_AUTH_TOKEN`, `SENTRY_ORG`, `SENTRY_PROJECT` | Build-time only: uploads source maps when the token is set. `SENTRY_PROJECT` defaults to `credit-card-ledger-apps`. |

### Edge Functions (`supabase/functions/.env` locally; production: `supabase/functions/.env.production` pushed with `scripts/cutover/set-edge-secrets.sh`)

`SUPABASE_URL`, `SUPABASE_SECRET_KEYS` and `SUPABASE_PUBLISHABLE_KEYS` (JSON `{name: key}`; the
`default` key is used) are injected by Supabase, as are the legacy `SUPABASE_SERVICE_ROLE_KEY` /
`SUPABASE_ANON_KEY`. `_shared/supabase.ts` prefers the new keys, then the optional custom secrets
`SB_SECRET_KEY` / `SB_PUBLISHABLE_KEY` (custom names cannot start with `SUPABASE_`), then the legacy
JWTs. The service client logs which source it used (never the value).

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
| `GMAIL_PUSH_BUDGET_MS` | gmail-push | `100000` | Time budget per push; the rest continues on the redelivery (503) |
| `OPS_SMS_UNPARSED_THRESHOLD` | ops-monitor | `5` | Unparsed SMS per 24 h before an issue |
| `OPS_OPEN_REVIEWS_THRESHOLD` | ops-monitor | `50` | Open reviews before an issue |
| `OPS_QUEUED_DOCUMENT_AGE_S` | ops-monitor | `10800` | Age (s) of the oldest `queued` document before a backlog warning |
| `ALLOWED_ORIGINS` | all (CORS) | any | Comma-separated allowed origins |
| `SENTRY_DSN` | all | — | Sentry `credit-card-ledger-backend` DSN (empty disables Sentry) |
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
| `SENTRY_DSN`, `SENTRY_ENVIRONMENT`, `SENTRY_RELEASE`, `SENTRY_TRACES_SAMPLE_RATE` | —, `local`, —, `0.2` | Sentry `credit-card-ledger-backend`. Unset, `local`, `development` and `test` never report; `production` also disables `/debug-sentry` and the OpenAPI docs |
| `LOG_LEVEL`, `PORT` | `INFO`, `8080` | Logging and listen port (Cloud Run sets `PORT`) |

### iOS (`apps/ios/Config/Secrets.xcconfig`; `Secrets.Release.xcconfig` for TestFlight; both gitignored)

| Key | Purpose |
|---|---|
| `LEDGER_SUPABASE_URL` | `http:/$()/127.0.0.1:54321` locally, `https:/$()/<ref>.supabase.co` in release |
| `LEDGER_SUPABASE_PUBLISHABLE_KEY` | Publishable key (`sb_publishable_…`; never a secret key) |
| `LEDGER_SENTRY_DSN` | Sentry `credit-card-ledger-apps` DSN (empty disables Sentry) |
| `LEDGER_ENVIRONMENT` | `local` / `production`. Sentry starts only in Release builds with an environment other than local/development/dev/test |

`apps/ios/scripts/testflight.sh` (and `publish-build.sh`, which calls it) also reads these:
- `SENTRY_AUTH_TOKEN` for dSYMs and the Sentry release, from the environment or the login
  keychain item `ledger-sentry-auth-token` (never an xcconfig); `SENTRY_ORG` and `SENTRY_PROJECT`
  (default `credit-card-ledger-apps`) from the environment or else `Secrets.Release.xcconfig`.
  The token is never printed, and Sentry failing never fails the release
- `ASC_KEY_ID` and `ASC_ISSUER_ID` (with the AuthKey `.p8`) for the TestFlight upload and
  `testflight-distribute.mjs`; both default to the single key in `~/.appstoreconnect/private_keys`
- `LEDGER_REVIEW_EMAIL` and `LEDGER_REVIEW_PASSWORD` for `testflight-distribute.mjs --review-account`
  (the App Review demo account), from the gitignored `.env.review-demo` that
  `scripts/cutover/create-review-demo.sh` writes (PRODUCTION §7)

### Scraper (`scraper/.env`)

| Variable | Default | Purpose |
|---|---|---|
| `CCS_SCRAPER_TARGET_URL` | `http://127.0.0.1:8040` | Upload base URL: the Supabase URL. Always set it; the default is the removed legacy backend |
| `CCS_SCRAPER_UPLOAD_PATH` | `/api/v1/jobs/upload` | Set `/functions/v1/statements-upload`; the default is the removed legacy route |
| `{PROFILE}_CCS_SCRAPER_API_TOKEN` | — | Per-profile service token (v2 tokens are profile-scoped; scope `statements:upload`). Wins over the global token |
| `CCS_SCRAPER_API_TOKEN` | — | Global fallback token for profiles without their own |
| `CCS_SCRAPER_SUPABASE_PUBLISHABLE_KEY` | — | Optional publishable key (`sb_publishable_…`), sent as `apikey`. `CCS_SCRAPER_SUPABASE_ANON_KEY` is read as a deprecated fallback |
| `CCS_SCRAPER_UPLOAD_MAX_FILES`, `CCS_SCRAPER_UPLOAD_MAX_MB` | `20`, `32` | Upload batching: files and MB of PDF per request; they can only lower the defaults (the server accepts 20 files / 40 MB per request). A 413 halves the batch; batches that succeeded are recorded, so `upload-pending` retries only the rest |
| `CCS_SCRAPER_HEADLESS`, `CCS_SCRAPER_DOWNLOAD_DIR`, `CCS_SCRAPER_BROWSER_*` | `true`, `./downloads`, Dubai | Browser settings |
| `{PROFILE}_{BANK}_*` | — | Bank portal credentials per profile (see `scraper/.env.example`) |
| `SIB_CARD_LAST4S` | every card the portal's Credit Card section lists | SIB cards to export, e.g. `4821` or `4821,9218` (also `card_last4s:` under `SIB` in `config/banks.yaml`). One export per card; a replaced card stays listed next to its successor |

### Production secret helpers (`scripts/cutover/`)

Used for the production Edge Function secrets and Vault entries, and for secret rotation
(PRODUCTION.md §2.4–2.5, §11):

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
| `/signin`, `/welcome` | Sign-in (emailed one-time code or passkey; existing users only; offers to add a passkey after a code sign-in) and first-profile setup |
| `/` | **Overview**: month hero with pace rule, live pending SMS, category ring, monthly spend bars (split by category / bank / merchant, with totals), cards and dues with bank logos, what each card owes now and the total, utilisation, insights |
| `/activity` | **Activity**: unified ledger with URL-synced filters, a summary line (count, net AED, date span) for the current filters, search over description or merchant, evidence badges, drawer with evidence timeline, inline, bulk and "apply to merchant" categorisation, notes. Numbered pages (100–2000, in the URL) on wide screens; infinite scroll below 768 px |
| `/insights` | **Insights**: trends (monthly bars split by category / bank / merchant, top 10 + Others, with a totals table; filter by categories, banks, cards and a merchant search), categories, merchants, subscriptions, FX, calendar heatmap, time of day, YoY, anomalies |
| `/budgets` | **Budgets**: total and per category, on every card or one card, with progress |
| `/cards` | **Cards & Statements**: accounts, cards (each with its editable Wallet name for the payment shortcut), statements with recon status, upload with a live per-file processing log, documents (each with its processing log) |
| `/statements/$stmtCode` | **Statement**: header (bank, cards, period, dates), balance / debit / credit / min-due / utilisation tiles, Debits and Credits with every line (opens the transaction drawer), reconciliation checks, PDF, processing log |
| `/review` | **Review inbox**: match reviews, unknown cards (a Wallet payment links to Cards to set its Wallet name), unparsed SMS ("not a card transaction") and LLM template proposals. On mobile it is a bottom tab with a count and scrolls forever |
| `/rules` | **Rules**: categories, merchants, rules with live impact preview |
| `/settings` | **Settings**: ledger, members (and invites), account (sign-out, passkeys: add, rename, remove), sources and health (queues, DLQ, mailboxes, tokens, PDF passwords), iPhone SMS setup guide (step-by-step Shortcuts automation with copy buttons, *Open Shortcuts* on iPhone, a QR code to open it on the phone from a desktop, optional TestFlight button) |

**iPhone** (`apps/ios/Ledger`)

| Screen | Contents |
|---|---|
| Sign in / Profile picker | Email one-time code or passkey, then an offer to add a passkey; choose a ledger. Settings → Passkeys manages them. *Sign in with a password* is for the App Review demo account, the only account with a password |
| Overview | Month spend posted so far (server comparisons), pending SMS, categories, dues ("Was due …"), Needs attention (reviews, uncategorised), a stuck-outbox strip, a set-up checklist on an empty ledger (Realtime refresh) |
| Activity | Ledger list, filters, transaction detail and categorisation |
| Insights | Swift Charts views over the same RPCs; the budgets card's "See all budgets" opens the Budgets tab |
| Budgets | Month switcher, `budget_status` per budget (spent of limit, % used, pace; tone from the server's figures; this month an "expected by today" tick and "AED X over pace" from its `expected_share` and `over_pace_aed`), budgets not active that month (the server's `is_effective`, with `p_include_inactive`), create / edit / delete with an optional card (owners; viewers read only) |
| Settings → Statements | Statements, recon, uploads and their processing logs, PDF upload (document picker), PDFs waiting from the share sheet (the former Statements tab) |
| Review | Open match reviews: link, keep as new, dismiss, register an unknown card (read-only for viewers) |
| Settings | Cards & statements → Statements, "SMS go to" ledger, SMS capture guide (one "Card" automation, Last captured, Send test), "Not sent" outbox list (Retry / Delete), Privacy → Require Face ID (the app is always covered in the app switcher), profile; sign-out confirms and clears what is waiting on the phone |
| **Log Bank SMS** (App Intent) | Called by the Shortcuts automation, with no UI |
| **Add to Bank Ledger** (share extension) | Sends shared PDFs to `statements-upload` |

## API surface

### Edge Functions (`<SUPABASE_URL>/functions/v1/<name>`)

| Function | Method | Auth | Purpose |
|---|---|---|---|
| `statements-upload` | POST multipart (`files`, `bank_code_hint`, `profile_code`); ≤ 20 files and ≤ 40 MB per request | Service token `statements:upload` (+ `X-Profile-Key`) or user JWT (owner) | Store PDFs, dedup, queue parsing. Each result has `filename`, `doc_code`, `status` (`queued`/`duplicate`), `parse_status` and, when a failed duplicate was queued again, `requeued: true`. Follow a file with `document_events` (`doc_code=eq.<doc_code>`, Realtime) |
| `sms-ingest` | POST JSON `{profile_code?, messages[≤200]}` | User JWT or service token `sms:ingest` | Batch SMS ingest (idempotent on `client_msg_id`) |
| `gmail-push` | POST (Pub/Sub envelope) | Google OIDC token | Gmail notifications → documents (200 done or permanent failure acked, 503 budget used up, 500 transient: Pub/Sub redelivers) |
| `member-invite` | POST JSON `{profile_code, email, role?, action?, redirect_to?}` (`action`: `invite` or `resend`) | User JWT (owner) | Add a member and send the Auth invite email (sign-ups are off), or resend it. `redirect_to` must be on the caller's own origin |
| `worker`, `gmail-watch-renew`, `outlook-poll`, `ops-monitor`, `fx-rates` | POST | `x-cron-secret` | pg_cron-driven jobs |

### RPCs (`supabase.rpc(...)`, PostgREST)

| Group | RPCs (callable by signed-in members; owner-only marked *) |
|---|---|
| Profiles and members | `create_profile`, `add_profile_member`*, `list_profile_members`, `remove_profile_member`*, `cancel_profile_invite`*, `delete_profile`* (archives; the profile key confirms) |
| Tokens and secrets | `create_service_token`*, `revoke_service_token`*, `set_profile_secret`*, `list_profile_secrets`, `set_mailbox_secret`* |
| Ingest and review | `add_replacement_card`* (a re-issued card's new number on the same account), `ingest_sms`* (per-message statuses), `resolve_review`* (`link`, `create_new`, `dismiss`, `card`, `supersede`, `not_a_transaction`), `retry_sms_fallback`*, `review_context` (the context of a page of reviews in one call: subject line, SMS without its body, transaction or statement, candidate transactions, proposed format), `requeue_documents`*, `set_sms_template_active`* |
| Activity | `activity_summary` (the Activity header for the list's filters), `activity_day_totals` (each date header's net over the filtered set, for the days of a page), `activity_selection_summary` (count, net AED and excluded count of ticked codes or "all matching" a filter), `bulk_update_transactions`* (Exclude / Include from spend and Categorise for codes or a filter), `activity_export` (a selection's rows for Export CSV, money as decimal strings) |
| Categorisation | `set_transaction_category`*, `set_transactions_category`*, `preview_rule` (optional `p_rule_code` when editing), `merchant_search`, `reject_merchant_suggestion`* |
| Analytics | `overview`, `spend_pace` (overview's month-to-date 3-month average and projected month end), `spend_series`, `spend_breakdown` (monthly spend by category/bank/merchant, top N + Others), `category_breakdown`, `merchant_leaderboard`, `merchant_context` (the drawer's visits, average, 6-month total and first-seen date at a merchant), `daily_spend`, `hour_weekday_pattern`, `fx_spend`, `statement_cycles` and `statement_detail` (one statement with its debit and credit lines; both, and `overview`'s latest statements, carry the server's `payment_status` and `amount_paid`), `yoy_compare`, `anomalies` (merchant and category names, `baseline_scope`, `times_usual`; leaves out dismissed charges), `dismiss_anomaly`* ("This is fine"), `filter_meta`, `budget_status`, `recurring_list` (shapes: ARCHITECTURE §6) |
| Service-role only (Edge Functions) | `authenticate_service_token`, `ingest_parsed_document`, `fail_document`, `queue_read`, `queue_delete`, `queue_send`, `queue_to_dlq`, `worker_document_context`, `worker_llm_context`, `worker_sms_context`, `worker_mailbox_secret`, `apply_llm_suggestions`, `propose_sms_template`, `promote_sms_template`, `ops_health`, `upsert_fx_rates`, `begin_document_parse`, `resubmit_document`, `log_document_event`, `save_mailbox_sync_state`, `drain_dlq`, `requeue_dlq`, `restore_profile` |

Views: `v_spend` (the single spend definition), `v_transactions` (the Activity read model), `v_account_balances` (what each card owes) and `v_statement_payments` (whether each statement was paid).
Tables are readable by members under RLS. Owners edit categories, rules, budgets, accounts,
cards and transaction user fields directly.

## Legacy v1 (removed)

The v1 stack (FastAPI `backend/` on Render, React `frontend/`, `deploy/` Dockerfiles and the
Gmail relay, the one-off `scripts/migrate_legacy.py` cutover script) was deleted from the repo
after the cutover; it lives on in git history only. Its **data** was not touched: the legacy
tables stay in the `legacy` schema of the production database as the historical record (no
client role can read them), and the migrations that reference that schema (quarantine, legacy
import, parity report) are applied history and stay as they are. See
[PRODUCTION.md §10](PRODUCTION.md#10-cutover-record).
