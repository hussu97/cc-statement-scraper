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
| Database (Supabase SQL) | 0 | 2 | – | 2 | 4 |
| Edge Functions | 0 | 0 | – | – | 0 |
| Parser | 5 | 3 | – | – | 8 |
| Web | 17 | 26 | 5 | – | 48 |
| iOS | 14 | 11 | 7 | 3 | 35 |
| Scraper | – | 2 | – | – | 2 |
| CI, config and ops | 0 | 3 | – | 1 | 4 |
| **Total** | **36** | **47** | **12** | **6** | **101** |

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
   (PRODUCTION §2.2), or with the `member-invite` Edge Function (NEW-1; the web button is NEW-1r).
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
    nor v2 ever ingested (DP-18); any legacy category name still listed by
    `private.legacy_unresolved_category_names()` at finalize (add an alias row; `Entretainment`
    is built in, DP-19/X-24). Prod's `public.rls_auto_enable()` stays (X-10, decided).
11. **Vercel previews** talk to production (X-32). Decision (2026-10-09): previews are **off** for the
    `apps/web` project; switch them off in the Vercel dashboard (PRODUCTION §4).

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
| DP-10 | FAB `total_credits` extraction is short by whole payment amounts in 4 statements, giving a false recon `fail` (the balance equation holds) | Not part of the P0/P1 parser fixes | Read the summary block's payment and other-credit lines separately in `totals.py`, plus golden cases | M |
| DP-11 | Mashreq FX rows aren't recognised: stored as AED with currency, amount and reference left in the description (38 transactions, 36 one-off merchants, invisible to `fx_spend`) | Not part of the P0/P1 parser fixes | Parse the FX sub-line into `currency_original`, `amount_original`, `fx_rate`; golden cases | M |
| DP-12 | Mashreq totals are never extracted, so all 12 Mashreq statements are `warn` and 42 % of lines have no completeness check | Not part of the P0/P1 parser fixes | Add Mashreq to `totals.py` | M |
| X-17 | `EIB_PDF_PASSWORD` and `MASHREQ_PDF_PASSWORD` are accepted and stored but never sent to or tried by the parser | Contract and parser change | Wire them into the parser's password map, the worker `settings` and parse-v1, or remove them from the allow-list and Settings | S |
| NEW-2 | `PARSER_VERSION` is still `2026.10.0` although the ENBD-year, FAB-amount and validation fixes change output, so `documents.parser_version` can't tell old parses from new | Found while writing the post-import checks | Bump it (for example `2026.10.1`) and on every output change; a test that a golden delta requires a bump | S |

### Web

| ID | Summary | Why deferred / dependency | Suggested fix | Effort |
|---|---|---|---|---|
| NEW-1r | Settings → Members still calls `add_profile_member` directly, so a new member gets no email | The `member-invite` Edge Function (owner-only, rate-limited, same-origin redirect) landed; the UI is a follow-up | "Invite" calls `member-invite` (`action: invite`) and shows `invite_sent` / `invite_error`; "Resend invite" on pending members (`action: resend`; handle `INVITE_COOLDOWN` / `ALREADY_ACTIVE`). iOS later | S |
| WEB-09 | Realtime channel topic reused while the old channel is still leaving can silently kill live updates (verified in source, not reproduced) | Out of the P1 pass | Unique topic per effect run (`ledger:${code}:${uuid}`) | S |
| WEB-10r | Each review card runs 1–3 context queries, and every `transactions` event invalidates all review contexts | The badge part is fixed (head count) | One `review_context` RPC per list; invalidate only `["p", code, "reviews", "open"]` on txn events | M |
| WEB-11 | First load is 1.16 MB JS (≈ 365 kB gz): Sentry with Replay, supabase-js and Radix preloaded on every route | Perf | Lazy-load Replay and Sentry after first paint, keep `/signin` free of chart and Radix chunks, drop `chunkSizeWarningLimit: 1200`, budget ~200 kB gz | M |
| WEB-12 | "Apply to merchant" stays ticked after a pick, so the next change silently rewrites the whole merchant | Out of the P1 pass | Reset `toMerchant` on pick and on popover close | S |
| WEB-13 | Rule regex validated with JS `RegExp` but run as Postgres ARE; Save stays enabled when the preview errors | Server now validates on write (DB-09/13), the client still lets you try | Block Save on `preview.isError`, show the server's 22023 message | S |
| WEB-14 | Rejecting a merchant suggestion deletes the row, so the nightly LLM pass re-suggests it | **SQL side done**: `reject_merchant_suggestion` + `merchant_category_skips` (`20261009000200`); the Merchants tab must call it | Store `source = 'rejected'` and skip it in `enqueue_llm_categorize` (pairs with DB-37) | S |
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
| IOS-11 | Filter tests use invented bodies, not the template examples; CI never compiles the app or extension targets | Out of the P1 pass (outbox failure tests were added) | Export `sms_templates` examples to a fixture with a drift check (the app and extension build was done: `ios-build.yml`, 2026-10-09) | M |
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

