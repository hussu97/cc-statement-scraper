# Changelog

## Database audit backlog, P2 and P3 — 2026-10-09

### Backend (Supabase)

- **fix** `20261009000100_db_ledger_fixes.sql`:
  - An SMS held as `unknown_card` is re-processed when a statement registers its card, and its review resolves itself (`private.reprocess_waiting_sms`, called at the end of `ingest_parsed_document`, which now returns `sms_card_registered`) (DB-17r)
  - `overview`'s month-to-date base stops at the end of last month on the 29th–31st (`public.prev_month_to_date_end(p_month, p_today)`) (DB-18)
  - `resolve_merchant` reads before it writes; an existing merchant row is never rewritten (DB-19r)
  - `v_transactions.has_sms` / `has_statement` are scalar sub-queries on the evidence index, evaluated only for the returned page (DB-20)
  - `statement_lines (profile_code, currency_original, txn_date desc)` index for `estimate_fx`; `anomalies` uses window frames instead of two laterals per row, same output (DB-32r)
  - Declined alerts are stored `ignored` (existing rows migrated) (DB-34)
  - An SMS template date more than 7 days from `received_at` falls back to `received_at` and is kept as `parsed_fields.event_at_rejected` (DB-36)
  - Utilisation uses `greatest(closing_balance, 0)` in `overview` and `statement_cycles` (DB-39)
  - New transactions are inserted with their merchant and AED amount, so they are categorised once, not twice (DB-44)
  - `overview.pending_unpriced_count`: pending transactions with no AED amount yet (DB-45)
  - Ingest rejects a statement dated more than 31 days ahead with a permanent `22023` (DP-04r)
  - `transactions.fx_rate` is null for AED (backfilled); a statement `fx_rate` that rounds to 0 is stored as unknown instead of failing the ingest (X-33)
- **test** `13_db_ledger_fixes.test.sql`; `09` and `12` pin `ledger.test_today` for their fixed future dates
- **fix** `20261009000200_db_categorisation_and_jobs.sql`:
  - Seed rules `REST`, `NOON`, `LIME`, `HEALTH`, `BONUS` match whole words (regex), so `INTEREST`, `AFTERNOON`, `SUBLIME` no longer mis-categorise; existing profiles updated where the rule is still exactly as seeded (DB-24)
  - Cashback seeds `MURABAHA PROFIT` and `BONUS` require `direction = credit`: an Islamic-card finance charge is spend again (DP-09)
  - `nightly`, `enqueue_llm_categorize`, `recategorize_stale` and `reestimate_pending_fx` catch errors per profile (per transaction for the FX job) and log them to `private.job_errors` (30-day retention) (DB-25)
  - `generate_insights` produces `spend_pace`, `new_recurring`, `large_transaction` (from `anomalies`) and `review_backlog` (DB-29r)
  - `preview_rule(…, p_rule_code text default null)`: `would_change` follows `recategorize`'s full tie-break and leaves out the rule being edited (DB-31)
  - `public.merchant_category_skips` (`declined` / `rejected`): `apply_llm_suggestions(…, p_merchant_codes text[] default null)` records merchants the LLM declined for the current category set; `public.reject_merchant_suggestion(p_profile_code, p_merchant_code)` drops a suggestion for good; `enqueue_llm_categorize` skips both (DB-37, WEB-14 SQL side)
- **test** `14_db_categorisation_and_jobs.test.sql`; `11_privileges` matrix gains `merchant_category_skips` SELECT
- **fix** `20261009000300_db_sms_templates.sql`:
  - A template change re-processes messages only when the template is live and its pattern, priority, scope or activation changed; only messages its sender pattern (and scope) reaches; newest first, 500 at most. Deactivations and renames re-process nothing (two statement triggers with transition tables) (DB-22)
  - `sms_templates_examples_required`: every template has at least one example (DB-26r)
  - `sms_templates.scope_profile_code`: `propose_sms_template` scopes an LLM template to the proposing profile and builds its sender pattern from `banks.sms_senders` (a message from another sender is `22023`); `private.match_sms_template(…, p_profile_code)` honours the scope; `public.promote_sms_template(p_template_code)` (service role) makes an approved template global (DB-26r)
- **test** `15_db_sms_templates.test.sql`; `02_ledger`'s reversal template gains an example
- **feat** `20261009000400_db_ops_and_worker_rpcs.sql` (SQL side; the Edge Functions wire them up):
  - `ops_health()` adds `mailboxes_stale` (enabled, unsynced > 2 days), `gmail_watch_expiring` (< 24 h or none), `mailbox_errors` (`sync_state.last_error`), each a list of `{mailbox_code, …}` (SRV-10); `job_errors_24h` (DB-25); `open_reviews_total`, `documents_queued_oldest_age_s`; queue metrics gain `newest_age_s` and `total` so a DLQ alert can fire only when a message arrived since the last run (SRV-22)
  - `ops_health()` changes: `recon_failed` and `open_reviews` count the last 7 days, `cron_last_success` scans 7 days (DB-38); `documents_stuck` counts only `parsing` for over an hour, not `queued` (SRV-22)
  - `drain_dlq(p_queue)` and `requeue_dlq(p_queue, p_limit default 100)` (service role; `parse_document` / `llm_categorize` / `sms_fallback`); a re-queued parse message re-opens its failed document (SRV-22)
  - `save_mailbox_sync_state(p_mailbox_code, p_patch, p_last_synced_at, p_watch_expires_at)`: key-wise jsonb merge under a row lock; `gmail_history_id`, `last_synced_at` and `watch_expires_at` never move back (SRV-15)
  - `begin_document_parse(p_doc_code, p_attempt)` claims a document for parsing, or returns `{skip: 'parsed'|'failed'}` for a duplicate or stale message; `resubmit_document(p_profile_code, p_doc_code)` re-queues a failed PDF that is uploaded again; `fail_document` never flips a `parsed` document back (SRV-20)
- **test** `16_db_ops_and_worker_rpcs.test.sql`

## Supabase publishable / secret API keys — 2026-10-08 (branch `ledger-v2`)

### Backend

- **feat** Edge Functions prefer the new API keys: `_shared/supabase.ts` resolves the secret key from the runtime-injected `SUPABASE_SECRET_KEYS` (JSON, `default`), then the custom secret `SB_SECRET_KEY`, then the legacy `SUPABASE_SERVICE_ROLE_KEY`; the publishable key likewise (`SUPABASE_PUBLISHABLE_KEYS` → `SB_PUBLISHABLE_KEY` → `SUPABASE_ANON_KEY`). User clients still forward the caller's JWT. The service client logs its key source (name only). Prod and local both resolve to `SUPABASE_SECRET_KEYS`, so no custom secrets were added
- **test** `api_keys_test.ts` (resolution order, malformed JSON, no values in errors); `e2e_local_test.ts` uses `PUBLISHABLE_KEY` / `SECRET_KEY` from `supabase status`

### Web

- **feat** `VITE_SUPABASE_ANON_KEY` → `VITE_SUPABASE_PUBLISHABLE_KEY` (`lib/supabase.ts`, setup error, `.env.example`); `lib/supabase-key.ts` refuses an `sb_secret_` key so it can never ship to the browser (`supabase-key.test.ts`). supabase-js 2.117.3 (latest) already supports the new keys; Realtime authenticates with the user's JWT
- **chore** Vercel env: `VITE_SUPABASE_PUBLISHABLE_KEY` (production + preview) added, `VITE_SUPABASE_ANON_KEY` removed

### Scraper

- **feat** `CCS_SCRAPER_SUPABASE_ANON_KEY` → `CCS_SCRAPER_SUPABASE_PUBLISHABLE_KEY` (`ScraperConfig.supabase_publishable_key`, `ScraperClient(publishable_key=)`); the old name is a deprecated fallback with a `DeprecationWarning`

### Docs

- PRODUCTION §2.8 (key map and the checklist for disabling the legacy JWT keys), §2.5/§2.7/§4/§10 key names; README env tables and setup; ARCHITECTURE §8 API keys; scraper README

## Bank Ledger iOS on TestFlight — 2026-10-08 (branch `ledger-v2`)

### Frontend (mobile)

- **fix** App Intent description no longer says "iPhone" (App Store processing rejected build 2 with ITMS-90626)
- **fix** A stored session the server rejects (`notSignedIn` while loading ledgers) now signs out locally instead of leaving a signed-in "Couldn't load — You are signed out" screen (`ProfileStore.sessionRejected`, test in `AppRouteTests`)
- **feat** Supabase publishable key: `LEDGER_SUPABASE_ANON_KEY` / `LedgerSupabaseAnonKey` → `LEDGER_SUPABASE_PUBLISHABLE_KEY` / `LedgerSupabasePublishableKey` (xcconfigs, Info.plists, `LedgerConfig.supabasePublishableKey`, `StatementUploader(apiKey:)`); `LedgerConfig` refuses an `sb_secret_` key. supabase-swift 2.55.3 (already validates the new key format)
- **feat** Brand icon (`assets/brand/ios/AppIcon-1024.png`) and "Bank Ledger" in the remaining product strings (unconfigured screen, share extension, Settings SMS copy)
- **chore** `testflight.sh` uploads dSYMs to the DSN's Sentry project id when `SENTRY_PROJECT` is unset (the `ledger-apps` slug returned "Project not found"); `ASC_SIGN_WITH_KEY=1` optionally signs with the API key
- **chore** App Store Connect: app "Bank Ledger" (6820524042), groups "Bank Ledger Internal" (automatic) and "Friends & Family" (public link), Test Information and review contact set

### Docs

- apps/ios/README.md, README.md, PRODUCTION.md: publishable key, Bank Ledger naming, TestFlight groups

## Bank Ledger rebrand and SMS setup guide — 2026-10-08 (branch `ledger-v2`)

### Web

- **feat** Brand mark (a ledger column closed by a double rule) drawn from tokens: `BrandMark` / `BrandLockup` in the sidebar, mobile header, splash, sign-in and privacy page; product copy says "Bank Ledger" everywhere (the *ledger* entity keeps its name)
- **feat** Favicons (SVG, dark-mode aware; 16/32 PNG), `apple-touch-icon.png`, maskable `icon-192/512.png` and `site.webmanifest` (name, theme/background colours from tokens), wired in `index.html` with description, app-name and per-scheme `theme-color` meta; CSP unchanged (all `'self'`)
- **feat** Settings → iPhone SMS rewritten as a step-by-step guide for the one "Log Bank SMS" automation: prerequisites, 10 steps with mock-ups of the exact field values, copy buttons for `Card` and `Log Bank SMS`, *Open Shortcuts app* (iOS only), a client-side QR code to open the guide on the phone (desktop), optional TestFlight button (`VITE_TESTFLIGHT_URL`), how to test, banner meanings, troubleshooting and the privacy note
- **test** `brand.test.ts` (mark geometry = source SVG, favicon/manifest/index.html colours = tokens, linked icons exist), `sms-guide.test.ts` (UA detection incl. iPadOS, TestFlight URL validation, step integrity, keyword and action name pinned to the Swift sources), `qr.test.ts`
- **chore** dependency `uqr` (QR encoding, no runtime deps)

