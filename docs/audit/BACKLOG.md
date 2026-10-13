# Audit backlog: everything not yet fixed

Built on 2026-10-08 from the six pre-cutover audits ([01 database](01-database.md),
[02 data parity](02-data-parity.md), [03 server](03-server.md), [04 web](04-web.md),
[05 iOS](05-ios.md), [06 cross-cutting](06-cross-cutting.md)) and each report's **Fix status**,
as of commits `6286e6b`…`98f901c` on `ledger-v2`.

> **Legacy code removed.** After the cutover the legacy v1 code (`backend/`, `frontend/`,
> `deploy/`) and the one-off cutover script `scripts/migrate_legacy.py` were deleted from the
> repo. Findings that only concerned that script (SRV-09r, DP-17) were dropped; the audit
> reports keep their original file references, which now resolve only in git history.

- IDs are the reports' own. A trailing **r** (for example `DB-17r`) is the unfixed remainder of a
  finding that is otherwise fixed. `NEW-n` items were found while cross-checking the fixes. `MA-n`
  and `UX-n` / `N-n` are the web and iOS reports' unnumbered recommendations.
- Fixed items are not listed here; see each report's Fix status. Remove a row when its fix lands
  and mark it in that report's Fix status.
- Effort: **S** ≤ half a day, **M** 1–3 days, **L** more than 3 days.

## Summary

Findings by area and priority (UX recommendations and verification checks are counted
separately):

| Area | P2 | P3 | UX recs | Verify | Total |
|---|---|---|---|---|---|
| Database (Supabase SQL) | 0 | 2 | – | 1 | 3 |
| Edge Functions | 0 | 0 | – | – | 0 |
| Parser | 1 | – | – | – | 1 |
| Web | 0 | 6 | 0 | – | 6 |
| iOS | 0 | 18 | 0 | 2 | 20 |
| Scraper | – | 0 | – | – | 0 |
| CI, config and ops | 0 | 0 | – | 0 | 0 |
| **Total** | **1** | **26** | **0** | **3** | **30** |

