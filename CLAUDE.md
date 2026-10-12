# Project Rules — Bank Ledger

Bank Ledger is a personal credit-card finance system: a Supabase backend (Postgres + Edge Functions), a Python statement parser on Cloud Run, a React web app, a SwiftUI iPhone app, and a local Playwright scraper. Code identifiers keep the `ledger` name (`@ledger/*`, `LedgerKit`, function and Sentry project names); only prose and UI say "Bank Ledger".

Every rule below exists because the codebase once had several coexisting variants of a convention and the wrong one got copied. Copy THESE patterns, not a neighbouring file's. When you touch code that predates a rule, migrate it opportunistically.

**At session start:** skim the index of [`tasks/lessons.md`](tasks/lessons.md). Area detail lives next to the code and loads when you work there: [`supabase/CLAUDE.md`](supabase/CLAUDE.md) (database, Edge Functions) and [`apps/ios/CLAUDE.md`](apps/ios/CLAUDE.md) (iPhone app, TestFlight). Code comments cite sections of this file (`CLAUDE.md §3.1`): add new sections at the end, never renumber.

## 0. Layout

| Path | What | Run / test |
|---|---|---|
| `supabase/migrations/` | Schema + all business logic (SQL functions, triggers, RLS, pg_cron, pgmq) | `supabase db reset` → `supabase test db` |
| `supabase/functions/` | Deno Edge Functions (HTTP ingress, queue worker, LLM, email) | `cd supabase/functions && deno test -A .` |
| `services/parser/` | Stateless Python `/parse` on Cloud Run (contract: `docs/contracts/parse-v1.md`) | `cd services/parser && .venv/bin/pytest -q` |
| `apps/web/` | React web app (Vite) | `pnpm web:test`, `pnpm web:build` |
| `apps/ios/` | SwiftUI iPhone app + `LedgerKit` Swift package | `cd apps/ios/LedgerKit && swift test` |
| `packages/tokens/` | Design tokens → CSS + Swift | `pnpm tokens` |
| `assets/brand/` | Mark source SVG; every web icon and the iOS 1024 icon render from it | `pnpm brand:icons` (`:check` in CI-style runs) |
| `packages/db-types/` | Generated DB types | `pnpm db:types` |
| `scraper/` | Local-only bank scraper CLI (architecture frozen) | `cd scraper && .venv/bin/pytest -q` |
| `scripts/` | Git hooks, CI helpers, production secret helpers (`cutover/`) | `pnpm check` (CI mirror) |
| `.claude/` | `settings.json` + `hooks/guard.py`, the enforced form of §9 and §11 | `python3 .claude/hooks/guard_test.py` |
| `tasks/` | `lessons.md` (read at session start), `todo.md` (plans) | — |

## 1. Database (Supabase Postgres)

1. **Identifiers are codes.** Every PK is `<x>_code text default public.gen_code('<x>')` (prefix + 26-char ULID) with a CHECK on its shape. FKs reference codes. Never numeric ids. Natural codes only for reference data (`bank_code = 'FAB'`, currencies). Treat codes as opaque strings everywhere.
2. **Statuses are `text` + `CHECK (col in (...))`.** No native enums: Postgres can't drop enum values.
3. **Money is `numeric(14,2)`; FX rates are `numeric(18,8)`.** Never float, in SQL, TypeScript or Swift. Money crosses the wire as a decimal string.
4. **Time is `timestamptz`.** Business dates are calendar dates in `Asia/Dubai` (`public.dubai_date()`).
5. **RLS on every table**, with policies built on `authz.my_profile_codes()` / `authz.my_owned_profile_codes()` written exactly as `profile_code = any ((select authz.my_profile_codes())::text[])`: the `select` makes it an initplan (once per statement), the `::text[]` cast makes `any` take an array rather than a subquery. Every table carries `profile_code`, even child tables. A pgTAP guard (`supabase/tests/01_rls.test.sql`) fails the build otherwise.
6. **Never `REVOKE EXECUTE` on a function.** On Supabase Postgres 17.6.1.104, calling a function you lack EXECUTE on segfaults the server. Guard in the body instead: `perform private.assert_service_role();` (Edge Function–only RPCs) or `perform private.assert_member(p_profile_code, need_owner);` (user RPCs). Internals live in the `private` schema, which client roles cannot use at all. This is enforced by a pgTAP guard.
7. **Every `SECURITY DEFINER` function sets `search_path = ''`** and fully qualifies names. Views are `security_invoker = true`. Both are enforced by guards.
8. **Migrations are append-only**: `supabase migration new <name>`. Verify with `supabase db reset && supabase test db` before committing. Never edit a migration that is on `origin/main` (hooks and CI refuse it): fix forward.
9. **Content migrations are guarded** so they cannot fight user edits: insert only when absent, update only rows still holding the exact old value.
10. **Evidence is immutable.** Statement lines and SMS are never updated in place beyond `is_current`/`superseded_at`/parse fields. Transaction facts are *derived* from evidence by `private.refresh_transaction()`. Only user fields (`manual_category_code`, `notes`, `exclude_from_spend`) are edited directly.
11. **Categorisation precedence is structural**: `effective_category_code` is a generated column (manual > merchant manual > rule > LLM). Background recompute writes only `rule_*` / `merchant_*` columns.
12. **One definition of spend**: `public.v_spend`. Analytics RPCs build on it and never re-derive spend.
13. **Grant clients exactly what they need**, per column for updates. Production has older default privileges than local (audit FV-01), so a grant left to defaults is wide open there. Change a client grant ⇒ update `supabase/tests/11_privileges.test.sql` in the same commit.

