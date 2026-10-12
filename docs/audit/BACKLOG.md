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
| Web | 4 | 20 | 5 | – | 29 |
| iOS | 3 | 9 | 7 | 2 | 21 |
| Scraper | – | 2 | – | – | 2 |
| CI, config and ops | 0 | 1 | – | 0 | 1 |
| **Total** | **8** | **34** | **12** | **3** | **57** |

There are no open P0 or P1 findings. The last P1 remainders (WEB-02 statements beyond 500 and
merchant search, WEB-07 "Retry AI") landed in `98f901c`. What is left of the P1s are the device
and production checks under [Needs verification](#needs-verification) and the cutover actions
below.

## Open operational actions

Actions, not code changes. The cutover happened on 2026-10-08 (PRODUCTION §10, §10.1); what is
left of the cutover list:

1. **Rotate the secrets that appeared in chat or logs:** the Anthropic API key, the Sentry org
   auth token, the Supabase secret key, the database password and the first `sbp_` access token
   (delete it; the CI token is `github-actions-<project>-prod`). Put the new values in
   the gitignored env files, Vercel, Edge Function secrets and GitHub, then revoke the old ones.
2. **Postgres upgrade** off 17.6.1.104 (§2.1). Blocked on the free tier; do it when the plan allows.
3. **Gmail:** a new OAuth client in `<gcp-project>` (PRODUCTION §5 item 6), then the
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
| WEB-10r | Each review card runs 1–3 context queries, and every `transactions` event invalidates all review contexts | The badge part is fixed (head count) | One `review_context` RPC per list; invalidate only `["p", code, "reviews", "open"]` on txn events | M |
| WEB-16 | Anomalies show raw uppercase descriptions as separate rows, flag "Large first purchase" on a charge below usual, and use jargon | Partly server-side (`anomalies`) | Return `merchant_name`, require first purchase **and** above threshold, phrase as "about 4× your usual Shopping purchase", add a "this is fine" action | M |
| WEB-24 | Bulk bar: phone selection and Categorise are done; still no Exclude, Export CSV or server-computed selection total | UX | Add those actions (server total via an RPC) | M |
| WEB-27 | Empty ledger shows AED 0.00, an empty ruler and four empty states; no first-run guidance | Out of the P1 pass | "Get your ledger going" checklist from server state: statement, mailbox, PDF passwords, SMS shortcut, member | M |

### iOS

| ID | Summary | Why deferred / dependency | Suggested fix | Effort |
|---|---|---|---|---|
| IOS-11 | SMS filter tests use invented bodies, not the `sms_templates` examples (the pre-push hook compiles the app and extension; no macOS CI) | Test fixture | Export template examples to a fixture with a drift check | M |
| IOS-18 | Category sheet opens at `.medium` (3 categories), no search, no "None", merchant toggle defaults off, no notes or exclude-from-spend | UX, out of the P1 pass | `.large` + `.searchable`, merchant toggle on unless the category is manual, "Exclude from spend" and notes, swipe actions on rows | M |
| IOS-21r | Release config still includes the local `Secrets.xcconfig` (one dropped key ships a local value); no assertion on the archived Info.plist; no Sentry releases; the token in `Secrets.Release.xcconfig` is an Xcode build setting (also X-28) | Only the token handling in `publish-build.sh` was done | Include `Secrets.xcconfig` from `Debug.xcconfig` only; `plutil` asserts on the archived app and `.appex` (https, `production`, non-empty keys); `sentry-cli releases new/set-commits/finalize`; keep the token in the shell or keychain | M |

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
| WEB-13r | The rule editor still pre-checks regex syntax with JS `RegExp`, so Postgres-only syntax (embedded options such as `(?b)…`) is blocked on the client | Found in the batch-1 WEB-13 fix; only the opposite direction was in scope | Drop the JS pre-check and let `preview_rule` (22023) judge | S |
| WEB-31 | "Uncategorised" vs "Uncategorized" across UI, Trends and the server name | Polish | UK spelling everywhere, server name included | S |
| WEB-34 | Mixed decimals for the same kind of figure | Polish | Two decimals for transactions, whole units for balances, limits and aggregates | S |
| WEB-35 | "Pending from SMS" and "Recent activity" show largely the same rows | UX | Merge, or exclude pending from Recent | S |
| WEB-36 | "Due in 0 d"; past dues show no paid/overdue state | Needs payment-matched status from the server (also iOS "Paid") | "Due today/tomorrow"; server flag for a payment covering the statement | M |
| WEB-37 | No headline totals (subscriptions per year, YoY YTD delta, Trends period total/avg); partial month unmarked | Needs small RPC additions | Server totals and an "Oct (to date)" marker | M |
| WEB-38 | Budgets have no "expected by today" tick or "AED X over pace" | UX | Today tick on meters, over-pace text | S |
| WEB-39 | Deep links are lost on sign-in | UX | Carry a same-origin `redirect` through `/signin` | S |
| WEB-40 | First-run "Key … X-Profile-Key header" jargon; "one person's cards" copy vs a "Household" example | UX copy | Move "Key" under Advanced with a generated default; fix the copy | S |
| WEB-41 | Disabled-until-valid primary buttons are ~2:1 and give no reason | UX | Keep enabled and validate on submit, or explain | S |
| WEB-42 | Revoked tokens are listed forever (the pluralisation is fixed) | UX | Collapse revoked tokens behind a "Show revoked" toggle | S |
| WEB-46 | The drawer loads a `txn=` from another profile (no `profile_code` filter) | RLS still applies; confusing only | `.eq('profile_code', …)` and a "belongs to another ledger" state | S |
| WEB-47 | `timestamptz.slice(0,10)` / `toISOString()` show the UTC day, not the Dubai day | Polish | `todayDubai(new Date(ts))` | S |
| WEB-49 | Notes stay dirty after saving padded text; preview shows "1,000+" though counts are exact | Polish | Compare trimmed; drop the cap text | S |
| WEB-50 | New token plaintext and PDF passwords linger in the MutationCache ~5 min | Hygiene | `gcTime: 0` on those mutations | S |
| WEB-52 | `<a>` directly in `<dl>`, unnamed `role=meter`, 404 outside the shell, no skip link | a11y polish | `<div><dt/><dd/></div>`, `aria-label`, 404 in the shell, "Skip to content" | S |
| WEB-53 | Overview loads the 285 kB Recharts chunk for one donut | Perf | Hand-rolled SVG ring | S |
| WEB-54 | Two pager components, duplicated helpers, `ConfirmDialog` under `rules/`, 480-line `email-section.tsx`, 470-line `data/rules.ts` | Readability | Consolidate and split | M |
| WEB-55 | The `usePager` page reset on filter change is untested (the other helpers have tests) | Test gap | One unit test for the reset | S |
| WEB-56 | Netted refunds show as AED 0.00 top merchants; columns not sortable; no per-merchant trend | UX | Gross and refund columns, sorting, a trend link | M |

### iOS

| ID | Summary | Why deferred / dependency | Suggested fix | Effort |
|---|---|---|---|---|
| IOS-07r | No deep link from a Shortcut result to the Review screen | The Review screen shipped | `ledger://review` URL handled by the app; use it in the intent's result | S |
| IOS-24 | App and share extension can refresh the same rotating refresh token concurrently (10 s reuse window) | Needs device testing | Extension: `autoRefreshToken: false` and re-read storage before each request, or an App Group file lock | M |
| IOS-25r | Two Swift 6 warnings remain (`nonisolated(unsafe)` in `LedgerDates`, deprecated `Breadcrumb.data` setter) | Reentrancy part fixed (flushes chained) | Fix both warnings | S |
| IOS-26 | `ActivityModel.sections` re-sorts on every body evaluation; an `ISO8601DateFormatter` per timestamp | Perf | Cache sections on state change; static formatters | S |
| IOS-27 | Large nav titles are SF Bold while section heads are serif; redundant title and eyebrow; AED hard-coded despite `base_currency` | UI polish | Serif large titles via `UINavigationBarAppearance`; month as the Overview title; "Cycles" section; profile currency | S |
| IOS-28 | Insights draws the partial month like a full one; no average line, values or budget rule; rows not drillable | UX | Hatched current month with projection, `RuleMark` average, `chartXSelection`, rows link to filtered Activity | M |
| IOS-29 | Small presentation decisions in views (`prefix(4)`, `prefix(10)`, fallbacks) | Readability | Move into LedgerKit presentation extensions with tests | S |
| IOS-30 | Sentry failed-request capture can carry Activity search text in the PostgREST URL; `NSAllowsLocalNetworking` ships in Release | Hygiene | Strip query strings in `beforeSend`; set the ATS key in Debug only | S |
| X-33r | iOS relies on Foundation's `spend_avg_3m` → `spendAvg3M` key mapping (the DB parts of X-33 were fixed on 2026-10-09) | Minor | Explicit `CodingKeys` on the overview model | S |

### Scraper

| ID | Summary | Why deferred / dependency | Suggested fix | Effort |
|---|---|---|---|---|
| SRV-16 | `uploaded.json` is written non-atomically and a corrupt file is silently treated as empty; long or padded filenames never get recorded | Out of the P1 pass | Temp file + `os.replace`, keep a `.corrupt` copy with a warning; normalise names before matching | S |
| NEW-3 | `scraper/README.md` doesn't document `CCS_SCRAPER_UPLOAD_MAX_FILES` / `_MAX_MB` or the batch-and-retry behaviour (root README does) | File outside the docs pass | Add both to the scraper README's env table and upload section | S |

### CI, config and ops

| ID | Summary | Why deferred / dependency | Suggested fix | Effort |
|---|---|---|---|---|
| X-34 | `pnpm db:types:check` can flip between resets: two `v_transactions` relationships share the FK name `accounts_bank_code_fkey` and the generator orders them nondeterministically | Seen during batch 2; CI has passed so far | Normalise the generated file (stable sort of `Relationships`) in `db:types` and `db:types:check`, or give the view's second bank join a distinct FK-backed name | S |

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
| MA-1 | Category drill-down over time: a per-category trend and its top merchants instead of jumping to Activity | `spend_series(p_group='category')`, `category_breakdown.prev_amount` exist | M |
| MA-2 | Card and account comparison: statement-balance trend and utilisation sparkline per account on Cards | `spend_series` account/card grouping, statement utilisation | M |
| MA-3 | Activity summary row ("498 transactions · AED 52,300") and per-day totals in date headers | A small sum RPC for the filtered set | S |
| MA-4 | Merchant context in the drawer ("13th visit · avg AED 254 · AED 3,306 in 6 months") | `merchant_leaderboard` / `v_spend` | S |
| MA-5 | "Worth a look" insight feed on Insights, linked by kind (cards on Overview already link) | — | S |

(04's sixth item, projected month end and subscriptions total, is WEB-26 and WEB-37 above.)

### iOS (05 "Top 5" and "iOS-native opportunities")

| ID | Recommendation | Dependency | Effort |
|---|---|---|---|
| UX-1r | Overview truthfulness, remaining part: show pending in the hero ("incl. AED 3,105 pending") and "Paid" for past dues | "Paid" needs the server payment flag (WEB-36) | S (+ server M) |
| N-1 | Local notifications: (a) only for actionable intent outcomes (unknown card, outbox stuck > 1 h, signed out), permission asked from the SMS guide; (b) statement due reminders at T-3 and T-0 from `statement_cycles` | — | M |
| N-2 | WidgetKit Home and Lock Screen widgets (month spend and pace, next due, utilisation) from an App Group snapshot JSON, no network | Also ROADMAP §5 | M |
| N-3 | App Intents beyond SMS: "How much have I spent this month?", "What's due?", a `CategoryEntity` with "Categorise last transaction" | Existing `AppShortcutsProvider` | M |
| N-4 | Controls (Control Center / Action button): "Open Uncategorised", "Add statement" | — | S |
| N-5 | Live Activities: low value; at most "Parsing 3 statements…" after a share. Recommendation: don't build before N-1 to N-4 | — | – |
| IOS-06g | SMS guide: an inline three-image strip for the iOS 18 Shortcuts UI (variable picker for "Shortcut Input") | Screenshots from a device | S |

(05's recommendations 3–5 are IOS-19r, IOS-20r, IOS-18, IOS-28 and IOS-17 above.)

---

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

## Needs verification

Checks that only a real device or the production project can answer. Each is fixed in code or
docs, but unproven where it matters.

| ID | What to verify | Where / how | Effort |
|---|---|---|---|
| V-IOS-06 | The single *Message contains "Card"* automation fires once per alert on a locked phone, with alphanumeric senders, and passes body and sender; **whether "contains" is case-insensitive** (the ENBD refund says "card"). If it isn't, add a second automation on "card" | Real iPhone, one alert per bank format | S |
| V-IOS-09 | A signed Release build on a device saves the session to the shared keychain and App Group, so the App Intent and the share extension see it | TestFlight build, sign in, run Send test and a share | S |
| V-DB-13 | Which `statement_timeout` applies to the worker's `ingest_parsed_document` call in prod (PostgREST as `service_role`, possibly the `authenticator` 8 s). With the function-level timeout gone, a very large re-ingest could hit `57014` and retry to the DLQ | `select rolname, rolconfig from pg_roles where rolname in ('authenticator','service_role');` on prod; time the largest statement during the canary | S |
