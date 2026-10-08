# Audit 06 — Cross-cutting (contracts, config, docs, CI/CD, hygiene, cutover)

Scope: branch `ledger-v2` (13 commits over `main`, 4ec697c), audited 2026-10-08 before the
production cutover. Other audits cover DB, server, web, iOS and data parity in depth; this one
covers what falls between them. Read-only: no source edits, no commits, no `db reset`.

**What was run**
- `actionlint`: clean.
- `deno test -A .`: 70 passed, 1 ignored. `deno lint` and `deno check` are clean. `deno fmt --check` fails on 18 files.
- Web: tokens check, `lint`, `test` (119 passed) and `build` all pass. `pnpm install --frozen-lockfile --lockfile-only` changes nothing.
- Parser: `ruff` clean, `pytest` 196 passed and 6 skipped (golden PDFs absent).
- Scraper: `pytest` passes.
- `supabase gen types --local`: byte-identical to `packages/db-types`.
- Legacy prod dumps (`data/backups/prod-{schema,data}-20261008T094435Z.sql`): replayed with all 18 v2 migrations plus `import_legacy_metadata` on a throwaway `supabase/postgres:17.6.1.104` container.
- `supabase test db` on the shared local stack is **inconclusive**. Another auditor had loaded a `legacy` schema and real statements into it, so 02 and 03 failed for environmental reasons (see X-31).

**Not verifiable from here:**
- GitHub repo settings, environments and secrets. The repo is private and the `gh` account has no access.
- Render and Vercel dashboard settings, including Git auto-deploy.
- Contents of prod Vault and prod `supabase_migrations`.

## Findings

