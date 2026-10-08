# Project Rules — Bank Ledger

Bank Ledger is a personal credit-card finance system: a Supabase backend (Postgres + Edge Functions), a Python statement parser on Cloud Run, a React web app, a SwiftUI iPhone app, and a local Playwright scraper. Code identifiers keep the `ledger` name (`@ledger/*`, `LedgerKit`, function and Sentry project names); only prose and UI say "Bank Ledger".

Every rule below exists because the codebase once had several coexisting variants of a convention and the wrong one got copied. Copy THESE patterns, not a neighbouring file's. When you touch code that predates a rule, migrate it opportunistically.

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

## 1. Database (Supabase Postgres)

1. **Identifiers are codes.** Every PK is `<x>_code text default public.gen_code('<x>')` (prefix + 26-char ULID) with a CHECK on its shape. FKs reference codes. Never numeric ids. Natural codes only for reference data (`bank_code = 'FAB'`, currencies). Treat codes as opaque strings everywhere.
2. **Statuses are `text` + `CHECK (col in (...))`.** No native enums: Postgres can't drop enum values.
3. **Money is `numeric(14,2)`; FX rates are `numeric(18,8)`.** Never float, in SQL, TypeScript or Swift. Money crosses the wire as a decimal string.
4. **Time is `timestamptz`.** Business dates are calendar dates in `Asia/Dubai` (`public.dubai_date()`).
5. **RLS on every table**, with policies built on `authz.my_profile_codes()` / `authz.my_owned_profile_codes()` written as `profile_code = any ((select authz.my_profile_codes())::text[])`. Every table carries `profile_code`, even child tables. A pgTAP guard (`supabase/tests/01_rls.test.sql`) fails the build otherwise.
6. **Never `REVOKE EXECUTE` on a function.** On Supabase Postgres 17.6.1.104, calling a function you lack EXECUTE on segfaults the server. Guard in the body instead: `perform private.assert_service_role();` (Edge Function–only RPCs) or `perform private.assert_member(p_profile_code, need_owner);` (user RPCs). Internals live in the `private` schema, which client roles cannot use at all. This is enforced by a pgTAP guard.
7. **Every `SECURITY DEFINER` function sets `search_path = ''`** and fully qualifies names. Views are `security_invoker = true`. Both are enforced by guards.
8. **Migrations are append-only**: `supabase migration new <name>`. Verify with `supabase db reset && supabase test db` before committing. Never edit a migration that has reached production.
9. **Content migrations are guarded** so they cannot fight user edits: insert only when absent, update only rows still holding the exact old value.
10. **Evidence is immutable.** Statement lines and SMS are never updated in place beyond `is_current`/`superseded_at`/parse fields. Transaction facts are *derived* from evidence by `private.refresh_transaction()`. Only user fields (`manual_category_code`, `notes`, `exclude_from_spend`) are edited directly.
11. **Categorisation precedence is structural**: `effective_category_code` is a generated column (manual > merchant manual > rule > LLM). Background recompute writes only `rule_*` / `merchant_*` columns.
12. **One definition of spend**: `public.v_spend`. Analytics RPCs build on it and never re-derive spend.

## 2. Contracts

1. **Types are generated, never hand-written.** After any schema change run `pnpm db:types` in the same commit. CI fails on drift (`pnpm db:types:check`).
2. **Money and analytics are computed server-side** (SQL RPCs). Clients render what the API returns. A client-side formula mirroring a server one is a bug.
3. The parser ⇄ worker JSON is versioned (`docs/contracts/parse-v1.md`). Change the doc, the pydantic model and the SQL ingest together.

## 3. Edge Functions

1. Every function's `index.ts` wraps its handler with `withSentry(name, handler)` from `_shared/sentry.ts`. A `deno test` guard enforces it.
2. Callers are authenticated inside the function: a user JWT (`_shared/auth.ts`), a profile service token (`authenticate_service_token` RPC), or `x-cron-secret` for pg_cron. Functions that accept non-JWT callers set `verify_jwt = false` in `config.toml`.
3. Use the service-role client only after authenticating the caller. Pass `profile_code` explicitly to RPCs.

## 4. Web (`apps/web`)

1. **One data layer**: supabase-js + TanStack Query hooks in `src/data/`. No raw `fetch` to the backend in components.
2. **Tokens are the only source of colour.** Use Tailwind classes or `var(--color-*)` / `var(--chart-*)`. No hex literals in components; a vitest guard enforces it.
3. Every list and chart has loading, empty and failed states. An empty state is a claim, so make it only when the data proves it.
4. Category colours come from `category.color_token`, so a category looks the same on every chart.
5. Pagination: one default page size of 100, with options 100/200/500/1000/2000. Never hard-code a page size elsewhere.
6. Every frontend change ships with tests for its pure logic (formatters, query-param codecs, transforms). Don't test rendering unless needed.

## 5. iOS (`apps/ios`)

1. Decisions live in `LedgerKit` (pure, `swift test`-able). Views hold layout only. If you are writing an `if` about business rules in a View, move it into LedgerKit.
2. Files are ≤ ~350 lines, one screen or concern each.
3. Money is `Decimal` parsed from strings; never `Double`. Date formatters pin `en_US_POSIX` and `Asia/Dubai`.
4. `Theme/Tokens.swift` is generated from `packages/tokens`. Don't edit it by hand.
5. The SMS App Intent drops OTPs and non-credit-card messages on the device. Never log SMS bodies.

## 6. Observability (Sentry)

Every runtime initialises Sentry through its shared helper: Edge `_shared/sentry.ts`, parser `ccs_parser/sentry.py`, web `src/lib/sentry.ts`, iOS `LedgerKit/Telemetry`. `sendDefaultPii` is off. Scrub SMS bodies, passwords, tokens, `Authorization` and `X-Profile-Key` headers. Tag only opaque codes. Each scrubber has a unit test.

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

## 9. Git

Commit after every coherent change, one logical change per commit. Every commit is authored exactly:
```
git commit --author="Hussain Abbasi <h_abbasi97@hotmail.com>" -m "..."
```
No variations and no `Co-Authored-By` trailer of any kind.

## 10. Testing and verification

- Backend: `supabase db reset && supabase test db`. Add a pgTAP case for every ingest, matching, categorisation or RLS change.
- Use `127.0.0.1`, not `localhost`, when curling local services (e.g. `curl -s http://127.0.0.1:54321/functions/v1/...`).
- Python: activate the service's `.venv` and install its `requirements.txt` first.
- Never call a change done on the strength of tests alone when it can be run. Run it and look at it.

## 11. Production data

The production project is Supabase `cc-statement-scraper` (ref `<project-ref>`). Never push migrations, deploy functions or run writes against it without explicit confirmation in chat. Historical data must never be lost: the legacy schema is kept until v2 parity is signed off.
