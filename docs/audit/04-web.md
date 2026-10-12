# Audit 04: Ledger v2 web app (`apps/web`)

- **Date:** 2026-10-08
- **Branch:** `ledger-v2` (HEAD `4ec697c`)
- **Scope:** `apps/web/src` (~12.4k lines) and `packages/tokens`
- **Method:** code read (data layer, shell, every route and component), plus `pnpm --filter @ledger/web test|lint`, `tsc -b` and a production `vite build` into the scratchpad. Every screen was driven with headless Chromium (Playwright) at 1440×900 and 390×844 (mobile UA, 2× DPR), in light and dark (`prefers-color-scheme`), with `prefers-reduced-motion: reduce`. axe-core (WCAG 2 A/AA + best practice) ran on every screen. The only account used was `demo@ledger.local`, on the **Demo ledger** and **Household** profiles.
- **Screenshots** are in `$SCRATCHPAD/audit-web/shots/`, named `<d|m>-<light|dark>-<screen>.png` (full page), `vp-…` (viewport only) and `probe-…` (targeted repros). `$SCRATCHPAD` is `/private/tmp/claude-502/-Users-hussainabbasi-Documents-GitHub-scrapers-credit-card-scraper/5728e284-6178-4733-b21f-3693bd034d9c/scratchpad`. Raw axe and request counts: `audit-web/walk-*.json`.

**Baseline health:**

| Check | Result |
|---|---|
| Tests | 119/119 pass (15 files) |
| ESLint | clean |
| Typecheck | clean |
| Build | succeeds |
| Hex guard and CSP-hash guard | pass |
| `dangerouslySetInnerHTML` | none |
| Raw `fetch` outside `src/data` | none |
| Open redirect | none (sign-in always lands on `/`) |
| Profile-scoped query keys | all carry `["p", profileCode, …]` |
| Query cache on sign-out | cleared |
| Sensitive values | SMS bodies are fetched on demand with `gcTime: 0` |

The visual direction lands well. Linen and charcoal palettes, Fraunces numerals, hairline cards and restrained colour read as "earthy minimal", and dark mode is genuinely good (`d-dark-overview.png`). Most findings are about correctness at scale, accessibility contrast, and turning the analytics into guidance.

## Summary

| Severity | Count |
|---|---|
| P0 (broken / security before cutover) | 0 |
| P1 (fix before cutover) | 7 |
| P2 (soon after) | 22 |
| P3 (polish) | 27 |

## Findings table