| ID | Sev | Category | Location | Problem (one line) |
|---|---|---|---|---|
| X-01 | **P0** | cutover-risk | PRODUCTION.md:456-467; local `supabase/functions/.env.production` | Step 7 pushes the whole local functions env file over the step-5 secrets, and that file holds a placeholder `PARSER_URL` |
| X-02 | **P0** | cutover-risk | `20261008000950_legacy_import.sql:236-269`; `scripts/migrate_legacy.py:235-252` | `legacy_parity_report()` errors on prod (`varchar` ≠ `text`), so `--step finalize` crashes and the parity sign-off can't be produced |
| X-03 | P1 | config / docs | PRODUCTION.md:441-442, 463-467; ROADMAP.md §1; `migrate_legacy.py:56-61` | Gmail OAuth client id/secret aren't in legacy `runtime_settings`, so step 7 never emits `GMAIL_OAUTH_*` |
| X-04 | P1 | docs | PRODUCTION.md:97-131, 439-443, 148-150 | `CRON_SECRET` is generated inline with `openssl` in §2.5, so the same value can't be put in Vault, and `$CRON_SECRET` is never exported for the smoke test |
| X-05 | P1 | ci | `.github/workflows/ci.yml:13-14, 45-47` | `permissions: contents: read` without `pull-requests: read`: `dorny/paths-filter` can't list PR files in a private repo, so every PR run fails |
| X-06 | P1 | contract | `services/parser/ccs_parser/contract.py:66,75-80` vs `20261008000300_documents_statements.sql:65,75,114`; `banks/enbd.py:124-128` | The contract doesn't enforce the period-order and last-4 checks SQL does, so documents fail permanently (`INGEST_23514`) and ENBD years come out wrong |
| X-07 | P1 | config / contract | `supabase/config.toml` `max_rows = 1000`; `apps/web/src/lib/pagination.ts:2`; `data/transactions.ts:41-48` | The 2000/page option is silently truncated to 1000 rows by PostgREST, so rows 1000–1999 of each page are never shown |
| X-08 | P1 | cutover-risk | `supabase/functions/worker/index.ts:37-38,62-64`; `ingest_and_match.sql:109-170` | Concurrent parse and ingest with select-then-insert account/card creation, and no per-profile lock. The bulk legacy import (380 PDFs into an empty ledger) is the worst case for duplicate accounts and deadlocks |
| X-09 | P2 | cutover-risk | PRODUCTION.md §10 step 4 | Prod's CLI migration history (`supabase_migrations.schema_migrations`) is unknown; there's no `supabase migration list --linked` check before `db push` |
| X-10 | P2 | cutover-risk | `20261008000000_quarantine_legacy.sql`; prod schema dump 151-179 | `public.rls_auto_enable()` (and its likely event trigger) isn't quarantined, so prod drifts from local and CI |
| X-11 | P2 | cutover-risk | `20261008000900_queues_secrets_cron.sql:494-501`, 431-433 | `cron.job_run_details` grows about 1.6k rows a day with no purge, against a 500 MB free tier, and `ops_health` scans it |
| X-12 | P2 | ci | `deploy-supabase.yml`, `deploy-parser.yml` | Manual deploys can be dispatched from any branch with no ref guard, and they can't be dispatched at all until merged to `main`. The runbook doesn't say when to merge |
| X-13 | P2 | ci / cutover-risk | `.github/workflows/*` legacy; Render and Vercel dashboards | The full list of things to disable at cutover is incomplete: workflow_run deploys, the security.yml legacy jobs, and Git-integrated auto-deploys outside the repo |
| X-14 | P2 | hygiene | `scripts/hooks/pre-commit`, `pre-push` | Hooks check only legacy code, run no v2 checks on push, and will fail every commit and push once `backend/` and `frontend/` are deleted. There's also an ANSI escape typo |
| X-15 | P2 | config | `services/parser/.gitignore`; PRODUCTION.md:192 | `gcloud run deploy --source .` would upload `services/parser/.env` and `.env.production` (`PARSER_SECRET`, DSN) to the Cloud Build bucket, because there's no `.gcloudignore` |
| X-16 | P2 | config | local `supabase/functions/.env.production`; no `supabase/functions/.env.example` | The local prod functions env file is missing 7 of the §2.5 keys, and there's no committed example for function secrets |
| X-17 | P2 | contract | `20261008000900:142`; `apps/web/src/data/settings.ts:108,110`; `ccs_parser/__init__.py:9`; `parse-v1.md:22-28` | `EIB_PDF_PASSWORD` and `MASHREQ_PDF_PASSWORD` are accepted and stored but never sent to or used by the parser |
| X-18 | P2 | contract | `contract.py:61`; `ingest_and_match.sql:606-607` | `amount_aed: null` is allowed on lines (Mashreq and SIB FX), but recon sums skip nulls, giving false `fail` |
| X-19 | P2 | contract | `apps/ios/.../SupabaseLedgerAPI.swift:224-226`; `LedgerAPI.swift:89` | iOS treats every Postgres error as transient, so the SMS outbox retries permanent errors (viewer role, bad input) forever |
| X-20 | P2 | contract | `ingest_and_match.sql:705, 784-790`; parse-v1.md | Re-ingesting a shorter SIB history export for the same cycle supersedes lines and orphans their transactions. The contract doesn't say whether history is complete or partial |
| X-21 | P3 | cutover-risk | PRODUCTION.md §10 steps 4–11 | pg_cron mailbox jobs start as soon as Vault is set (step 5): `outlook-poll` errors hourly until OAuth is set, then ingests before step 11 |
| X-22 | P3 | docs | PRODUCTION.md:98-99 | `vault.create_secret` fails if the name already exists; `private.vault_upsert` makes the step safe to re-run |
| X-23 | P3 | cutover-risk | quarantine migration | 294 legacy table grants to anon/authenticated remain on `legacy.*`. Schema USAGE is revoked, so they're not exploitable |
| X-24 | P3 | cutover-risk | `legacy_import.sql:224-227` | 9 staged choices for the legacy category `Entretainment` (typo) are marked applied but dropped |
| X-25 | P3 | docs / contract | `docs/contracts/parse-v1.md:111-115`; `app.py:38,123,136,138`; `contract.py` `country_code` | The documented error table drifts from the code (`DOWNLOAD_FAILED` is also 502; `INVALID_REQUEST` is missing), and `country_code` has no defined format |
| X-26 | P3 | ci | `ci.yml` | No `deno fmt/lint/check` (fmt fails 18 files today), no build of the iOS app/extension targets, and golden parity is always skipped |
| X-27 | P3 | docs | PRODUCTION.md:412, 428; repo-root `.env.cutover` | `$LEGACY_DB_URL` is undefined. The `psycopg[binary]` install fails unquoted in zsh. `.env.cutover` (service-role key, Fernet key, DB URL) is undocumented and should be destroyed after cutover |
| X-28 | P3 | config | `apps/ios/Config/Secrets.Release.xcconfig`; `apps/web/.env.production.local` | `SENTRY_AUTH_TOKEN` sits in files where it's never read: the iOS script and `vite.config.ts` read the process env. In the xcconfig it becomes an Xcode build setting |
| X-29 | P3 | ci | `deploy-parser.yml:24-29` | The `me-central1` region option has no `ccs-platform` Artifact Registry repo and would change `PARSER_URL` |
| X-30 | P3 | docs | README.md (Legacy section, Tests) | README says legacy tables "now live in" `legacy` (not yet true) and describes only the pre-commit hook, not pre-push |
| X-31 | P3 | hygiene | `supabase/tests/02_ledger`, `03_legacy_import` | pgTAP assumes a freshly reset DB, so it fails on a stack that holds a `legacy` schema or extra data |
| X-32 | P3 | config | Vercel project (§4) | Preview deployments get prod `VITE_SUPABASE_URL` and the prod CSP, and their auth redirects aren't allow-listed |
| X-33 | P3 | contract | various | Minor contract nits: `fx_rate` is 1 or null for AED by bank, the `concat_ws` dedup key drops nulls, a tiny FX rate rounds to `"0"`, `amount_drift` is never produced, and iOS `spendAvg3M` key mapping is fragile |

**Counts:** P0 = 2 · P1 = 6 · P2 = 12 · P3 = 13 (33 total)

---

## Details

### X-01 (P0, cutover-risk): step 7 overwrites good function secrets with a placeholder file
- **Location.** PRODUCTION.md §10 step 7 (lines 456, 463-467) runs `--step secrets --apply --functions-env-out supabase/functions/.env.production`, then "push it as-is with `supabase secrets set --env-file supabase/functions/.env.production`".
- **Problem.** `migrate_legacy.py:146-153` *merges* the OAuth keys into the existing file rather than writing a fresh one. The local file already exists and contains `ANTHROPIC_API_KEY`, `LLM_MODEL`, `SENTRY_*`, `CRON_SECRET`, `PARSER_SECRET` and `PARSER_URL`.
- **Evidence.** I checked the shape only and printed no values:
  - `PARSER_URL` contains `<` and does not start with `https://`, so it's a placeholder.
  - `SENTRY_RELEASE` is a fixed value.
  - `CRON_SECRET` is whatever was generated when the file was written, not necessarily the Vault value.