## 2. Contracts

1. **Types are generated, never hand-written.** After any schema change run `pnpm db:types` in the same commit. CI fails on drift (`pnpm db:types:check`).
2. **Money and analytics are computed server-side** (SQL RPCs). Clients render what the API returns. A client-side formula mirroring a server one is a bug.
3. The parser ⇄ worker JSON is versioned (`docs/contracts/parse-v1.md`). Change the doc, the pydantic model and the SQL ingest together.

## 3. Edge Functions

1. Every function's `index.ts` wraps its handler with `withSentry(name, handler)` from `_shared/sentry.ts`. A `deno test` guard enforces it.
2. Callers are authenticated inside the function: a user JWT (`_shared/auth.ts`), a profile service token (`authenticate_service_token` RPC), or `x-cron-secret` for pg_cron. Functions that accept non-JWT callers set `verify_jwt = false` in `config.toml`.
3. Use the service-role client only after authenticating the caller. Pass `profile_code` explicitly to RPCs.
4. API keys come from `_shared/supabase.ts`: the secret key from the runtime-injected `SUPABASE_SECRET_KEYS`, never by reading `SUPABASE_SERVICE_ROLE_KEY` directly.

## 4. Web (`apps/web`)

1. **One data layer**: supabase-js + TanStack Query hooks in `src/data/`. No raw `fetch` to the backend in components.
2. **Tokens are the only source of colour.** Use Tailwind classes or `var(--color-*)` / `var(--chart-*)`. No hex literals in components; a vitest guard enforces it.
3. Every list and chart has loading, empty and failed states. An empty state is a claim, so make it only when the data proves it.
4. Category colours come from `category.color_token`, so a category looks the same on every chart.
5. Pagination: one default page size of 100, with options 100/200/500/1000/2000. Never hard-code a page size elsewhere.
6. Every frontend change ships with tests for its pure logic (formatters, query-param codecs, transforms). Don't test rendering unless needed.

## 5. iOS (`apps/ios`) — detail in [`apps/ios/CLAUDE.md`](apps/ios/CLAUDE.md)

1. Decisions live in `LedgerKit` (pure, `swift test`-able). Views hold layout only. If you are writing an `if` about business rules in a View, move it into LedgerKit.
2. Files are ≤ ~350 lines, one screen or concern each.
3. Money is `Decimal` parsed from strings; never `Double`. Date formatters pin `en_US_POSIX` and `Asia/Dubai`.
4. `Theme/Tokens.swift` is generated from `packages/tokens`. Don't edit it by hand.
5. The SMS App Intent drops only OTPs (and empty input) on the device; the server classifies everything else (`process_sms`). Never log SMS bodies.
6. App Intent and App Shortcut text never says "iPhone" (or another Apple trademark): App Store processing rejects the build (ITMS-90626).

## 6. Observability (Sentry)

Every runtime initialises Sentry through its shared helper: Edge `_shared/sentry.ts`, parser `ccs_parser/sentry.py`, web `src/lib/sentry.ts`, iOS `LedgerKit/Telemetry`. `sendDefaultPii` is off. Scrub SMS bodies, passwords, tokens, `Authorization` and `X-Profile-Key` headers. Tag only opaque codes. Each scrubber has a unit test.

Sentry is **off** unless there is a DSN and a deployed environment: `''`, `local`, `development` and `test` never report (iOS: also `dev`, `debug` and any Debug build). Keep it that way, with a test, in every new entry point. The projects are `credit-card-ledger-backend` (Edge `service=edge`, parser `service=parser`) and `credit-card-ledger-apps` (web `app=web`, iOS `app=ios`); `ledger-apps`/`ledger-backend` do not exist.

## 7. Scraper

The scraper architecture stays as it is (local-only Playwright). Every system-initiated wait in a bank adapter **must** have a `logger.info(...)` immediately before it, in the form `"{BANK}: waiting {X}ms — {reason}"`:
- `time.sleep`, `page.expect_download`, `page.wait_for_event("download")`: always.
- `page.wait_for_timeout`: when ≥ 700ms, and always inside auth-polling loops.
- `locator.wait_for(timeout=…)`: when ≥ 4000ms.