| ID | Sev | Category | Location | Problem |
|---|---|---|---|---|
| WEB-01 | P1 | bug | `data/transactions.ts:41-48`, `routes/activity.tsx:62-73,122-128` | A page past the end gives "Requested range not satisfiable" with no way out |
| WEB-02 | P1 | bug | `data/cards.ts:45,64`, `data/reviews.ts:74`, `data/rules.ts:245-251` | Silent caps (120 statements, 500 documents/reviews, 200 merchants over 12 months) make lists, counts and pagination wrong after the history import |
| WEB-03 | P1 | security | `lib/sentry.ts:52-54` | `beforeSendTransaction` is ignored by Sentry v11's streamed spans, so span data bypasses the §6 scrubber |
| WEB-04 | P1 | security | `data/auth.tsx:66` | `shouldCreateUser: true`: anyone with an email can self-register on production and create ledgers |
| WEB-05 | P1 | money | `routes/activity.tsx:225`, `components/activity/drawer.tsx:85` | A foreign amount without an FX rate is rendered as AED (`amount_aed ?? amount_original` with AED currency) |
| WEB-06 | P1 | a11y | `packages/tokens` (`--color-subtle`, `--color-warn`, accent-on-soft) | `text-subtle` (103 uses) is 2.98:1 on bg; 781 axe colour-contrast nodes on desktop light |
| WEB-07 | P1 | bug | `routes/review.tsx:133-137` | An "Unrecognised message" review with no proposed template has no action, so it stays open forever and keeps the badge lit |
| WEB-08 | P2 | bug | `components/activity/filters.tsx:16-22` | "Clear filters" / Back clears `?q` but the search box keeps the text |
| WEB-09 | P2 | bug | `data/realtime.ts:41-59` | Channel topic is reused while the old channel is still leaving, which can silently kill live updates (StrictMode, A→B→A switch) |
| WEB-10 | P2 | perf | `components/shell.tsx:39`, `data/reviews.ts`, `data/realtime.ts:8` | The nav badge fetches up to 500 full review rows on every screen; every txn event refetches all review contexts |
| WEB-11 | P2 | perf | build output, `lib/sentry.ts:43`, `vite.config.ts:31` | First load is 1.16 MB JS (≈365 kB gz): Sentry with Replay/rrweb, supabase-js and Radix in one preloaded chunk; the warning limit was raised to hide it |
| WEB-12 | P2 | bug | `components/ledger.tsx:90-102` | The "Apply to merchant" checkbox persists after a pick, so the next change silently applies merchant-wide |
| WEB-13 | P2 | bug | `components/rules/rule-editor.tsx:63-66` | Regex is validated with JS `RegExp` but run with Postgres `~*`, and Save isn't blocked when the preview errors |
| WEB-14 | P2 | bug | `components/rules/merchants-tab.tsx:176`, `data/rules.ts:289` | Rejecting a merchant suggestion deletes the row, so the nightly LLM pass re-suggests it |
| WEB-15 | P2 | bug | `components/insights/calendar-tab.tsx:140`, `daily_spend` range | Calendar counts future days ("135 days of 184") and draws them as zero-spend cells |
| WEB-16 | P2 | ux/bug | Insights → Anomalies | Raw uppercase descriptions, duplicate merchant variants, and "Large first purchase" on a charge *below* usual |
| WEB-17 | P2 | ui | `charts/palette.ts`, category `color_token` | 18 categories share 12 colours: Dining = Forex Charge, Grocery = Medicine, Subscription = Cashback. Travel and Shopping are hard to tell apart |
| WEB-18 | P2 | ui | `insights/trends-tab.tsx:85-92` | At 390 px the 6-month Trends axis drops "May" and "Aug" labels (`minTickGap`) |
| WEB-19 | P2 | a11y | `routes/activity.tsx:161`, `ui/dialog.tsx` | Closing the URL-driven drawer (Esc/×) drops focus to `<body>` |
| WEB-20 | P2 | a11y | `routes/activity.tsx:186-196` | `<button role="cell">` strips button semantics from the main row action (351 axe nodes) |
| WEB-21 | P2 | a11y | `styles.css:90-92` | Reduced-motion rule sets 1 ms duration but keeps `infinite` iterations, so `animate-ping`/`animate-pulse` strobe |
| WEB-22 | P2 | a11y | mobile, many | Tap targets under 44 px: insight dismiss 22×22, category pill 24 px tall, rule switch 36×20, "All categories" 16 px |
| WEB-23 | P2 | ux | `components/shell.tsx:165` | Review (the daily action surface) is hidden behind "More" on mobile, shown only as a dot |
| WEB-24 | P2 | ux | `routes/activity.tsx:134-156`, `:193` | Bulk bar has one action, labelled like a state ("Uncategorised"). No bulk on mobile (checkboxes `hidden md:block`) |
| WEB-25 | P2 | ux | `routes/overview.tsx:244-286` | Insight cards aren't actionable: no link by `kind`/`data`, only dismiss |
| WEB-26 | P2 | ux | `overview/pace-rule.tsx`, `routes/overview.tsx:149` | Pace rule compares month-to-date spend with the *full-month* 3-month average, which reads as "way under" all month |
| WEB-27 | P2 | ux | Overview with an empty ledger | No first-run guidance: a big "AED 0.00", an empty pace rule and four separate empty states |
| WEB-28 | P2 | compliance | `routes/budgets.tsx:48,96-113`, `data/budgets.ts:108` | Budget/category load errors are ignored ("listed below" over nothing); `budgetAppliesTo` copies server selection logic (§2.2) |
| WEB-29 | P2 | test-gap | `packages/tokens` | No contrast validation for token pairs or chart colours, though the plan requires "validated for contrast" |
| WEB-30 | P3 | ui | `components/ledger.tsx:111-116` | Italic "Uncategorised" inside `truncate` clips the final glyph ("Uncategorisea") |
| WEB-31 | P3 | ui | copy, many | "Uncategorised" (UI) vs "Uncategorized" (Trends legend, Categories) |
| WEB-32 | P3 | ui | Cards → Statements | A row with the "Doesn't add up" badge shifts its columns left |
| WEB-33 | P3 | ui | `/rules`, `/settings` | Content column is narrower and indented compared with the other pages |
| WEB-34 | P3 | ui | Overview, Cards, Statements | Mixed decimals for the same kind of figure (hero 2 dp, card tiles whole, statements 2 dp) |
| WEB-35 | P3 | ux | Overview | "Pending from SMS" strip and "Recent activity" list show largely the same rows |
| WEB-36 | P3 | ux | Overview account card | "Due in 0 d"; past due dates (FAB 25 Sep) show no paid/overdue state |
| WEB-37 | P3 | ux | Insights → Subscriptions / Year over year / Trends | No headline totals (annual subscriptions, YTD vs last YTD, period total/avg); partial current month not marked |
| WEB-38 | P3 | ux | Budgets | No "expected by today" marker, and no explicit "over pace by X" |
| WEB-39 | P3 | ux | `routes/auth.tsx`, `shell.tsx:242` | Deep link lost on sign-in (`/activity?txn=…` → `/signin` → `/`) |
| WEB-40 | P3 | ux | `/welcome` | "Key … X-Profile-Key header" jargon in first-run; copy says "one person's cards" but the example is "Household" |
| WEB-41 | P3 | ux | Sign-in, Review, Welcome | Disabled-until-valid primary buttons are ~2:1 and give no reason |
| WEB-42 | P3 | ux | Settings → Sources | "2 statements couldn't be read. Check its password"; revoked tokens listed forever |
| WEB-43 | P3 | ux | Activity | Back after closing the drawer reopens it (push, not replace) |
| WEB-44 | P3 | ux | Insights tabs on mobile | 9 tabs scroll with no affordance; most are off-screen |
| WEB-45 | P3 | bug | `data/overview.ts:81-94` | Insights aren't filtered by `valid_until`, so expired ones show until the nightly cleanup |
| WEB-46 | P3 | bug | `data/transactions.ts:59` | Drawer loads a `txn=` from another profile (no `profile_code` filter) |
| WEB-47 | P3 | bug | `settings/members-tab.tsx:71`, `tokens-section.tsx:79`, `secrets-section.tsx:46`, `lib/dates.ts:118` | `timestamptz.slice(0,10)` / `toISOString()` show the UTC day, not the Dubai day |
| WEB-48 | P3 | bug | `cards/upload.tsx:46-48`, `data/cards.ts:103` | "Up to 10 files" vs a server limit of 20 with no client count check; input value not reset; concurrent drops |
| WEB-49 | P3 | bug | `activity/drawer.tsx:160,169`, `rule-editor.tsx:304` | Notes stay "dirty" after saving padded text; preview shows "1,000+" though the RPC returns exact counts |
| WEB-50 | P3 | security | `settings/tokens-section.tsx:131,146`, `data/settings.ts:82-91` | New token plaintext and PDF passwords linger in the MutationCache for about 5 min (`gcTime` default) |
| WEB-51 | P3 | security | `lib/supabase.ts:14` | Session in `localStorage` (supabase default). Acceptable with the strict CSP; noted as a residual XSS risk |
| WEB-52 | P3 | a11y | `routes/overview.tsx:153-166`, `ui/display.tsx:66`, router 404 | `<a>` as a direct child of `<dl>`; unnamed `role=meter` in Statements; 404 has no `main`/`h1`/nav; no skip link |
| WEB-53 | P3 | perf | `overview/category-ring.tsx` | Overview pulls the 285 kB Recharts chunk for one static donut |
| WEB-54 | P3 | readability | several | Two pager components, a duplicated invalidate helper and SMS-body toggle, `ConfirmDialog` under `rules/`, 480-line `email-section.tsx`, 470-line `data/rules.ts` |
| WEB-55 | P3 | test-gap | `lib/pagination.ts`, `rules/shared.tsx`, `data/realtime.ts`, `lib/pace.ts` | No tests for `slicePage`/`usePager` reset, `domainsFor`, `placeMarks`/`labelLanes`, member error mappers |
| WEB-56 | P3 | ux | Insights → Merchants | Netted refunds show as "AED 0.00" top merchants; columns not sortable; no per-merchant trend |