- **Impact.** Pushing the file "as-is" in step 7 resets `PARSER_URL` to a placeholder right before the canary `--step pdfs`:
  - Every parse fails as `PARSER_*` transient errors, then lands in the DLQ.
  - If the file's `CRON_SECRET` differs from Vault, every pg_cron → Edge call gets a 401.
- **Fix.** Write the OAuth values to a fresh file (`--functions-env-out /tmp/oauth.env`), push that, then delete it. Alternatively, make `.env.production` the single complete source of truth: fill in every §2.5 key and the real Cloud Run URL, then use it in step 5 too. Either way, make the runbook say which.

### X-02 (P0, cutover-risk): the parity report crashes on prod data
- **Location.** `20261008000950_legacy_import.sql:236` declares `returns table (profile_key text, bank_code text, …)`. The legacy CTE returns `legacy.profiles.key` as `varchar(64)` and `legacy.statements.bank_code` as `varchar(16)`, so after the `full join … using (…)` columns 1 and 2 are `varchar`.
- **Evidence.**
  - On a prod-image clone loaded with the prod dumps, the parity call fails with "Returned type character varying does not match expected type text in column 1".
  - `migrate_legacy.py:240-250` calls `apply_legacy_category_choices()` and then the report in one transaction. The error rolls back the applied choices, and the step 8 "Parity sign-off" can never be read.
  - Local runs and CI never see this: the function returns early at line 243 when `legacy` is empty, and pgTAP 03 builds its own `text` columns.
- **Fix.** Cast `p.key::text` and `s.bank_code::text` in the legacy CTE. The migration hasn't reached prod, so editing it is allowed. Add a pgTAP case with `varchar` legacy columns that matches the prod DDL.

### X-03 (P1, config/docs): Gmail OAuth client values have no source in the runbook
- **Evidence.**
  - Prod `legacy.runtime_settings` has `EMAIL_MS_CLIENT_ID` and `EMAIL_MS_CLIENT_SECRET`, plus the refresh tokens `EMAIL_GMAIL_REFRESH_TOKEN_MAILBOX_2` and `EMAIL_MS_REFRESH_TOKEN_MAILBOX_1`. It has **no** `EMAIL_GMAIL_CLIENT_*`.
  - Legacy reads the Gmail client from env (`backend/ccs_platform/core/settings.py:87-88`, prefix `CCS_PLATFORM_`, so `CCS_PLATFORM_EMAIL_GMAIL_CLIENT_ID` and `…_SECRET` on Render).
  - Step 5 defers Gmail and MS OAuth values to step 7, and ROADMAP ticks "emit `GMAIL_OAUTH_CLIENT_*`" as done.
- **Impact.**
  - `gmail-push` and `gmail-watch-renew` throw `MISCONFIGURED` at step 11.
  - The migrated Gmail refresh token only works with the *same* OAuth client that minted it. A new client means re-consenting the mailbox.
- **Fix.** Add an explicit step: copy `CCS_PLATFORM_EMAIL_GMAIL_CLIENT_ID` and `_SECRET` from the Render env, or the relay's, into `GMAIL_OAUTH_CLIENT_ID` and `_SECRET`. Note the same-client requirement in §5.4, and correct ROADMAP.

### X-04 (P1, docs): the CRON_SECRET can't match Vault
- **Problem.**
  - §2.4 (run first in step 5) needs `'<CRON_SECRET>'`.
  - §2.5 then sets `CRON_SECRET="$(openssl rand -hex 32)"` inline. The value is never captured, and `supabase secrets list` shows only digests.
  - Line 131 ("Use the CRON_SECRET value you put in Vault") contradicts the command.
  - The smoke test at lines 148-150 and the curl commands in §5 and §6 use `$CRON_SECRET`, which is never exported.
- **Impact.** Following the steps literally, every `invoke_edge` call gets a 401: the worker never runs, nothing parses, and `ops-heartbeat` alerts.
- **Fix.** Start step 5 with `export CRON_SECRET=$(openssl rand -hex 32)`. Use it in both `vault_upsert('edge_cron_secret', …)` and `secrets set CRON_SECRET="$CRON_SECRET"`.

### X-05 (P1, ci): PR CI breaks on the paths filter
- **Location.** `ci.yml` sets workflow-wide `permissions: contents: read` (line 13). `main`'s CI had no `permissions` block, so it inherited the defaults.
- **Problem.** On `pull_request` events, `dorny/paths-filter@v3` lists changed files through the REST API, which needs `pull-requests: read`. The repo is private (the unauthenticated API returns 404).
- **Impact.** The `changes` job fails with "Resource not accessible by integration", so every downstream job is skipped and PR checks go red. Pushes to `main` are unaffected, because they use git history.
- **Fix.** Add `pull-requests: read` to the top-level `permissions` or to the `changes` job.

### X-06 (P1, contract): the parser emits values the DB rejects
- **Location.** The contract (`contract.py:75-80`) types `period_start`, `period_end` and `due_date` as plain ISO dates with no ordering rule, and `card_last4` and `primary_card_last4` (66, 80) as any string. SQL enforces `period_start <= period_end` (`documents_statements.sql:75`) and `^[0-9]{4}$` on last-4 (65, 114).
- **Evidence** (local DB):
  - 2 ENBD documents failed permanently with `INGEST_23514` on `statements_check`.
  - An ENBD December statement was stored with `statement_date = 2026-12-28`, `period_start = 2025-11-29` and `due_date = 2026-01-22`, which points to a year-rollover bug in `banks/enbd.py:124-128`.