## 8. Docs

After any feature, fix or notable change, update in the same commit:
- **CHANGELOG.md**: entries under **Backend (Supabase)**, **Parser**, **Web**, **iOS**, **Scraper**, **Docs** as applicable.
- **ARCHITECTURE.md**: when services, schemas, auth, queues or deployment change.
- **PRODUCTION.md**: when env vars, secrets, Vault entries, cron jobs, functions or build/deploy steps change.
- **README.md**: when setup, structure, commands, env vars, endpoints or screens change.
- **docs/audit/BACKLOG.md**: remove a row when its fix lands, and mark it in that report's Fix status.
- **A new env var** goes in that runtime's example file (`apps/web/.env.example`, `services/parser/.env.example`, `scraper/.env.example`, `apps/ios/Config/Secrets.example.xcconfig`), README's env table and, for production, PRODUCTION.md's table (§2.5 for Edge Functions).

## 9. Git

Commit after every coherent change, one logical change per commit. Every commit is authored exactly:
```
git commit --author="Hussain Abbasi <h_abbasi97@hotmail.com>" -m "..."
```
No variations and no `Co-Authored-By` trailer of any kind.

1. **Stage explicit paths only**: `git add path/one path/two`. Never `git add -A`, `git add .`, `git add -u` or `git commit -a`. Read `git diff --cached --stat` before committing and account for every path; an unrelated staged deletion of `backend/` once rode into an iOS commit (`f530ca1`). Other sessions and worktrees share this repo and its stash: never touch work that isn't yours, and never use a bare `git stash`.
2. **Hooks are the local CI** (`pnpm hooks:install` once per clone): pre-commit (secrets guard, append-only migrations, linters), pre-push (`pnpm check`, the CI mirror; stages the TestFlight build on `main`). Don't bypass them (`--no-verify`, `SKIP_PRE_PUSH=1`, `SKIP_RELEASE=1`) unless the user asks.
3. **`gh`** for `hussu97/cc-statement-scraper` runs as `GH_TOKEN=$(gh auth token --user hussu97) gh …`; the active account can't see the repo. Never print the token.
4. **New paths named like `data`, `build`, `dist`, `logs`, `tmp` or `.env.example`**: run `git check-ignore -v <path>`. The root `data/` rule once hid `apps/web/src/data/`, and the trailing `.env*` re-ignores new `.env.example` files.
5. **Branches and PRs**: `git fetch` and check the branch is current before designing on it. One concern per PR; the description says what changed, how it was verified and what deploys on merge (§11.2).

## 10. Testing and verification