## Details

### P1

**WEB-01: Pagination past the last page is a dead end** (bug)
- **Where:** `data/transactions.ts:41-48`; `routes/activity.tsx:62-73,122-128`.
- **Problem:** nothing clamps `page` to `ceil(total/size)`. PostgREST returns 416/`PGRST103`, the retry rule skips `PGRST*`, and the pager is hidden because `q.data` is undefined.
- **Evidence:** `/activity?page=99` → "Couldn't load this · Requested range not satisfiable" (`probe-activity-page99.png`).
- **Real scenario:** bulk-categorise every row on the last page of "Uncategorised". The page empties and the user is stranded.
- **Fix:** when `total > 0 && page > pageCount`, `navigate({ page: pageCount, replace: true })`. Treat 416 as "clamp", not as an error.

**WEB-02: Hidden row caps** (bug, §4.3/§4.5)
- **Where:**
  - `useStatementCycles(limit = 120)` (`data/cards.ts:45`)
  - documents `.limit(500)` (`:64`)
  - reviews `.limit(500)` (`data/reviews.ts:74`)
  - merchants: leaderboard for the last 12 months, `p_limit: 200` (`data/rules.ts:245-251`)
- **Problem:** each screen paginates in memory over a truncated list and reports `total = rows.length`.
- **Effect once the legacy history is imported:**
  - Statements older than the newest 120 can't be reached.
  - "Open PDF" says "No PDF for this statement" for older documents (`cards.tsx:164`).
  - Health counts and "Retry failed" ignore documents past 500.
  - Merchants with no spend in the last year can't be recategorised.
  - The Review badge tops out at 500.