- **Cutover impact.** Step 7 re-parses every legacy PDF. These rows show up as failed documents or parity deltas, which block sign-off. Wrong years also misplace spend months.
- **Fix.** Add model validators to the contract (date order, `due_date >= statement_date`, 4-digit last-4) so failures are classified as `PARSE_*` with a clear code. Fix the ENBD year inference and add a golden case. Update parse-v1.md.

### X-07 (P1, config/contract): 2000/page is silently capped at 1000
- **Location.** `config.toml` `[api] max_rows = 1000`. Prod API "Max rows" also defaults to 1000 and isn't managed by `db push`.
- **Problem.** The web offers 100/200/500/1000/2000 (CLAUDE.md §4.5) and requests `.range(from, from+1999)`. PostgREST returns at most 1000 rows, while `pageCount` uses `total/2000`.
- **Impact.** On page 1, rows 1000-1999 never render. On page 2, rows 3000-3999 never render, and so on. No error is shown.
- **Fix.** Raise "Max rows" to at least 2000 in prod (Dashboard → API settings) and in `config.toml`, and add it to PRODUCTION §2. Alternatively, drop 2000 from `PAGE_SIZES` and amend the standard.

### X-08 (P1, cutover-risk): concurrent ingest makes duplicate accounts during the bulk import
- **Problem.**
  - The worker processes 3 parse messages at once with `Promise.allSettled` (`worker/index.ts:37-38,62`). The every-minute kick can also start a second worker while one is still running.
  - `resolve_statement_account` and `ensure_card` are select-then-insert with no advisory lock (no `pg_advisory` anywhere in migrations).
- **Evidence** (local DB): 3 documents failed with `INGEST_23505` and 1 with `INGEST_40P01`, and one profile has 2 FAB accounts.
- **Why P1 now.** Step 7 `--step pdfs` loads 380 PDFs into a ledger with no accounts yet. That is exactly the race window, and duplicate accounts then distort recon, cards and parity.
- **Fix.** Start `ingest_parsed_document` with `perform pg_advisory_xact_lock(hashtext(p_profile_code))`. As a stopgap, have the runbook import with parse batch size 1.

### X-09 (P2, cutover-risk): unknown prod migration history
`db push` refuses or misbehaves if `supabase_migrations.schema_migrations` already holds versions the local folder doesn't have, for example from earlier dashboard or CLI experiments. Before step 4, add `supabase migration list --linked` and expect only local versions listed as pending. The Deploy Supabase workflow's `dry_run` covers the same check.

### X-10 (P2, cutover-risk): leftover prod function
Prod `public.rls_auto_enable()` is an event-trigger function granted to anon and authenticated (schema dump 151-179, around 1450), and Supabase's `ensure_rls` event trigger probably goes with it. The quarantine doesn't handle either.
- **Collisions.** None.
- **Effect.** It auto-enables RLS on new tables, which is harmless because all 29 v2 tables enable RLS anyway. But it is drift: `supabase db diff` and `db pull` will show it.
- **Fix.** Decide and document. Either leave it in place, noted in PRODUCTION §2.3 alongside the claim that "every legacy table and enum" moves, or move or drop it explicitly.

### X-11 (P2, cutover-risk): unbounded cron run history
- **Growth.** `ledger-worker-kick` alone logs 1,440 rows a day in `cron.job_run_details`, about 1.6k a day with the other jobs, so roughly 600k rows a year. pg_net responses expire, but cron history doesn't.
- **Cost.** `ops_health()` aggregates the whole table every 15 minutes.
- **Free-tier load (the rest is fine).** Edge invocations stay under 50k a month in the worst case, against a 500k limit:
  - `ops-monitor`: 2,880
  - `outlook-poll`: 720
  - `fx-rates` and `gmail-watch-renew`: 30 each
  - `worker`: at most 43,200, and only when a queue has work
- **Fix.** Add `delete from cron.job_run_details where end_time < now() - interval '14 days'` to `private.nightly()` in a new migration, and bound `ops_health` to a recent window.

### X-12 (P2, ci): deploy workflow guards and merge timing
- **No branch guard.** `deploy-supabase` and `deploy-parser` check a typed confirmation but not `github.ref`. Someone could push migrations or deploy functions from an unmerged branch. Add `if: github.ref == 'refs/heads/main'` and a deployment-branch policy on the `production` environment.
- **Merge timing.** `workflow_dispatch` workflows can only be dispatched once the file is on the default branch. Steps 3, 4 and 6 ("or run the Deploy … workflow") therefore need `ledger-v2` merged first.
  - Merging is safe for legacy: no `backend/`, `frontend/` or `deploy/` paths changed, so `deploy-backend`, `deploy-frontend` and `deploy-gmail-relay` won't fire.
  - Add "merge `ledger-v2` to `main`" to "Before the day".
- **Not verified.** I couldn't confirm that the `production` environment and the `SUPABASE_*`, `GCP_SA_KEY` and `GCP_PROJECT_ID` secrets exist (private repo).

### X-13 (P2, ci/cutover-risk): what must be disabled at cutover
Step 1 disables only `email-ingest-microsoft` and the Cloud Scheduler `ccs-gmail-watch-renew`. Also:
- `gh workflow disable` for `deploy-backend.yml`, `deploy-frontend.yml` and `deploy-gmail-relay.yml`. They are `workflow_run` on CI success and fire on any later legacy-path edit.
- The `security.yml` legacy `python` and `container` jobs keep running weekly until deleted.
- **Outside the repo.**
  - Turn off Render "Auto-Deploy on commit" if it's on. Once suspended, Render won't build, but before that a merge rebuilds the legacy API.
  - The legacy Vercel project builds `frontend/` on every push to `main` if it's Git-connected.
  - The new `apps/web` project will deploy Production on every `main` push from the moment it's created.
