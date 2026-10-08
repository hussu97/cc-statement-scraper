# Roadmap — Bank Ledger (v2)

## Done (branch `ledger-v2`)

| Area | Delivered |
|---|---|
| Supabase schema and logic | Tenancy with `authz` RLS and in-body RPC guards; documents, statements and immutable statement lines; data-driven SMS templates; canonical transactions with evidence links; deterministic scored matcher (ties, FX, reversals, re-ingest diffing, SIB history extracts); reconciliation; dynamic categorisation with structural manual precedence; `v_spend` and analytics RPCs; budgets, recurring and insights; pgmq queues, Vault and pg_cron; Realtime. pgTAP suites cover RLS guards, ledger, legacy import, SMS templates, FX and web follow-ups. |
| Edge Functions | `statements-upload`, `sms-ingest`, `worker` (parse, LLM categorise, SMS fallback), `gmail-push`, `gmail-watch-renew`, `outlook-poll`, `ops-monitor`, `fx-rates`; shared auth and Sentry; deno tests including the `withSentry` guard. |
| Parser | Stateless Cloud Run `/parse` (contract parse-v1) reusing the legacy parsers, with totals, `fx_rate`, legacy fingerprints and golden parity tests. |
| SMS | 25 real templates (ADCB, FAB, ENBD, SIB) including known non-transaction alerts; daily FX fallback for pending foreign-currency SMS. |
| Web | New `apps/web`: Overview, Activity, Insights, Budgets, Cards & Statements, Review, Rules, Settings; tokens-driven earthy theme; Realtime; Sentry. |
| iOS | SwiftUI app + LedgerKit: Overview, Activity, Insights, Statements, Settings; `LogBankSMSIntent` with App Group outbox; "Add to Bank Ledger" share extension; TestFlight script. |
| Scraper | Configurable upload target and path, per-bank failure isolation, `upload-pending`. |
| Cutover tooling | `private.import_legacy_metadata`, legacy category choices, parity report, the one-off `scripts/migrate_legacy.py` (removed after the cutover), pending invites. |
| CI/CD | Path-filtered CI (supabase, edge, parser, web, ios, scraper) and manual deploy workflows for Supabase and the parser. |
| Pre-cutover audit | Six audits (`docs/audit/01`–`06`) and their P0/P1 fixes: structural tenant integrity (composite FKs), per-profile ingest lock, multi-document line union (no data loss from companion PDFs or history windows), per-message SMS ingest, sign-ups off, parser resource limits and output validation, ENBD year and FAB amount fixes, code-based worker retry classification, scraper upload batching, cutover target guard, iOS outbox that can't wedge, "SMS go to" ledger, iOS Review, AA contrast tokens. Everything not yet fixed is in [docs/audit/BACKLOG.md](docs/audit/BACKLOG.md). |

## Next

### 1. Cutover (blocking)
- [x] Add `apps/web/vercel.json` (SPA rewrite, asset caching, CSP and security headers).
- [x] Map legacy OAuth settings to the names the functions read in the cutover script's
      secrets step. In practice the legacy DB holds only the **MS**
      client (`MS_OAUTH_CLIENT_*`); the Gmail client was never in `runtime_settings`.
- [ ] Copy the Gmail OAuth client from Render (`CCS_PLATFORM_EMAIL_GMAIL_CLIENT_ID/SECRET`) into
      `GMAIL_OAUTH_CLIENT_ID/SECRET` before Render is deleted. It must be the same client that
      issued the Gmail refresh token (PRODUCTION.md §5.4).
- [x] Single-source production secrets: `scripts/cutover/set-edge-secrets.sh` (refuses
      placeholders) and `scripts/cutover/set-vault-secrets.sql`, so `CRON_SECRET` and Vault
      `edge_cron_secret` always match.
- [x] Guard legacy workflows behind `LEGACY_DEPLOYS_ENABLED` and the production deploy
      workflows to `main`; cutover disable list in PRODUCTION.md §10 step 1.
- [ ] Merge `ledger-v2` into `main` before the cutover day (after setting
      `LEGACY_DEPLOYS_ENABLED=true`), so the manual deploy workflows can be dispatched.
- [ ] Dashboard settings (PRODUCTION.md §2.7): sign-ups off before the day, API max rows 2000
      at step 4.
- [x] Purge `cron.job_run_details` older than 7 days with a daily pg_cron job
      (`ledger-cron-history-purge`, migration `20261008001800`).
- [ ] Rotate the Anthropic API key and the Sentry org auth token that were exposed in chat
      transcripts and logs (PRODUCTION.md §10, Before the day).
- [ ] Re-run the full legacy rehearsal with the final code on a fresh prod backup and reach
      `legacy_lines_missing = 0` for every bank (PRODUCTION.md §10).
- [ ] Invite both members through Supabase Auth after the metadata step (sign-ups stay off).
- [ ] Upgrade Supabase Postgres off 17.6.1.104 and re-test the `REVOKE EXECUTE` segfault.
- [ ] Run the cutover runbook (PRODUCTION.md §10), sign off parity, run old and new side by
      side.
- [x] Remove the legacy code from the repo: `backend/`, `frontend/`, `deploy/`, legacy
      workflows, CI jobs and hook steps, `docs/operations/`, `docs/security/` and
      `scripts/migrate_legacy.py`. The `legacy` schema and its migrations stay.
- [ ] After 30 days: decommission Render, GCS, the Cloud Run Gmail relay and its scheduler and
      the legacy Vercel project; delete the `LEGACY_DEPLOYS_ENABLED` variable (PRODUCTION.md
      §10 step 12). (`ledger-legacy-choices` unschedules itself.)

### 2. Observability follow-ups
- [x] Set the agreed Sentry tags (`service=edge|parser`, `app=web|ios`) and default the web
      and iOS project names to `ledger-apps`.
- [ ] Add a web debug trigger for verifying Sentry outside production.

### 3. Smart features
- [ ] Turn on LLM categorisation and the SMS fallback by setting `ANTHROPIC_API_KEY` (queues
      fill until then). Review the first suggestion batches.
- [ ] Promote accepted LLM suggestions to exact rules from the Review inbox.

### 4. SMS capture
- [ ] Verify the single *Message contains "Card"* automation on real devices: locked phone,
      alphanumeric senders, how sender and body reach the intent, and whether "contains" is
      case-insensitive (the ENBD refund says "card").
- [ ] SIB declined-transaction template from a real sample (the current one is inferred).
- [ ] Templates for EIB and Mashreq once real alerts are captured.

### 5. iOS
- [ ] Sign in with Apple (currently stubbed behind `SessionStore.appleSignInEnabled`).
- [ ] Home-screen and Lock-screen widgets (month spend, pace, pending SMS).

### 6. Scraper
- [x] Per-profile service tokens: `<PROFILE>_CCS_SCRAPER_API_TOKEN`, falling back to the
      global `CCS_SCRAPER_API_TOKEN`.
- [ ] Backlog: dedupe adapter helpers into `shared.py` (fixed sleeps, broad excepts).

### 7. Audit backlog
- [ ] Work through [docs/audit/BACKLOG.md](docs/audit/BACKLOG.md): deferred P2/P3 findings and
      UX recommendations from the six audits, grouped by priority and area.

### 8. Later
- [ ] Current-account and debit-card statements (today only credit cards; debit SMS is stored
      as `ignored`).
- [ ] Supabase log drains (Pro plan) if DB-side observability needs more than `ops-monitor`.