There are no open P0 or P1 findings. The last P1 remainders (WEB-02 statements beyond 500 and
merchant search, WEB-07 "Retry AI") landed in `98f901c`. What is left of the P1s are the device
and production checks under [Needs verification](#needs-verification) and the cutover actions
below.

## Open operational actions

Actions, not code changes. The cutover happened on 2026-10-08 (PRODUCTION §10, §10.1); what is
left of the cutover list:

1. **Rotate the secrets that appeared in chat or logs:** the Anthropic API key, the Sentry org
   auth token, the Supabase secret key, the database password and the first `sbp_` access token
   (delete it; the CI token is `github-actions-cc-statement-scraper-prod`). Put the new values in
   the gitignored env files, Vercel, Edge Function secrets and GitHub, then revoke the old ones.
2. **Postgres upgrade** off 17.6.1.104 (§2.1). Blocked on the free tier; do it when the plan allows.
3. **Gmail:** a new OAuth client in `credit-card-scraper-ht` (PRODUCTION §5 item 6), then the
   Gmail watch. The Outlook poll is live.
4. **Real-device SMS check (V-IOS-06):** the *Message contains "Card"* automation on a locked
   phone, and whether "contains" is case-insensitive.
5. **DP-18:** the encrypted staging PDF in the legacy bucket that was never ingested.
6. **Vercel previews off** (X-32): switch them off in the Vercel dashboard (PRODUCTION §4).
7. **CI token permissions:** `supabase link` needs read access to secret API keys and the Auth /
   PostgREST / network config (PRODUCTION §10.1); until then deploy-supabase fails at link.

### Done: cutover actions (2026-10-08)

| Item | Evidence |
|---|---|
| Sign-ups off, email confirmations on (V-DB-23) | `[remotes.production]` in `supabase/config.toml`, verified with `/auth/v1/settings` |
| Data API max rows 2000 (X-07) | `d9d3bcb`; a 2500-row request returns 2000 |
| Members invited with sign-ups off | PRODUCTION §10 step 7 |
| Repo and CI: `production` environment, `main`-only policy, secrets (V-X-12, except reviewers: not on the Free plan) | docs/ci-cd.md; `LEGACY_DEPLOYS_ENABLED` deleted |
| Parser 2026.10.2 deployed; FAB and Mashreq re-parsed | PRODUCTION §10.1 steps 3–4 (FAB 20 ok, Mashreq 12 ok) |
| Full rehearsal and post-import ENBD/FAB checks | Superseded by the real cutover: §10 step 8, `legacy_lines_missing = 0` |
| TestFlight upload with the privacy manifests (V-IOS-08) | Builds 3–5 processed (§10.1 step 5) |
| Gmail OAuth client carried over from Render (X-03) | PRODUCTION §5 |

---

## P2

### Database (Supabase SQL)

None open. All twelve were done or decided on 2026-10-09: see
[Done: database pass 2026-10-09](#done-database-pass-2026-10-09).

### Edge Functions

None open. All five were done on 2026-10-09: see [Done: Edge Functions and CI pass 2026-10-09](#done-edge-functions-and-ci-pass-2026-10-09).

### Parser

| ID | Summary | Why deferred / dependency | Suggested fix | Effort |
|---|---|---|---|---|
| NEW-4 | Mashreq `card_last4` / `primary_card_last4` is the card's first four digits (BIN): `_CARD_LAST4_RE` takes the first group of "Card No 4xxx XXXX XXXX 1234". Every Mashreq statement of a profile lands on one card, SMS with the real last 4 can't match it, and the fallback statement reference carries the BIN | Found while building the synthetic golden set; fixing it changes card and account identity | Take the last group of the masked number (keep the BIN-based `legacy_fingerprint`). Decide with DP-20 first: with real last-4s, a replacement card (two in the local corpus) creates a second Mashreq account | S |

### Web

| ID | Summary | Why deferred / dependency | Suggested fix | Effort |
|---|---|---|---|---|

### iOS

| ID | Summary | Why deferred / dependency | Suggested fix | Effort |
|---|---|---|---|---|

### CI, config and ops

None open. X-16r was done on 2026-10-09: see [Done: Edge Functions and CI pass 2026-10-09](#done-edge-functions-and-ci-pass-2026-10-09).

---

## P3

### Database (Supabase SQL)

| ID | Summary | Why deferred / dependency | Suggested fix | Effort |
|---|---|---|---|---|
| DB-40 | `add_profile_member` reveals whether an email has an account (`invited` vs `added`) and adds existing users without consent | Low risk for a two-person app; needs an accept step and UI, so it goes with NEW-1 | Return one status; optional accept step (with NEW-1) | M |
| DP-20 | A FAB card replacement creates a second FAB account, splitting `statement_cycles` and utilisation history | Model change | Treat a new primary card on the same bank and holder as a replacement on the existing account, or offer "merge accounts" | M |

### Edge Functions

None open. All eight (including DB-21e) were done on 2026-10-09: see [Done: Edge Functions and CI pass 2026-10-09](#done-edge-functions-and-ci-pass-2026-10-09).

### Parser

None open (SRV-12, SRV-17 and X-25r are done).

### Web

| ID | Summary | Why deferred / dependency | Suggested fix | Effort |
|---|---|---|---|---|
| WEB-37 | No headline totals (subscriptions per year, YoY YTD delta, Trends period total/avg); partial month unmarked | Needs small RPC additions | Server totals and an "Oct (to date)" marker | M |
| WEB-40 | First-run "Key … X-Profile-Key header" jargon; "one person's cards" copy vs a "Household" example | UX copy | Move "Key" under Advanced with a generated default; fix the copy | S |
| WEB-41 | Disabled-until-valid primary buttons are ~2:1 and give no reason | UX | Keep enabled and validate on submit, or explain | S |
| WEB-42 | Revoked tokens are listed forever (the pluralisation is fixed) | UX | Collapse revoked tokens behind a "Show revoked" toggle | S |
| WEB-54 | Two pager components, duplicated helpers, `ConfirmDialog` under `rules/`, 480-line `email-section.tsx`, 470-line `data/rules.ts` | Readability | Consolidate and split | M |
| WEB-56 | Netted refunds show as AED 0.00 top merchants; columns not sortable; no per-merchant trend | UX | Gross and refund columns, sorting, a trend link | M |

### iOS

| ID | Summary | Why deferred / dependency | Suggested fix | Effort |
|---|---|---|---|---|
| IOS-24 | App and share extension can refresh the same rotating refresh token concurrently (10 s reuse window) | Needs device testing | Extension: `autoRefreshToken: false` and re-read storage before each request, or an App Group file lock | M |
| IOS-27 | Large nav titles are SF Bold while section heads are serif; redundant title and eyebrow; AED hard-coded despite `base_currency` | UI polish | Serif large titles via `UINavigationBarAppearance`; month as the Overview title; "Cycles" section; profile currency | S |
| IOS-28 | Insights draws the partial month like a full one; no average line, values or budget rule; rows not drillable | UX | Hatched current month with projection, `RuleMark` average, `chartXSelection`, rows link to filtered Activity | M |
| IOS-29 | Small presentation decisions in views (`prefix(4)`, `prefix(10)`, fallbacks) | Readability | Move into LedgerKit presentation extensions with tests | S |

### iOS parity with the web (2026-10-13 audit)

Analysis, search and filtering the web has and the iOS app lacks. Every row is backed by an RPC
that already exists; rules, categories and merchant management stay web-first by design, and CSV
export is web-only. Order is the recommended build order.

| ID | Gap | Backing RPC | Effort |
|---|---|---|---|
| PAR-1 | Activity filters: date presets and custom range, card filter, void status, source (SMS/statement) | `activity_summary`, `v_transactions` | S |
| PAR-2 | A detail sheet viewers can open too: FX rate and estimate badges, time and posted date, status badges, merchant context, related reversal, evidence timeline and SMS body | `v_transactions`, `merchant_context`, `transaction_evidence` | M |
| PAR-3 | Per-day net totals in Activity date headers | `activity_day_totals` | S |
| PAR-4 | Open Activity with filters from other screens (ring slices, uncategorised and pending counts, merchants, insights) | — (routing) | S–M |
| PAR-5 | Category drill-down screen (trend, top merchants, change vs previous period) | `category_breakdown`, `spend_breakdown` | M |
| PAR-6 | Overview pace rule and "Projected AED X by …" (fields already decoded) | `overview` | S |
| PAR-7 | Budget "expected by today" tick and over/under pace | `budget_status` | S |
| PAR-8 | Categories show change vs previous period; merchants top 20 with tap-through | `category_breakdown`, `merchant_leaderboard` | S |
| PAR-9 | Anomalies with "This is fine"; full "Worth a look" feed with links | `anomalies`, `dismiss_anomaly`, `insights` | M |
| PAR-10 | Trends: week/day buckets, account/card grouping, custom range | `spend_series`, `spend_breakdown` | M |
| PAR-11 | Bulk select with Categorise and Exclude (CSV export stays web-only) | `activity_selection_summary`, `bulk_update_transactions` | M |
| PAR-12 | Calendar heatmap, time of day, year over year, FX & travel, full subscriptions | `daily_spend`, `hour_weekday_pattern`, `yoy_compare`, `fx_spend`, `recurring_list` | M–L |
| PAR-13 | Account comparison sparklines; open a statement's PDF | `statement_cycles`, `spend_series`, storage | M |
| PAR-14 | Review: accept/reject a proposed SMS format on the phone | `resolve_review`, `set_sms_template_active` | S–M |

### Scraper

| ID | Summary | Why deferred / dependency | Suggested fix | Effort |
|---|---|---|---|---|

### CI, config and ops

| ID | Summary | Why deferred / dependency | Suggested fix | Effort |
|---|---|---|---|---|

---

## Done: database pass 2026-10-09

Migrations `20261009000100_db_ledger_fixes` (`23d9480`), `…0200_db_categorisation_and_jobs`
(`9c77e7c`), `…0300_db_sms_templates` (`398f391`), `…0400_db_ops_and_worker_rpcs` (`9f2003a`),
`…0500_db_identity_and_legacy` (`46fd89c`), tests `13`–`18` (`a843808` adds `18`). Details in
[01 Fix status](01-database.md#fix-status) and CHANGELOG.

| ID | Outcome |
|---|---|
| DB-17r | Done: `reprocess_waiting_sms` at the end of `ingest_parsed_document` |
| DB-18 | Done: `prev_month_to_date_end` |
| DB-19r | Done: select first; `merchant_aliases` kept for manual merges |
| DB-20 | Done: scalar sub-queries on the evidence index, page rows only |
| DB-21 | Done: `delete_profile`, `storage_cleanup` queue, `trg_audit` skip (the worker must drain `storage_cleanup`) |
| DB-22 | Done: sender/scope-targeted, newest first, live pattern changes only (stays synchronous, bounded at 500) |
| DB-23 | Done: confirmed-email triggers and `add_profile_member` |
| DB-24 | Done: whole-word seed rules, guarded update of untouched seed rules |
| DB-25 | Done: per-profile isolation, `private.job_errors`, `ops_health.job_errors_24h` |
| DB-26r | Done: examples ≥ 1, bank-sender patterns, per-profile LLM templates, `promote_sms_template` |
| DP-09 | Done: Cashback `MURABAHA PROFIT` / `BONUS` need `direction = credit` |
| X-10 | Decided: leave prod's `rls_auto_enable()` (PRODUCTION §2.3) |
| DP-04r | Done: statement more than 31 days ahead → `22023` |
| DB-28r | Done: `18_review_regressions` (DB-27, DB-43). Real two-connection concurrency is out of pgTAP's reach |
| DB-29r | Done: the four insight kinds are generated; `amount_drift` stays reserved (decision) |
| DB-31 | Done: `preview_rule(…, p_rule_code)` |
| DB-32r | Done: FX index; `anomalies` with window frames |
| DB-34 | Done: declined → `ignored`; `profiles.timezone` / `base_currency` documented as reserved (decision) |
| DB-35 | Accepted: ~79 random bits |
| DB-36 | Done: > 7 days from `received_at` falls back |
| DB-37 | Done: `merchant_category_skips` (`declined` per category-set hash) |
| DB-38 | Done: 7-day windows, bounded cron scan |
| DB-39 | Done |
| DB-41 | Decided: no squash, every migration is in production; Appendix A updated; stale name noted in PRODUCTION §2.3 |
| DB-44 | Done: new transactions are inserted fully derived (one categorisation each) |
| DB-45 | Done: `overview.pending_unpriced_count` (the web/iOS can show it) |
| DP-19 / X-24 | Done: `legacy_category_aliases`, `legacy_unresolved_category_names()` |
| DP-21 | Accepted: noted in PRODUCTION §2.6 |
| X-23 | Done |
| X-33 | DB part done (AED `fx_rate`, sub-1e-8 rate); the `concat_ws` line key is kept on purpose (changing it would re-key all evidence); iOS part is X-33r above |

## Done: Edge Functions and CI pass 2026-10-09

Also done after the merge: WEB-14 (the web Merchants tab's Reject calls `reject_merchant_suggestion`, `76a4667`), SRV-13 parser half and SRV-24 (parser pass).

Commits `24ec851`…`584b039`, then reconciled with the database pass (it uses its
`save_mailbox_sync_state`, `begin_document_parse`, `resubmit_document` and `ops_health()`
shapes). New: migration `20261009100100_storage_cleanup_worker` and test `19`. Details in
[03 Fix status](03-server.md#fix-status), [06 Fix status](06-cross-cutting.md#fix-status) and
CHANGELOG.

| ID | Outcome |
|---|---|
| SRV-05 | Done: gmail-push budget (503 to continue), per-page cursor, watch-label filter, reported 404 reset with a bounded backfill |
| SRV-07 | Done: native / `@std` base64 (~45 ms per 20 MB); attachments over 25 MB skipped before download |
| SRV-10 | Done: `evaluateHealth` on the `ops_health()` mailbox lists, `job_errors_24h`, queued-document age |
| SRV-11r | Done: fake Db/fetch tests for gmail-push, outlook-poll, `storeDocument`/`ingestAttachment`, token rotation, worker, ops-monitor; e2e viewer 403 on upload and SMS |
| NEW-1 | Backend done: `member-invite` Edge Function. The web/iOS buttons are NEW-1r |
| SRV-14 | Done: rotation save failures reported; `last_error` recorded and cleared by gmail-push, gmail-watch-renew, outlook-poll |
| SRV-15 | Done: `saveSyncState` → `save_mailbox_sync_state` |
| SRV-18 | Done: email regex in the Edge and parser scrubbers, fixed constraint messages; per-request Sentry tags (the interleaving test proved they leaked) |
| SRV-19 | Done: permanent gmail-push failures recorded and acked; the subscription's dead-letter topic already existed |
| SRV-20 | Done: uploads call `resubmit_document`; the worker claims with `begin_document_parse` |
| SRV-22 | Done: a DLQ alerts when it grew (`newest_age_s < 900`), then daily |
| SRV-23 | Done: `_shared/provider.ts`, `prepareDocument`, fetch/classify/apply split, checked status writes |
| DB-21e | Done: the worker drains `storage_cleanup`; `storage_cleanup_dlq`, `kick_worker` and the DLQ tools cover it |
| SRV-13 | Edge part done (frozen `deno.lock`); the parser part is SRV-13r |
| X-16r | Done: `supabase/functions/.env.example` (names only) and a guard test |
| X-26 | Done: `deno check` in CI; `ios-build.yml` compiles the app and extension (golden parity in CI stays SRV-24) |
| X-32 | Decided: Vercel Preview deployments off (PRODUCTION §4; a dashboard switch) |
| FV-04 | Already covered by `scripts/ci/check-migrations.sh` (`diff` in CI and hooks; `remote local` for edited local migrations) |

---

## UX recommendations not yet implemented

### Web (04 "Missing analytics the backend already supports")

| ID | Recommendation | Dependency | Effort |
|---|---|---|---|

(04's sixth item, projected month end and subscriptions total, is WEB-26 and WEB-37 above.)

### iOS (05 "Top 5" and "iOS-native opportunities")

| ID | Recommendation | Dependency | Effort |
|---|---|---|---|

(05's recommendations 3–5 are IOS-19r, IOS-20r, IOS-18, IOS-28 and IOS-17 above.)

---

## Done: backlog batch 6 (2026-10-13)

Branch `batch/backlog-6`, migrations `20261013180516_statement_payment_status`,
`…181102_activity_day_totals`, `…181400_merchant_context`, `…183327_statement_due_skips_paid`,
pgTAP `48`–`50`. New iOS target `LedgerWidgets` (`com.hussu97.ledger.widgets`). Audited after merge:
the overdue rule counts payments made so far (a minimum paid late is part paid), the nightly
`statement_due` insight skips paid statements, and the iOS fixes for due reminders, paid
statements in widgets and Arabic-locale Wallet currencies. N-5 was closed by decision.

| ID | Outcome |
|---|---|
| UX-1r, WEB-36 | Done: `v_statement_payments` → `payment_status` / `amount_paid` on `overview`, `statement_cycles`, `statement_detail`; web and iOS show Paid / Part paid / Overdue and "Due today / tomorrow / in N days"; iOS hero shows "+ AED X pending" |
| MA-1 | Done: `/insights/category/$code` with trend, top merchants and change vs previous period |
| MA-2 | Done: Cards "Balances, utilisation and spending" sparklines per account |
| MA-3 | Done: `activity_day_totals`; per-day net in Activity date headers |
| MA-4 | Done: `merchant_context`; visits, average, 6-month total in the drawer |
| MA-5 | Done: Insights "Worth a look" tab grouping every open insight |
| N-1 | Done: local notifications (unknown card, captures stuck > 1 h, waiting while signed out) and due reminders T-3 / T-0 at 09:00 Dubai; one switch per kind |
| N-2 | Done: Home and Lock Screen widgets from an App Group snapshot; no amounts on the Lock Screen with Require Face ID |
| N-3 | Done: Month Spend, What's Due, Categorise Last Transaction intents and Shortcuts phrases |
| N-4 | Done: Open Uncategorised and Add Statement controls; `ledger://uncategorised`, `ledger://add-statement` |
| IOS-06g | Done: three Shortcuts-editor screenshots in the SMS guide |
| (user) | Log Card Payment takes the currency from the Wallet transaction's Amount; "Currency if missing" is only a fallback, never for an unrecognised symbol |

## Done: backlog batch 5 (2026-10-13)

Branch `batch/backlog-5`, migrations `20261013111525_uk_uncategorised` and
`20261013112601_budget_status_pace`, pgTAP `46` and `47`. Audited after merge: the "Debug ATS"
build phases were made to hide the build environment (a test now checks every phase), amounts you
pay keep two decimals, and the pending strip makes no claim before the overview loads. The IOS-21r
token moved to the keychain item `ledger-sentry-auth-token`; Vercel's `SENTRY_AUTH_TOKEN` was
replaced with it.

| ID | Outcome |
|---|---|
| WEB-31 | Done: "Uncategorised" in UI, iOS and RPC labels; pgTAP 46 and `uk-spelling.test.ts` guard it |
| WEB-34 | Done: `formatTotal` / `<Money total>`: transactions two decimals, limits and aggregates whole units; outstanding balance and statement totals stay exact |
| WEB-35 | Done: the pending strip is one server-figure line; pending rows appear once, in Recent |
| WEB-38 | Done: `budget_status` `expected_share` / `expected_aed` / `over_pace_aed`; meters show an "expected by today" tick and over/under pace |
| WEB-49 | Done: trimmed notes comparison; exact preview counts |
| WEB-52 | Done: `dt`/`dd` groups, named meters (`Meter.label` required), 404 in the shell, skip link |
| WEB-53 | Done: SVG category ring; monthly bars lazy; the bundle budget fails if Overview loads charts before rendering |
| WEB-55 | Done: `usePager` reset test |
| IOS-21r | Done: Release reads only `Secrets.Release.xcconfig` with a "Check release config" phase; `release-config-check.sh` on the archive and IPA; `sentry-release.sh`; the token from the shell or keychain |
| IOS-25r | Done: no Swift 6 warnings |
| IOS-26 | Done: Activity sections cached by revision and day; shared locked ISO formatters |
| IOS-30 | Done: query strings and fragments stripped from Sentry URLs, breadcrumbs and spans; `NSAllowsLocalNetworking` in Debug only |
| IOS-07r | Done: `ledger://review` deep link; Shortcut results say "Needs a look in Review" and never open the app |
| SRV-16r | Done: uploads tracked by path; `upload` records partial successes and exits 1 cleanly |

## Done: backlog batch 4 (2026-10-13)

Branch `batch/backlog-4`, migrations `20261013042808_activity_bulk_actions` and
`20261013042809_large_transaction_merchant_title`, pgTAP `44` and `45`. Audited after merge (CSV
formula check hardened for leading spaces). IOS-21r was built but held back (see its row).

| ID | Outcome |
|---|---|
| WEB-24 | Done: `activity_selection_summary`, `bulk_update_transactions` (owner), `activity_export` take ticked codes or the Activity filter, never neither; the bulk bar shows the server total, "Select all N", Exclude/Include and Export CSV (formula-safe cells, decimal-string money, UTF-8 BOM) |
| WEB-16r | Done: the nightly `large_transaction` insight is titled with the merchant name |
| WEB-13r | Done: regex syntax is judged only by `preview_rule` (22023), so Postgres-only syntax can be saved |
| WEB-46 | Done: the drawer loads `txn=` only from the active ledger and offers to switch when it belongs to another |
| WEB-47 | Done: `dubaiDate()`; timestamps show their Dubai day |
| WEB-50 | Done: `SECRET_MUTATION` (`gcTime: 0`) on token, PDF password and mailbox secret mutations |
| IOS-18 | Done: the transaction sheet is large and searchable, with None, merchant-wide by default unless the category is the transaction's own choice, exclude and notes; Activity swipe actions; viewers get no write controls |
| X-33r | Done: the overview model decodes by its snake_case wire keys (`WireKeyedContainer`) and carries `spend_avg_3m_to_date` / `projected_month_end` |

## Done: backlog batch 3 (2026-10-13)

Branch `batch/backlog-3`, migrations `20261012234036_anomalies_plain_and_dismissals` and
`20261013001856_review_context`, pgTAP `42` and `43`. Audited after merge; the sign-in redirect
validator was tightened (dot segments could normalise to `//host`).

| ID | Outcome |
|---|---|
| WEB-16 | Done: `anomalies` returns merchant and category names, `baseline_scope`, `times_usual`; a first purchase needs a known merchant, ≥ AED 500 and ≥ 2× the category's usual; "This is fine" (`dismiss_anomaly`, `anomaly_dismissals`). Insight titles are WEB-16r |
| WEB-10r | Done: `review_context` loads a page of reviews' context in one call; transaction events refetch only the open-review list |
| WEB-27 | Done: "Get your ledger going" checklist on an empty ledger, each step proven by data, unknown when unreadable |
| WEB-39 | Done: `/signin?redirect=` carries a validated same-origin path through email code and passkey sign-in |
| SRV-16 | Done: atomic `uploaded.json` / `bank_map.json`, corrupt files kept aside, server-normalised filenames. Remainder SRV-16r |
| NEW-3 | Done: scraper README and `.env.example` document the upload limits and batch-and-retry |
| X-34 | Done: `packages/db-types/scripts/gen-types.mjs` sorts `Relationships`; `db:types`, `db:types:check`, pre-push and CI use it |
| IOS-11 | Done by IOS-10 (batch 1): `38_sms_otp_filter` fails when a `sms_templates` example is missing from the shared fixture, and `SMSOTPParityTests` runs the same bodies on the device filter |

## Done: backlog batch 2 (2026-10-13)

Branch `batch/backlog-2`, migrations `20261012215047_overview_pace` and
`20261012220834_category_palette_16`, pgTAP `40` and `41`. Audited after merge (three review
passes); the projection was corrected for ledgers with under three months of history. The iOS
work was rebased onto the Wallet outbox refactor (`OutboxItem`).

| ID | Outcome |
|---|---|
| WEB-26 | Done: `overview` returns `spend_avg_3m_to_date` and `projected_month_end` (`spend_pace`, `month_to_date_end`); the web pace rule pins "3-month average by the Nth" and "Projected AED X by 31 Oct" |
| WEB-17r | Done: 16 categorical hues (ΔE ≥ 15, ≥ 3:1 in both themes); ten seeded categories recoloured by a guarded migration. 26 spend categories over 16 hues still share ten hues, each pairing a frequent with a rare category |
| WEB-11 | Done: first load 377 → 177 kB gz; Sentry and Replay load after first paint (deployed builds only); `/signin` and `/privacy` carry no Radix or charts; a bundle budget runs in every `vite build` |
| IOS-12r | Done: SMS and card payments captured with no ledger wait in the outbox and are adopted by the "SMS go to" ledger; sign-out confirms and clears the device queue; stuck-outbox Settings badge and Overview strip |
| IOS-22 | Done: privacy cover when not active; optional Require Face ID (device check pending) |
| IOS-23 | Done: an empty ledger shows a set-up checklist (SMS capture, a statement, a member), each step proven by server data |
| WEB-28i | Done: iOS Budgets split `budget_status(p_include_inactive)` on `is_effective`; the device selection logic is gone |

## Done: backlog batch 1 (2026-10-13)

Branch `batch/backlog-1`, migrations `20261012210407_budget_status_is_effective` and
`20261012212011_sms_otp_filter`, pgTAP `37` and `38`. Audited after merge (two review passes);
the OTP pattern was also run read-only against every production SMS (0 of 123 matched).

| ID | Outcome |
|---|---|
| NEW-1r | Done (web): Settings → Members invites through `member-invite`, "Resend invite" on pending members with cooldown / already-active messages. iOS has no Members screen |
| WEB-09 | Done: a fresh Realtime topic per effect run (`channelTopic`), also for the document-events channel |
| WEB-12 | Done: "Apply to merchant" resets on pick, Escape and outside click |
| WEB-13 | Done: Save is blocked while `preview_rule` rejects the rule (22023) and shows the server's reason; other preview failures offer Try again. The JS pre-check remainder is WEB-13r |
| WEB-28 | Done (web): `budget_status` returns `is_effective` (and `p_include_inactive`); Budgets render errors and use the server flag. iOS remainder is WEB-28i |
| IOS-10 | Done: one OTP pattern, `private.sms_otp_pattern()` = `SMSCapture.otpPatternSource`, pinned by the shared fixture in `38_sms_otp_filter` and `SMSOTPParityTests`; every `sms_templates` example is must-send |
| IOS-19r | Done: caption text uses `muted`; iOS pairs in `tokens.json#contrast.ios`; `PaletteUsageTests` fails on `subtle` text |
| IOS-20r | Done: the Overview hero is one VoiceOver element ("October spend, posted so far, 860 dirhams") |

## Done: release 2026-10-09

WEB-15, WEB-19, WEB-20, WEB-22r, WEB-30, WEB-32, WEB-33, WEB-43, WEB-44 (mobile web audit), WEB-48
(upload limit), IOS-13, IOS-14, IOS-15 (iOS paging), IOS-16r, IOS-17 (upload queue and per-file log);
WEB-24 and IOS-20r partly (rows reworded above). New features: statement detail, spend split, bank
logos, upload/parse event log, infinite scroll, iOS month navigation, replacement cards, private
merchant masks (PRODUCTION §10.2).

## Closed without change (2026-10-08)

| ID | Why |
|---|---|
| DP-22 | Only mattered for cutover rehearsals on the shared stack |
| X-33r (database row) | Decided: the `concat_ws` line key stays (re-keying every line is worse); the iOS half stays open |
| WEB-51 | Accepted: strict CSP; nothing to change |
| IOS-08r | Accepted: personal use; revisit only if distributed |
| IOS-31 | Accepted filter edge cases |
| N-5 | Decided (2026-10-13): no Live Activities; the only candidate ("Parsing N statements…") isn't worth a new surface |

## Needs verification

Checks that only a real device or the production project can answer. Each is fixed in code or
docs, but unproven where it matters.

| ID | What to verify | Where / how | Effort |
|---|---|---|---|
| V-IOS-06 | The single *Message contains "Card"* automation fires once per alert on a locked phone, with alphanumeric senders, and passes body and sender; **whether "contains" is case-insensitive** (the ENBD refund says "card"). If it isn't, add a second automation on "card" | Real iPhone, one alert per bank format | S |
| V-IOS-09 | A signed Release build on a device saves the session to the shared keychain and App Group, so the App Intent and the share extension see it | TestFlight build, sign in, run Send test and a share | S |
| V-DB-13 | Which `statement_timeout` applies to the worker's `ingest_parsed_document` call in prod (PostgREST as `service_role`, possibly the `authenticator` 8 s). With the function-level timeout gone, a very large re-ingest could hit `57014` and retry to the DLQ | `select rolname, rolconfig from pg_roles where rolname in ('authenticator','service_role');` on prod; time the largest statement during the canary | S |