- **Fix:** server-side `.range()` with `count: 'exact'` and the shared page sizes. Use a `head: true` count for the badge. Add a merchant search RPC that isn't limited by spend.

**WEB-03: Sentry span data bypasses the scrubber** (security, §6)
- **Evidence:** the browser console on every load prints `[Sentry] beforeSendTransaction and ignoreTransactions are ignored with traceLifecycle: 'stream' (enabled by default). Use beforeSendSpan …`.
- **Problem:** `scrubEvent` is wired only to `beforeSend` and `beforeSendTransaction` (`lib/sentry.ts:52-53`). With `tracesSampleRate: 0.2`, router and Supabase spans (URLs, `?q=` search text, span attributes) ship unscrubbed. `sentry-scrub.test.ts` passes because it tests the function, not the wiring.
- **Fix:** add `beforeSendSpan: scrubSpan`, or set `traceLifecycle: 'static'`. Add a test asserting `Sentry.init` receives a span hook.

**WEB-04: Open self-registration** (security)
- **Where:** `sendMagicLink` passes `shouldCreateUser: true` (`data/auth.tsx:66`).
- **Problem:** if Auth sign-ups are enabled on `cc-statement-scraper`, any email can create an account, then `create_profile`, consuming storage, LLM and queue capacity. RLS still isolates data.
- **Fix:** confirm intent. For a private app, set `shouldCreateUser: false`, disable sign-ups in Supabase Auth, and invite members via the existing members flow.

**WEB-05: Foreign amounts rendered as AED** (money)
- **Where:** `routes/activity.tsx:225` and `drawer.tsx:85` render `amount_aed ?? amount_original` with the default AED currency. `amount_aed` is NULL when `estimate_fx` has no rate.
- **Scenario:** an INR 1,000 SMS shows "AED 1,000.00" and the AED total looks wrong.
- **Fix:** when `amount_aed` is null, format `amount_original` with `currency_original` and add an "FX pending" hint, as `review.tsx:92` already does. Overview "recent" (`overview.tsx:104`) has the same pattern.

**WEB-06: Contrast below AA on core text tokens** (a11y)
Measured with `audit-web/contrast.mjs` against `packages/tokens/dist/tokens.css`:

| Pair | Light | Dark | Needed |
|---|---|---|---|
| subtle on bg / surface / surface-2 | **2.98 / 3.19 / 2.78** | 3.89 / 3.57 / 3.23 | 4.5 (text) |
| accent on accent-soft (badges, 11 px) | **4.01** | 4.89 | 4.5 |
| warn on surface | **4.45** | 7.42 | 4.5 |
| warn on warn-soft ("pending" badge) | **3.84** | 6.35 | 4.5 |
| chart cat-3 on surface | **2.51** | 8.41 | 3.0 (graphics) |
| chart uncategorized on surface | **2.04** | **2.91** | 3.0 |

- **Usage:** `text-subtle` carries every eyebrow, dt label, timestamp, axis tick and hint (103 uses). axe flags 781 (desktop light), 915 (mobile light) and 578 (dark) colour-contrast nodes (`walk-*.json`).
- **Fix:** darken light `--color-subtle` to about `#7A7166` (≥4.5 on bg), `--color-warn` to about `#8A5F12`, and accent-on-soft badges to `--color-accent-hover`. Lift dark `--color-subtle` to about `#8F8778`. Darken `cat-3`/`uncategorized` in light. Ship WEB-29's test so this cannot regress.

**WEB-07: Review item with no possible action** (bug)
- **Where:** `routes/review.tsx:133-137`. For `unparsed_sms` the action bar is suppressed, and `TemplateProposal` renders only when `ctx.data.template` exists.
- **Scenario:** the LLM proposed nothing (or failed). The card has no Accept, Reject or Dismiss and lives forever, inflating the badge and "To review".
- **Fix:** render Dismiss (and "Mark as not a card message") whenever `!ctx.data.template`.

### P2

- **WEB-08: Stale search text.** `SearchBox` seeds `text` once from the URL. After "Clear filters" the URL is `/activity` but the input still shows "cafe" (`probe-activity-search-after-clear.png`). Fix: `key={search.q ?? ""}` on `SearchBox`, or sync in an effect.
- **WEB-09: Realtime topic reuse.** `supabase.channel('ledger:'+code)` returns the existing channel while `removeChannel` is still pending. `subscribe()` is then a no-op, and the leave tears it down. Verified against realtime-js 2.117.3 source, not reproduced. Fix: a unique topic per effect run (`ledger:${code}:${crypto.randomUUID()}`).
- **WEB-10: Request fan-out.**
  - The nav badge (`useOpenReviews`) loads up to 500 full `match_reviews` rows, including `candidates` jsonb, on every screen. It also fires with `profileCode=""` before a profile exists.
  - Each review card runs 1–3 context queries. Every realtime `transactions` event invalidates the `reviews` domain, and with it every context.
  - The Review screen made 8 Supabase requests with 3 items, and Settings → Sources made 13.
  - Fix: a head-count badge with `enabled: !!profileCode`, one `review_context` RPC per list, and invalidate only `["p", code, "reviews", "open"]` on txn events.
