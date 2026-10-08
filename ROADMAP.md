# Roadmap — Ledger v2

## Done (branch `ledger-v2`)

| Area | Delivered |
|---|---|
| Supabase schema and logic | Tenancy with `authz` RLS and in-body RPC guards; documents, statements and immutable statement lines; data-driven SMS templates; canonical transactions with evidence links; deterministic scored matcher (ties, FX, reversals, re-ingest diffing, SIB history extracts); reconciliation; dynamic categorisation with structural manual precedence; `v_spend` and analytics RPCs; budgets, recurring and insights; pgmq queues, Vault and pg_cron; Realtime. pgTAP suites cover RLS guards, ledger, legacy import, SMS templates, FX and web follow-ups. |
| Edge Functions | `statements-upload`, `sms-ingest`, `worker` (parse, LLM categorise, SMS fallback), `gmail-push`, `gmail-watch-renew`, `outlook-poll`, `ops-monitor`, `fx-rates`; shared auth and Sentry; deno tests including the `withSentry` guard. |
| Parser | Stateless Cloud Run `/parse` (contract parse-v1) reusing the legacy parsers, with totals, `fx_rate`, legacy fingerprints and golden parity tests. |
| SMS | 25 real templates (ADCB, FAB, ENBD, SIB) including known non-transaction alerts; daily FX fallback for pending foreign-currency SMS. |
| Web | New `apps/web`: Overview, Activity, Insights, Budgets, Cards & Statements, Review, Rules, Settings; tokens-driven earthy theme; Realtime; Sentry. |
| iOS | SwiftUI app + LedgerKit: Overview, Activity, Insights, Statements, Settings; `LogBankSMSIntent` with App Group outbox; "Add to Ledger" share extension; TestFlight script. |
| Scraper | Configurable upload target and path, per-bank failure isolation, `upload-pending`. |
| Cutover tooling | `private.import_legacy_metadata`, legacy category choices, parity report, `scripts/migrate_legacy.py`, pending invites. |
| CI/CD | Path-filtered CI (supabase, edge, parser, web, ios, scraper) and manual deploy workflows for Supabase and the parser. |

## Next

### 1. Cutover (blocking)
- [ ] Add `apps/web/vercel.json` with an SPA rewrite before switching the production domain
      (PRODUCTION.md §4).
- [ ] Fix `scripts/migrate_legacy.py --step secrets`: it emits `GOOGLE_OAUTH_CLIENT_*`, but
      the functions read `GMAIL_OAUTH_CLIENT_*`.
- [ ] Upgrade Supabase Postgres off 17.6.1.104 and re-test the `REVOKE EXECUTE` segfault.
- [ ] Run the cutover runbook (PRODUCTION.md §10), sign off parity, run old and new side by
      side.
- [ ] After 30 days: decommission Render, GCS, the Cloud Run Gmail relay and its scheduler, the
      MS GitHub Actions cron and the legacy Vercel project; delete `backend/`, `frontend/`,
      legacy Dockerfiles, workflows and docs; unschedule `ledger-legacy-choices`.

### 2. Observability follow-ups
- [ ] Set the agreed Sentry tags:
  - [ ] `service=edge` in `_shared/sentry.ts` and `service=parser` in `ccs_parser/sentry.py`
  - [ ] `app=web` in `apps/web/src/lib/sentry.ts` and `app=ios` in LedgerKit `Telemetry`
  - [ ] change the default project names (`ledger-web`, `ledger-ios`) to `ledger-apps` in
        `vite.config.ts`, `.env.example`, `publish-build.sh` and the iOS README
- [ ] Add a web debug trigger for verifying Sentry outside production.

### 3. Smart features
- [ ] Turn on LLM categorisation and the SMS fallback by setting `ANTHROPIC_API_KEY` (queues
      fill until then). Review the first suggestion batches.
- [ ] Promote accepted LLM suggestions to exact rules from the Review inbox.

### 4. SMS capture
- [ ] Verify the Shortcuts "Message contains …" automation on real devices: locked phone,
      alphanumeric senders, duplicate fires, and how sender and body reach the intent.
- [ ] SIB declined-transaction template from a real sample (the current one is inferred).
- [ ] Templates for EIB and Mashreq once real alerts are captured.

### 5. iOS
- [ ] Sign in with Apple (currently stubbed behind `SessionStore.appleSignInEnabled`).
- [ ] Home-screen and Lock-screen widgets (month spend, pace, pending SMS).

### 6. Scraper
- [ ] Per-profile service tokens. v2 tokens belong to one profile, but the scraper reads a
      single `CCS_SCRAPER_API_TOKEN`.
- [ ] Backlog: dedupe adapter helpers into `shared.py` (fixed sleeps, broad excepts).

### 7. Later
- [ ] Current-account and debit-card statements (today only credit cards; debit SMS is stored
      as `ignored`).
- [ ] Supabase log drains (Pro plan) if DB-side observability needs more than `ops-monitor`.