- **Fix.** List all of the above in step 1, and add the matching re-enable steps to Rollback.

### X-14 (P2, hygiene): git hooks
- `pre-commit` always runs `compileall` and `bandit` on `backend/`. `pre-push` runs only the legacy backend and frontend suites: no supabase, deno, parser or web checks.
- After step 12 deletes `backend/` and `frontend/`, both hooks fail on every commit and push. `cd frontend` fails, and `compileall` on a missing directory exits non-zero.
- `pre-push:13` has `YELLOW='\033[1;33d'`: `d` instead of `m` is a cursor-move sequence and garbles the output.
- Neither hook enforces the CLAUDE.md §9 "no Co-Authored-By" rule. Today's 13 commits comply: all authored correctly, 0 trailers.
- **Fix.** Gate each section on the directory existing. Add v2 checks to pre-push (`deno test`, parser `pytest`, `pnpm web:test`, `pnpm db:types:check` when the stack is up). Reject `Co-Authored-By` in `commit-msg`.

### X-15 (P2, config): parser secrets leak into the Cloud Build source upload
`services/parser/` has no `.gcloudignore`. gcloud's default upload honours only that directory's `.gitignore`, which lists `tests/golden/` and `.venv/` but not `.env*`. The root `.gitignore` doesn't apply.
- **Impact.** The manual §3 path (`gcloud run deploy --source .`) uploads `.env` and `.env.production` (`PARSER_SECRET`, Sentry DSN) to the `<project>_cloudbuild` bucket. The image itself is clean: `.dockerignore` excludes them.
- **Fix.** Add `services/parser/.gcloudignore` (copying the `.dockerignore` rules, plus `tests/golden/`). Alternatively, recommend only the workflow, which builds from a clean checkout.

### X-16 (P2, config): incomplete function secret inventory files
- **Key names in the code** (`Deno.env.get`):
  - `CRON_SECRET`, `PARSER_URL`, `PARSER_SECRET`, `PARSER_DOCUMENT_BASE_URL`, `PARSER_TIMEOUT_MS`, `WORKER_BUDGET_MS`
  - `ANTHROPIC_API_KEY`, `LLM_MODEL`
  - `GMAIL_PUSH_AUDIENCE`, `GMAIL_PUSH_SA_EMAIL`, `GMAIL_PUBSUB_TOPIC`, `{GMAIL,MS}_OAUTH_CLIENT_{ID,SECRET}`, `MS_OAUTH_TENANT`
  - `OUTLOOK_LOOKBACK_DAYS`, `OUTLOOK_BUDGET_MS`, `OPS_SMS_UNPARSED_THRESHOLD`, `OPS_OPEN_REVIEWS_THRESHOLD`
  - `ALLOWED_ORIGINS`, `SENTRY_{DSN,ENVIRONMENT,RELEASE,TRACES_SAMPLE_RATE}`, `LEDGER_E2E`
  - plus the injected `SUPABASE_*` and `SB_*`
- **Docs match.** README's table matches the code, including defaults (0.1, 90, 100000, 50000, 5, 50).
- **Local prod file is short.** `supabase/functions/.env.production` lacks `ALLOWED_ORIGINS`, `GMAIL_PUSH_AUDIENCE`, `GMAIL_PUSH_SA_EMAIL`, `GMAIL_PUBSUB_TOPIC` and the four OAuth keys. It correctly doesn't set `PARSER_DOCUMENT_BASE_URL`.
- **No committed template.** There's no `supabase/functions/.env.example` (web and parser have one).
- **Fix.** Commit `supabase/functions/.env.example` listing every key, grouped as required, prod-only, local-only and optional.
- **Other inventories checked, no gaps:**
  - parser `.env.example` against `os.environ` reads
  - web `.env.example` against `import.meta.env` reads
  - iOS `Secrets.example.xcconfig` against `project.yml` and Info.plist
  - scraper `.env.example` against `config.py`
  - cutover env (`.env.cutover`) against the `migrate_legacy.py` docstring

### X-17 (P2, contract): EIB and Mashreq PDF passwords
`set_profile_secret`, the web Settings screen and the PRODUCTION Vault table accept `EIB_PDF_PASSWORD` and `MASHREQ_PDF_PASSWORD`. The parser's password map (`ccs_parser/__init__.py:9`) and `dispatcher.py` never try them, and parse-v1 lists only FAB, ADCB, ADCB_CID, ENBD and SIB. Encrypted EIB or Mashreq PDFs fail even with the password saved. Either wire them into the parser and the contract, or remove them from the allow-list and the UI.

### X-18 (P2, contract): null `amount_aed` and reconciliation
The contract allows `amount_aed: null`, and three SIB FX lines locally have it null alongside `fx_rate`. `reconcile_statement` and `statement_cycles` sum `amount_aed` and drop the nulls. Ingest estimates AED for the *transaction* but not for the statement line, so the result is false recon `fail` and low debit totals. Either have recon use the transaction estimate, or have the parser emit `fx_rate` whenever the statement shows it.

### X-19 (P2, contract): iOS retries permanent errors
`SupabaseLedgerAPI.swift:224-226` maps every PostgREST error to `status: nil`, and `LedgerAPI.swift:89` treats `nil` as transient. `ingest_sms` is owner-only (`ingest_and_match.sql:1002`). So a viewer's SMS shortcut reports "Saved … will be sent" and retries forever, and one bad message blocks its whole batch. Map SQLSTATE `42501`, `22023`, `22P02` and `P0001` to permanent errors, and drop or flag the message.