- **WEB-11: Bundle.** `states-*.js` is 837 kB (261 kB gz) and `index-*.js` 325 kB (105 kB gz), both modulepreloaded on every route, including `/signin`. The states chunk holds Sentry (303 refs), rrweb/Replay, supabase-js and Radix.
  - Fixes:
    - Load Replay lazily (`Sentry.lazyLoadIntegration('replayIntegration')`, error-only anyway).
    - Lazy-init Sentry after first paint.
    - Keep the sign-in route free of the chart and Radix chunks.
    - Drop `chunkSizeWarningLimit: 1200`.
    - Budget about 200 kB gz for the first route.
  - Recharts (285 kB) is correctly split, but Overview pulls it in for one donut (WEB-53).
- **WEB-12: "Apply to merchant" sticks.** `toMerchant` isn't reset in `pick()`, so the next category change on that row silently rewrites the whole merchant. Reset it on pick and on popover close.
- **WEB-13: Regex dialects.** The editor validates with JS `RegExp`, but rules run with Postgres `~*` (ARE). Lookbehind and other JS-only syntax passes the client, and Save stays enabled when the preview RPC errors. Fix: block Save on `preview.isError`, and validate with a CHECK/trigger (`'' ~* pattern` inside a guarded block). It is unverified whether a bad pattern on an empty profile can break later inserts; worth a pgTAP case.
- **WEB-14: Merchant "Reject" isn't sticky.** Deleting the `merchant_profile_category` row lets the cron re-queue it. Store `source='rejected'` and skip it in the cron.
- **WEB-15: Calendar future days.** Range presets end at month end, so 23 future days render as empty cells and the denominator says 184 (`d-light-insights-calendar.png`). Clamp `to` at `todayDubai()` for display and counts. On desktop the heatmap also uses about 35% of the card width; scale cell size to the container.
- **WEB-16: Anomalies copy and logic** (`d-light-insights-anomalies.png`).
  - Rows show statement descriptions in uppercase ("BAYLEAF RESTAURANT,DUBAI" and "BAYLEAF RESTAURANT" as separate rows) instead of merchant names.
  - "GRANDVIEW HOTEL · Large first purchase · Usually AED 3,000.00 ± 339.41" flags a charge below the category norm.
  - "± one standard deviation" is analyst jargon.
  - There's no "this is fine" action.
  - Fix: return `merchant_name` from `anomalies`, fix the server rule (first purchase AND above threshold), and phrase it as "about 4× your usual Shopping purchase". This is partly server-side; coordinate with the backend audit.
- **WEB-17: Category colour collisions.** In `d-light-insights-categories.png` and `d-light-rules-categories.png`:
  - Dining and Forex Charge are both clay.
  - Grocery and Medicine are both green.
  - Subscription and Cashback are both ochre.
  - Travel (`cat-7`) and Shopping (`cat-4`) are near-identical blue-greens in both themes.

  The plan requires "a fixed colour for each category". Fix: give each *spending* category a unique token (extend the palette to about 16, or reserve colours for kind=spend), and pick hues with ΔE ≥ 15 between neighbours.
- **WEB-18: Mobile axis labels dropped.** `minTickGap={18}` hides May and Aug on a 6-bar chart (`vp-m-dark-insights-trends.png`). Use `interval={0}` with short labels ("M", "J") at narrow widths, or angle them.
- **WEB-19: Focus not restored.** The drawer is opened by URL, so Radix has no trigger to return focus to. After Esc, `document.activeElement` is `<body>` (`probe.py` output). Fix: remember the opener (row button ref keyed by `txn_code`) and focus it in `onCloseAutoFocus`.
- **WEB-20: Row semantics.** `<button role="cell">` overrides the button role, so screen readers announce a cell, not an action (axe `aria-allowed-role`, 351 nodes). Fix: keep `role="cell"` on a wrapper `<span>` and put a real `<button>` inside it. Or drop the ARIA table and use a list of buttons.
- **WEB-21: Reduced motion strobes.** The rule `animation-duration: 1ms !important` doesn't stop `animation-iteration-count: infinite`. `animate-ping` (Pending dot) and `animate-pulse` (every skeleton) then cycle every 1 ms. Add `animation-iteration-count: 1 !important` (or `animation: none` for those utilities).
- **WEB-22: Tap targets.** Measured at 390 px:
  - insight dismiss: 22×22
  - category pill: ~86×24
  - rule active switch: 36×20
  - "All categories", "Show message", "Documents →": 16–20 px tall
  - calendar cells: 13×13

  Use `--space-tap-min` (44 px) hit areas, padding or pseudo-element extenders, on mobile.