| ID | Summary | Why deferred / dependency | Suggested fix | Effort |
|---|---|---|---|---|
| SRV-12 | Capacity: `--concurrency 4` on 1 vCPU / 1 GiB with CPU-bound parses (and four 768 MB child caps) may time out or OOM under the bulk import (unverified) | Watch the canary step first | `--concurrency 2` (more instances), or a worker-side in-flight cap | S |
| SRV-17 | A wrong bank hint skips detection entirely, so it fails permanently | Out of the P1 pass | On `UNSUPPORTED_LAYOUT` with a hint, run detection and retry once with the detected bank plus a warning | S |
| X-25r | `country_code` has no defined format (`AE`, `ARE`, `UAE`, `IRL`, `DXB`, `YOU` seen) | The rest of the contract drift is fixed | Normalise to ISO 3166 alpha-2 or null, document it in parse-v1 | S |

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
| X-33r | iOS relies on Foundation's `spend_avg_3m` → `spendAvg3M` key mapping (the DB parts of X-33 were fixed on 2026-10-09) | Minor | Explicit `CodingKeys` on the overview model | S |

### Scraper

| ID | Summary | Why deferred / dependency | Suggested fix | Effort |
|---|---|---|---|---|
| SRV-16 | `uploaded.json` is written non-atomically and a corrupt file is silently treated as empty; long or padded filenames never get recorded | Out of the P1 pass | Temp file + `os.replace`, keep a `.corrupt` copy with a warning; normalise names before matching | S |
| NEW-3 | `scraper/README.md` doesn't document `CCS_SCRAPER_UPLOAD_MAX_FILES` / `_MAX_MB` or the batch-and-retry behaviour (root README does) | File outside the docs pass | Add both to the scraper README's env table and upload section | S |

### CI, config and ops

| ID | Summary | Why deferred / dependency | Suggested fix | Effort |
|---|---|---|---|---|
| SRV-13r | Supply chain, parser side: no pip hashes, base image by tag, `uvicorn[standard]` extras | The Edge part was done (frozen `deno.lock`, checked with `--frozen` in CI, pre-push and before deploy) | `uv pip compile --generate-hashes` + `--require-hashes`; pin the base image digest; plain `uvicorn` | S |
| SRV-24 | Golden parity never runs in CI (the corpus is private) | Needs a redacted corpus or protected storage | A small synthetic/redacted golden set per layout, or a protected CI job with encrypted corpus | M |
| DP-22 | A rehearsal on the shared local stack also categorises the demo profiles' merchants and drains their `sms_fallback` queue (demo SMS sent to Claude) | Local ops only | Rehearse on a stack without seed data, or scope `enqueue_llm_categorize` by profile when run by hand | S |

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