### X-20 (P2, contract): partial SIB history exports
History extracts are keyed by account, statement date and kind. A later, shorter export for the same cycle supersedes the missing lines (`ingest_and_match.sql:784-790`). Locally there are duplicate `Transaction history_27_08_2026*.pdf` files. Define in parse-v1 whether a history export is authoritative for its window, and only supersede lines inside the new file's date range.

### X-21 (P3, cutover-risk): cron jobs run mid-cutover
From step 5, Vault is set and the cron calls go live:
- `ledger-outlook-poll`, hourly at :05, hits `MISCONFIGURED` until the MS keys are pushed in step 7, which adds Sentry noise during the freeze.
- Once they're pushed, Outlook ingestion starts immediately, before step 11 "Switch email". Dedup makes this safe.
- `ledger-gmail-watch-renew` at 03:00 UTC renews the watch while the push subscription still targets the legacy relay.

Note this in the runbook, or set Vault `edge_cron_secret` only at step 6.

### X-22 to X-24 (P3): smaller cutover items
- `vault.create_secret('…','project_url')` errors if the name already exists. Use `select private.vault_upsert('project_url', …)` (it exists, and the migration owner can call it).
- `legacy.*` keeps 294 grants to anon and authenticated. They're blocked by revoked schema USAGE and RLS with no policies; optionally `revoke all on all tables in schema legacy from anon, authenticated`.
- 9 legacy line choices name the category `Entretainment` (sic). They're marked `applied_at` but never applied. Add an alias, or report unresolved category names in the finalize output.

### X-25 (P3, docs/contract): parse-v1 drift
- `DOWNLOAD_FAILED` is documented as permanent 422, but `app.py:123,136,138` also returns it as 502 for transient download failures. The worker branches on status, so behaviour is correct.
- `INVALID_REQUEST` (422, `app.py:38`) is undocumented.
- `country_code` is `str | None` with no format. Values seen include `ARE`, `AE`, `UAE`, `IRL`, `DXB` and `YOU`.

### X-26 (P3, ci): CI coverage gaps
- **Edge job.** Runs only `deno test`. Add `deno lint`, `deno check **/*.ts` and `deno fmt --check` (fmt fails on 18 files today; fix them first or drop fmt).
- **iOS job.** `swift test` covers LedgerKit only. The app, App Intent and share extension targets are never compiled; consider a weekly `xcodegen && xcodebuild build` job.
- **Golden parity.** It always skips in CI, so the parser regression net exists only on the laptop.
- **Confirmed fine:**
  - `supabase start -x …`: every name is valid for CLI 2.109.1
  - the `pnpm/action-setup` and `packageManager` combination
  - Node 22
  - `macos-26` with `latest-stable` Xcode against swift-tools 6.0
  - the scraper `[dev]` extra
  - `uv pip sync` against the fully pinned `requirements.txt`