- **WEB-23: Review buried on mobile.** The bottom tabs are Overview, Activity, Insights, Cards and More, while Review is the only screen with a call to action. Swap Cards for Review with a numeric badge (Cards moves to More), or show a "3 to review" chip on Overview mobile.
- **WEB-24: Bulk actions are thin** (`vp-d-light-activity-bulk.png`).
  - The bar holds one pill that reads "Uncategorised", which looks like a status rather than an action.
  - There's no selected count by amount, no "Exclude from spending", no "Export".
  - Checkboxes are `hidden md:block`, so there is no bulk at all on mobile.
  - Fix: "Categorise…", "Exclude", "Export CSV" buttons, a server-computed selection total, and long-press to select on mobile.
- **WEB-25: Insights are dead ends.** `insights.kind` and `data` already identify budget, merchant, statement or category, but the Overview cards (`d-light-overview.png`) only allow dismissal. Map each kind to a destination:

  | Kind | Destination |
  |---|---|
  | `budget_risk` | `/budgets` |
  | `statement_due` | `/cards?tab=statements` |
  | `price_change`, `new_recurring` | `/insights?tab=subscriptions` |
  | `uncategorized` | `/activity?category=none` |
  | `category_spike` | `/insights?tab=categories` |
  | `large_transaction` | `?txn=` |
  | `review_backlog` | `/review` |

  Also give them a "Worth a look" section on Insights, not just Overview.
- **WEB-26: Misleading pace rule.** The "3-month average AED 9,865" pin is a full-month figure set against MTD spend of 860 on the 8th, so the dot always sits far left early in the month. Ask the server for `spend_avg_3m_to_date` and `projected_month_end` (the budget insight already computes "on pace for"). Pin those, and show "Projected AED X by 31 Oct".
- **WEB-27: Empty ledger onboarding.** On a fresh profile (`probe-household-overview.png`) the user gets a giant AED 0.00, an empty ruler, a pulsing "Pending" dot and four separate empty states. Replace them with a "Get your ledger going" checklist built from server state: upload a statement, connect the mailbox, set bank PDF passwords, install the SMS shortcut, invite a member.
- **WEB-28: Budgets.**
  - `budgets.isError` and `categories.isError` aren't rendered, so a failed load shows an empty state that says "listed below" (`routes/budgets.tsx:96-113`).
  - `budgetAppliesTo` (`data/budgets.ts:108`) re-implements the server's `distinct on` choice to label "Replaced by a newer budget", which §2.2 forbids. Return an `is_effective` flag from the RPC instead.
- **WEB-29: No contrast guard.** Add a vitest test in `packages/tokens` (or `apps/web/src/test`) that asserts every text pair ≥ 4.5, non-text and chart pairs ≥ 3, and distinct chart hues, in both themes. `audit-web/contrast.mjs` is a ready starting point.

### P3 (polish, grouped)

**UI consistency (WEB-30–34)**
- **WEB-30:** add `pr-0.5` or `not-italic` to the truncated label (`d-light-activity-drawer.png` shows "Uncategorisea").
- **WEB-31:** pick UK "Uncategorised" everywhere, including `pivotSeries`' fallback label and the server's category name.
- **WEB-32:** use fixed grid column widths in Statements rows (`d-light-cards-statements.png`, the 5 Apr row).
- **WEB-33:** Rules and Settings use a different container than other pages (`d-light-rules-categories.png` content starts at x=328, other pages at 272).
- **WEB-34:** pick one rule. Two decimals for transaction-level figures; whole units for balances, limits and aggregates, everywhere.

**UX copy and flows (WEB-35–44, WEB-56)**
- **WEB-35:** merge the pending strip into Recent activity, or exclude pending rows from Recent.
- **WEB-36:** "Due today", "Due tomorrow", and "Paid", "Overdue" for past dues (needs payment-matched status from the server).
- **WEB-37:** add server totals: subscriptions annual sum, YoY YTD delta, Trends period total and monthly average with an "Oct (to date)" marker. YoY shows only Dec 2025 as its comparison bar, so add a "no data for 2025 Jan–Nov" note.
- **WEB-38:** add a today tick on budget meters and "AED X over pace".
- **WEB-39:** carry `redirect` (same-origin path only) through `/signin`.
- **WEB-40:** move "Key" under "Advanced" with an auto-generated default.
- **WEB-41:** keep buttons enabled and show validation on submit, or explain why they're disabled.
- **WEB-42:** fix pluralisation; collapse revoked tokens.
- **WEB-43:** `replace: true` when opening and closing the drawer.
- **WEB-44:** mobile tab overflow needs a fade and a scroll hint, or a Select.
- **WEB-56:** merchant leaderboard should show gross and refund separately and allow sorting.