- Backend: `supabase db reset && supabase test db`, always from a fresh reset (`migration up` matches versions, not contents, and pgTAP assumes a pristine DB). Add a pgTAP case for every ingest, matching, categorisation or RLS change.
- Use `127.0.0.1`, not `localhost`, when curling local services (e.g. `curl -s http://127.0.0.1:54321/functions/v1/...`).
- Python: environments are made with `uv` (`uv venv --python 3.12 .venv`, then `uv pip sync` / `uv pip install --python .venv/bin/python …`, as in each service's README); never `pip install` into the system Python.
- `pnpm check` runs exactly what CI runs for the areas you changed (`pnpm check:plan` to preview). Run it before you say done.
- Never call a change done on the strength of tests alone when it can be run. Run it and look at it: the web app in a browser, iOS in the simulator, a function with `curl` against the local stack. Report which checks ran and which were skipped.

## 11. Production, deploys and secrets

The production project is Supabase `cc-statement-scraper` (ref `nkmylznisjcnmqbxosey`); the parser is Cloud Run `ccs-parser` (`credit-card-scraper-ht`, `me-central1`); the web app is Vercel `cc-statement-scraper`; iOS ships through TestFlight. Production data is irreplaceable.

1. **Every production action needs an explicit yes in chat, each time**: `supabase db push`, `functions deploy`, `secrets set`, `config push` (pushes the whole `config.toml`, no dry run, no prompt off a TTY; prod-only values belong in `[remotes.production]`, see `supabase/CLAUDE.md`), Vault writes, any write through `--linked` or the prod DB URL, `scripts/cutover/*`, `gcloud run deploy`/traffic changes, Secret Manager, Vercel deploys and env, `gh secret`/`variable set`, `gh workflow run deploy-*`, TestFlight uploads. Read-only inspection (`supabase migration list --linked`, `db push --dry-run`) is fine. The Supabase MCP connector reaches this project when it is connected to the `cc-statement-scraper` organisation (check with `list_projects`): read-only `execute_sql` is inspection; anything that writes is a production action. Otherwise use the CLI.
2. **A push or merge to `main` is a production deploy**, with no reviewer gate: `deploy-supabase` (migrations + functions), `deploy-parser`, Vercel Production, and a TestFlight build when the iOS app changed (`docs/ci-cd.md`). Ask before pushing to `main`; say what will deploy.
3. **Historical data is never lost.** The `legacy` schema is the read-only record of v1: never write, drop or truncate it, and keep the migrations that reference it. The main checkout's untracked `backend/` (private PDFs, backups, logs under `backend/data`, `backend/logs`) and root `data/` are never deleted.
4. **Secrets live only in gitignored files**: `.env.cutover`, `supabase/functions/.env` and `.env.production`, `services/parser/.env` and `.env.production`, `apps/web/.env.local` and `.env.production.local`, `apps/ios/Config/Secrets.xcconfig` and `Secrets.Release.xcconfig`, `scraper/.env` (and any other `.env*`). Never print, `cat`, echo, `Read` or commit them; check shape, not value (`cut -d= -f1 FILE`, `grep -c '^KEY=' FILE`). Push them with the file-based or prompted tools (`scripts/cutover/set-edge-secrets.sh`, `gh secret set NAME` without `--body`). A leaked value gets rotated: tell the user.
5. **Keys**: web, iOS and the scraper use only the publishable key (`sb_publishable_…`), and each refuses an `sb_secret_…` key. Edge Functions use the runtime-injected `SUPABASE_SECRET_KEYS` (§3.4). The secret key exists elsewhere only in `.env.cutover`, for admin scripts.

## 12. Workflow

1. **Plan first** for anything with 3+ steps or an architectural choice: plan mode, or checkable items in `tasks/todo.md` with a short review when done. Check in before implementing when the plan touches the schema, a contract or production. If it goes sideways, stop and re-plan.
2. **Use subagents** for research, exploration and parallel per-area work, one task each, to keep the main context clean. A subagent follows this file too: tell it the commit, staging and production rules when it may commit.
3. **Self-improvement loop**: after any correction from the user, or a bug that cost a debugging session, add an entry to `tasks/lessons.md` (title = the lesson; what went wrong; the rule; what enforces it).
4. **Enforce, don't remember**: when a rule is mechanically checkable, add a guard (§13) in the same change; a rule that bites twice must get one.
5. **Root causes, minimal changes**: no temporary fixes; for non-trivial work, ask whether there is a more elegant way before presenting it. Given a bug report, fix it from the evidence (Sentry, function logs, failing tests) without hand-holding.
6. **A rule that the codebase contradicts everywhere is stale**: resolve the contradiction (fix the rule or the code) instead of silently following either.

## 13. Guards (enforced, not remembered)

| Rule | Guard |
|---|---|
| RLS + policy on every table; `search_path` on SECURITY DEFINER; `security_invoker` views; no revoked EXECUTE (§1.5–1.7) | `supabase/tests/01_rls.test.sql` |
| Exact client grants (§1.13) | `supabase/tests/11_privileges.test.sql` |
| Migrations append-only (§1.8) | pre-commit, pre-push, `ci.yml` (`scripts/ci/check-migrations.sh`), `deploy-supabase` history check |
| Generated DB types (§2.1) | `pnpm db:types:check` (CI, pre-push) |
| `withSentry` + `verify_jwt = false` (§3.1–3.2) | `supabase/functions/_tests/guard_test.ts` |
| Sentry off locally; scrubbers (§6) | `sentry_local_test.ts`, `sentry_scrub_test.ts`, web `sentry.test.ts` / `sentry-scrub.test.ts`, parser `test_sentry_scrubber.py`, iOS `AuditFixTests` / `TelemetryScrubberTests` |
| One web data layer (§4.1) | ESLint `no-restricted-imports` (`apps/web/eslint.config.js`) |
| No hex colours (§4.2) | `apps/web/src/test/no-hex-colors.test.ts` |
| Publishable key only in clients (§11.5) | `supabase-key.test.ts`, iOS `LedgerConfig`, `api_keys_test.ts` |
| Generated tokens and icons (§5.4) | `pnpm tokens:check`, `pnpm brand:icons:check` |
| iOS text never uses the `subtle` colour; iOS contrast pairs | LedgerKit `PaletteUsageTests`, `packages/tokens` contrast test |
| One SMS OTP pattern on the phone and the server (§5.5) | `supabase/tests/38_sms_otp_filter.test.sql` + LedgerKit `SMSOTPParityTests` (shared fixture) |
| No secret files committed (§11.4) | pre-commit secrets guard |
| Commit author, no co-author trailer (§9) | `prepare-commit-msg`, `commit-msg`, `.claude/hooks/guard.py` |
| Explicit staging, production confirmation, no secret printing, `legacy`/`backend/` kept (§9, §11) | `.claude/hooks/guard.py` (Claude Code PreToolUse), tested by `guard_test.py` |
