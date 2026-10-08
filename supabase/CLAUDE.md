# Supabase: database and Edge Functions

Detail for work under `supabase/`. The canon is the root [`CLAUDE.md`](../CLAUDE.md) §1–§3 and
§11; this file adds the how and the traps. Design: [ARCHITECTURE.md](../ARCHITECTURE.md);
operations and secrets: [PRODUCTION.md](../PRODUCTION.md) §2.

## Loop

```bash
supabase start                              # local stack (Docker)
supabase migration new <name>               # never hand-name or edit an applied file
supabase db reset && supabase test db       # always from a fresh reset
pnpm db:types                               # same commit as the schema change
cd supabase/functions && deno lint && deno fmt --check && deno test -A .
curl -s http://127.0.0.1:54321/functions/v1/<name> …   # 127.0.0.1, not localhost
```

`pnpm check` runs the same set the CI `supabase` and `edge` jobs run. pgTAP is skipped by the
pre-push hook (with a warning) when Docker or the stack is down; then run it yourself.

## Migrations

- **Append-only, and immutable once on `origin/main`.** Pre-commit, pre-push and CI refuse edits;
  `deploy-supabase` also fails if an applied migration's file differs from what production ran.
- **`supabase migration up` matches versions, not contents.** A stack that applied an older body
  keeps it (audit FV-04). Test from `supabase db reset`, not from a long-lived stack.
- **Production is not shaped like local.** Prod was created with Supabase's older default
  privileges (`GRANT ALL ON TABLES TO anon, authenticated`); the quarantine migration revokes them
  before any table exists. Grant clients exactly what they need, per column for updates, and
  update the matrix in `tests/11_privileges.test.sql` in the same commit (FV-01).
- **Destructive statements** (`DROP TABLE|SCHEMA|COLUMN`, `TRUNCATE`, `DELETE FROM`) stop a
  push-triggered deploy. They need a backup and a manual `allow_destructive` dispatch: a
  production action to ask about, not a flag to set.
- **Content migrations** (seed rules, categories, templates) are guarded: insert when absent,
  update only rows still holding the exact old value, so a user's edit makes them a no-op.
- `config.toml` is not deployed by any workflow. `max_rows` is 2000 to match the largest page
  size (audit X-07).

## `supabase config push` (production auth lives here)

`supabase config push` sends the **whole** `config.toml` to the remote project and does **not**
ask for confirmation when stdin is not a TTY; piping `n` does not stop it. It once overwrote
production auth (`site_url`, email confirmations, OTP length, MFA) with local values, which then
had to be restored by hand.

1. **There is no dry run.** Never run it to "preview a diff".
2. **Production-only values are pinned in `[remotes.production]`** at the end of
   `config.toml`. Any value that differs between local and prod goes there in the same commit as
   the change that introduces it; a value left only in the local sections will be pushed to prod.
3. **It is a production action**: explicit yes in chat first; run it from the repo root
   (`--workdir` from elsewhere silently picks up the cwd's config); afterwards verify with
   `GET /auth/v1/settings` on the production URL.

Auth facts that a push must not break:
- **Email sign-in is code-only.** The templates in `supabase/templates/` carry `{{ .Token }}`:
  no magic links, no passwords.
- **Passkeys** use `rp_id = <web-host>`, with the AASA file at
  `apps/web/public/.well-known/apple-app-site-association`. Changing `rp_id` strands every
  existing passkey.

## Functions, policies and grants

- Policies are copied, not composed:
  ```sql
  using (profile_code = any ((select authz.my_profile_codes())::text[]))
  with check (profile_code = any ((select authz.my_owned_profile_codes())::text[]))
  ```
  The `(select …)` is an initplan (evaluated once per statement); the `::text[]` cast makes
  `any` take the array instead of treating the subquery as a row set.
- No `REVOKE EXECUTE`, ever (PG 17.6.1.104 segfaults on the call). Service-only RPCs start with
  `perform private.assert_service_role();`, user RPCs with
  `perform private.assert_member(p_profile_code, need_owner);`.
- `SECURITY DEFINER` ⇒ `set search_path = ''` and schema-qualified names (`public.`, `private.`,
  `extensions.`, `auth.`). Views are `security_invoker = true`.
- New tables: `profile_code` column, RLS enabled, at least one policy, explicit grants. The
  guards in `tests/01_rls.test.sql` and `tests/11_privileges.test.sql` fail otherwise.
- Every ingest, matching, categorisation or RLS change gets a pgTAP case. Tenant isolation
  cases go in `tests/08_tenant_isolation.test.sql`.

## The `legacy` schema

The read-only record of v1 in production. Never write to it, drop it or change its grants
without an explicit decision in chat. The migrations that reference it (quarantine, legacy
import, parity report) are applied history and stay. pgTAP `03_legacy_import` mocks it with the
real `varchar`/enum types, because prod's column types differ from what a test would invent
(audit X-02).

## Edge Functions

- `index.ts` is `Deno.serve(withSentry("<name>", handler))`; authenticate the caller first
  (`_shared/auth.ts`, service token RPC, or `x-cron-secret`), then use the service client, and
  pass `profile_code` explicitly. Non-JWT callers ⇒ `verify_jwt = false` in `config.toml`.
- Keys come from `_shared/supabase.ts` (`resolveApiKey`): `SUPABASE_SECRET_KEYS` (runtime JSON,
  `default`) → `SB_SECRET_KEY` → legacy `SUPABASE_SERVICE_ROLE_KEY`. Never read the env vars
  directly, and never log which value was used, only its source name.
- `deno fmt --check` is blocking in CI and pre-push.
- Function secrets: the inventory is README's Edge table and PRODUCTION §2.5. Locally they live
  in `supabase/functions/.env`; production values in `supabase/functions/.env.production`, pushed
  only with `scripts/cutover/set-edge-secrets.sh` (refuses placeholders and local-only keys)
  after a yes in chat. Never `supabase secrets set --env-file` a file "as is" (audit X-01).
- Sentry: `SENTRY_ENVIRONMENT` unset or `local`/`development`/`test` never reports. Production
  events go to `credit-card-ledger-backend`, tagged `service=edge` and `function=<name>`.

## Reaching production

Read-only: `supabase migration list --linked`, `supabase db push --dry-run`,
`bash scripts/ci/check-migrations.sh remote linked`. Everything else (db push, functions deploy,
`config push`, secrets, Vault via `scripts/cutover/set-vault-secrets.sql`, SQL writes) is a production action
(root §11.1), and a push to `main` that touches `supabase/` deploys on its own (§11.2). The
Supabase MCP connector can't see this project; use the CLI.