**Correctness nits (WEB-45–49)**
- **WEB-45:** filter `valid_until` in `useInsights`.
- **WEB-46:** add `.eq('profile_code', …)` and show the "belongs to another ledger" state.
- **WEB-47:** use `todayDubai(new Date(ts))`.
- **WEB-48:** add `MAX_FILES` to `checkUploadFiles` matching the server's 20, reset `e.target.value`, and ignore drops while pending.
- **WEB-49:** compare against the trimmed note; drop the "1,000+" cap text.

**Security hygiene (WEB-50, WEB-51)**
- **WEB-50:** `gcTime: 0` on `useCreateToken` and `useSetSecret`.
- **WEB-51:** keep the CSP strict (it is good: hashed inline script, no `unsafe-inline` for scripts, `frame-ancestors 'none'`). Note that `window.open('about:blank')` in `cards.tsx:169` leaves `opener` set; use `noopener` after navigation.

**Accessibility and performance (WEB-52, WEB-53)**
- **WEB-52:** wrap each Overview stat in `<div><dt/><dd/></div>` with the link inside `dd`; give the Statements utilisation meter an `aria-label`; render 404 inside the shell; add a "Skip to content" link.
- **WEB-53:** draw the Overview ring as a hand-rolled SVG (about 40 lines) so Overview doesn't load Recharts.

**Readability and tests (WEB-54, WEB-55)**
- **WEB-54:** consolidate `Pager` into `components/pagination.tsx`; move `ConfirmDialog` to `components/ui`; split `email-section.tsx` and `data/rules.ts` (hooks vs pure helpers).
- **WEB-55:** add unit tests for the listed pure helpers.

## Missing analytics the backend already supports (or nearly)

1. **Category drill-down over time.** `spend_series(p_group='category')` plus `category_breakdown.prev_amount` already exist. Clicking a category in Insights could open a per-category trend and its top merchants, instead of jumping straight to Activity.
2. **Card and account comparison.** `spend_series` supports `account` and `card` grouping, and statements carry utilisation. A Cards tab with a statement-balance trend and utilisation sparkline per account would replace today's two sparse tiles (`d-light-cards.png`).
3. **Activity summary row.** A server count is already fetched (`count: 'exact'`). Adding `sum(amount_aed)` for the filtered set, via a small RPC, gives "498 transactions · AED 52,300", plus per-day totals in the date headers.
4. **Merchant context in the drawer.** Show "Your 13th visit · avg AED 254 · AED 3,306 in 6 months" from `merchant_leaderboard`/`v_spend`, which makes recategorise-to-merchant decisions informed.
5. **Insight feed on Insights.** All nine server insight kinds are shown only as five cards on Overview. Use a dedicated "Worth a look" tab or rail, linked by kind (WEB-25).
6. **Projected month end** (WEB-26) and **subscriptions annual total** (WEB-37): small RPC additions that make the hero and Subscriptions answer "am I OK?".

## Screens walked

All four modes unless noted:
- Sign-in; Welcome / create ledger; 404
- Overview, plus the previous month
- Activity: list, drawer, bulk selection, mobile filters sheet, uncategorised filter
- Insights: all 9 tabs, plus Trends by merchant/week
- Budgets, plus the new-budget dialog
- Cards & statements: Cards, Statements, Upload, Documents
- Review
- Rules: Categories, Rules, new-rule editor with preview, Merchants
- Settings: Sources & health, Members, iPhone SMS, Appearance, Ledger
- Mobile "More" sheet
- Household (empty) profile: overview, insights, review, members

No horizontal page overflow was found at 390 px on any screen. No console errors were seen apart from the Sentry warning (WEB-03).

## Fix status

Fixed on `ledger-v2` (uncommitted), 2026-10-08. Verified with `pnpm --filter @ledger/web test` (145 pass), lint, `tsc -b`, `vite build`, `pnpm --filter @ledger/tokens check` (drift + 9 contrast tests), and a headless walk of the affected screens at 1440 and 390 px in light and dark (demo account, Demo ledger). axe colour-contrast nodes on those screens went from 781 (desktop light) to 0. The only remaining nodes are 8–10 on Settings → Sources, which are revoked tokens drawn at 60% opacity (inactive UI, WEB-42).