### Docs

- README, ARCHITECTURE, PRODUCTION, CLAUDE.md say "Bank Ledger"; `VITE_TESTFLIGHT_URL` documented (README env table, PRODUCTION §4, `.env.example`); PRODUCTION §2.7 lists the dashboard settings that still say the old name (Auth email templates, SMTP sender name, Google/Microsoft consent screens, App Store Connect name)
- **chore** `assets/brand/bank-ledger-mark.svg` + `scripts/brand/generate-icons.mjs` (`pnpm brand:icons[:check]`, root devDependency `@resvg/resvg-js`) render every icon, including the opaque `assets/brand/ios/AppIcon-1024.png` staged for the iOS asset catalog

## CI/CD follow-ups — 2026-10-08 (branch `ledger-v2`)

### Backend (Supabase)

- **style** `deno fmt` on `supabase/functions` (19 files, formatting only; lint and 91 tests unchanged); `deno fmt --check` is now blocking in `ci.yml` (`edge`) and the pre-push hook (the unused advisory helper is gone)

### Docs

- PRODUCTION.md §9 and README hooks/CI section point to docs/ci-cd.md and describe `ci.yml` + `ci-ok`, `deploy-supabase`, `deploy-parser`, `web-smoke`, `ios-testflight`, pre-commit (fast) / pre-push (full) and `SKIP_PRE_PUSH` / `SKIP_RELEASE`; `LEGACY_DEPLOYS_ENABLED` noted as deletable

## Legacy v1 removed — 2026-10-08 (branch `ledger-v2`)

The cutover is complete, so the legacy v1 code is deleted (it stays in git history). The
`legacy` database schema and the migrations that reference it are untouched.

### Backend (Supabase)

- **chore** Removed `backend/` (FastAPI + embedded worker, Alembic, Gmail/MS ingest scripts; 189 files), `deploy/` (legacy Dockerfiles, compose, Caddyfile, nginx, network policy) and the root `.dockerignore` (only legacy images built from the repo root; the parser has its own)
- **chore** Removed the one-off cutover script `scripts/migrate_legacy.py` and `scripts/tests/`; `scripts/cutover/` (Edge and Vault secret helpers) stays for rotations

### Parser

- **chore** Removed `scripts/build_golden.py` and `scripts/_legacy_runner.py`, which ran the legacy parser from `backend/.venv`. The local golden fixtures are now a frozen legacy snapshot (not regenerated from the current parser); `test_golden_parity.py` still runs against them with the same allowed deltas

### Web

- **chore** Removed the legacy React admin `frontend/` (66 files) and its `.gitignore` entries

### Docs

- README, ARCHITECTURE, CLAUDE.md layout: legacy rows and sections replaced by a short "Legacy v1 (removed)" note; PRODUCTION.md §10 is now a cutover record with the remaining out-of-repo decommission checklist (Render, legacy Vercel project, Gmail relay, GCS, `LEGACY_DEPLOYS_ENABLED`), §9 without legacy workflows and a merge-timing warning (legacy Git-connected builds must be off before `main` loses `backend/`/`frontend/`), and the post-import statement-date check moved to §11 Operations; removed the legacy `docs/operations/` and `docs/security/`; parser README documents the frozen golden fixtures; BACKLOG drops the findings that only concerned the removed cutover script (SRV-09r, DP-17); ROADMAP marks the code removal done

## Ledger iOS TestFlight pipeline — 2026-10-08 (branch `ledger-v2`)

### Frontend (mobile)

- **feat** TestFlight release flow mirroring mm-pos: `apps/ios/scripts/testflight.sh` (test, archive, export, dSYMs → Sentry, altool upload with the App Store Connect API key, `--no-upload`, `--keep-build`), `publish-build.sh` now stages the IPA + `build-meta.json` on the `ios-ledger-staged` release and commits the spent build number, and `testflight-distribute.mjs` waits for processing, sets "What to Test", attaches the build to "Friends & Family" and submits it for Beta App Review
- **chore** Registered bundle ids `com.hussu97.ledger` and `com.hussu97.ledger.share` in the developer portal with App Groups enabled

### Docs

- apps/ios/README.md: TestFlight groups, scripts, credentials and the staged-build contract for CI

## Final-verification fixes — 2026-10-08 (branch `ledger-v2`)

Fixes for [docs/audit/07-final-verification.md](docs/audit/07-final-verification.md) FV-01…FV-04.

### Backend (Supabase)