### X-27 (P3, docs): runbook shell details
- Step 2 uses `$LEGACY_DB_URL`, which is defined nowhere. Same DB as `LEDGER_DB_URL`; say so.
- "Local tools ready": `pip install psycopg[binary] …` errors with "no matches found" in zsh (the user's shell); quote it. The deps are already present in `backend/.venv` (verified: psycopg 3.3.3, httpx, cryptography, google-cloud-storage).
- The untracked repo-root `.env.cutover` (gitignored, mode 600) holds the service-role key, legacy Fernet key and DB URL, plus unused `SENTRY_*` and `GCP_*`. It isn't mentioned in any doc. Document it as the cutover env file (`set -a; source .env.cutover`) and add "shred `.env.cutover` and `supabase/functions/.env.production`" to step 12.

### X-28 (P3, config): Sentry auth token placement
- `Secrets.Release.xcconfig` defines `SENTRY_AUTH_TOKEN` and `SENTRY_ORG`. `publish-build.sh:153-158` reads them from the process env only, so the xcconfig copy does nothing. As a build setting, it appears in `xcodebuild -showBuildSettings` and build logs.
- `apps/web/.env.production.local` also holds `SENTRY_AUTH_TOKEN`, but `vite.config.ts` reads `process.env`, which Vite doesn't populate from `.env*`.
- **Fix.** Keep both tokens in the shell or keychain.
- **Not a problem.** Web release tagging works without `VITE_SENTRY_RELEASE`, because the Sentry plugin injects the release and debug IDs.

### X-29 (P3, ci): parser region choice
The `deploy-parser.yml` region `me-central1` would push to `me-central1-docker.pkg.dev/<p>/ccs-platform`, which doesn't exist, and would create a second service with a different URL. Remove the option or document it.

### X-30 (P3, docs): README inaccuracies
- The "Legacy" section says legacy tables "now live in the `legacy` schema". That's only true after step 4.
- "`install-hooks.sh` installs a pre-commit hook" omits pre-push, which runs the full legacy suite.
- Otherwise README, ARCHITECTURE (cron table, Vault names, function list) and PRODUCTION §2.6 match the migrations and code.
- CHANGELOG has the per-area v2 section. ROADMAP's "fixed GMAIL_OAUTH" tick is wrong (X-03).

### X-31 (P3, hygiene): pgTAP needs a pristine DB
`03_legacy_import.test.sql:7` creates `legacy.profiles` and fails if a `legacy` schema exists. 02 assumes seed-only data ("more than one row returned by a subquery"). This is fine in CI (fresh reset), but the local stack is shared between audits and imports. Document "reset before test", or make 03 use a temp schema.

### X-32 (P3, config): Vercel previews hit prod
Preview deployments use the same env (only `VITE_SENTRY_ENVIRONMENT` differs) and so talk to the production Supabase. Magic links to preview URLs aren't in the Auth redirect allow-list. Either disable previews, or point them at a non-prod project.

### X-33 (P3, contract): minor contract nits
- `fx_rate` is `1` or null for AED lines depending on the bank.
- The line dedup key uses `concat_ws`, which silently drops a null `posting_date` or `amount_aed`.
- An FX rate below 1e-8 rounds to `"0"` and violates `fx_rate > 0`.
- The `amount_drift` review reason is allowed but never produced.
- iOS relies on Foundation turning `spend_avg_3m` into `spendAvg3M`.
- 7 FAB statements fail recon against the extracted totals (`totals.py:131-132`). That's for the parser and parity audits.

---

## Checked and consistent (no finding)
- **Parser → worker → SQL.** Every key `ingest_parsed_document` reads exists in the pydantic model. Money and totals are decimal strings cast to `numeric`, dates are ISO, and time is `isoformat`. Kinds, statement and document types, direction, reference source and currency all match the SQL CHECKs. The six bank codes are identical across parser, `banks` and scraper.
- **Types and clients.**
  - `packages/db-types` has no drift.
  - Web `tsc` passes against it, and both untyped select strings were checked against the local API.
  - iOS decoding keys, nullability, money-as-string and timestamp formats match the views and RPCs, including fractional seconds with `+00:00`.
- **Uploads.** iOS, web and scraper all match `statements-upload/form.ts`: `files`, `profile_code`, `bank_code_hint`, `source`, scope `statements:upload`, tokens with the `ccs_` prefix, and the response `{uploads:[{filename,doc_code,status}]}`. The 25 MB limit is the same in the bucket, Edge, web, iOS and parser.
- **Storage paths.** `migrate_legacy.py --step pdfs` uses `<profile_code>/<doc_code>.pdf`, the same layout as `storeDocument` and the bucket RLS (`foldername[1]`).
- **Quarantine.** All 21 prod tables, 10 enums and 19 owned sequences move. The 8 clashing names in the Rollback table are exactly the legacy ∩ v2 set. v2 creates no enums or standalone sequences.
- **Platform.** Prod is PG 17.6, matching `major_version = 17`. The extensions v2 needs are created by migration with no dashboard step.
- **Repo hygiene.**
  - The largest tracked v2 files are `pnpm-lock.yaml` (202 KB), `database.ts` (74 KB) and `AppIcon.png` (27 KB, the only binary).
  - Generated files are consistent: `Tokens.swift` and `database.ts` are committed and drift-checked; `packages/tokens/dist` is ignored and rebuilt by `prebuild`/`pretest`.
  - The `data/` ignore with `!apps/web/src/data/` works.
  - The gitignored secrets files exist and are not tracked.
  - No TODO, FIXME or HACK in v2 code; the `XXX` matches are masked card numbers.
  - Prod npm deps are MIT, ISC, BSD, Apache-2.0, OFL (fonts), 0BSD or Unlicense; Swift and Python deps are MIT or BSD.
  - All 13 commits are authored `Hussain Abbasi <h_abbasi97@hotmail.com>` with no co-author trailers.
- **Web CSP.** `connect-src` covers the prod ref and the DSN's `*.ingest.us.sentry.io`.

---

## Fix status

Updated 2026-10-08 by the runbook/CI/config pass. Owners: **this pass** = PRODUCTION.md,
README.md, ARCHITECTURE.md, ROADMAP.md, `.github/workflows/**`, `scripts/hooks/**`,
`scripts/cutover/**`, `services/parser/.gcloudignore`/`.dockerignore`. Nothing is committed yet.

| ID | Status | Notes |
|---|---|---|
| X-01 | **fixed** | `supabase/functions/.env.production` is the single source of truth. New `scripts/cutover/set-edge-secrets.sh` refuses empty/`<placeholder>` values, missing `CRON_SECRET`/`PARSER_URL`/`PARSER_SECRET`, non-https or local `PARSER_URL`, and local-only keys; pushes exactly the file's keys via a private temp file, never echoing values. Runbook pushes it in step 5 and again after `--step secrets` in step 7 (no more "push as-is"). PRODUCTION §2.5 has a per-key source table. |
| X-02 | owned by DB agent | `legacy_parity_report()` varchar/text cast (migration). |
| X-03 | **fixed** (docs) | PRODUCTION §5.4, §2.5 and "Before the day": copy `CCS_PLATFORM_EMAIL_GMAIL_CLIENT_ID/SECRET` from Render into `GMAIL_OAUTH_CLIENT_ID/SECRET`; same-client requirement noted. ROADMAP's wrong tick replaced with an accurate done item plus an open task. |
| X-04 | **fixed** | `CRON_SECRET` is read from the env file and exported once at session start; Vault is set from it with new `scripts/cutover/set-vault-secrets.sql` (psql variables, `private.vault_upsert`, placeholder/length checks, no values committed). Digest comparison documented. |
| X-05 | **fixed** | `ci.yml` `changes` job: `permissions: contents: read, pull-requests: read`. Other jobs keep workflow-level `contents: read`; `security.yml`, `deploy-backend.yml`, `deploy-frontend.yml` gained `permissions: contents: read`; deploy guard jobs use `permissions: {}`. actionlint 1.7.12 clean, all 8 workflows YAML-parse. |
| X-06 | owned by server agent | parser contract validators / ENBD year. |
| X-07 | owned by DB agent (config.toml) | Prod side documented: PRODUCTION §2.7 + §10 step 4 (Dashboard → Data API → Max rows = 2000). |
| X-08 | owned by DB agent | ingest advisory lock. |
| X-09 | **fixed** (docs) | Step 4 starts with `supabase migration list --linked`. |
| X-10 | deferred | `rls_auto_enable` drift: not addressed. |
| X-11 | documented; migration owned by DB agent | PRODUCTION §2.6 has the purge SQL (`ledger-cron-history-purge`, daily, 7-day window); ROADMAP item added. Bounding `ops_health` is left to the DB agent. |
| X-12 | **fixed** | `deploy-supabase.yml` / `deploy-parser.yml`: `guard` job fails unless `refs/heads/main`, deploy job `needs: guard` + `if: github.ref == 'refs/heads/main'`, typed confirmation kept. PRODUCTION §9 documents the environment branch policy and merge timing; "Before the day" now merges `ledger-v2` first. |
| X-13 | **fixed** | Legacy `deploy-*`, `email-ingest-microsoft` and `security.yml` legacy jobs are gated on repo variable `LEGACY_DEPLOYS_ENABLED == 'true'` (set `true` before merge, `false` at step 1). Step 1 is an ordered disable list (Actions → Render auto-deploy then suspend → legacy Vercel Git → Cloud Scheduler → Cloud Run relay → scraper); Rollback reverses it; step 12 removes the variable and jobs. |
| X-14 | **fixed** | Hooks skip missing `backend/`/`frontend/` and missing tools; `pre-push` runs v2 checks (deno test, parser ruff/pytest, tokens, web lint/test, DB types drift when the stack is up, scraper); ANSI typo fixed; `commit-msg` rejects `Co-Authored-By`. bash -n + shellcheck clean; exercised in an empty repo. |
| X-15 | **fixed** | New `services/parser/.gcloudignore` (and expanded `.dockerignore`) exclude `.env`, `.env.*` (keep `.env.example`), `.venv/`, `tests/` incl. golden PDFs, `scripts/`, caches, `*.pdf`. `gcloud meta list-files-for-upload` shows no env files. |
| X-16 | partly fixed | The §2.5 table lists every prod key and its source; no `supabase/functions/.env.example` committed (functions dir not owned here). |
| X-21 | **fixed** (docs) | Vault now set in step 6, after functions are deployed; expected `outlook-poll` noise and watch renewal documented. |
| X-22 | **fixed** | Vault via `private.vault_upsert` (template). |
| X-27 | **fixed** (docs) | `LEGACY_DB_URL` = `LEDGER_DB_URL`; `'psycopg[binary]'` quoted; `.env.cutover` documented with the other local secret files; shred step added to step 12. |
| X-29 | deferred | `me-central1` option kept in `deploy-parser.yml`; PRODUCTION §3 states the parser region is `europe-west1` (note `.env.cutover` has `GCP_REGION=me-central1`). |
| X-30 | **fixed** | README Legacy wording, hooks description and `scripts/cutover/` documented. |
| X-17–X-20, X-23–X-26, X-28, X-31–X-33 | not in this pass | Contract/server/iOS/web/DB items or P3 left for their owners. |

**Later updates (2026-10-08):** X-02, X-07 (local), X-08 and X-11 (`ledger-cron-history-purge`) were
fixed by the DB pass; X-06 by the server pass; X-18 by DB-16, X-19 by IOS-01, X-20 by the
multi-document line union (DP-02). X-29 is resolved: the parser deploys to
`credit-card-scraper-ht` / `me-central1` (repo `ledger`), the workflow's only region. X-25 is fixed
in parse-v1 except the `country_code` format. Open items: [BACKLOG.md](BACKLOG.md).

**Later updates (2026-10-09, Edge + CI pass):** X-16 is fixed (`supabase/functions/.env.example`, names only, with a guard test). X-26 is fixed (`deno check --frozen` in the `edge` job; `ios-build.yml` compiles the app and share extension weekly and on app changes; golden parity in CI stays open as SRV-24). X-32 is decided: Vercel Preview deployments are off for `apps/web` (PRODUCTION §4; a dashboard action). `deploy-parser.yml` is WIF-only now that the `GCP_SA_KEY` repo secret is deleted.

**Database P2/P3 pass (2026-10-09):** X-10 decided (leave production's `rls_auto_enable()`;
PRODUCTION §2.3); X-23 fixed (`legacy.*` table and sequence grants revoked from `anon` /
`authenticated`, `20261009000500`); X-24 fixed with DP-19; X-33 DB part fixed
(`transactions.fx_rate` null for AED, a statement rate that rounds to 0 is stored as unknown,
`…0100`; `amount_drift` stays reserved). Not changed: the `concat_ws` line key, because changing
`line_key` would re-key every stored line and break re-parse matching of existing evidence (two
values can only collide if a null shifts a field into a neighbour of a different type). The iOS
`CodingKeys` nit is for the iOS pass.

**Parser pass (2026-10-08):** X-17 is fixed: the parser's password list and the EIB and Mashreq
parsers use `EIB_PDF_PASSWORD` / `MASHREQ_PDF_PASSWORD`; the worker already sent them. X-25 is
fully fixed: `country_code` is ISO 3166-1 alpha-2 or null. X-33's parser nits are fixed (`fx_rate`
`"1"` for every AED line, null below 1e-8); the line-key and iOS nits remain (BACKLOG X-33r).