| ID | Status | Notes |
|---|---|---|
| Sentry local | fixed | `shouldInitSentry`: no init when `VITE_SENTRY_ENVIRONMENT` is empty, `local`, `development` or `test`, or under `import.meta.env.DEV`, even with a DSN. The supabase integration's `errors: true` is off. It reported every failed PostgREST request a second time, unfiltered, which is how the two Activity errors reached Sentry. Errors now go only through `reportQueryError`. |
| Sentry "Requested range not satisfiable" | fixed | See WEB-01. |
| Sentry "permission denied for table match_reviews" | fixed (client) | The shell's nav badge ran `useOpenReviews("")` before the session was restored, so it went out with the anon key. Anon has no grant on `match_reviews`; reproduced with curl and the anon key. The badge is now a `head` count gated on session + profile (`useOpenReviewCount`). No grant is needed. |
| WEB-01 | fixed | `fetchPage` turns 416/PGRST103 into `{rows: [], total}` via a head count. `useClampPage` moves to the last page. Applied to Activity, Statements, Documents and Review. `/activity?page=99` now lands on `?page=5`. |
| WEB-02 | fixed / partial | Statements, documents and reviews are paginated server-side with `.range()` and an exact count. The health counts use head counts per status. "Open PDF" looks up its document by code. Merchants now also list every assigned or suggested merchant outside the top-200 leaderboard, and say when the cap is hit. Still needed: `statement_cycles` caps at 500 (the UI says so), and a merchant search RPC (see the report). |
| WEB-03 | fixed | `beforeSendSpan: scrubSpan` scrubs span names, attributes and links: `db.query`, `db.body`, query-string values and secrets. `beforeSendTransaction` is removed. Tests cover the wiring as well as the function. |
| WEB-04 | fixed (client) | `shouldCreateUser: false`. GoTrue's `otp_disabled` maps to "There's no Ledger account for that email. Ask the ledger's owner to invite you." Still needed: set `[auth] enable_signup = false` in Supabase Auth for production. |
| WEB-05 | fixed | `displayAmount` + `<TxnAmount>`: with no `amount_aed`, the amount shows in its original currency with an "awaiting FX" hint (the drawer shows an "Awaiting FX rate" badge). Applied to Activity, the drawer, Overview, Review and related transactions. |
| WEB-06 / WEB-29 | fixed | Light: muted `#5E574D`, subtle `#6E665B`, accent `#964F2F`, warn `#855C11`. Dark: muted `#B0A799`, subtle `#9A9184`. New 12-colour chart palette with every pair ≥ 15 ΔE2000 and ≥ 3:1 on bg and surface. `tokens.json#contrast` declares the pairs, and `packages/tokens/test/contrast.test.mjs` (run by `check`) enforces them. `Tokens.swift` is regenerated. |
| WEB-07 | fixed / partial | An unparsed SMS with no proposed format now offers "Not a card transaction" (`{dismiss, not_a_transaction}`) and "Dismiss". "Retry AI" needs a new RPC (see the report). |
| WEB-08 | fixed | The search box follows `?q=` when it changes elsewhere ("Clear filters", Back). |
| WEB-17 | partial | The palette is now distinct. Seed categories still share tokens (Dining = Forex Charge, Grocery = Medicine). That needs a DB reassignment (see the report). |
| WEB-18 | fixed | `axisTickInterval` replaces `minTickGap`: every label shows when they fit (7 on mobile, 14 on desktop). |
| WEB-21 | fixed | Reduced motion also sets `animation-iteration-count: 1`. |
| WEB-22 | fixed / partial | The new `tap` utility extends hit areas to 44 px below `lg` on small buttons, switches, checkboxes, category pills and inline links. Insight dismiss is 44×44 on mobile. Calendar heat cells are deferred (a 7×N grid can't take 44 px cells). |
| WEB-23 | fixed | Review replaces Cards in the mobile bottom bar, with a numeric badge. Cards moves to More. |
| WEB-25 | fixed | `insightTarget` maps each kind to its screen. Cards are links ("See budgets", …). |
| WEB-45 | fixed | Insights are filtered by `valid_until`. |
| Others | deferred | The other P2/P3 items are out of this pass's scope. Server totals and projections (WEB-26, WEB-37, Activity sum) need RPCs. |

**Later (`98f901c`):** WEB-02 is fixed (Merchants search and paging through `merchant_search`;
Statements up to 5000 cycles) and WEB-07 is fixed ("Retry AI" via `retry_sms_fallback`; "Not a card
transaction" now sends exactly `{not_a_transaction: true}`). Everything still open, including the
deferred P2/P3 items and the "Missing analytics" recommendations, is in [BACKLOG.md](BACKLOG.md).

**SQL side of WEB-14 (2026-10-09):** `public.reject_merchant_suggestion(p_profile_code,
p_merchant_code)` deletes the LLM suggestion and records `merchant_category_skips.reason =
'rejected'`, which `enqueue_llm_categorize` never re-queues (`20261009000200`). The Merchants tab
still has to call it instead of deleting the row.

**Backlog batch 1 (2026-10-13):** WEB-09, WEB-12, WEB-13, WEB-28 (web) and NEW-1r are fixed; outcomes in
[BACKLOG.md](BACKLOG.md#done-backlog-batch-1-2026-10-13).