- **fix** Client grants no longer depend on the database's default privileges (FV-01, blocking): `…0000` now starts by revoking `postgres`'s default privileges on `public` tables and sequences from `anon`/`authenticated` (production still has Supabase's older `GRANT ALL` defaults), and the new final migration `…2100_reassert_client_grants` revokes everything from both roles on `public` and replays the intended grants. On prod defaults `anon` would otherwise get full table rights, `authenticated` table-wide INSERT/UPDATE/DELETE (bypassing the column-level UPDATE limits) and `service_tokens.token_hash` would be readable. Also closes DB-30 (TRUNCATE/REFERENCES/TRIGGER/MAINTAIN revoked)
- **fix** Re-parse relink (FV-02, `…2000`): `match_statement_lines` prefers a line's own previous transaction (same line, same `line_key`+`occurrence`, or same source document with the same date and amount) and resolves same-amount purchases on consecutive days by date proximity, so a corrected statement date no longer holds them as `ambiguous`
- **fix** Stale reviews (FV-03, `…2000`): a trigger on `statements` dismisses open reviews about a statement that stops being active and any `period_overlap` review left with no active candidate; existing stale reviews are dismissed once
- **test** pgTAP `11_privileges` (default privileges, no `anon` rights, column-limited `authenticated` UPDATE, `token_hash`, exact client privilege matrix) and `12_final_verification` (FV-02/FV-03 regressions). 12 files, 533 assertions; also passes on a stack emulating production's default privileges

### Docs

- PRODUCTION.md: rehearsals start from `supabase db reset`, and how to rehearse against prod's grants (FV-04); ARCHITECTURE.md: explicit client grants, re-parse lineage, stale review dismissal; BACKLOG.md: FV-04 CI guard added, DB-30 removed

## Audit fixes (pre-cutover) — 2026-10-08 (branch `ledger-v2`)

Fixes for the P0 and P1 findings of the six pre-cutover audits in `docs/audit/` (01 database,
02 data parity, 03 server, 04 web, 05 iOS, 06 cross-cutting), plus the P2/P3 items fixed along
the way. IDs refer to those reports. Everything not yet fixed is listed in
[docs/audit/BACKLOG.md](docs/audit/BACKLOG.md).

### Backend (Supabase)

- **fix** Tenant integrity is structural (DB-01, DB-02, DB-03, DB-14; migration `…1500`): every parent has `UNIQUE (profile_code, code)` and every child references it through a composite FK (cards, statements, lines, SMS, transactions incl. related/rule/recurring, evidence, reviews, recon, email routes). `resolve_review`'s card branch only accepts an account of the review's profile and bank; `supersede` only an open candidate of the review on the same profile and account, never the subject (DB-33). Matcher candidate joins are on `(profile_code, account_code)`
- **fix** No data loss from extra documents (DP-01, DP-02, DP-06): `statement_lines.source_doc_codes` records which documents contain each line. A document only withdraws its own evidence, so a card-less ADCB companion PDF or a shorter SIB history window can no longer supersede lines; only a re-parse of the same document can. A card-less statement without rows is skipped with a document warning. Real-data replay: ADCB line coverage 80.8 % → 100 %, SIB 53.2 % → 100 %, orphaned reviews 150 → 0
- **fix** Re-parsing a document whose statement date or account changed retires the old statement instead of duplicating the ledger; a later re-parse that produces it again revives it with its codes (DB-06)
- **fix** A statement without a card number never invents an account: same document → its account, then the bank's only active account, then an explicit reference seen on one account, else a permanent `22023` (DB-07)
- **fix** `ingest_sms` validates and processes each message on its own: `invalid` (+ `reason`), `failed` (`error:<sqlstate>`, message kept), `duplicate_delivery`, `rejected_otp` or the processing outcome; one bad SMS never fails the batch. An impossible template date means "template doesn't apply". The template re-process trigger isolates errors too (DB-08)
- **fix** Rule `conditions` are validated on write (known keys, numeric amounts, existing bank, own card, ISO currency, kind, direction) by `private.rule_problem` in the trigger and `preview_rule`; evaluation uses `private.safe_numeric`, so a bad rule can't stop ingestion (DB-09)
- **fix** The matcher no longer calls separable pairs ambiguous: a competitor ≥ 0.3 below on merchant affinity isn't a conflict (DB-10)
- **fix** Ingestion and review resolution take a per-profile advisory lock (`private.lock_profile`) first, so the bulk legacy import can't create duplicate accounts or cards or deadlock (X-08, DB-42, DP-15)
- **fix** Function-level `statement_timeout` removed (it never applied); regex cost bounded on write instead: rule patterns ≤ 200 chars, template patterns ≤ 1000/200, no back-references, SMS bodies ≤ 2000 chars (DB-13)
- **fix** Merchants and aliases are readable only when the caller's profiles reference them; SMS templates only for the caller's banks, messages or proposals; `sms_templates.examples` is not granted to clients (DB-04)
- **fix** Self sign-up disabled (`[auth] enable_signup = false`, DB-04 / WEB-04); members join by invite. The legacy import refuses to adopt a profile key it did not create (`private.legacy_import_profiles`, DB-05)
- **fix** `legacy_parity_report(p_schema)` casts the legacy `varchar`/enum columns and adds `legacy_lines_missing` / `legacy_aed_missing`; `private.legacy_missing_lines()` lists lost lines (DB-11, X-02, DP-05)
- **fix** Legacy category choices are evaluated once per transaction and never re-applied over a user edit; `ledger-legacy-choices` unschedules itself when nothing is pending or 30 days after staging; `private.legacy_unmatched_choices()` lists leftovers (DB-12)
- **fix** Reconciliation: lines without an AED amount count at their printed rate and downgrade an explained mismatch to `warn` (`unpriced_lines`, DB-16 / X-18); history extracts get `n/a`; an empty statement whose header shows activity, or whose lines were all withdrawn, is `warn`, never `ok` (DP-08)
- **fix** Two alerts with different available limits are never duplicates (DB-15); `missing_from_statement` reviews resolve once the transaction stops being pending (DB-17, partly); a line displaced by a manual link gets its own transaction and linking onto a locked line is refused (DB-27); resolving `unknown_card` for an SMS without last4 binds it to the chosen account (DB-43); orphan reviews raised and resolved in one transaction are dropped (DP-06)
- **perf** The matcher resolves each line's merchant once (DB-19, partly); indexes on `transactions.stmt_code`, `related_txn_code`, `rule_code` and `statement_lines(profile_code, legacy_fingerprint)` (DB-32, partly)
- **feat** Migration `…1900`: `retry_sms_fallback` (owner re-asks the LLM for an unparsed SMS), `merchant_search` (every merchant of a profile, not limited by spend), `statement_cycles` `p_limit` up to 5000, `resolve_review {"not_a_transaction": true}`, and distinct seed colours for Medicine, Forex Charge and Apple in-app purchase
- **chore** `ledger-cron-history-purge` deletes `cron.job_run_details` older than 7 days (X-11); local `[api] max_rows = 2000` (X-07)
- **test** pgTAP `08_tenant_isolation` (negative cross-profile tests), `09_ingest_robustness`, `10_web_review_and_search`; `02` and `03` are hermetic and `03` mocks the legacy schema with the real `varchar`/enum types (DB-28, X-31). 10 files, 503 assertions
- **fix** Edge `worker`: only a 422 carrying a contract permanent code is permanent; every other parser response (401/403/404/400/413, a 422 without a known code, a 200 without parse-v1, 5xx, timeouts) is retried with backoff (60 s / 5 min / 15 min / 30 min) and dead-lettered after 5 attempts, with error-level Sentry events per status (SRV-03). Ingest SQLSTATE class 22, `23502` and `23514` are permanent; the event carries the SQLSTATE and constraint with literal values filtered (X-06)
- **fix** Edge `worker` time budget: a round starts only if it fits the Edge wall clock (`EDGE_WALL_CLOCK_MS`, 150 s); `PARSER_TIMEOUT_MS` defaults to 75 s (was 100 s), above the parser's 60 s kill (SRV-04)
- **fix** `statements-upload` caps a request at 40 MB, enforced on `content-length` and while streaming chunked bodies, before form parsing (SRV-06)
- **fix** SMS fallback: a non-transaction message (`msg_kind=other`, null amount) is skipped without a DLQ entry; deterministic failures dead-letter once with a sanitised reason; no LLM call without banks (`NO_BANKS`); SDK retries off (the queue retries)
- **fix** Edge Sentry never initialises when `SENTRY_ENVIRONMENT` is unset, `local`, `development` or `test`, even with a DSN (`sentryActive`)
- **test** deno: `worker_test.ts` (parse state machine, DLQ, budget, backoff, upload body cap), `sentry_local_test.ts`. 91 pass
- **fix** `scripts/migrate_legacy.py`: `--target local|prod` is required and checked against `LEDGER_DB_URL`/`SUPABASE_URL`; `--apply` against prod also needs `--yes-i-mean-prod <ref>` (DP-13). Legacy PDFs carry their known bank as `documents.bank_code`; an insert conflict deletes the uploaded object; a missing profile exits with a clear message; differing OAuth app credentials across profiles warn (SRV-09). `scripts/tests` 12 pass

### Parser

- **fix** Resource limits (SRV-01): every parse runs in a killable forkserver child (30 s CPU, 60 s wall, 768 MB address space on Linux, 32 MB inflated streams); PDFs over 15 MB or 30 pages are rejected before extraction. A 65 KB crafted PDF that took 202 s is now rejected in 0.2 s. New permanent 422 codes `PARSE_TIMEOUT` and `PDF_TOO_LARGE`
- **fix** Output validated against the DB's constraints before it is returned (X-06): real dates (2000–2100), `period_start ≤ period_end`, statement period ≤ 100 days, due date 0–120 days after the statement date, 4-digit last-4 (malformed values become null), `txn_time`, `numeric(14,2)` amounts, `fx_rate > 0`. A violation is the permanent 422 `PARSE_OUTPUT_INVALID` (field paths only)
- **fix** ENBD/EIB statement years come from the full Statement Date (else the newest posting date), so Dec/Jan statements no longer fail or land a year in the future: 38 lost lines recovered (DP-03, DP-04)
- **fix** FAB rows with an original amount in decimal-comma (`EUR 108,99`) or 3-decimal (`KWD 18.750`) format were skipped; both affected statements now reconcile (DP-07)
- **fix** Bank detection scores every bank on legal-name and brand markers outside transaction rows, so "TRANSFER EMIRATES NBD" on a FAB statement no longer wins (SRV-08)
- **fix** Parser Sentry never initialises for an unset, `local`, `development` or `test` environment (`sentry_active`)
- **test** `test_limits.py`, `test_output_validation.py`, `test_upload_bank_detection.py`; golden parity allows the ENBD year and FAB line deltas explicitly. 272 pass (92 golden cases on the private corpus)

### Web

- **fix** Out-of-range pages clamp to the last page instead of "Requested range not satisfiable" (WEB-01); statements, documents and reviews paginate server-side with exact counts, health counts use head counts, and Merchants lists every assigned or suggested merchant beyond the top 200 (WEB-02, partly)
- **fix** The Review nav badge is a head count gated on session and profile (fixes "permission denied for table match_reviews" sent with the anon key); the Supabase Sentry integration no longer re-reports every failed request
- **fix** Sentry spans are scrubbed (`beforeSendSpan`; `beforeSendTransaction` was ignored by streamed spans, WEB-03); Sentry never initialises for an empty, `local`, `development` or `test` environment or in Vite dev mode
- **fix** Magic links never create users (`shouldCreateUser: false`); an unknown email is told to ask for an invite (WEB-04)
- **fix** A foreign amount without an FX rate shows in its own currency with "awaiting FX" instead of as AED (WEB-05)
- **fix** An unparsed SMS without a proposed format can be marked "Not a card transaction" or dismissed (WEB-07)
- **fix** Tokens meet WCAG AA: darker light `muted`/`subtle`/`accent`/`warn`, lighter dark `muted`/`subtle`, a 12-hue chart palette with every pair ≥ 15 ΔE2000 and ≥ 3:1; `packages/tokens/test/contrast.test.mjs` enforces the declared pairs (WEB-06, WEB-29). axe colour-contrast nodes 781 → 0 on the walked screens. `Tokens.swift` regenerated
- **feat** Insight cards link to their screen (WEB-25); Review replaces Cards in the mobile bottom bar with a count (WEB-23); 44 px hit areas below `lg` (WEB-22, partly); "Clear filters"/Back resets the search box (WEB-08); every Trends label shows on mobile (WEB-18); reduced motion stops infinite animations (WEB-21); expired insights are hidden (WEB-45)
- **feat** Adopts the post-audit DB contracts: "Not a card transaction" sends exactly `{not_a_transaction: true}` (it was also sending `dismiss`, so the SMS was never marked), and also applies to unknown-card SMS; "Retry AI" on an unparsed SMS (`retry_sms_fallback`, WEB-07); friendly P0002/22023 review errors; Rules → Merchants searches and pages server-side through `merchant_search`; Statements page up to 5000 cycles (WEB-02); recon `n/a` shows as a neutral "Nothing to reconcile" with the unpriced / no-lines checks explained; document parse warnings shown with digits masked
- **test** `src/test/audit-fixes.test.ts`, `db-contract.test.ts`, `sentry-scrub.test.ts`, `sentry.test.ts` wiring tests. 159 pass

### iOS

- **fix** Sentry never starts for `LEDGER_ENVIRONMENT` local/development/dev/test or Debug builds, even with a DSN (`Telemetry.shouldStart`)
- **fix** SMS outbox can no longer wedge (IOS-01): failures are classified (`LedgerAPIError.kind`: 42501/22xxx/23xxx/P0xxx/PGRST1-2xx/4xx permanent; network, 5xx, 57014, 08/40/53xxx transient; 401/PGRST3xx signed out). A permanently failing batch is split until the bad message is alone; a permission error parks that ledger's batch; per-message `invalid`/`error` statuses (newer `ingest_sms`) park only that message; transient retries stop after 8 attempts. Parked messages are listed in Settings → "Not sent" with Retry (to the current SMS ledger) / Delete. Flushes in one process are serialised. Shortcut results say why a message waits (offline / signed out / server) instead of always "when you're back online"
- **feat** Explicit "SMS go to" ledger (IOS-02): owned ledgers only, defaults to the first owned one, stored in the App Group; the App Intent and the Share Extension (which now shows "Uploading to …") use it instead of the last-viewed ledger. Viewers no longer see the statement upload card
- **fix** One due-date rule for Overview and Statements (`DueStatus`, IOS-03): past due dates read "Was due 25 Sep"; "Overdue" only for an account's latest statement with no payment detected (not detectable on the phone yet, so never shown)
- **fix** Overview hero (IOS-04) renders the server's `change_vs_prev_month_to_date` ("52% below the same day last month") and per-account `utilisation`; the 3-month average is shown as a plain figure (it is a full-month average) and only used as a ratio for completed months. Overview no longer fetches `statement_cycles`
- **fix** Dynamic Type (IOS-05): the hero number scales with `@ScaledMetric` and stacks under its unit when needed; pending strip, ring card, card, statement, upload and Activity rows stack from xxxLarge (`AdaptiveRow`); money stays on one line (`moneyLine()`); chips wrap between words and cap at accessibility2; labelled filter and 44 pt dismiss buttons
- **feat** SMS setup guide (IOS-06): one automation on "Card" (present in every ADCB/FAB/ENBD/SIB card alert in the template seed), keep "Notify When Run" on; Settings and the guide show "Last captured" and a "Send test" that runs the intent's path with a synthetic non-transaction message
- **feat** Review screen (IOS-07) from Overview → Needs attention: open `match_reviews` with link to candidate / keep as new / dismiss, and register an unknown card to an account of the same bank (`resolve_review`); read-only for viewers. Shortcut results for `unknown_card`/`held` point to it
- **feat** `PrivacyInfo.xcprivacy` in the app and the share extension (IOS-08): UserDefaults (1C8F.1, CA92.1), crash data only, no tracking
- **fix** A sign-in whose session couldn't be saved to the keychain is no longer shown as signed in (IOS-09); Debug builds keep the session in memory instead, and the no-access-group keychain fallback is Debug-only
- **chore** `scripts/publish-build.sh` reads `SENTRY_AUTH_TOKEN` / `SENTRY_ORG` / `SENTRY_PROJECT` from the environment or `Config/Secrets.Release.xcconfig`, passes the token via the environment and never prints it
- **chore** `Tokens.swift` regenerated from the AA-contrast tokens (with the web change)
- **feat** Adopts the post-audit DB contracts: Review offers "Retry AI" (`retry_sms_fallback`) and "Not a card transaction"; the outbox parks per-message `invalid`/`failed` statuses with readable reasons; recon `n/a` decodes
- **test** `AuditFixTests`, `OutboxFailureTests`, `DBContractTests` and decoding fixtures for the new `overview` and `ingest_sms` shapes. 114 pass

### Scraper

- **fix** Uploads are split into requests of ≤ 20 files and ≤ 32 MB (`CCS_SCRAPER_UPLOAD_MAX_FILES` / `CCS_SCRAPER_UPLOAD_MAX_MB`, clamped to the server's limits); a 413 halves the batch; a partial failure raises `UploadBatchError` and the batches that succeeded are recorded, so `upload-pending` retries only the rest (SRV-02). 135 tests pass

### Docs / CI

- **docs** `docs/audit/01`–`06`: database, real-data parity (aggregates only), server, web, iOS and cross-cutting audits, each with a Fix status. `docs/audit/BACKLOG.md` collects every finding and recommendation not yet fixed, with a "do before / at cutover" list
- **docs** PRODUCTION.md runbook: function and Vault secrets from one gitignored source (`scripts/cutover/set-edge-secrets.sh`, which refuses placeholders and never echoes, and `set-vault-secrets.sql`) (X-01, X-04); Gmail OAuth client copied from Render (X-03); ordered legacy disable list and rollback (X-13); dashboard settings: Postgres upgrade, API max rows 2000, sign-ups off (X-07); `supabase migration list --linked` before `db push` (X-09); Vault set only after functions deploy (X-21)
- **docs** PRODUCTION.md after the fixes: `migrate_legacy.py --target prod`, dry run first, `--yes-i-mean-prod nkmylznisjcnmqbxosey` for writes (zsh-safe); members added via Supabase Auth → Invite user with sign-ups off; parser limits and nested timeouts (60 s < 75 s < 120 s) on Cloud Run in `credit-card-scraper-ht` / `me-central1`; Sentry off for local/dev/test in every runtime; post-import ENBD/FAB checks with SQL to requeue and supersede a stale bad-year statement; parity sign-off on `legacy_lines_missing = 0`; rotate the exposed Anthropic key and Sentry org token
- **docs** parse-v1: the full error table (`INVALID_REQUEST`, `PARSE_TIMEOUT`, `PDF_TOO_LARGE`, `PARSE_OUTPUT_INVALID`, 502 `DOWNLOAD_FAILED`, 500 `INTERNAL_ERROR`), output validation rules, resource limits, and code-based worker classification (SRV-21, X-25)
- **docs** ARCHITECTURE: composite FKs, per-profile ingest lock, multi-document line union, recon `n/a`, per-message `ingest_sms` statuses, iOS outbox classification and "SMS go to", no self sign-up, local-off Sentry; removed the stale "120 s statement timeout" and "regex runs under a statement timeout" claims (DB-13) and the insight kinds that are never generated (DB-29). README: env vars (`PARSER_TIMEOUT_MS` 75000, `EDGE_WALL_CLOCK_MS`, parser limits, scraper batching, Sentry local behaviour), `docs/audit`, new RPCs and screens. ROADMAP: audit row and remaining cutover tasks
- **ci** `ci.yml` `changes` job gets `pull-requests: read`, so PR runs no longer fail on the paths filter (X-05); legacy workflows run only while the repository variable `LEGACY_DEPLOYS_ENABLED` is `true` (X-13); `deploy-supabase` and `deploy-parser` refuse any ref but `main` (X-12)
- **chore** The parser deploys to `credit-card-scraper-ht` / `me-central1`, Artifact Registry repo `ledger` (X-29); `services/parser/.gcloudignore` and `.dockerignore` keep `.env*`, `.venv` and tests out of the upload and image (X-15)
- **chore** Git hooks skip missing `backend/`/`frontend/` and tools, `pre-push` runs the v2 checks, `commit-msg` rejects `Co-Authored-By` (X-14)

## Ledger v2 — 2026-10-08 (branch `ledger-v2`)

A rebuild around Supabase. The DB and business logic move into Postgres, ingress and I/O into
Edge Functions, and parsing into a stateless Cloud Run service. There is a new web app, a new
iPhone app with real-time SMS capture, and an evidence-based ledger reconciled against
statements. Legacy `backend/` and `frontend/` are frozen until cutover (PRODUCTION.md §10).
Later v2 follow-ups are listed under [Unreleased] below.

### Backend (Supabase)

- **feat** Schema in `supabase/migrations`:
  - Tenancy: `profiles`, `profile_members` owner/viewer, profile-scoped `service_tokens`.
  - `authz` RLS helpers on every table. RPCs guard in-body (`assert_member` /
    `assert_service_role`); there is no `REVOKE EXECUTE`, because of the PG 17.6.1.104 segfault.
  - Codes as PKs, text + CHECK statuses, numeric money, Dubai dates.
- **feat** The first migration moves every legacy table and enum into a `legacy` schema, so v2
  lives in the existing `cc-statement-scraper` project.
- **feat** Documents, statements and immutable statement lines. Line identity is
  `(line_key, occurrence)`, so identical same-day purchases stay distinct.
- **feat** Canonical `transactions` derived from `transaction_evidence` (statement line >
  history line > SMS).
- **feat** Deterministic scored matcher:
  - amount, date, merchant trigram and card components
  - auto-link ≥ 75 with a 15-point margin, review 55–75
  - interchangeable ties, FX estimates, pre-auth tolerance
  - reversals and released-authorisation voiding
  - in-place re-ingest diffing with orphaning instead of deletes
  - SIB history extracts as separate evidence, never double-counted
- **feat** Statement reconciliation (totals, balance equation, SMS coverage, missing-from-statement)
  and a match review inbox.
- **feat** Dynamic categorisation:
  - generated `effective_category_code` (manual > merchant manual > rule > LLM)
  - set-based `recategorize`, with triggers on transactions, rules and merchant choices
  - `rules_version` sweep every 3 h
  - `preview_rule`
  - defaults seeded once per profile
- **feat** One spend definition, `v_spend`, and analytics RPCs: `overview`, `spend_series`,
  `category_breakdown`, `merchant_leaderboard`, `daily_spend`, `hour_weekday_pattern`,
  `fx_spend`, `statement_cycles`, `yoy_compare`, `anomalies`, `filter_meta`, `budget_status`
  and `recurring_list`.
- **feat** Budgets, recurring-charge detection, a nightly insights feed and an audit trail.
- **feat** Background plumbing:
  - pgmq queues (`parse_document`, `llm_categorize`, `sms_fallback`, each with a DLQ)
  - Vault secrets (PDF passwords, mailbox refresh tokens, `project_url` / `edge_cron_secret`)
  - pg_cron schedules
  - Realtime on transactions, SMS, documents, reviews and insights
- **feat** Data-driven `sms_templates` that reject templates whose examples don't parse and
  re-run unparsed messages on change. 25 real templates for ADCB, FAB, ENBD and SIB, including
  known non-transaction alerts classified as ignored.
- **feat** Daily `fx_rates` fallback for pending foreign-currency SMS (statement rate → USD peg
  → market rate).
- **feat** Legacy import: `private.import_legacy_metadata`, staged legacy category choices
  re-applied nightly, `legacy_parity_report`, and pending member invites claimed on sign-up.
- **feat** Edge Functions, all wrapped in `withSentry` with in-function auth:
  - `statements-upload` (legacy scraper multipart contract or user JWT, sha256 dedup)
  - `sms-ingest`
  - `worker` (parser → `ingest_parsed_document`; Claude categorisation and SMS-template proposals)
  - `gmail-push` (OIDC-verified), `gmail-watch-renew`, `outlook-poll` (Graph delta, resumable)
  - `ops-monitor` (ops health → Sentry, `ops-heartbeat` cron check-in)
  - `fx-rates`
- **test** pgTAP suites (RLS and security guards, ledger and matching, legacy import, SMS
  templates, FX) and deno tests (auth, upload, worker, email routes, LLM, Sentry scrubber,
  `withSentry` guard, opt-in local e2e).

### Parser

- **feat** `services/parser`: stateless FastAPI `POST /parse` for Cloud Run, implementing
  `docs/contracts/parse-v1.md`.
  - Copies of the legacy FAB, ADCB, ENBD, EIB, SIB and Mashreq parsers.
  - Adds decimal-string money with direction, the `interest` kind, `fx_rate`,
    `legacy_fingerprint`, statement identity and best-effort totals.
  - `X-Parser-Secret` auth that fails closed, a download host allow-list and size limit, and a
    Sentry scrubber.
- **test** Unit tests, ported legacy tests and golden parity tests against the legacy parsers.

### Web

- **feat** `apps/web`: Vite + React 19, TanStack Router/Query, supabase-js with Realtime,
  Tailwind v4 on `@ledger/tokens`, owned Radix components, Recharts with stable category
  colours, Fraunces/Inter, light/dark, responsive to 390 px.
- **feat** Screens:
  - Overview
  - Activity (URL-synced filters, evidence timeline, inline, bulk and merchant categorisation)
  - Insights (trends, categories, merchants, subscriptions, FX, heatmaps, YoY, anomalies)
  - Budgets
  - Cards & Statements
  - Review inbox
  - Rules (live impact preview)
  - Settings (sources and health, tokens, PDF passwords, members, SMS setup)
- **feat** Single data layer in `src/data` (ESLint-enforced), Sentry with a scrubber, and a no-hex
  guard.
- **feat** `packages/tokens` (CSS variables, chart palette, `Tokens.swift`), `packages/db-types`
  (generated), and a pnpm workspace.
- **chore** `supabase/seed.sql` adds synthetic demo ledgers (`demo@ledger.local`).

### iOS

- **feat** `apps/ios`: an XcodeGen project with the Ledger app and the LedgerShare "Add to
  Ledger" PDF extension, an App Group and a shared keychain session.
- **feat** `LedgerKit` holds every decision the app makes:
  - Decimal-exact money and Dubai dates
  - supabase-swift API behind a protocol
  - on-device OTP and debit filtering, `client_msg_id` idempotency
  - App Group outbox with backoff
  - Sentry telemetry and scrubber
  - screen models
- **feat** `LogBankSMSIntent` for the Shortcuts "When I get a message containing…" automation.
  Screens: Overview, Activity, Insights, Statements (upload) and Settings (SMS setup guide,
  outbox status), refreshed by Realtime.
- **chore** `scripts/publish-build.sh`: archive and export, dSYM upload, TestFlight upload.

### Scraper

- **feat** `CCS_SCRAPER_UPLOAD_PATH` (`/functions/v1/statements-upload` for v2) and optional
  `CCS_SCRAPER_SUPABASE_ANON_KEY`. The default target is fixed to `:8040`.
- **feat** Per-file `queued` / `duplicate` status. A failed bank upload no longer aborts the
  others. New `upload-pending` command.

### CI / Infra

- **feat** `ci.yml` gains path-filtered v2 jobs:
  - `supabase`: start, db reset, pgTAP, types drift
  - `edge`: deno test
  - `parser`: uv, ruff, pytest
  - `web`: tokens check, lint, test, build
  - `ios`: `swift test` on LedgerKit, macOS, on LedgerKit/tokens changes or manual runs

  The legacy jobs are kept.
- **feat** Manual-only `deploy-supabase.yml` (db push and/or functions deploy, typed project-ref
  confirmation, `production` environment) and `deploy-parser.yml` (Artifact Registry + Cloud
  Run, min instances 0, Secret Manager).
- **chore** `security.yml` also audits the parser's dependencies. The legacy deploy workflows
  are marked as legacy.

### Docs

- **docs** README, ARCHITECTURE, PRODUCTION and ROADMAP rewritten for v2:
  - structure, prerequisites, local setup, every test command, env vars per component
  - screens, API surface
  - data model, matching and categorisation, auth and RLS, SMS capture
  - Sentry topology (two projects: `ledger-backend`, `ledger-apps`)
  - free-tier deployment
  - cutover runbook with rollback

  CLAUDE.md is rewritten for v2. The legacy `docs/operations` and `docs/security` notes are
  marked as v1.

## [Unreleased]

### Backend

- **feat** Ledger v2 migration `20261008001300_web_followups.sql` — `list_profile_members` (members with auth emails plus pending invites), owner-only `remove_profile_member` (refuses to remove the last owner, 22023) and `cancel_profile_invite`; `preview_rule` now honours `currency` and `card_code` conditions exactly like `private.recategorize` and counts every match (20-row sample); `overview` adds per-account `utilisation` and `change_vs_prev_month_to_date` / `change_vs_avg_3m` fractions (existing keys unchanged); `spend_series` gains optional `p_top` that folds the long tail into an "Other" group (signature change: dropped and recreated). pgTAP suite `06_web_followups.test.sql`; regenerated `packages/db-types`
- **feat** Edge Functions: Sentry tags every event `service=edge` at init (`_shared/sentry.ts`), alongside the per-request `function`, so Edge and parser events separate in the shared `ledger-backend` project; asserted in `sentry_runtime_test.ts`
- **fix** `scripts/migrate_legacy.py --step secrets` writes `GMAIL_OAUTH_CLIENT_ID/SECRET` (was `GOOGLE_OAUTH_CLIENT_*`), exactly the names `_shared/oauth.ts` reads, so the exported env file can be pushed with `supabase secrets set --env-file` without renaming

### Frontend (web)

- **feat** Ledger web: Settings → Members shows emails, roles and pending invites, with confirm dialogs to remove a member or cancel an invite
- **refactor** Ledger web: Overview uses the server's `utilisation` and change fractions (removed `latestCycleByAccount` and `formatDeltaPercent`; `formatChange` only formats a server fraction); Insights → Trends asks the server for the top 8 groups (`p_top`) instead of folding client-side, and keeps grouping/bucket in the URL (`?group=&grain=`), preserved when the range changes
- **chore** `@ledger/tokens` build emits `dist/chart.d.ts` (exported via `types`) and skips unchanged outputs; removed the `apps/web/src/types/tokens.d.ts` stopgap
- **fix** `.gitignore`: the root `data/` rule no longer hides `apps/web/src/data/` (the web data layer)
- **feat** `apps/web/vercel.json`: SPA rewrite to `/index.html` for every path except `/assets/*`, immutable caching for hashed assets, and security headers (`nosniff`, `strict-origin-when-cross-origin`, `X-Frame-Options: DENY`, `Permissions-Policy`, a CSP allowing only self, the inline theme script by hash, the Supabase project over https + wss, and Sentry ingest). Vitest guard `src/test/vercel-config.test.ts` keeps the script hash and CSP in sync with `index.html`
- **feat** Sentry tags every web event `app=web` (`initialScope` in `src/lib/sentry.ts`, tested in `sentry.test.ts`); the source-map upload project defaults to `ledger-apps` (was `ledger-web`) in `vite.config.ts` and `.env.example`
- **fix** `pnpm --filter @ledger/tokens check` works from a clean clone: it regenerates the gitignored `dist/` in memory and fails only when the committed `Tokens.swift` drifts from `tokens.json`

### Parser

- **feat** Sentry tags every parser event `service=parser` at init (`ccs_parser/sentry.py`), sharing `ledger-backend` with the Edge Functions; covered by a pytest case

### iOS

- **feat** LedgerKit `Telemetry` tags every event `app=ios` (plus `target`) via `Telemetry.scopeTags(target:)`, for the shared `ledger-apps` project; dSYM upload in `scripts/publish-build.sh` defaults to `SENTRY_PROJECT=ledger-apps` (was `ledger-ios`)

### Docs

- **docs** PRODUCTION.md: documented `apps/web/vercel.json` (§4) and dropped the "add a vercel.json" note; removed the cutover step to rename `GOOGLE_OAUTH_*` by hand; the scraper cutover step uses per-profile tokens; Sentry tags are no longer "until the runtimes set them". ARCHITECTURE.md §10, README, `scraper/README.md`, iOS README and ROADMAP updated to match

### CI / Infra

- **chore** Pre-commit hook runs `pnpm --filter @ledger/web lint` and `test` when `apps/web/**/*.{ts,tsx}` files are staged (legacy `frontend/` ESLint check unchanged)
- **chore** CI `web` job: the tokens step is just `pnpm --filter @ledger/tokens check` (the build-then-`git diff` workaround is gone)

### Scraper

- **feat** Per-profile service tokens: `get_config(profile)` reads `<PROFILE>_CCS_SCRAPER_API_TOKEN` (profile upper-cased, like the bank credentials) and falls back to the global `CCS_SCRAPER_API_TOKEN`; the fail-fast error names both. Ledger v2 tokens belong to one profile, so `scrape --profile tejasvie` no longer needs the token swapped per run. Updated `.env.example` and README
- **fix** FAB: after "DOWNLOAD STATEMENTS" modal opens, wait for `select[name='estatementTenure']` to become visible before attempting to select months — previously a fixed 700ms wait was insufficient, causing `_download_requested_months` to see `has_tenure=False` and try to re-open the modal (which fails while the modal is already shown), silently skipping all requested months
- **fix** ADCB: wrap `login_selector_visible` and `is_authenticated_session` in try/except to handle `TargetClosedError` — after clicking "Login" on the concurrent-session gate, ADCB navigates/reloads the page and the old page reference closes, causing a crash on the next auth-poll tick
- **fix** SIB: restructure "Secure Login" polling from 3 × 1400ms (4.2s) to 2 × (7 × 1500ms) = up to 21s; click the button once per outer attempt rather than on every inner poll iteration, preventing unintended re-clicks while the password screen is loading

### Backend

- **chore** Build `Dockerfile.api` from the lock files instead of `pip install ".[export]"` — the image previously re-resolved `pyproject.toml`'s version ranges at build time, so production shipped versions that were never tested by CI and never scanned by `pip-audit` (the image had `fastapi` 0.141.1 against a pinned 0.136.3, `sqlalchemy` 2.0.51 against 2.0.47, and so on). The image now installs `requirements.txt` plus a new `requirements-export.txt` in a single pip invocation and adds the project itself with `--no-deps`; verified the built image contains exactly the pinned set and nothing else
- **chore** Add `backend/requirements-export.in` / `requirements-export.txt` — pinned `pandas`/`openpyxl` for the optional `[export]` extra, kept out of `requirements.txt` so the Gmail relay image that shares that lock file does not pull in pandas/numpy; both CI and the Security Scan now run `pip-audit` over it as well
- **chore** Regenerate `backend/requirements.txt` — adds the missing `sentry-sdk[fastapi]==2.66.1` (added to `pyproject.toml` when Sentry monitoring landed but never compiled into the lock file) and `greenlet==3.5.4`; all other pins unchanged
- **chore** Uninstall `pip` from `Dockerfile.api` and `Dockerfile.gmail-relay` after dependencies are installed — pip 26 ships a CycloneDX SBOM of its vendored libraries (`pip/_vendor/bom.cdx.json`) which Trivy reads as installed packages, failing the Security Scan container job on `msgpack` 1.1.2 and `setuptools` 70.3.0 even though nothing in the app imports them; a runtime image needs no package installer, so removing pip clears the findings and trims the attack surface
- **chore** CI: grant the workflow token `pull-requests: read` — `dorny/paths-filter` resolves changed files for `pull_request` events through the PR listFiles API, which failed with "Resource not accessible by integration" under the repo's default token scopes, making the `changes` job (and therefore every downstream job) fail on PRs
- **chore** Bump vulnerable dependencies (pip-audit) — `click` 8.3.1→8.4.2 (PYSEC-2026-2132), `cryptography` 48.0.1→50.0.0 (PYSEC-2026-3552/3553/3554), `pillow` 12.2.0→12.3.0 (PYSEC-2026-2253…2257, 3451…3454, 3493…3496), `pyasn1` 0.6.3→0.6.4 (PYSEC-2026-3455/3456/3457), `pypdf` 6.13.3→6.15.0 (PYSEC-2026-3610…3613, CVE-2026-71852, CVE-2026-71870); lower bounds for the direct dependencies tightened in `pyproject.toml` to prevent re-introduction
- **chore** Bump vulnerable dependencies — `cryptography` 48.0.0→48.0.1 (GHSA-537c-gmf6-5ccf), `pydantic-settings` 2.13.1→2.14.2 (GHSA-4xgf-cpjx-pc3j), `pypdf` 6.13.0→6.13.3 (GHSA-jm82-fx9c-mx94), `starlette` 1.2.1→1.3.1 (PYSEC-2026-248, PYSEC-2026-249); tightened lower bounds in `pyproject.toml` to prevent re-introduction

- **fix** Email ingestion 500 — `save_binary` (GCS upload) was outside the `try/except` block in `POST /email-ingestion/upload`; unhandled exceptions rolled back the DB and returned a generic 500 with no event record; moved `save_binary` inside the block so storage failures produce a FAILED event and a structured error response
- **fix** Email ingestion script: retry on 5xx — `email_ingestion_common.py` now retries HTTP 5xx responses (up to 3 attempts with backoff) instead of raising immediately; 4xx still raises immediately
- **fix** Email ingestion script: per-attachment error isolation — `email_ingest_microsoft.py` now wraps each `api.upload_pdf` call in a try/except; a single failed attachment is counted as `failed` and recorded in `attachment_errors` but no longer aborts the rest of the mailbox; the delta link still advances so future runs do not reprocess messages that already succeeded
- **feat** Sentry error monitoring — `sentry-sdk[fastapi]` added; `init_sentry()` in `ccs_platform/core/sentry.py` wires up FastAPI and SQLAlchemy integrations on startup; controlled via `CCS_PLATFORM_SENTRY_DSN` and `CCS_PLATFORM_SENTRY_TRACES_SAMPLE_RATE` env vars (no-op if DSN is unset)

### Frontend (web)

- **feat** Sentry error monitoring — `@sentry/react` added; initialised in `main.tsx` with browser tracing and session replay (errors only); controlled via `VITE_SENTRY_DSN` and `VITE_ENVIRONMENT` env vars (no-op if DSN is unset)

### Backend

- **chore** Migrate production database from Neon to Supabase — updated PRODUCTION.md setup steps (session pooler DSN, Supabase dashboard instructions), ARCHITECTURE.md provider references, and `.env.example` PostgreSQL DSN example; escape `%` as `%%` in `set_main_option` calls in `session.py` and `alembic/env.py` to fix configparser interpolation error when database password contains percent-encoded characters



- **feat** SIB transaction history PDF support — `parse_sib_transaction_history()` parses SIB's "Transaction history" export (date format `DD MMM YYYY`, amount format `CUR [-]amount`) and splits transactions into per-billing-cycle statements using the 12th of each month as the statement cutoff date (13th of M through 12th of M+1 → statement dated 12th of M+1); duplicate rows across PDF pages are deduplicated by fingerprint; the `parse_statement_for_bank()` dispatcher auto-detects the PDF type for SIB and returns a list when multiple statements are produced; `ingest_statement_pdf()`, the parser adapter, and the upload handler all support 1 PDF → N statements; bank detection in the upload endpoint recognises "TRANSACTION HISTORY" + "ACCOUNT NO." + "ACCOUNT TYPE" as SIB

- **chore** Remove scraper-only runtime settings from seed catalog — `DEFAULT_RUNTIME_SETTING_SPECS` now only includes PDF-password keys used by backend parsers (`FAB_PDF_PASSWORD`, `ADCB_CID`, `ADCB_PDF_PASSWORD`, `ENBD_PDF_PASSWORD`, `SIB_PDF_PASSWORD`); login credentials and scraper-specific flags (`FAB_USERNAME/PASSWORD`, `ADCB_LOGIN_PASSWORD`, `ADCB_FORCE_VIRTUAL_KEYBOARD`, `ENBD_USERNAME/PASSWORD`, `EIB_USERNAME/PASSWORD`, `SIB_USER_ID/PASSWORD/SECURE_IMAGE_TEMPLATE_BASE64`, `MASHREQ_USERNAME/PASSWORD`) are no longer seeded or shown in the UI; migration `20260304_000015` deletes any existing rows for these keys

- **feat** Statement line category override — users can pin a category on any transaction line via `PUT /api/v1/transactions/{id}/category-override`; the pin is stored in a new `category_overrides` table (keyed by fingerprint) and survives both reclassify (skipped by `reclassify_statement_lines`) and reparse (applied during ingestion); `DELETE /api/v1/transactions/{id}/category-override` clears the pin and restores auto-classification; migration `20260304_000014` adds the `category_overrides` table and `category_override` column on `statement_lines`

### Frontend (web)

- **feat** Category override controls — `RawLinesPage` and `StatementsPage` lines tables now show a category dropdown with Pin/Clear buttons; pinned rows display a ⊘ lock indicator; category list is fetched from `GET /api/v1/categories` on mount

### Frontend (web)

- **fix** Proxy API calls through Vercel to fix session cookies on Safari and Chrome incognito — `vercel.json` now rewrites `/api/:path*` to the Render backend so the session cookie is first-party, bypassing browser third-party cookie blocking (`SameSite=None` cross-site cookies were silently dropped)

### Backend

- **feat** Log security events — login success/failure logged via Python logger and audit table; service token creation/revocation emit `service_token_created` / `service_token_revoked` audit events with actor metadata
- **fix** Clean up orphaned staging objects on upload failure — `POST /jobs/upload` now deletes any storage objects already saved before the exception so storage stays consistent with DB state
- **fix** Rate limit login endpoint — sliding window (5 attempts / 60 s per IP) in `POST /auth/login`; returns 429 on excess; no new dependency
- **fix** Add missing FK indexes via migration `20260302_000012` — `job_items.job_id`, `statements.bank_code`, `statement_lines.statement_id`; also declare them in model `__table_args__`
- **fix** Enforce CORS origin list in production — `model_post_init` raises `RuntimeError` if `CCS_PLATFORM_CORS_ALLOW_ORIGINS` is `"*"` or empty when `ENVIRONMENT=production`; `create_app` disables `allow_credentials` when origins is wildcard (browser spec violation)
- **fix** Log bcrypt failures — `authenticate_credentials` now calls `logger.exception()` before returning `None` on bcrypt error; distinguishes corrupted-hash system errors from wrong-password denials
- **fix** Enforce upload size limit — new setting `CCS_PLATFORM_MAX_UPLOAD_SIZE_MB` (default 50); upload endpoint returns 413 for files exceeding the limit
- **feat** Service token expiry — add optional `expires_at` column to `service_api_tokens` (migration `20260302_000011`); `require_service_token` returns 401 if token is past its expiry; `ServiceApiTokenCreate` accepts `expires_at`; `ServiceApiTokenOut` exposes it

### Scraper

- **fix** Fail fast on missing API token — `get_config()` raises `RuntimeError` if `CCS_SCRAPER_API_TOKEN` is unset; previously the error only surfaced at upload time after a full scrape run
- **fix** Retry uploads with exponential backoff — `ScraperClient.upload_pdfs` retries up to 3 times (delays: 5 s, 15 s, 45 s) on transient server errors (5xx / network); 4xx errors are not retried

### Frontend (web)

- **refactor** Split `EmailIngestionPage.tsx` (948 lines) into focused sub-components — `MailboxesPanel`, `OAuthTokenPanel`, `BankRoutingMatrix`, `ServiceTokensPanel`, and a shared `types.ts`; main page is now ~230 lines
- **feat** Add `extractErrorMessage` utility — consistent error message extraction from `Error` objects, FastAPI JSON bodies (`{"detail":"…"}`), and strings; available in `lib/errors.ts`
- **feat** Add `ConfirmDialog` component — modal confirmation before destructive actions; used on service token revocation
- **fix** Add `ErrorBoundary` component wrapping the entire app — catches React render errors and shows a "Something went wrong" fallback with a reload button instead of a blank screen

### CI / Infra

- **feat** Add scraper test job to CI pipeline — runs `pytest` on `scraper/**` changes; no browser required (tests mock httpx)
- **fix** Expose `scraper` change-detection output in CI `changes` job — was declared in path filters but not wired to outputs
- **chore** Pin backend dependencies via `pip-compile` — `requirements.txt` now contains fully-pinned transitive versions generated from `requirements.in` / `pyproject.toml`

### Docs

- **docs** Update `ARCHITECTURE.md` — document in-process rate limiter, token expiry/audit, error boundary, and confirm dialog
- **fix** Restore `deploy/nginx/frontend.conf` — standard SPA nginx config (try_files, aggressive cache headers for hashed assets, no-cache for index.html); `Dockerfile.frontend` was broken without it
- **fix** Fix `security.yml` Trivy scan job — update Dockerfile reference from deleted `Dockerfile.app` to `Dockerfile.api`; CI security job was always failing
- **chore** Add non-root `appuser` (uid 1000) to `Dockerfile.api` and `Dockerfile.gmail-relay`; switch `Dockerfile.frontend` to built-in `nginx` user with corrected directory ownership

- **docs** Add Microsoft Outlook / Hotmail ingestion section to `PRODUCTION.md` (section 6) — Azure app registration, API permissions (`Mail.Read`, `offline_access`), client secret, Render env vars (`CCS_PLATFORM_EMAIL_INGESTION_ENABLED`, `CCS_PLATFORM_EMAIL_MS_CLIENT_ID`, `CCS_PLATFORM_EMAIL_MS_CLIENT_SECRET`), OAuth refresh token generation via admin UI, mailbox setup, and verification steps; renumber Scraper CLI section from 6 to 7
- **docs** Remove pre-deploy command from `PRODUCTION.md` — `init_db()` already runs `alembic upgrade head` automatically on startup for PostgreSQL; pre-deploy command is a paid Render feature and is not needed

### Backend

- **fix** Email ingestion `_runtime_setting_value` now falls back to Pydantic settings (`CCS_PLATFORM_EMAIL_MS_CLIENT_ID`, `CCS_PLATFORM_EMAIL_MS_CLIENT_SECRET`, etc.) when the DB row is missing — eliminates the need to duplicate OAuth client credentials as runtime settings when they are already set as env vars on the server

- **fix** MASHREQ parser: parse credit transactions whose amount ends with a trailing ` -` suffix — extend both `_ROW_RE_SHORT` and `_ROW_RE` suffix group to `(?:CR|DR|-)` and treat `-` suffix same as `CR` (negate the amount); credits appearing after the debits sub-total (e.g. inward IPP payments) were previously silently skipped

- **feat** Make service tokens profile-agnostic — drop `profile_id` FK from `service_api_tokens` (migration `20260301_000010`); add global `UNIQUE(name)` constraint; `ServiceTokenContext` no longer carries `profile_id`/`profile_key`; `get_profile_context_or_service_token` now requires `X-Profile-Key` header when using a bearer token; automation entity endpoints (`/oauth/{provider}/access-token`, `PATCH /mailboxes/{mailbox_id}/sync-state`, `POST /upload`) auto-derive profile from the mailbox/route in the request; automation list endpoints (`GET /automation/mailboxes`, `GET /automation/routes`) return data across all profiles; token management endpoints (list, create, revoke) are global and no longer scoped to the active profile

- **fix** Lazy-import `pandas` inside `build_yearly_workbook_from_statements()` — removes ~104 MB (pandas + numpy) from startup memory footprint, fixing OOM crash (exit code 3) on Render 512 MB free tier
- **fix** Lazy-import `pdfplumber` inside `_extract_pdf_text()` in `jobs.py` — consistent with lazy-import pattern; was already loaded transitively via bank parsers but removes the module-level import
- **fix** Lazy-import all bank parsers in `dispatcher.py` and `parser_validate.py` — removes pdfplumber (~15 MB) from startup; parsers are now imported only when a parse job actually runs; cleaned up `parsers/__init__.py` to stop eagerly re-exporting all 6 parsers
- **fix** Add `pool_size=2`, `max_overflow=2`, `pool_recycle=300` for PostgreSQL engine — prevents "SSL connection closed" errors caused by Render managed Postgres dropping idle connections after 5 min; keeps total connections within free tier's 25-connection limit
- **chore** Add `CCS_PLATFORM_REQUEST_LOGGING_ENABLED=false` to Render env vars in `PRODUCTION.md` and document the setting in `backend/.env.example`
- **refactor** Delete `adapters/banks/browser/` — dead browser adapter code (base, downloader, shared, and 6 bank adapters) removed from backend; confirmed zero imports outside that directory after decoupling
- **refactor** Rename package `creditcardstatementscraper` → `ccs-platform` in `pyproject.toml`; remove `playwright>=1.50` dependency
- **fix** Change `ScheduleCreate.job_type` default from `JobType.SCRAPE` to `JobType.UPLOAD` — SCRAPE has no handler and raises `ValueError` at runtime
- **chore** Add deprecation comments to `JobType.SCRAPE` and `JobType.BANK_CONNECTION_TEST` in `enums.py` — no handlers exist; kept in enum for PostgreSQL compatibility only
- **chore** Rewrite `backend/.env.example` — remove browser geo-spoofing section (`BROWSER_PROXY_URL`, `BROWSER_GEO_*`, `BROWSER_TIMEZONE_ID`, `BROWSER_LOCALE`); remove `QUEUE_BACKLOG_SLO_SCRAPE`; update `WORKER_QUEUES` default to `default`; rename "Scraper credentials" section to "Bank credentials (seeded into runtime settings)"; fix timezone comment ("scrape-month" → "billing month")

### Scraper

- **feat** Introduce `BankMap` — persistent JSON map (`state/bank_map.json`) that records each downloaded PDF's origin bank at download time; `scrape` command creates the map before scraping, passes it to `run_end_to_end_downloads`, then groups new PDFs by their recorded bank code and uploads each group with an explicit `bank_code` arg; entries are removed after a successful upload; PDFs not in the map (e.g. pre-existing files or manual downloads) fall through to the existing backend detection logic — eliminates all ambiguity in PDF→bank mapping at upload time
- **feat** Pass `bank_code_hint` from scraper to backend on `/api/v1/jobs/upload` — when the scraper knows the bank (via `BankMap` or filename prefix), it sends `bank_code_hint` as a multipart form field so the backend skips the expensive `pdfplumber` content scan entirely

- **refactor** Make bank adapter system generic and auto-discovering — add `AuthPollAction` enum and `AuthPollState` dataclass to `base.py`; expand `BankAdapter` with optional hook params (`is_authenticated_session`, `is_login_screen`, `is_login_failure`, `on_auth_poll_tick`, `skip_mfa_user_prompt`, `skip_keyword_fallback`, `skip_login_selector_fallback`, `browser_launch_overrides`); add `discover_adapters()` via `pkgutil` auto-discovery; move all bank-specific auth logic (FAB continue gate, ADCB OTP/concurrent session/re-login, MASHREQ anti-bot retry) into per-adapter `on_auth_poll_tick` hooks; replace ~135 lines of `if code ==` branching in `downloader.py` with a generic hook-based polling loop; `_launch_bank_context` now reads `channel_candidates` and `init_scripts` from `adapter.browser_launch_overrides()`; adding a new bank now requires only a new adapter module with an `ADAPTER` constant — no changes to `downloader.py`
- **docs** Add `scraper/ADDING_A_NEW_BANK.md` — step-by-step guide covering the 3 required functions, all optional hook functions with examples, `AuthPollAction`/`AuthPollState` field references, and verification commands

- **refactor** Make `--profile` a required option on `scrape` and `upload` CLI commands — remove `CCS_SCRAPER_PROFILE_KEY` env var support; `get_config(profile: str)` now requires a profile; `ScraperConfig.profile_key` defaults to `""` instead of reading from env

### Scraper

- **chore** Add `scraper/.env.example` — documents all `CCS_SCRAPER_*` settings and bank credential keys with inline comments
- **test** Add scraper test suite (`tests/`): `test_config.py` (env var parsing, profile isolation, credential filtering), `test_month_utils.py` (month name/abbreviation mapping), `test_bank_config.py` (YAML loading, path structure), `test_shared.py` (MFA/failure pattern detection, PDF snapshot utilities, `require_env`), `test_client.py` (HTTP upload request structure, headers, multipart); no browser automation required — 86 tests, all pure logic
- **chore** Add `[project.optional-dependencies] dev = ["pytest>=8.0"]` and pytest config (`testpaths`, `pythonpath`) to `scraper/pyproject.toml`; fix build backend to `setuptools.build_meta`
- **chore** Add scraper test step to `scripts/hooks/pre-commit` — runs `pytest -q` via `scraper/.venv/bin/pytest` when scraper files are staged; skips gracefully if scraper venv not found; update `scraper/README.md` to show `pip install -e ".[dev]"`

### Docs

- **docs** Create `backend/README.md` — setup, database, run commands, test instructions, key env vars, password hash generation
- **docs** Update `scraper/README.md` — expand setup section with explanation of `pip install -e .`, add `cp .env.example .env` step
- **docs** Update root `README.md` — reference `backend/README.md` in backend setup section; reference scraper `.env.example`

### Backend

- **refactor** Remove browser scraping from backend: delete `handlers/scrape.py`, `handlers/bank_connection_test.py`, `adapters/banks/browser/` (browser code moved to `scraper/`); remove `POST /jobs/scrape` and `POST /diagnostics/bank-connection-test` endpoints; remove `ScrapeJobRequest` schema; remove `SCRAPE` and `BANK_CONNECTION_TEST` from job dispatcher and service defaults; remove `browser_proxy_url`, `browser_geo_*`, `browser_timezone_id`, `browser_locale`, `queue_backlog_slo_scrape` from settings; change `worker_queues` default to `default`; remove `playwright>=1.50` from `requirements.txt`
- **feat** Add `require_operator_or_service_token` and `get_profile_context_or_service_token` dependencies in `api/deps.py`; `POST /jobs/upload` now accepts either a session (operator+) or a Bearer service token with `upload` scope — enables the scraper CLI to upload directly

### Scraper

- **feat** Add `scraper/` — standalone Python CLI package for browser-based bank statement downloads; Playwright + Chromium bank adapters (FAB, ADCB, ENBD, EIB, SIB, Mashreq) moved verbatim from backend with updated import paths; `ccs-scraper scrape` downloads PDFs and uploads to backend; `ccs-scraper upload` sends local PDFs; `ccs-scraper install-browser` installs Chromium; all config via `CCS_SCRAPER_*` env vars

### DevOps

- **chore** Delete `deploy/Dockerfile.app` (Playwright image no longer needed); update `Dockerfile.api` comment; simplify `docker-compose.prod.yml` — remove `worker` service and `edge_public` on `app_internal` containers; API service gets `CCS_PLATFORM_EMBEDDED_WORKER=true` and `edge_public` for outbound GCS/email connectivity
- **ci** Remove `deploy/Dockerfile.app` from backend path filter in `ci.yml`; add `scraper/**` filter; update `deploy-backend.yml` to remove `Dockerfile.app` from change detection pattern

### Docs

- **docs** Create `ARCHITECTURE.md` — system overview, component boundaries, data flows, auth model, technology stack, design decisions
- **docs** Rewrite `PRODUCTION.md` — single deployment plan covering Render (API), Vercel (frontend), Neon (PostgreSQL), GCS (storage), Cloud Run (Gmail relay), and local Scraper CLI; remove Plan 2 (GCP full), standalone worker, and all browser-related env vars
- **docs** Update `README.md` — add `scraper/` to directory structure, describe decoupled architecture, add Scraper CLI quick-start, remove Dockerfile.app and worker service references

### Backend

- **feat** Add `job_logs` table and `JobDBLogHandler` — captures all `ccs_platform.*` and `playwright.*` INFO+ log records emitted during a job run into `job_logs` via thread-local job ID; retention cleans up entries older than 7 days (`retention_job_logs_days=7`); `GET /jobs/{id}/logs` endpoint returns the log stream; alembic migration `20260301_000009`
- **feat** Add `JobLogOut` response schema; `GET /jobs/{job_id}/logs` endpoint (limit up to 2000)
- **feat** Statements list: rename "Date" column to "Statement Date"; add "Upload Date" column showing `ingested_at` (already in DB/API, no migration needed)
- **feat** Add `deploy-gmail-relay.yml` GitHub Actions workflow — automatically rebuilds and redeploys the `ccs-gmail-relay` Cloud Run service on changes to `gmail_ingest_relay.py`, `email_ingestion_common.py`, `requirements.txt`, or `deploy/Dockerfile.api`; uses `GCP_SA_KEY`, `GCP_PROJECT_ID`, `CCS_API_BASE_URL`, and `CCS_GMAIL_RELAY_SERVICE_TOKEN` secrets
- **fix** Eliminate temp-dir cross-process dependency in the upload pipeline: PDF uploads (manual UI and email ingestion) are now saved directly to the storage backend (GCS in prod, local `StorageAdapter` in dev) and a `storage_key` is stored in the job payload instead of a local file path; the upload job handler reads from storage and deletes the staging object after processing; backward-compatible with queued jobs that still carry `temp_path`; export workbook handler now writes to `io.BytesIO` instead of a temp file; `build_yearly_workbook_from_statements` accepts `Path | BinaryIO`; `delete(key)` added to all storage adapters (`StorageAdapter` base, `GCSStorageAdapter`, `LocalStorageAdapter`)
- **fix** Use `/consumers/` endpoint for Microsoft token refresh in `TOKEN_ENDPOINT_BY_PROVIDER`; was incorrectly using `/common/`, causing `AADSTS9002331` errors for personal-account-only app registrations
- **fix** Use `mailFolders/Inbox/messages/delta` instead of `messages/delta` in `email_ingest_microsoft.py`; Graph API does not support change tracking on the top-level messages collection, only on specific folders
- **feat** Scan `Inbox`, `DeletedItems`, and `Archive` folders per mailbox in `email_ingest_microsoft.py`; each folder tracks its own delta link in sync_state (`microsoft_delta_link_inbox`, `microsoft_delta_link_deleteditems`, `microsoft_delta_link_archive`); missing folders (e.g. no Archive) are silently skipped (HTTP 404); backwards-compatible with old single `microsoft_delta_link` key
- **fix** Handle permanently-deleted Gmail messages in `gmail_ingest_relay.py`; `get_message` 404 (message hard-deleted before relay processed the push) now skips silently instead of crashing the notification handler
- **feat** Add four optional env-var-backed settings fields (`email_ms_client_id`, `email_ms_client_secret`, `email_gmail_client_id`, `email_gmail_client_secret`) to `PlatformSettings`; sourced from `CCS_PLATFORM_EMAIL_MS_*` / `CCS_PLATFORM_EMAIL_GMAIL_*` env vars; profile-agnostic, no DB table
- **feat** Add `OAuthConfigOut`, `OAuthCodeExchangeRequest`, `OAuthCodeExchangeOut` schemas to `email_ingestion.py`
- **feat** Add `GET /api/v1/email-ingestion/oauth/config` — returns auth URLs and `configured` status for Microsoft and Gmail; auth URLs built from the new settings fields
- **feat** Add `POST /api/v1/email-ingestion/oauth/exchange-code` — exchanges an OAuth authorisation code for a refresh token entirely server-side; reads client credentials from settings; returns `OAuthCodeExchangeOut`; never persists the token

### Frontend (web)

- **feat** Remove `profile_id` from `ServiceApiTokenOut` type in `EmailIngestionPage.tsx` — tokens are now global; field no longer returned by the API

- **feat** Add **OAuth Token Setup** panel to `EmailIngestionPage.tsx` between Mailboxes and Bank Routing Matrix; one card per provider with Authorize link, code input, server-side exchange, token copy button, mailbox dropdown, and Save to Mailbox action; code input accepts raw code or full redirect URL

### Docs

- **docs** Update `PRODUCTION.md` EI-4: replace multi-step manual curl workflow with new in-UI OAuth flow (6 steps, no terminal)
- **docs** Update `backend/.env.example`: document the four `CCS_PLATFORM_EMAIL_*` OAuth credential env vars

- **refactor** Comprehensive env-var config redesign: `session.py` engine/SessionLocal creation is now lazy (`@lru_cache` `get_engine()`/`get_session_local()`); `auth/service.py` `_ACCOUNTS` replaced with lazy `_build_accounts()`; login hashes moved from raw `os.getenv()` to pydantic-settings fields (`login_hash_hussain`, `login_hash_tejasvie`); `_SUPPRESS_ENV_FILE` hack replaced with `PYTEST_CURRENT_TEST` detection in `_resolve_env_file()`; `load_dotenv()` bridge removed; `clear_settings_caches()` centralises cache-clearing for tests; `conftest.py` simplified to a clean autouse fixture
- **fix** `get_settings()` now calls `load_dotenv()` alongside pydantic-settings so that values in `backend/.env` (e.g. `CCS_PLATFORM_LOGIN_HASH_*`) are visible to `os.getenv()` calls made at module-import time (fixes HTTP 401 on local backend when hashes are set only in `.env`)
- **fix** `conftest.py` sets `_SUPPRESS_ENV_FILE=True` before importing `ccs_platform.db` so the real encryption key is never loaded into `os.environ` during pytest — encryption-related tests that use `monkeypatch` work correctly again
- **security** Remove hardcoded fallback password in `auth/service.py`; raise `RuntimeError` at startup if a login credential env var is absent in production (ROADMAP 1.1)
- **security** Add `session.rollback()` on exception in `get_db` FastAPI dependency so partial writes are never committed on error (ROADMAP 1.2)
- **security** Validate `CCS_PLATFORM_SESSION_SECRET_KEY` at startup in production — raises `RuntimeError` if the value is the insecure default or shorter than 32 bytes (ROADMAP 1.3)
- **security** Eliminate thread-unsafe `os.environ` mutation for bank credential injection; credentials are now fetched as a plain dict and passed explicitly through the adapter call chain so concurrent worker threads cannot corrupt each other's credentials (ROADMAP 1.4)
- **security** Upload endpoint (`POST /jobs/upload`) now loads ADCB PDF passwords from the `runtime_settings` table instead of `os.environ`, so credentials updated via the admin UI are reflected without a restart (ROADMAP 1.5)
- **architecture** Extract `JobRunner` God-class (1,068 lines) into `application/jobs/handlers/` package — one module per job type (`upload`, `scrape`, `reclassify`, `export_workbook`, `parser_validate`, `bank_connection_test`, `reparse`); `JobContext` dataclass decouples handlers from the runner; `runner.py` reduced to 237-line thin dispatcher (ROADMAP 2.1)
- **architecture** Introduce repository layer (`StatementRepository`, `JobRepository`, `CategoryRepository`) in `db/repositories/`; all SELECT/COUNT query logic moved out of route handlers (ROADMAP 2.2)
- **architecture** Add `BankAdapter` dataclass and `LoginFn` / `LoginSelectorVisibleFn` / `DownloadLatestStatementFn` Protocol types in `adapters/banks/browser/base.py`; `downloader.py` now registers all adapters in a single `BANK_ADAPTERS` dict instead of three separate Callable maps (ROADMAP 2.3)
- **architecture** Consolidate `MONTH_INDEX` into `domain/parsing/month_utils.py`; all five bank adapters import from the single source of truth (ROADMAP 2.4)
- **architecture** Replace bespoke RRULE parser with `dateutil.rrule.rrulestr` in `application/jobs/scheduler.py`; DAILY, MONTHLY, and YEARLY schedules now work correctly (ROADMAP 2.5)
- **testing** Add `backend/tests/conftest.py` with shared `sqlite_engine`, `db_session`, `sample_profile`, `sample_banks`, and `dev_settings` fixtures; eliminates per-file boilerplate (ROADMAP 3.6)
- **fix** Correct `ROOT_DIR` resolution in `core/bank_config.py` (`parents[2]` → points to `backend/`) so `config/banks.yaml` is found when running from the project root with `PYTHONPATH=backend`
- **refactor** Remove hardcoded `"hussain"` profile key fallback from `deps.py`; default now falls through to `get_default_profile(db)`; `ProfileContext` enriched with `is_default` field; `runtime_settings.py` guard uses `not profile.is_default` (ROADMAP 3.2)
- **refactor** Drop dead `CategoryRule` columns `priority`, `bank_code`, `card_last4` from model and all callers; Alembic migration `20260228_000007` removes the columns and `ix_category_rules_priority` index (ROADMAP 3.3)
- **refactor** Move `EXPECTED_SAMPLE_COUNTS` out of `parser_validate.py` into `domain/parsing/bank_samples.py` as `PARSER_SAMPLE_EXPECTED_COUNTS` (ROADMAP 3.4)
- **refactor** Add `backend/requirements.in` as pip-tools source-of-truth; `requirements-dev.txt` gains `pip-tools>=7.0`; run `pip-compile requirements.in` to regenerate the lock file (ROADMAP 3.5)
- **perf** Fix N+1 query in `reclassify_statement_lines`: active rules fetched once via `_fetch_active_rules(db)`; per-line matching done by pure `find_best_rule(rules, merchant)` function; dead `bank_code`/`card_last4` params removed from `categorize()` (ROADMAP 3.8)
- **fix** Log heartbeat thread errors in `runner.py` via `_log.exception()` before exiting; `_run_job` unhandled exceptions also logged; jobs now surface failures rather than silently hanging (ROADMAP 3.1 / 3.9)
- **feat** Run `alembic upgrade head` automatically at startup for non-SQLite (PostgreSQL) databases; removes need for any manual migration step or paid Render feature in production (`db/session.py` `init_db()`)
- **fix** `test_email_ingestion_api.py` tests now use an isolated per-test temp SQLite file instead of the default `platform.db`; prevents test mailboxes, tokens, and routes from leaking into the development database; deleted 64 leaked test mailboxes and related rows from `platform.db`
- **fix** `test_platform_api.py` CI failures: add `_test_platform_env` autouse fixture that sets a per-test temp SQLite DB, a precomputed bcrypt hash, and explicitly calls `init_db()` + `seed_defaults()` before the test body; all 28 tests now pass without any secrets configured in CI

### Frontend (web)

- **feat** Move Ingestion Activity out of Email Ingestion config page into its own dedicated page (`/email-ingestion/activity`) under the Operations nav section — prevents the event log from crowding configuration panels as it grows over time
- **docs** Rewrite `PRODUCTION.md` email ingestion section: full step-by-step setup guide for Azure OAuth app registration, GCP OAuth client setup, mailbox creation, refresh token flow, bank routing matrix field reference, service token creation; clarify that all OAuth credentials live in Runtime Settings (not deployment env vars); add test-data cleanup note and routing troubleshooting table

- **testing** Configure Vitest 3 + `@testing-library/react` + `jsdom` as the frontend test framework; add `npm test` and `npm run test:watch` scripts (ROADMAP 4.1)
- **testing** Extract duplicated inline utilities to `src/lib/`: `format.ts` (`formatAmount`), `errors.ts` (`isAbortError`), `useDebounce.ts` (`useDebouncedValue`); update imports in `DashboardPage`, `RawLinesPage`, `RuntimeSettingsPage` (ROADMAP 4.1 / 4.3 partial)
- **testing** Add 25 unit tests across 4 test files: `format.test.ts`, `errors.test.ts`, `useDebounce.test.ts`, `datetime.test.ts`
- **security** Remove hardcoded personal email `h_abbasi97@hotmail.com` from `LoginPage.tsx`; email field starts empty (ROADMAP 4.5)
- **fix** Add `2000` to `PAGE_SIZE_OPTIONS` in `TablePagination.tsx`; options are now `[100, 200, 500, 1000, 2000]` per CLAUDE.md rule 12 (ROADMAP 4.6)
- **refactor** Deduplicate `LoginResponse` type: defined once in `src/types/auth.ts`, imported by `App.tsx` and `LoginPage.tsx` (ROADMAP 4.7)
- **feat** `ExportsDiagnosticsPage` now fetches bank list from `GET /api/v1/banks` on mount instead of hardcoding bank codes; shows loading state; auto-selects first bank (ROADMAP 4.8)
- **refactor** Extract all data-fetching logic from `DashboardPage` into `src/lib/useDashboardData.ts` hook; `DashboardPage` reduced from 408 to ~195 lines (ROADMAP 4.9)
- **types** Eliminate all `any` typings across the frontend: new types in `src/types/statements.ts` (`Statement`, `StatementLine`, `PagedResponse`, `Schedule`, `Job`, `Bank`, `Category`, `CategoryRule`, `RuleTestResult`, `RawLine`) cover all API response shapes (ROADMAP 4.4)
- **tooling** Add ESLint 9 (flat config), `@typescript-eslint/eslint-plugin`, `eslint-plugin-react-hooks`, `prettier`, `eslint-config-prettier`; `eslint.config.js` and `.prettierrc` configured; `npm run lint` and `npm run format` scripts added; lint passes with `--max-warnings 0` (ROADMAP 4.2)

### DevOps

- **infra** Add `deploy/Dockerfile.api` — slim image with no Playwright (~500 MB smaller); docker-compose `api` service now builds from it; `Dockerfile.app` (with Playwright) retained for the `worker` service and Render embedded-worker deployments (ROADMAP 5.1)
- **fix** Add `edge_public` network to the `worker` service in `docker-compose.prod.yml` so browser scraping can reach bank websites; all other internal services remain on `app_internal` (ROADMAP 5.2)
- **chore** Remove dead `deploy/nginx/` directory; Caddy is the only reverse proxy in use (ROADMAP 5.5)
- **docs** Update PRODUCTION.md GCP section: build and push `$IMAGE_API` (Dockerfile.api) and `$IMAGE_WORKER` (Dockerfile.app) separately; deploy API and migration job from `$IMAGE_API`, worker from `$IMAGE_WORKER`

### Docs

- **ci** Add `Run frontend tests` step to `frontend-gates` job in `release-cicd.yml`; runs `npm test -- --run` before the build on every PR and push (ROADMAP 5.3)
- **docs** Expand PRODUCTION.md Plan 1 (Free) from a stub into a full step-by-step guide covering secret generation, Neon DB setup, Render Web Service and Background Worker configuration (env vars, persistent disk, queue split), Alembic migration strategy (pre-deploy command), credential seeding via admin UI, Vercel frontend deploy, CORS wiring, health-check verification, and ongoing operations (log access, storage upgrade, key rotation)
