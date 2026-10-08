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
| Database (Supabase SQL) | 12 | 20 | – | 2 | 34 |
| Edge Functions | 5 | 7 | – | – | 12 |
| Parser | 2 | 1 | – | – | 3 |
| Web | 16 | 26 | 5 | – | 47 |
| iOS | 14 | 10 | 7 | 3 | 34 |
| Scraper | – | 2 | – | – | 2 |
| CI, config and ops | 1 | 6 | – | 1 | 8 |
| **Total** | **50** | **72** | **12** | **6** | **140** |

There are no open P0 or P1 findings. The last P1 remainders (WEB-02 statements beyond 500 and
merchant search, WEB-07 "Retry AI") landed in `98f901c`. What is left of the P1s are the device
and production checks under [Needs verification](#needs-verification) and the cutover actions
below.

## Do before / at cutover

These are actions, not code changes. Most are already steps in [PRODUCTION.md](../../PRODUCTION.md) §10.

1. **Rotate the exposed secrets.** The Anthropic API key and the Sentry org auth token appeared in
   chat transcripts and logs during development. Create new ones, put them in
   `supabase/functions/.env.production` (Anthropic) and in Vercel plus your shell (Sentry), and
   revoke the old ones. (PRODUCTION §10, Before the day)
2. **Dashboard settings** (PRODUCTION §2.7): sign-ups **off** before the day (DB-04, WEB-04),
   Postgres upgrade off 17.6.1.104 at step 3, Data API *Max rows* = 2000 at step 4 (X-07), Site
   URL and redirects at step 9. While there, check Auth → *Confirm email* (V-DB-23).
3. **Members with sign-ups off.** After `--step metadata`, invite both emails through Dashboard →
   Authentication → Users → *Invite user*; the pending invites attach on user creation
   (PRODUCTION §2.2). There is no in-app invite yet (NEW-1).
4. **Repo and CI.** `gh variable set LEGACY_DEPLOYS_ENABLED --body true` **before** merging
   `ledger-v2` into `main`; create the `production` environment with its secrets and a `main`-only
   branch policy (V-X-12).
5. **Parser.** Bump `PARSER_VERSION` (NEW-2), deploy to `credit-card-scraper-ht` / `me-central1`,
   put the URL in `PARSER_URL`, and check `/health`.
6. **Gmail OAuth client** from Render into `GMAIL_OAUTH_CLIENT_ID/SECRET` before Render is
   deleted (X-03).
7. **Full rehearsal with the final code** on the local stack loaded from a fresh prod backup:
   migrations from scratch (the step 4 `db push` path on a prod-schema copy, 02 "Runbook
   problems" 1, X-09), then metadata, secrets, pdfs, drain, post-import checks, finalize. Target:
   `legacy_lines_missing = 0` for every bank and only the expected deltas (02 "Recommended fix
   order" 5). The earlier re-run covered only the ADCB/SIB documents, before the ENBD and FAB
   parser fixes.
8. **Post-import ENBD/FAB checks** (PRODUCTION step 8): no statement with an impossible date,
   requeue anything parsed before the parser deploy, supersede a stale bad-year ENBD statement
   if one survives, and dismiss its `period_overlap` reviews.
9. **Real-device SMS checks** before relying on SMS capture: the single *Message contains
   "Card"* automation, including whether "contains" is case-insensitive (V-IOS-06), and the first
   TestFlight upload with the privacy manifests (V-IOS-08).
10. **Manual data decisions:** the encrypted staging PDF in the legacy bucket that neither legacy
    nor v2 ever ingested (DP-18); legacy typo categories reported by
    `private.legacy_unmatched_choices()` at finalize (DP-19/X-24); leave or drop prod's
    `public.rls_auto_enable()` (X-10).
11. **Vercel previews** talk to production (X-32): turn previews off for the `apps/web` project, or
    accept it knowingly.

---

## P2

### Database (Supabase SQL)

| ID | Summary | Why deferred / dependency | Suggested fix | Effort |
|---|---|---|---|---|
| DB-17r | An `unknown_card` SMS is re-processed only when its review is resolved, not when a later statement registers the same card | Outside the functions touched in the P1 pass | After `ensure_card` inserts a card, re-process `sms_messages` with `account_code is null` and the same bank and last4, and auto-resolve their reviews | S |
| DB-18 | `overview`'s month-to-date base overruns into the current month on the 29th–31st, so `change_vs_prev_month_to_date` is wrong those days | Deferred P2 | `least(v_prev + v_day, v_month)` plus a pgTAP case for 30 Mar and 31 Dec | S |
| DB-19r | `resolve_merchant` still writes a global `merchants` row on every lookup (write-on-read, row lock) | Only the per-candidate call was removed | Select first, then `insert … on conflict do nothing` and re-select; populate or drop `merchant_aliases` | S |
| DB-20 | `v_transactions.has_sms` / `has_statement` hash the whole evidence table on every Activity page | Perf; about 8 ms today, grows with total evidence | `LATERAL (select bool_or(…) where e.txn_code = t.txn_code and e.is_active)`, or maintain the flags in `refresh_transaction` | S |
| DB-21 | Deleting a profile leaves its Vault PDF passwords and mailbox tokens and Storage objects; a user-JWT delete fails on `trg_audit`'s FK | No profile deletion in the UI yet | `delete_profile` routine that purges `vault.secrets` by name prefix, enqueues Storage cleanup, and makes `trg_audit` skip a vanished profile | M |
| DB-22 | Template re-processing always takes the oldest 500 unparsed SMS across all profiles, synchronously, even on deactivation | Deferred P2 (errors are isolated now, DB-08) | Re-process only messages from the template's bank senders, newest first or by cursor; skip when only `active=false` or non-pattern columns change; move to the queue | M |
| DB-23 | Pending-invite claim and `add_profile_member` trust `auth.users.email` without `email_confirmed_at` | Low risk with sign-ups off and invite-only users; still matters if password sign-ups with confirmations off are ever enabled | Attach on `after update of email_confirmed_at` (and on insert when already confirmed); same check in `add_profile_member` | S |
| DB-24 | Short `contains` seed rules mis-categorise: `REST` (INTEREST → Dining), `NOON` (AFTERNOON), `LIME`, `BONUS`, `HEALTH` | Seed content change needs a guarded content migration | Word-boundary regex (`\mREST\M`) or `prefix`; seed regression test with known descriptions | S |
| DB-25 | Cron batch jobs (`nightly`, `enqueue_llm_categorize`, `recategorize_stale`, `reestimate_pending_fx`) have no per-profile error isolation | Deferred P2 | Per-profile `begin … exception` that logs to a `job_errors` table (or `raise warning`) and continues | S |
| DB-26r | SMS templates: a template with no `examples` is never validated; LLM proposals default to sender `.*` and go live for every profile when approved | `field_groups` validation was done; the rest changes the proposal flow | CHECK `jsonb_array_length(examples) >= 1`; sender must match the bank's `sms_senders`; scope LLM templates to the proposing profile until promoted | M |
| DP-09 | Seed rule `MURABAHA PROFIT` → Cashback (income), so an Islamic-card finance charge is dropped from spend (744 AED in the rehearsal) | Seed content change | Map it to a fee/charges spend category, or add `direction = credit` to the rule (guarded content migration) | S |
| X-10 | Prod `public.rls_auto_enable()` (and probably Supabase's `ensure_rls` event trigger) isn't quarantined, so prod drifts from local and CI | Needs a decision; harmless functionally | Decide at cutover: leave it and note it in PRODUCTION §2.3, or drop it in a migration | S |

### Edge Functions

| ID | Summary | Why deferred / dependency | Suggested fix | Effort |
|---|---|---|---|---|
| SRV-05 | `gmail-push` has no time budget or incremental cursor, so a large backlog never finishes; a 404 cursor reset silently skips mail | Needs its own design and tests | Deadline like `outlook-poll`; save the cursor after each page; `labelId` filter on `history.list`; `captureMessage` on a 404 reset; optional bounded `messages.list` backfill | M |
| SRV-07 | Base64 attachment decoding costs about 1 s of CPU per 20 MB against the 2 s Edge CPU limit | Needs a decoder swap and tests | `Uint8Array.fromBase64` / `@std/encoding` `decodeBase64Url`; skip attachments over 25 MB before downloading | S |
| SRV-10 | Nothing alerts on stale mailboxes, expiring Gmail watches, mailbox `last_error` or parse-queue age | New `ops_health` checks are SQL (DB owner) | Add `mailboxes_stale` (> 2 days), `gmail_watch_expiring` (< 24 h), `mailbox_errors` to `ops_health()` and `evaluateHealth` | M |
| SRV-11r | Gmail push, Outlook resume, `ingestAttachment`/`storeDocument` races, token rotation and a viewer e2e (403 on upload and SMS) are untested | `worker_test.ts` covered the worker only | Fake `Db` and `fetch`, table-driven tests per path; e2e viewer case | M |
| NEW-1 | No in-app invite: with sign-ups off, a new member needs a dashboard *Invite user* after `add_profile_member` | Found while documenting sign-ups off | An owner-only Edge Function that calls `auth.admin.inviteUserByEmail` when `add_profile_member` returns `invited` (rate-limited, same-origin redirect); a "Resend invite" action in web Settings → Members (and iOS later) | M |

### Parser

| ID | Summary | Why deferred / dependency | Suggested fix | Effort |
|---|---|---|---|---|
| NEW-4 | Mashreq `card_last4` / `primary_card_last4` is the card's first four digits (BIN): `_CARD_LAST4_RE` takes the first group of "Card No 4xxx XXXX XXXX 1234". Every Mashreq statement of a profile lands on one card, SMS with the real last 4 can't match it, and the fallback statement reference carries the BIN | Found while building the synthetic golden set; fixing it changes card and account identity | Take the last group of the masked number (keep the BIN-based `legacy_fingerprint`). Decide with DP-20 first: with real last-4s, a replacement card (two in the local corpus) creates a second Mashreq account | S |
| NEW-2 | `PARSER_VERSION` is still `2026.10.0` although the ENBD-year, FAB-amount and validation fixes change output, so `documents.parser_version` can't tell old parses from new | Found while writing the post-import checks | Bump it (for example `2026.10.1`) and on every output change; a test that a golden delta requires a bump | S |

### Web

| ID | Summary | Why deferred / dependency | Suggested fix | Effort |
|---|---|---|---|---|
| WEB-09 | Realtime channel topic reused while the old channel is still leaving can silently kill live updates (verified in source, not reproduced) | Out of the P1 pass | Unique topic per effect run (`ledger:${code}:${uuid}`) | S |
| WEB-10r | Each review card runs 1–3 context queries, and every `transactions` event invalidates all review contexts | The badge part is fixed (head count) | One `review_context` RPC per list; invalidate only `["p", code, "reviews", "open"]` on txn events | M |
| WEB-11 | First load is 1.16 MB JS (≈ 365 kB gz): Sentry with Replay, supabase-js and Radix preloaded on every route | Perf | Lazy-load Replay and Sentry after first paint, keep `/signin` free of chart and Radix chunks, drop `chunkSizeWarningLimit: 1200`, budget ~200 kB gz | M |
| WEB-12 | "Apply to merchant" stays ticked after a pick, so the next change silently rewrites the whole merchant | Out of the P1 pass | Reset `toMerchant` on pick and on popover close | S |
| WEB-13 | Rule regex validated with JS `RegExp` but run as Postgres ARE; Save stays enabled when the preview errors | Server now validates on write (DB-09/13), the client still lets you try | Block Save on `preview.isError`, show the server's 22023 message | S |
| WEB-14 | Rejecting a merchant suggestion deletes the row, so the nightly LLM pass re-suggests it | Needs a DB marker | Store `source = 'rejected'` and skip it in `enqueue_llm_categorize` (pairs with DB-37) | S |
| WEB-15 | Calendar counts and draws future days ("135 days of 184"); heatmap uses ~35 % of the card on desktop | Out of the P1 pass | Clamp `to` at `todayDubai()` for display and counts; scale cells to the container | S |
| WEB-16 | Anomalies show raw uppercase descriptions as separate rows, flag "Large first purchase" on a charge below usual, and use jargon | Partly server-side (`anomalies`) | Return `merchant_name`, require first purchase **and** above threshold, phrase as "about 4× your usual Shopping purchase", add a "this is fine" action | M |
| WEB-17r | 18 categories over 12 hues still share colours (Medicine/Insurance, Forex Charge/Fines, Apple/Subscription/Cashback, Donation/Transport) | `…1900` moved the worst pairs; a full fix needs more hues or a policy | Extend the palette to ~16, or reserve unique hues for `kind = spend` categories; keep ΔE ≥ 15 | S |
| WEB-19 | Closing the URL-driven drawer drops focus to `<body>` | Out of the P1 pass | Remember the opener by `txn_code` and focus it in `onCloseAutoFocus` | S |
| WEB-20 | `<button role="cell">` strips button semantics from the main Activity row action (351 axe nodes) | Out of the P1 pass | `role="cell"` on a wrapper span with a real button inside, or a list of buttons | S |
| WEB-22r | Calendar heat cells are 13×13 px on mobile | A 7×N grid can't take 44 px cells | Tap opens a day sheet, or a list view on mobile; keep the grid as a picture | S |
| WEB-24 | Bulk bar has one state-like pill ("Uncategorised"), no exclude/export/selection total, and no bulk on mobile | Out of the P1 pass | "Categorise…", "Exclude", "Export CSV", server-computed total, long-press select on mobile | M |
| WEB-26 | Pace rule compares month-to-date spend with the full-month 3-month average, so it reads "way under" all month | Needs a server field | `overview` returns `spend_avg_3m_to_date` and `projected_month_end`; pin those, "Projected AED X by 31 Oct" | M |
| WEB-27 | Empty ledger shows AED 0.00, an empty ruler and four empty states; no first-run guidance | Out of the P1 pass | "Get your ledger going" checklist from server state: statement, mailbox, PDF passwords, SMS shortcut, member | M |
| WEB-28 | Budget/category load errors render an empty state; `budgetAppliesTo` re-implements the server's selection (CLAUDE.md §2.2) | Needs an RPC flag | Render `isError`; return `is_effective` from the budget RPC and drop the client logic | S |

### iOS

| ID | Summary | Why deferred / dependency | Suggested fix | Effort |
|---|---|---|---|---|
| IOS-10 | OTP false negatives pass the filter ("Use 482913 as the code…", "authentication code", Arabic "رمز التحقق"); the server mirrors the same regex | Out of the P1 pass | Add `auth(entication)? code`, `secure code`, `3-?d ?secure`, code-near-digits patterns, `do not share`, `رمز`, `كلمة المرور`; one generated source or a parity test with the SQL regex | S |
| IOS-11 | Filter tests use invented bodies, not the template examples; CI never compiles the app or extension targets | Out of the P1 pass (outbox failure tests were added) | Export `sms_templates` examples to a fixture with a drift check; CI `xcodebuild build … CODE_SIGNING_ALLOWED=NO` (with X-26) | M |
| IOS-12r | `noProfile` still discards the SMS; the outbox isn't cleared on sign-out; nothing outside Settings shows a stuck outbox | Honest queued reasons and "Not sent" were done | Enqueue with a pending profile; confirm-and-clear outbox and pending PDFs on sign-out; Settings badge and an Overview strip when the outbox is older than 1 h | S |
| IOS-13 | A failed Realtime subscribe ends the stream with no retry; foreground reloads only Overview; Insights never refreshes | Out of the P1 pass | Restart with backoff while the profile is selected; reload or mark stale every loaded tab on foreground; include Insights in the fan-out | M |
| IOS-14 | Switching ledger briefly shows the previous ledger's numbers | Out of the P1 pass | Reset screen models to `.idle` on profile change, or key `previous` by profile code | S |
| IOS-15 | Activity filters bind live (swipe-dismiss leaves them changed but unapplied), no date filter, `loadMore` ignores `loadToken`, recategorising resets to page 0 | Out of the P1 pass | Edit a local copy, add a month/range picker, guard `loadMore`, patch the edited row in place | M |
| IOS-16r | One permanently rejected PDF still blocks the pending-upload queue; no count of waiting PDFs | Target ledger now follows "SMS go to" | Delete or quarantine on non-transient errors; "2 PDFs waiting" on Statements | S |
| IOS-17 | Statement upload: no per-file progress or parse outcome, `parse_error` never shown, the explainer card always occupies the top, "Statements" twice | UX, out of the P1 pass | Toolbar `+`, per-file row that turns into the parse result via Realtime with Retry / "Set password on web", cycle detail with recon chips explained | M |
| IOS-18 | Category sheet opens at `.medium` (3 categories), no search, no "None", merchant toggle defaults off, no notes or exclude-from-spend | UX, out of the P1 pass | `.large` + `.searchable`, merchant toggle on unless the category is manual, "Exclude from spend" and notes, swipe actions on rows | M |
| IOS-19r | Contrast: the AA token change (WEB-06) regenerated `Tokens.swift`, but iOS still uses `subtle` for some caption text and the iOS pairs aren't declared in `tokens.json#contrast` | Token fix landed with the web pass | Use `muted` for text, keep `subtle` for glyphs and dividers; declare the iOS pairs (warn on warnSoft) in the contrast test | S |
| IOS-20r | VoiceOver: the hero still reads "AED" and the number apart; charts have no `accessibilityChartDescriptor` or summary | Labels, 44 pt dismiss and combined rows were done | Combine the hero ("October spend, 860 dirhams"); chart descriptors for the ring and bars | S |
| IOS-21r | Release config still includes the local `Secrets.xcconfig` (one dropped key ships a local value); no assertion on the archived Info.plist; no Sentry releases; the token in `Secrets.Release.xcconfig` is an Xcode build setting (also X-28) | Only the token handling in `publish-build.sh` was done | Include `Secrets.xcconfig` from `Debug.xcconfig` only; `plutil` asserts on the archived app and `.appex` (https, `production`, non-empty keys); `sentry-cli releases new/set-commits/finalize`; keep the token in the shell or keychain | M |
| IOS-22 | No privacy cover in the app switcher and no optional Face ID lock | Out of the P1 pass | Blur overlay when `scenePhase != .active`; optional "Require Face ID" with `NSFaceIDUsageDescription` | S |
| IOS-23 | An empty ledger asserts "AED 0 · No 3-month history yet · Same as this time last month" | Out of the P1 pass | Three-step checklist (SMS capture, statement, invite) when there are no transactions and no cards | S |

### CI, config and ops

| ID | Summary | Why deferred / dependency | Suggested fix | Effort |
|---|---|---|---|---|
| X-16r | No committed `supabase/functions/.env.example`; the PRODUCTION §2.5 table is the only full inventory of function secrets | Functions directory wasn't owned by the docs pass | Commit an example grouped as required / prod-only / local-only / optional | S |

---

## P3

### Database (Supabase SQL)

| ID | Summary | Why deferred / dependency | Suggested fix | Effort |
|---|---|---|---|---|
| DP-04r | Ingest doesn't reject a statement dated more than a month in the future (the parser now validates periods and due dates) | Defence in depth only | Reject `statement_date > today + 31` with a permanent 22023 | S |
| DB-28r | DB-27 (displaced line) and DB-43 (unknown card without last4) have no dedicated pgTAP tests; the per-profile lock is checked as held, not under real concurrency | pgTAP is single-session | Add the two tests; a two-connection concurrency test in a script or CI step | S |
| DB-29r | `spend_pace`, `new_recurring`, `review_backlog`, `large_transaction` insight kinds and the `amount_drift` review reason are allowed by CHECKs but never produced (ARCHITECTURE now says so) | Product decision | Implement them (WEB-25 already routes each kind) or drop them from the CHECKs | M |
| DB-31 | `preview_rule`'s `would_change` ignores the equal-priority tie-break and counts the rule being edited | Out of the P1 pass | Mirror `recategorize`'s full ORDER BY; accept `p_rule_code` to exclude it | S |
| DB-32r | No index for `estimate_fx`'s `(profile_code, currency_original, txn_date desc)` scan; `anomalies` is O(n²) | Three FK indexes were added | Add the index; rewrite `anomalies` with window functions | S |
| DB-34 | `declined` SMS are stored `parsed` (docs say ignored); `Asia/Dubai` is hard-coded while `profiles.timezone`/`base_currency` are unused | Out of the P1 pass | Store `ignored`; use or drop the profile columns | S |
| DB-35 | `gen_code` UUIDv4 nibble leaves ~79 random bits instead of 80 | Negligible | Accept (or derive from 16 random bytes) | S |
| DB-36 | No sanity bound on a template date vs `received_at`: a DD/MM vs MM/DD mistake moves transactions by months | Out of the P1 pass | Fall back to `received_at` when the parsed date is more than 7 days away, with a warning | S |
| DB-37 | Merchants the LLM declines (< 0.5) are re-enqueued every night | Out of the P1 pass | Store a "declined" marker with `category_set_hash` (pairs with WEB-14) | S |
| DB-38 | `ops_health` counts (`recon_failed`, `open_reviews`) are all-time, so their Sentry issues never clear; it still scans `cron.job_run_details` unbounded (X-11 remainder; the purge keeps it to 7 days) | Out of the P1 pass | Window the counts (for example 7 days) and the cron scan | S |
| DB-39 | Utilisation goes negative when the card is in credit | Out of the P1 pass | `greatest(closing_balance, 0) / limit` | S |
| DB-40 | `add_profile_member` reveals whether an email has an account (`invited` vs `added`) and adds existing users without consent | Low risk for a two-person app | Return one status; optional accept step (with NEW-1) | M |
| DB-41 | Eight functions are redefined across migrations; one stale filename reference in `…0000` | Squashing touches every migration | Squash before the first production push if still possible, or keep Appendix A current; fix the reference | M |
| DB-44 | Per-row trigger overhead: two `recategorize` runs per new statement line | Perf | Batch inserts in `match_statement_lines`, or one `recategorize` per ingest | M |
| DB-45 | Pending foreign SMS with no FX rate (`amount_aed` null) vanish from spend, budgets and `pending_amount` | Out of the P1 pass | Surface an "unpriced pending" count in `overview` (the web already shows "awaiting FX" per row) | S |
| DP-19 / X-24 | Choices on a legacy typo category (`Entretainment`, 9 lines) never apply | Data quirk | Add an alias at import, or report unresolved category names in the finalize output | S |
| DP-20 | A FAB card replacement creates a second FAB account, splitting `statement_cycles` and utilisation history | Model change | Treat a new primary card on the same bank and holder as a replacement on the existing account, or offer "merge accounts" | M |
| DP-21 | Legacy fingerprints collide for genuine same-day repeat purchases, so fingerprint-keyed choices can cross-apply | Legacy data; v2 keeps every row | Accept; note it in the finalize output | S |
| X-23 | `legacy.*` keeps 294 grants to `anon`/`authenticated` (blocked by revoked schema USAGE) | Defence in depth | `revoke all on all tables in schema legacy from anon, authenticated` | S |
| X-33r | Contract nits: the `concat_ws` line-key hash drops nulls; iOS relies on Foundation's `spendAvg3M` key mapping (the parser now always sends `fx_rate` `"1"` for AED and null for a sub-1e-8 rate) | Minor | Use `format('%s|%s', …)` for the key (re-keys every line: pair with a re-parse), explicit `CodingKeys` on iOS | S |

### Edge Functions

| ID | Summary | Why deferred / dependency | Suggested fix | Effort |
|---|---|---|---|---|
| SRV-14 | A failed save of a rotated Microsoft refresh token is ignored; `gmail-push` never records `sync_state.last_error` | Out of the P1 pass | Check the RPC error and capture a warning; record `last_error` in gmail-push and gmail-watch-renew | S |
| SRV-15 | `saveSyncState` writes back a whole stale snapshot, so concurrent writers can regress the cursor | Out of the P1 pass | jsonb merge in SQL; keep the max cursor in an RPC | S |
| SRV-18 | The Edge and parser scrubbers don't regex-strip free-text emails; `pgErrorToHttp` returns raw PG messages (constraint names) to clients; `withScope` isolation across concurrent requests unverified | Out of the P1 pass | Email regex in both scrubbers; fixed messages for 23505/23503; an interleaving test | S |
| SRV-19 | Permanent `gmail-push` errors (bad envelope, `invalid_grant`, missing config) are nacked and redelivered for up to 7 days | Out of the P1 pass | Ack permanent errors (with `last_error`); dead-letter topic on the subscription | S |
| SRV-20 | Re-uploading a failed PDF says `duplicate` and never re-parses; a duplicate queue message flips a parsed document back to `parsing`/`failed` | Out of the P1 pass | Return `parse_status` with `duplicate` and requeue failed ones; skip messages for already-parsed documents unless requeued | S |
| SRV-22 | DLQ and `documents_stuck` alerts repeat every 15 min until a manual purge, including during the bulk import | Out of the P1 pass | Alert on depth increase; `drain_dlq`/`requeue_dlq` RPC; base "stuck" on `parsing` older than 1 h | S |
| SRV-23 | Duplicated helpers, double `validatePdf`, `ProviderHttpError` in `gmail.ts`, long `processParseMessage`, unchecked `failDocument`/status results | Readability | `_shared/provider.ts`, `storeDocument` owns validation, split fetch/classify/apply | M |

### Parser

| ID | Summary | Why deferred / dependency | Suggested fix | Effort |
|---|---|---|---|---|
| SRV-12 | Capacity: `--concurrency 4` on 1 vCPU / 1 GiB with CPU-bound parses (and four 768 MB child caps) may time out or OOM under the bulk import (unverified) | Watch the canary step first | `--concurrency 2` (more instances), or a worker-side in-flight cap | S |

### Web

| ID | Summary | Why deferred / dependency | Suggested fix | Effort |
|---|---|---|---|---|
| WEB-30 | Italic "Uncategorised" in a truncated label clips its last glyph | Polish | `pr-0.5` or `not-italic` | S |
| WEB-31 | "Uncategorised" vs "Uncategorized" across UI, Trends and the server name | Polish | UK spelling everywhere, server name included | S |
| WEB-32 | The "Doesn't add up" badge shifts Statements row columns | Polish | Fixed grid column widths | S |
| WEB-33 | Rules and Settings use a narrower, indented container | Polish | Same container as other pages | S |
| WEB-34 | Mixed decimals for the same kind of figure | Polish | Two decimals for transactions, whole units for balances, limits and aggregates | S |
| WEB-35 | "Pending from SMS" and "Recent activity" show largely the same rows | UX | Merge, or exclude pending from Recent | S |
| WEB-36 | "Due in 0 d"; past dues show no paid/overdue state | Needs payment-matched status from the server (also iOS "Paid") | "Due today/tomorrow"; server flag for a payment covering the statement | M |
| WEB-37 | No headline totals (subscriptions per year, YoY YTD delta, Trends period total/avg); partial month unmarked | Needs small RPC additions | Server totals and an "Oct (to date)" marker | M |
| WEB-38 | Budgets have no "expected by today" tick or "AED X over pace" | UX | Today tick on meters, over-pace text | S |
| WEB-39 | Deep links are lost on sign-in | UX | Carry a same-origin `redirect` through `/signin` | S |
| WEB-40 | First-run "Key … X-Profile-Key header" jargon; "one person's cards" copy vs a "Household" example | UX copy | Move "Key" under Advanced with a generated default; fix the copy | S |
| WEB-41 | Disabled-until-valid primary buttons are ~2:1 and give no reason | UX | Keep enabled and validate on submit, or explain | S |
| WEB-42 | "2 statements couldn't be read. Check its password"; revoked tokens listed forever (the last axe nodes) | UX | Fix pluralisation; collapse revoked tokens | S |
| WEB-43 | Back after closing the drawer reopens it | UX | `replace: true` when opening and closing | S |
| WEB-44 | Nine Insights tabs scroll on mobile with no affordance | UX | Edge fade and scroll hint, or a Select | S |
| WEB-46 | The drawer loads a `txn=` from another profile (no `profile_code` filter) | RLS still applies; confusing only | `.eq('profile_code', …)` and a "belongs to another ledger" state | S |
| WEB-47 | `timestamptz.slice(0,10)` / `toISOString()` show the UTC day, not the Dubai day | Polish | `todayDubai(new Date(ts))` | S |
| WEB-48 | "Up to 10 files" vs the server's 20 with no client count check; input not reset; concurrent drops | Polish | `MAX_FILES = 20` (and 40 MB) in `checkUploadFiles`, reset the input, ignore drops while pending | S |
| WEB-49 | Notes stay dirty after saving padded text; preview shows "1,000+" though counts are exact | Polish | Compare trimmed; drop the cap text | S |
| WEB-50 | New token plaintext and PDF passwords linger in the MutationCache ~5 min | Hygiene | `gcTime: 0` on those mutations | S |
| WEB-51 | Session in `localStorage`; `window.open('about:blank')` leaves `opener` set | Accepted with the strict CSP | Keep the CSP strict; `noopener` after navigation | S |
| WEB-52 | `<a>` directly in `<dl>`, unnamed `role=meter`, 404 outside the shell, no skip link | a11y polish | `<div><dt/><dd/></div>`, `aria-label`, 404 in the shell, "Skip to content" | S |
| WEB-53 | Overview loads the 285 kB Recharts chunk for one donut | Perf | Hand-rolled SVG ring | S |
| WEB-54 | Two pager components, duplicated helpers, `ConfirmDialog` under `rules/`, 480-line `email-section.tsx`, 470-line `data/rules.ts` | Readability | Consolidate and split | M |
| WEB-55 | No tests for `slicePage`/`usePager` reset, `domainsFor`, `placeMarks`/`labelLanes`, member error mappers | Test gap | Unit tests for those pure helpers | S |
| WEB-56 | Netted refunds show as AED 0.00 top merchants; columns not sortable; no per-merchant trend | UX | Gross and refund columns, sorting, a trend link | M |

### iOS

| ID | Summary | Why deferred / dependency | Suggested fix | Effort |
|---|---|---|---|---|
| IOS-07r | No deep link from a Shortcut result to the Review screen | The Review screen shipped | `ledger://review` URL handled by the app; use it in the intent's result | S |
| IOS-08r | The privacy manifest declares crash data only | Correct for personal use | If distributed beyond personal use, add Financial Info, Email Address and Performance Data | S |
| IOS-24 | App and share extension can refresh the same rotating refresh token concurrently (10 s reuse window) | Needs device testing | Extension: `autoRefreshToken: false` and re-read storage before each request, or an App Group file lock | M |
| IOS-25r | Two Swift 6 warnings remain (`nonisolated(unsafe)` in `LedgerDates`, deprecated `Breadcrumb.data` setter) | Reentrancy part fixed (flushes chained) | Fix both warnings | S |
| IOS-26 | `ActivityModel.sections` re-sorts on every body evaluation; an `ISO8601DateFormatter` per timestamp | Perf | Cache sections on state change; static formatters | S |
| IOS-27 | Large nav titles are SF Bold while section heads are serif; redundant title and eyebrow; AED hard-coded despite `base_currency` | UI polish | Serif large titles via `UINavigationBarAppearance`; month as the Overview title; "Cycles" section; profile currency | S |
| IOS-28 | Insights draws the partial month like a full one; no average line, values or budget rule; rows not drillable | UX | Hatched current month with projection, `RuleMark` average, `chartXSelection`, rows link to filtered Activity | M |
| IOS-29 | Small presentation decisions in views (`prefix(4)`, `prefix(10)`, fallbacks) | Readability | Move into LedgerKit presentation extensions with tests | S |
| IOS-30 | Sentry failed-request capture can carry Activity search text in the PostgREST URL; `NSAllowsLocalNetworking` ships in Release | Hygiene | Strip query strings in `beforeSend`; set the ATS key in Debug only | S |
| IOS-31 | Filter edges: a merchant named "OTP …" is dropped; "payment received … via transfer from account" is sent (server classifies it) | Accepted | Document both in the tests | S |

### Scraper

| ID | Summary | Why deferred / dependency | Suggested fix | Effort |
|---|---|---|---|---|
| SRV-16 | `uploaded.json` is written non-atomically and a corrupt file is silently treated as empty; long or padded filenames never get recorded | Out of the P1 pass | Temp file + `os.replace`, keep a `.corrupt` copy with a warning; normalise names before matching | S |
| NEW-3 | `scraper/README.md` doesn't document `CCS_SCRAPER_UPLOAD_MAX_FILES` / `_MAX_MB` or the batch-and-retry behaviour (root README does) | File outside the docs pass | Add both to the scraper README's env table and upload section | S |

### CI, config and ops

| ID | Summary | Why deferred / dependency | Suggested fix | Effort |
|---|---|---|---|---|
| SRV-13 | Supply chain: `deno.json` `lock: false`, no pip hashes, base image by tag, `uvicorn[standard]` extras | Out of the P1 pass | Commit `deno.lock` and deploy `--frozen`; `uv pip compile --generate-hashes`; pin the base image digest; plain `uvicorn` | M |
| SRV-24 | Golden parity never runs in CI (the corpus is private) | Needs a redacted corpus or protected storage | A small synthetic/redacted golden set per layout, or a protected CI job with encrypted corpus | M |
| X-26 | CI runs no `deno lint`/`check`/`fmt` (fmt fails on 18 files) and never builds the iOS app or extension targets | Out of the P1 pass | Add lint and check (fix or drop fmt); a weekly `xcodegen && xcodebuild build` job (with IOS-11) | S |
| X-32 | Vercel previews use the production Supabase project and CSP; their auth redirects aren't allow-listed | Decision | Disable previews, or point them at a non-prod project | S |
| DP-22 | A rehearsal on the shared local stack also categorises the demo profiles' merchants and drains their `sms_fallback` queue (demo SMS sent to Claude) | Local ops only | Rehearse on a stack without seed data, or scope `enqueue_llm_categorize` by profile when run by hand | S |
| FV-04 | `supabase migration up` matches migrations by version only, so a migration edited after a stack applied it is silently skipped (the shared local stack ran stale bodies of 4 migrations; 07 FV-04). Prod is safe only while no v2 version has been pushed | Process; no tooling yet | CI guard: fail a PR that modifies (`git diff --diff-filter=MDR`) an existing file under `supabase/migrations/` once that version is on `main` (or, after cutover, listed by `supabase migration list --linked`), with an explicit override label for pre-cutover edits. Optionally record a sha256 per applied migration in a local table and warn on mismatch | S |

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

## Needs verification

Checks that only a real device or the production project can answer. Each is fixed in code or
docs, but unproven where it matters.

| ID | What to verify | Where / how | Effort |
|---|---|---|---|
| V-IOS-06 | The single *Message contains "Card"* automation fires once per alert on a locked phone, with alphanumeric senders, and passes body and sender; **whether "contains" is case-insensitive** (the ENBD refund says "card"). If it isn't, add a second automation on "card" | Real iPhone, one alert per bank format | S |
| V-IOS-08 | The first TestFlight upload with both `PrivacyInfo.xcprivacy` files passes App Store Connect (no ITMS-91053) | `publish-build.sh --upload` | S |
| V-IOS-09 | A signed Release build on a device saves the session to the shared keychain and App Group, so the App Intent and the share extension see it | TestFlight build, sign in, run Send test and a share | S |
| V-DB-13 | Which `statement_timeout` applies to the worker's `ingest_parsed_document` call in prod (PostgREST as `service_role`, possibly the `authenticator` 8 s). With the function-level timeout gone, a very large re-ingest could hit `57014` and retry to the DLQ | `select rolname, rolconfig from pg_roles where rolname in ('authenticator','service_role');` on prod; time the largest statement during the canary | S |
| V-DB-23 | Production Auth settings: email confirmations on, password sign-up off, sign-ups off, so an unconfirmed address can't claim an invite | Dashboard → Authentication | S |
| V-X-12 | The GitHub `production` environment exists with required reviewers, a `main`-only branch policy and the `SUPABASE_*` / `GCP_*` secrets (the auditor had no repo access) | GitHub → Settings → Environments | S |
