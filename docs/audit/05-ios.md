# Audit 05: iPhone app (Ledger v2)

**Scope:** `apps/ios` in full: the `LedgerKit` package (36 source files), the `Ledger` app target, the `LedgerShare` extension, `project.yml`, `Config/*.xcconfig`, `Info.plist`/entitlements and `scripts/publish-build.sh`. The house conventions were checked against `CLAUDE.md` §2, §5, §6 and `mm-pos/CLAUDE.md`.
**Branch:** `ledger-v2` @ `4ec697c`. **Date:** 2026-10-08.
**Method:**
- Read every Swift file and the related SQL (`ingest_sms`, `process_sms`, `match_sms`, `overview`, `assert_member`, the `sms_templates` seed).
- Ran `swift test`: 71 tests in 12 suites, all passing.
- Built the app twice with `xcodebuild` for the simulator: unsigned (`CODE_SIGNING_ALLOWED=NO`) and "Sign to Run Locally".
- Ran the app on three dedicated simulators (iPhone 17 Pro, iPhone SE 3rd gen, iPhone 17 Pro Max; iOS 26.5) against local Supabase as `demo@ledger.local`, on the Demo and Household profiles, in light, dark and Dynamic Type sizes up to AX5.
- Ran the real on-device SMS filter (`SMSCapture.classify`, compiled verbatim from source) against all 30 bank examples in `20261008001000_sms_templates.sql`, plus 11 synthetic adversarial cases.

No source files were changed and nothing was committed. No data was written to the local DB: the category and upload flows were opened and cancelled.

Screenshots are in the session scratchpad: `…/scratchpad/audit-ios/NN-*.png`. They are referred to below by file name.

## Summary

| Severity | Count |
|---|---|
| P0: broken, security or data loss before cutover | 1 |
| P1: should fix before cutover | 7 |
| P2: soon after | 15 |
| P3: polish | 8 |

**What is solid.**
- Money is `Decimal` end to end, with strict parsing and half-up rounding done in base 10.
- Dates are pinned to `en_US_POSIX` and `Asia/Dubai`.
- The keychain uses `AfterFirstUnlockThisDeviceOnly` and the outbox uses `completeUntilFirstUserAuthentication` with no backup. Both are the right classes for an automation that fires on a locked phone.
- The Sentry scrubber is thorough and unit-tested. No `print` or `os_log` calls exist anywhere, and SMS bodies never reach dialogs or breadcrumbs.
- Swift 6 strict concurrency compiles cleanly (two cosmetic warnings).
- `Tokens.swift` has no drift from `packages/tokens`.
- Every file is ≤ 242 lines.
- **The on-device filter is correct on every real alert.** All credit-card purchase, refund and declined formats from ADCB, FAB (multi-line, AED and USD), ENBD (including *"Payment of AED x to Noon with Credit Card"*) and SIB are accepted. ADCB *"Debit card XXX… linked to acc."*, FAB *"Debit Card Purchase"*, account credits, remittances, transfers and logins are dropped. Evidence: the `smscheck` run, 30/30.

**What breaks.**
- The SMS outbox can wedge permanently (IOS-01).
- SMS are filed to whichever ledger was last viewed (IOS-02).
- Several analytics and UX claims on Overview are wrong or alarming (IOS-03, IOS-04).
- The app does not survive large Dynamic Type sizes (IOS-05).
- The SMS setup guide fires each alert 2–3 times and hides failures (IOS-06).

## Findings

| ID | Sev | Category | Location | Title |
|---|---|---|---|---|
| IOS-01 | P0 | bug | `API/SupabaseLedgerAPI.swift:222-226`, `API/LedgerAPI.swift:86-91`, `Outbox/Outbox.swift:116-151` | Every PostgREST error is "transient", so one permanent failure blocks the SMS outbox forever and every new SMS joins the blocked batch |
| IOS-02 | P1 | bug | `Config/LedgerServices.swift:50-54`, `Screens/ProfileStore.swift:29-32,50-54` | SMS (and shared PDFs) go to the *last-viewed* ledger. Viewers are allowed to post. `canWrite` is never used. |
| IOS-03 | P1 | bug | `Screens/Presentation.swift:68-77` vs `Screens/StatementsModel.swift:55-60` | Overview shows paid past statements as red "Overdue by 13 days"; Statements says "Was due 25 Sep" for the same cycle |
| IOS-04 | P1 | ux | `Screens/Presentation.swift:34-52`, `Overview/OverviewView.swift:45-47` | The hero compares month-to-date spend with a *full-month* 3-month average ("91% below" on the 8th), re-deriving a ratio the server already returns (violates §2.2) |
| IOS-05 | P1 | a11y | `Theme/Typography.swift:7`, `OverviewView.swift:53-107`, `ActivityView.swift:91-120` | At accessibility sizes the hero inverts (unit larger than number), the pending strip clips, ring legend truncates to "Di…" and wraps "57/0", and Activity rows read "Live T…" |
| IOS-06 | P1 | ux | `Screens/SettingsModel.swift:51-75` (guide) | The Shortcuts guide creates three automations ("AED", "Card", "ending"), so most alerts fire 2–3 intents. "Notify When Run" off hides every result. The test step cannot be verified in-app. |
| IOS-07 | P1 | ux | `SMS/SMSIntake.swift:43`, `Models/Overview.swift:14-15` | The intent tells the user to "check Review", but iOS has no Review surface. `openReviews` and `uncategorizedCount` are decoded and never shown. |
| IOS-08 | P1 | security | `project.yml` (both targets) | No `PrivacyInfo.xcprivacy` in the app or the extension, which use `UserDefaults(suiteName:)` (a required-reason API). App Store Connect flags ITMS-91053. |
| IOS-09 | P2 | security | `Auth/SessionStore.swift:32-55`, `Auth/SharedKeychainStorage.swift:85-97`, `Screens/Presentation.swift:25-27` | If the session fails to persist, the UI is "signed in" while every request goes out as `anon` and shows raw "permission denied for table profiles". The keychain fallback silently drops sharing. |
| IOS-10 | P2 | bug | `SMS/SMSCapture.swift:59-61` (+ server mirror `…0700:1009`) | OTP false negatives: "Use 482913 as the code…", "authentication code", Arabic "رمز التحقق". The real-card wording means they pass the filter. |
| IOS-11 | P2 | test-gap | `Tests/SMSCaptureTests.swift`, `OutboxTests.swift`, `.github/workflows/ci.yml:211-232` | Filter tests use synthetic text, not the 30 real template examples. Nothing tests permanent outbox errors. CI never compiles the app or extension targets. |
| IOS-12 | P2 | ux | `SMS/SMSIntake.swift:13-21,71`, `Screens/AppModel.swift:108-113` | Intent outcomes mislead: "queued" always says "when you're back online" (also for signed-out or server errors), and `noProfile` silently discards the SMS. Stuck items surface nowhere outside Settings, and sign-out leaves SMS bodies in the outbox. |
| IOS-13 | P2 | bug | `API/SupabaseLedgerAPI.swift:165-193`, `Screens/LiveUpdates.swift`, `Screens/AppModel.swift:99-121` | A failed Realtime subscribe ends the stream with no retry. Foreground reloads only Overview. Insights never refreshes. |
| IOS-14 | P2 | bug | `Screens/AppModel.swift:85-95`, every `*Model.load` (`startLoading()` keeps `previous`) | Switching ledger briefly shows the *previous* ledger's numbers under the new one |
| IOS-15 | P2 | bug | `Activity/ActivitySheets.swift:67-98`, `Screens/ActivityModel.swift:57-87` | Filters bind live (swipe-dismiss leaves them changed but unapplied). There is no date filter, `loadMore` ignores `loadToken`, and recategorising resets to page 0. |
| IOS-16 | P2 | bug | `Upload/PendingUploads.swift:36-64` | Queued PDFs upload to the profile selected at *flush* time. One permanently rejected file blocks the queue forever. |
| IOS-17 | P2 | ux | `Statements/StatementsView.swift` | Statement upload flow: no per-file progress or parse outcome, `parse_error` never shown, the upload card permanently occupies the top, and viewers are not gated |
| IOS-18 | P2 | ux | `Activity/ActivitySheets.swift:6-64` | Category editing: no "None"/clear, no search, the medium detent shows 3 categories, "apply to merchant" defaults off, and there is no notes or exclude-from-spend control |
| IOS-19 | P2 | a11y | `Theme/Tokens.swift` (`subtle`, `warn`/`warnSoft`) | `Palette.subtle` used for text is 2.98:1 (light) and 3.57–3.89:1 (dark). The warn chip is 3.84:1. |
| IOS-20 | P2 | a11y | `ActivityView.swift:28-31`, `OverviewView.swift:40-44,165`, all charts | Zero `accessibility*` modifiers: icon-only filter and dismiss buttons have no labels, the dismiss target is < 44 pt, the hero reads "AED" and "860" apart, and charts have no summaries |
| IOS-21 | P2 | security | `scripts/publish-build.sh:59-67,153`, `Config/Release.xcconfig`, `Config/Base.xcconfig:30` | Release config inherits local `Secrets.xcconfig`. The preflight checks the file, not the built Info.plist. A Sentry org token sits in `Secrets.Release.xcconfig` where the script never reads it. |
| IOS-22 | P2 | security | `Ledger/App/LedgerApp.swift` | No privacy cover in the app switcher and no optional Face ID lock, so balances and transactions show in the multitasking snapshot |
| IOS-23 | P2 | ux | `OverviewView.swift:33-51` | An empty ledger (Household) shows "AED 0 · No 3-month history yet · Same as this time last month" instead of an onboarding checklist |
| IOS-24 | P3 | concurrency | `Config/LedgerServices.swift:29-42`, `ShareExtension/ShareViewController.swift:15` | The app and the share extension can refresh the same rotating refresh token concurrently. Only the 10 s reuse window protects against a revoked session. |
| IOS-25 | P3 | concurrency | `Outbox/Outbox.swift:117-151`, `Dates/LedgerDates.swift:28-32`, `Telemetry/Telemetry.swift:75` | Outbox actor reentrancy lets two flushes send the same entry: harmless server-side, but the intent may answer "Already logged" for a first delivery. There are 2 Swift 6 warnings. |
| IOS-26 | P3 | perf | `Screens/ActivityModel.swift:29,90-100`, `Dates/LedgerDates.swift:90,97` | `sections` is re-sorted on every body evaluation, and an `ISO8601DateFormatter` is allocated per decoded timestamp |
| IOS-27 | P3 | ui | `Components.swift:139-145`, `Typography.swift`, `StatementsView.swift:13,52` | Nav large titles are SF Bold while section heads are serif. Title and month eyebrow are redundant, "Statements" appears twice, and AED is hard-coded despite `base_currency`. |
| IOS-28 | P3 | ux | `Insights/InsightsView.swift` | The partial current month is drawn like a finished month. There is no average or budget rule, no bar values, and categories and merchants are not drillable. |
| IOS-29 | P3 | readability | several views | Small presentation decisions still sit in views (`categoryName ?? "Uncategorized"`, `prefix(4)`, `prefix(10)`, `bankCode ?? "Bank unknown"`, recurring subtitle) |
| IOS-30 | P3 | security | `Telemetry/Telemetry.swift:34-53`, `project.yml` ATS | Sentry's default failed-request capture can carry Activity search terms in the PostgREST URL. `NSAllowsLocalNetworking` ships in Release. |
| IOS-31 | P3 | bug | `SMS/SMSCapture.swift:59-87` | Minor filter edges: a merchant named "OTP …" is dropped. Credit-card wording overrides "transfer/account", so "payment received… via transfer from account" is sent (server classifies it). |

---

## Details

### IOS-01 (P0, bug): the SMS outbox can wedge permanently

**Problem.**
- `SupabaseLedgerAPI.map` turns every `PostgrestError` into `.server(status: nil, …)`.
- `LedgerAPIError.isTransient` returns `status.map { … } ?? true`, so *every* database error counts as transient. That includes:
  - 42501 from `assert_member(p_profile_code, true)`, which requires the owner role;
  - 22023 for the batch-size check;
  - any exception raised inside `process_sms` (for example a `to_date`/`parse_amount` failure or the `statement_timeout = '2s'` in `match_sms_template`).
- `ingest_sms` is one transaction, so a single bad message rolls back its whole batch of up to 200.
- `Outbox.flush` then:
  - keeps the batch;
  - backs off to a 1 h cap with **no attempt limit and no dead-letter**;
  - and, because `break outer` only fires for non-transient errors, retries forever.
- Every new SMS is batched together with the poison entry, so **nothing is ever delivered again**.
- The intent tells the user *"Saved. It will be sent when you're back online."* (`SMSIntake.swift:19`), and with "Notify When Run" off (IOS-06) they never see even that.
- A realistic trigger exists today: a household member with the `viewer` role selects the Household ledger. The seed has a viewer on the Demo ledger.

**Evidence.** Code path above. `OutboxTests` only exercises `.network` failures and `.notSignedIn`.

**Fix.**
1. Classify PostgREST errors by SQLSTATE: `42501`, `22xxx`, `23xxx` and `P0001` are permanent; `57014` (timeout), `08xxx`, `53xxx` and HTTP 5xx are transient.
2. On a permanent batch error, retry each message alone and quarantine the failing ones into a `failed` list with the reason, shown in Settings with "Discard / Retry".
3. Cap attempts (e.g. 20) and age (e.g. 14 days).
4. Server side, consider a per-message `begin … exception` inside `ingest_sms`, so one bad body yields `status: 'error'` instead of aborting the batch.
5. Add tests for "one permanent failure doesn't block later messages".

### IOS-02 (P1, bug): SMS go to whichever ledger was last opened

**Problem.**
- `LedgerServices.smsIntake()` posts to `selection.profileCode`, which is simply the ledger currently shown in the app. Shared PDFs follow the same rule (`flushPendingUploads` uses the same value).
- If you browse Household and then pay with a personal card, the SMS lands in Household. There it becomes `unknown_card`, because cards are matched per profile. It is missing from your own ledger, and no UI can move it.
- `ProfileStore.canWrite` exists ("SMS ingest and uploads need the owner role") but nothing reads it. Viewers can therefore select a ledger and post to it, which leads to IOS-01.

**Fix.**
- Store a separate, explicit **"SMS & shared statements go to: ___"** setting in the App Group. Default it to the first *owned* profile, show it in Settings, and on the intent's result line.
- Never let a non-owned profile be chosen.
- Longer term, let `ingest_sms` route by `(bank, last4)` across all of the caller's owned profiles.

### IOS-03 (P1, bug): a paid statement shown as overdue

**Problem.**
- `AccountSummary.dueLabel` and `dueTone` use `LedgerDates.dueLabel`, which yields "Overdue by N days" in `.danger` red for any past due date.
- `StatementCycle.dueText` deliberately says "Was due 25 Sep", because payment status is unknown.
- The same FAB cycle therefore reads **"Overdue by 13 days"** (red) on Overview and "Was due 25 Sep" on Statements.

**Evidence.** `05-overview-cards-insights.png` vs `15-statements-light.png`.

**Fix.** Reuse `dueText` semantics on Overview, with neutral tone for past dates. When the server knows a payment covered the statement (the `payments` credit since the statement date), say "Paid".

### IOS-04 (P1, ux): a misleading hero comparison

**Problem.**
- `SpendComparison.versusAverage` compares `spend` (month to date) with `spend_avg_3m`, which is a **full-month** average. On 8 October the hero reads "91% below your 3-month average" (`04-overview-light.png`). Early-month spend almost always looks "far below".
- It also recomputes the ratio on the client, although `overview` returns `change_vs_avg_3m` and `change_vs_prev_month_to_date` (`20261008001300_web_followups.sql:178,218-219`). That breaks CLAUDE.md §2.2.
- The hero also excludes the 32 pending transactions (AED 3,105) shown right below it. A first-time reader takes 860 as "spent so far".

**Fix.**
- Have the server return a pace-fair figure (`spend_avg_3m_to_date`, or a projected month-end) and the ratio, and render the server's ratio.
- Label the hero "Posted so far" or fold pending into it with a "incl. AED 3,105 pending" sub-line.

### IOS-05 (P1, a11y): Dynamic Type breaks the layout

**Problem.**
- `Typography.hero` is a fixed 52 pt, while `heroUnit` scales. At AX5, "AED" becomes larger than "860" (`22-overview-AX5.png`).
- The pending strip is a fixed `HStack` and clips "AED 3,105.3…".
- The ring card keeps the ring and legend side by side. Labels truncate to "Di…", "Un…", and numbers wrap digit by digit "57 / 0" (`23-overview-AX5-ring.png`).
- Activity rows truncate the merchant to "Live T…" and the chip hyphenates "Pend-ing" (`24-activity-AX5.png`). Even at xxxL (non-AX) the card label truncates to "ADCB •4…" (`25-activity-xxxl.png`).

**Fix.**
- Make the hero relative: `.system(.largeTitle, design: .serif)` scaled with `@ScaledMetric`, or a `relativeTo:` custom size.
- Use `ViewThatFits` or `dynamicTypeSize.isAccessibilitySize` to stack the hero, the pending strip, the ring above the legend, and the Activity row (amount and chip under the title).
- Cap the chip at `.dynamicTypeSize(...DynamicTypeSize.accessibility2)`.

### IOS-06 (P1, ux): the SMS setup guide

The guide is otherwise clear and correctly says to leave Sender empty (`18-sms-guide-1.png`). Four problems remain:

1. **Triple firing.**
   - Keywords "AED", "Card" and "ending" each need an automation. Almost every real alert contains two or three of them (e.g. ENBD *"Purchase of AED … with Credit Card ending 7205"* matches all three).
   - Each firing mints a new `client_msg_id`, so the server stores 2–3 `sms_messages` rows.
   - `match_sms` folds the extras as `duplicate` evidence. However, an `unknown_card` SMS creates 2–3 review rows, and an `unparsed` one triggers the LLM fallback 2–3 times.
   - The guide's "Duplicates are harmless" is therefore only partly true.
   - **Every real credit-card format for the four banks contains "card"** (ADCB "Cr.Card" and "Credit Card", FAB "Credit Card Purchase / Card No", ENBD "Credit Card ending" and the refund's "your card ending", SIB "Covered Card").
   - Recommend **one automation, "Message contains Card"**. Confirm on a device that Shortcuts matching is case-insensitive, since the ENBD refund uses lowercase "card". Drop "AED", which only adds account alerts and foreign-currency noise, and drop "ending".
2. **Step 3 turns off *Notify When Run*.** Combined with "Run Immediately", the intent's result dialog is never seen, so drops, `unknown_card` and queued failures are silent. Have the intent post a local notification (`UNUserNotificationCenter`) **only** for actionable outcomes (unknown card, stuck or failed, signed out). Request permission from the guide.
3. **Step 7** asks a friend to text *"AED 1.00 test card ending 0000"*.
   - That reaches the server from a phone-number sender, becomes `unparsed`, and calls the LLM.
   - Success then shows "Nothing waiting" in Settings, and unparsed SMS have no iOS surface.
   - Replace it with an in-app **"Test the automation"** dry-run. For example, the intent could accept a `isTest` parameter, or the app could keep the last intent outcome in the App Group and show "Last run: 14:05 · Logged" in Settings.
4. The guide has no screenshot-level detail for the iOS 18 Shortcuts UI ("Shortcut Input" is chosen via the variable picker). An inline 3-image strip would remove most setup errors.

### IOS-07 (P1, ux): "check Review" points nowhere

**Problem.**
- `SMSIntakeOutcome.statusMessage("unknown_card")` says "check Review", but the iOS app has no Review screen.
- `Overview.openReviews` and `uncategorizedCount` are decoded and never rendered.
- A new card's SMS therefore disappear from the user's point of view until they open the web app.

**Fix.**
- Add an Overview "Needs attention" row ("2 SMS from an unknown card · 5 uncategorised") linking to a minimal Review list: assign a card to an account, or ignore it.
- Until that exists, word the dialog "…open Ledger on the web to add this card".

### IOS-08 (P1, security): no privacy manifest

**Problem.**
- Neither target ships `PrivacyInfo.xcprivacy`.
- Both read and write `UserDefaults(suiteName:)`, a required-reason API (`NSPrivacyAccessedAPICategoryUserDefaults`, reason `1C8F.1` for App Group).
- App Store Connect emails ITMS-91053 on upload and blocks review submission. TestFlight external testing and the App Store privacy label also need `NSPrivacyCollectedDataTypes`: financial info, email, crash data and user ID, all linked and not used for tracking.

**Fix.** Add a manifest to `Ledger/` and `ShareExtension/` (XcodeGen picks it up via sources) and declare the collected data types.

### IOS-09 (P2, security): signed in on screen, anonymous on the wire

**Problem.**
- With the unsigned simulator build (no entitlements), sign-in succeeded in memory. The keychain write failed: there was one `SecItemUpdate` and no `SecItemAdd`, and the error is not `-34018`, so `withGroupFallback` did not retry.
- The `authStateChanges` event still set `.signedIn`. Every PostgREST call then went out with the anon key, and the profile picker showed **"permission denied for table profiles"** (`02-after-signin.png`).
- The signed build works (`03-after-signin-signed.png`). The failure mode is the real finding: a provisioning or keychain fault on a device produces a "signed-in" app that cannot read anything and an unhelpful raw Postgres message.
- In Release, the silent `groupUnavailable` fallback would also make the App Intent think it is signed out.

**Fix.**
- After `.signedIn`, verify `try await auth.session` round-trips from storage. If it does not, show "Couldn't save your sign-in" and capture a `KeychainError` to Sentry.
- Restrict the no-group fallback to `#if DEBUG`.
- Map PostgREST `42501` and `PGRST*` codes to friendly text in `LoadState.message`.

### IOS-10 (P2, bug): OTPs that pass the filter

Run against the real classifier:
- *"Use 482913 as the code to complete your purchase of AED 99.00 … Credit Card ending 7205. Never share this code."* → **accept**
- *"Your authentication code for Credit Card XX3687 transaction of AED 20.00 is 552211"* → **accept**
- Arabic *"رمز التحقق …"* → **accept** (through the amount rule)

Real UAE OTPs mostly say "OTP" or "One-Time Password", which are caught. Banks rotate wording, though, and the server mirrors the same regex.

**Fix.**
- Add `auth(entication)? code`, `secure code`, `3-?d ?secure`, `\bcode\b.{0,40}\b\d{4,8}\b` / `\b\d{4,8}\b.{0,40}\bcode\b`, `do not share`, `رمز`, `كلمة المرور`.
- Keep the iOS and SQL regexes in one generated source, or assert parity in tests.

### IOS-11 (P2, test-gap): what the tests miss

**Gaps.**
- `SMSCaptureTests` uses invented bodies.
- The 30 real examples in `sms_templates` (and whatever future templates add) are not asserted on the device. The parity property that matters is "every `purchase/refund/declined` example is accepted; every `debit_card` example is dropped".
- `OutboxTests` lacks permanent-error, dead-letter and multi-profile-mixed-failure cases.
- CI's `ios` job runs only `swift test`, so a view that fails to compile reaches TestFlight's archive step first.

**Fix.**
- Export the template examples to `Tests/Fixtures/sms_examples.json` (a script, like `db:types`) and drift-check it in CI.
- Add an `xcodebuild build -scheme Ledger -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO` CI step.

### IOS-12 (P2, ux): intent outcomes and outbox hygiene

**Problem.**
- `.queued` always says "when you're back online", even when `report.error` is `.notSignedIn` or a server error.
- `.noProfile` returns before enqueuing, so the SMS is lost. That happens, for example, right after signing out and before picking a ledger.
- Nothing outside Settings shows a non-empty outbox.
- Sign-out (`AppModel.signOut`) leaves SMS bodies in `sms-outbox.json`. They would later be sent under whoever signs in next, to the old profile code, which fails with 42501 and leads to IOS-01.

**Fix.**
- Carry the reason in `.queued(reason:)`.
- Enqueue with a pending profile on `noProfile`.
- Badge the Settings tab and add an Overview strip when the outbox is older than 1 h.
- Clear the outbox and pending uploads on sign-out, after a confirmation that names the count.

### IOS-13 (P2, bug): Realtime lifecycle

**Problem.**
- `changes()` finishes the stream when `subscribeWithError` throws (offline at launch, token expired), and `LiveUpdates` never restarts it.
- `becameActive` reloads only Overview, so Activity and Statements stay stale after a background period in which events were missed.
- `refresh(after:)` never reloads Insights.

**Fix.**
- Restart with backoff when the stream ends while the profile is still selected.
- On foreground, reload every loaded tab, or mark them stale and reload on appear.
- Include Insights in the `transactions` fan-out.

### IOS-14 (P2, bug): stale data after switching ledger

**Problem.** Models are long-lived and `startLoading()` keeps `previous`. After Settings → Switch ledger → Household, every tab first renders the Demo ledger's numbers until the new load completes.

**Fix.** On a profile change, reset all screen models to `.idle`, or key `previous` by profile code.

### IOS-15 (P2, bug): Activity filters, paging and recategorising

**Problem.**
- `ActivityFilterSheet` binds `$model.query` directly. Swipe-dismissing after a change leaves the query (and the "filled" icon) changed with no reload.
- `ActivityQuery.from` and `to` exist but have no UI.
- `loadMore` doesn't check `loadToken`, so a page from the old query can merge into new results.
- `setCategory` calls `load` (page 0), which drops loaded pages and the scroll position.

**Fix.**
- Edit a local copy and apply on "Apply" or dismiss.
- Add a month/date-range picker.
- Guard `loadMore` with the token.
- Patch the edited row in place, or re-fetch only that row.

### IOS-16 (P2, bug): pending uploads

**Problem.**
- `flushPendingUploads` uses the *current* selection, not the profile chosen at share time.
- `flush` stops at the first failure and never deletes, so a permanently rejected PDF (4xx: not a statement, not an owner) blocks the queue forever.
- The app shows no count of pending files.

**Fix.**
- Store the profile code in the queued file's name or a sidecar.
- Delete or quarantine on non-transient errors.
- Show "2 PDFs waiting" on Statements.

### IOS-17 (P2, ux): statement upload flow

**Problem.**
- The picker works (`16-statements-picker.png`), but the result is a single caption ("1 statement queued for parsing").
- The Uploads list shows a status chip, but `parse_error` and `parse_error_code` are fetched and never shown, and rows aren't tappable.
- The explanatory card permanently takes the top of the tab (`15-statements-light.png`), and the screen is titled "Statements" twice.

**Fix.**
- Move "Add" to a toolbar `+`.
- Show a per-file progress row that turns into the parse result via Realtime ("Parsed · ADCB •4821 · 42 lines", or the error with "Retry" / "Set password on web").
- Make cycle rows open a detail screen with reconciliation chips explained.

### IOS-18 (P2, ux): category editing

**Problem.**
- The sheet (`08-category-sheet.png`) opens at `.medium`, so only 3 categories are visible.
- There is no search, no "None" (a manual category cannot be cleared), and "Apply to every … transaction" defaults off. Applying to the merchant is the common intent and the cheapest way to cut future uncategorised rows.
- The sheet cannot set notes or `exclude_from_spend` (both user-editable per CLAUDE.md §1.10).
- It never shows the evidence (SMS or statement line), the card or the original currency.

**Fix.**
- Open at `.large` with `.searchable`.
- Default the merchant toggle on when `categorySource != "manual"`.
- Add "Exclude from spend" and notes.
- Add swipe actions on rows ("Categorise", "Exclude").

### IOS-19 (P2, a11y): contrast

The ratios were computed from the generated tokens:

| Pair | Light | Dark |
|---|---|---|
| `subtle` on `bg` | 2.98:1 | 3.89:1 |
| `subtle` on `surface` | 3.19:1 | 3.57:1 |
| `warn` on `warnSoft` | **3.84:1** | — |

`subtle` is used for real text, at caption size where 4.5:1 is needed: the "Pending" labels in Latest, merchant rank numbers and "Category from …". `muted` passes (4.6–6.4).

**Fix.** Use `muted` for any text and keep `subtle` for glyphs and dividers. Darken `warn` in light mode, or render the chip text in `ink2`. This is a token change, so make it in `packages/tokens`.

### IOS-20 (P2, a11y): VoiceOver

**Problem.**
- No view sets any `accessibility*` modifier.
- The filter toolbar button is an unlabeled SF Symbol.
- The insight dismiss is a `.caption` "xmark" (≈ 15 pt target, unlabeled).
- The hero reads as two elements, "AED" and "860".
- `TransactionRow` reads five fragments.
- The ring and bar charts have no `accessibilityChartDescriptor` or summary.

**Fix.**
- Add `.accessibilityLabel` to the filter ("Filters, 2 active") and to dismiss ("Dismiss insight"), with a `frame(minWidth: 44, minHeight: 44)`.
- Combine the hero (`.accessibilityElement(children: .combine)`, label "October spend, 860 dirhams") and rows ("Cafe Marina, 47 dirhams 50, Dining, FAB ending 7310, pending").
- Add `.accessibilityChartDescriptor` to both charts.

### IOS-21 (P2, security): release script and config

**Problem.**
- `Release.xcconfig` includes `Base.xcconfig`, which `#include?`s the **local** `Secrets.xcconfig` (127.0.0.1, local anon key, `local` env) before `Secrets.Release.xcconfig` overrides it.
- Today all four keys are overridden. Drop one, though, and a TestFlight build silently ships the local value. The preflight only greps `Secrets.Release.xcconfig` for `127.0.0.1`.
- `Secrets.Release.xcconfig` also holds a `SENTRY_AUTH_TOKEN` (an org token). The script reads it only from the environment (`${SENTRY_AUTH_TOKEN:-}`), so it is never used there: dSYMs are skipped unless it is exported separately. Meanwhile the token becomes a build setting visible to every build phase.
- No Sentry release is created or finalized, and there are no commits or deploy markers.

**Fix.**
- Include `Secrets.xcconfig` only from `Debug.xcconfig`.
- After archiving, assert from the archived app and `.appex`:
  - `plutil -extract LedgerSupabaseURL raw …` starts with `https://` and is not local;
  - `LedgerEnvironment` is `production`;
  - the anon key and DSN are non-empty.
- Move the Sentry token to the environment or the keychain. Add `sentry-cli releases new/set-commits/finalize ledger-ios@$VER+$BUILD`.

### IOS-22 (P2, security): app-switcher privacy

**Problem.** A finance app showing card balances has no snapshot cover. The multitasking switcher shows the last screen, and there is no optional Face ID lock.

**Fix.** Overlay a blurred cover on `scenePhase != .active`. Add an optional "Require Face ID" setting (add `NSFaceIDUsageDescription`).

### IOS-23 (P2, ux): empty ledger

**Problem.** Household (`27-se-household-overview.png`) asserts "AED 0", "No 3-month history yet" and "Same as this time last month". These are claims the data doesn't support (§4.3 spirit).

**Fix.** When there are no transactions and no cards, replace the hero with a three-step checklist: set up SMS capture, add a statement, invite a member.

### IOS-24 (P3, concurrency): refresh-token race

**Problem.**
- The app and the share extension are separate processes, each with its own `AuthClient` over the shared keychain item.
- Refresh tokens rotate, and `refresh_token_reuse_interval = 10`. Two refreshes more than 10 s apart, from a stale in-memory copy, can trip reuse detection and revoke the session for every process.
- The intent runs in the app process, so it is not exposed.

**Fix.** In the extension, set `autoRefreshToken: false` and always re-read storage before a request. Alternatively, serialise refreshes with an App Group file lock.

### IOS-25 (P3, concurrency): outbox reentrancy and compiler warnings

**Problem.**
- `Outbox` is an actor, but `flush` awaits the network, so a second `flush` (the intent and `becameActive`) can read the same due entries. Delivery stays at-least-once and the server dedupes. However, `SMSIntake` may then report `duplicate_delivery`, shown as "Already logged", for a message's first arrival.
- Two compiler warnings: unnecessary `nonisolated(unsafe)` (`LedgerDates.swift:28-32`) and the deprecated `Breadcrumb.data` setter (`Telemetry.swift:75`).

**Fix.** Keep an in-actor `flushTask` and have concurrent callers await it. Fix the two warnings.

### IOS-26 (P3, perf): repeated work on large lists

**Problem.**
- `ActivityModel.sections` regroups and sorts all rows on every SwiftUI body evaluation. After a few "Load more" pages (up to thousands of rows) this runs on each keystroke or redraw.
- `LedgerDates.parseTimestamp` and `isoTimestamp` allocate an `ISO8601DateFormatter` per call, about 2 per transaction row.

**Fix.** Cache the sections when `state` changes, and use static formatters.

### IOS-27 (P3, ui): typography and chrome

**Problem.**
- Large nav titles ("Overview", "Activity") render SF Pro Bold, while every section head is New York serif. The "earthy" voice is lost exactly where it is most visible.
- Overview stacks "Overview" plus "OCTOBER 2026".
- Statements shows "Statements" twice.
- `MoneyFormat.aed` and the hero's "AED" are hard-coded although profiles carry `base_currency`.

**Fix.**
- Apply serif large titles via `UINavigationBarAppearance`.
- Make the month the Overview title, or hide the nav title on Overview.
- Rename the section to "Cycles".
- Format with the profile's base currency.

### IOS-28 (P3, ux): Insights charts

**Problem.**
- The current (partial) month bar looks like a collapse (`12-insights-light.png`).
- There is no average line, no tap-to-read value, and no budget rule.
- Category and merchant rows are not tappable.
- "Uncategorized: 28 transactions" has no CTA.

**Fix.**
- Style the in-progress month as hatched or lighter, with a projected cap.
- Add a `RuleMark` for the 3-month average and `chartXSelection`.
- Make rows navigate to Activity filtered by category or merchant.

### IOS-29 (P3, readability): presentation logic in views

The rule "views are layout only" is broken in small ways:
- `OverviewView.swift:157` `prefix(4)`
- `InsightsView.swift:73` `prefix(10)`
- `InsightsView.swift:124,132`
- `ActivityView.swift:100`
- `StatementsView.swift:62,101`

None of these are business rules, but they are untested wording or limits. Move them to LedgerKit presentation extensions, as was done for `badge` and `dueText`.

### IOS-30 (P3, security): Sentry and ATS details

**Problem.**
- `enableCaptureFailedRequests` (on by default) reports failed URLs. Activity's `or=(description.ilike.*term*…)` carries the user's search text.
- The scrubber only clears query strings that look like SMS.
- `NSAllowsLocalNetworking` is set for both targets in every configuration.

**Fix.** Strip the PostgREST query string from `request.url` in `beforeSend`, and set the ATS key only in Debug.

### IOS-31 (P3, bug): minor filter edges

- A merchant named "OTP BANK …" is dropped as an OTP.
- *"Payment of AED 500.00 received for your Credit Card ending 7205 via transfer from account XXX1234"* is sent, because credit-card wording wins. The server then classifies it.

Both are acceptable. Document them in the tests.

---

## UX/UI verdict and recommendations

The visual language reads as **earthy, minimal and modern**:
- linen background, hairline cards, terracotta accent;
- New York serif heroes and section heads;
- good dark mode (`21-overview-dark-top.png`, `29-promax-dark-overview.png`);
- the iPhone SE layout holds up (`28-se-demo-overview.png`).

The analytics are mostly right, but the hierarchy over-promises: an alarming red "Overdue", a "91% below" chip, and a hero that ignores AED 3k of pending spend. Large text breaks the layout.

### Top 5 UX recommendations (in order)

1. **Make Overview truthful at a glance.**
   - Show a pace-fair comparison and a hero that includes pending, using server ratios.
   - Use "Was due" or "Paid" instead of "Overdue".
   - Add a "Needs attention" strip (unknown cards, uncategorised, stuck SMS) that links to a minimal Review list. (IOS-03, 04, 07, 12)
2. **One-keyword SMS setup with visible results.**
   - Use a single automation on "Card" and an explicit "SMS go to" ledger.
   - Notify only on actionable failures, and show a "Last run" status in Settings.
   - Replace the friend-text test with an in-app check. (IOS-02, 06)
3. **Dynamic Type and VoiceOver pass.**
   - Stacked layouts at accessibility sizes and a relative hero size.
   - Labels on icon buttons, combined rows, chart descriptors, and `muted` instead of `subtle` for text. (IOS-05, 19, 20)
4. **Faster categorising.**
   - Large searchable sheet, merchant-wide by default, swipe actions on rows.
   - An "Uncategorised (28)" entry point from Overview and Insights.
   - Category and merchant drill-downs into Activity. (IOS-18, 28)
5. **Statements as a status feed.**
   - Toolbar `+`, live per-file parse result with errors and next steps.
   - Cycle detail with reconciliation chips explained. (IOS-17)

### iOS-native opportunities (prioritised)

1. **Local notifications.** Two uses, neither needing push infrastructure:
   - (a) the intent's actionable outcomes (unknown card, outbox stuck > 1 h, signed out);
   - (b) statement due reminders at T-3 and T-0, scheduled from `statement_cycles` on each refresh.
2. **WidgetKit** for the Home and Lock Screen:
   - "October · AED 860 · on pace", the next due date, and utilisation per card.
   - The app writes a small snapshot JSON to the App Group after each Overview load, so the widget needs no network or session.
   - Accessory widgets suit the Lock Screen.
3. **App Intents beyond SMS.**
   - "How much have I spent this month?" and "What's due?" returning values (Siri and Spotlight snippets).
   - A `CategoryEntity` with a "Categorise last transaction" action.
   - Both reuse the existing `AppShortcutsProvider`.
4. **Controls** (iOS 18 Control Center or Action button): "Open Uncategorised" and "Add statement".
5. **Live Activities:** low value here. At most, a short-lived "Parsing 3 statements…" after a share. Not worth it before the items above.

## Appendix: SMS filter run (on-device `SMSCapture.classify`, 2026-10-08)

**Real template examples: 30/30 correct.**
- *Accepted:*
  - ADCB "Cr.Card" and "Credit Card" (AED, EGP, INR)
  - FAB "Credit Card Purchase" multi-line (AED, USD)
  - ENBD "Purchase … with Credit Card", "Payment of AED 42.00 to Noon with Credit Card ending", "Payment … to noon one", and the refund "credited to your card ending"
  - SIB "Covered Card" approved (AED and INR) and declined
- *Dropped:*
  - ADCB "Debit card XXX4467 linked to acc.", "Cr. transaction … on your account number", the dormancy notice, TouchPoints redemption
  - FAB "Debit Card Purchase", "Outward Remittance Debit / Account", "funds transfer", "Login detected"
  - ENBD "payment … needs confirmation", "new login"
- *Accepted, then marked `ignored` by the server (harmless):* ADCB approval prompt and billing alert, FAB statement issued, ENBD mini statement and due reminder, SIB activation notice.

**Synthetic cases:** 5 deviations (IOS-10, IOS-31).

## Fix status

Fixed on `ledger-v2` (uncommitted), 2026-10-08. `swift test`: 103 tests in 19 suites pass. `xcodegen generate` + `xcodebuild` (iPhone 17 Pro simulator, Debug) succeed; both bundles contain `PrivacyInfo.xcprivacy`. Re-screenshots against local Supabase (demo@ledger.local, Demo ledger) are in `…/scratchpad/audit-ios/after/` (Overview, Review, Activity, Statements and Settings in light, dark and AX5). No review was resolved and no SMS was sent during verification.

| ID | Status | Notes |
|---|---|---|
| Sentry local off | fixed | `Telemetry.shouldStart`: needs a DSN, a Release build and an environment other than local/development/dev/test. The app and the extension pass their own `DEBUG` flag. |
| IOS-01 | fixed | `LedgerAPIError.kind` sorts errors by SQLSTATE/PGRST code, then HTTP status. A permanent batch error is bisected until the bad message is alone, then only that one is parked. 42501 parks that ledger's batch once and is not bisected. Per-message `invalid`/`error`/`failed`/`rejected` statuses park only that message; `reason` is decoded when present, so the old all-or-nothing `ingest_sms` and the new per-message one are both handled. Transient errors get 8 attempts, then park. Signed-out does not use up attempts. Settings → "Not sent" offers Retry (re-targets the message to the current SMS ledger) and Delete. Flushes are chained, so they no longer overlap (also covers IOS-25). Shortcut lines say offline, signed out or server, and parked messages say "Not logged …". Tests: `OutboxFailureTests`, `SMSIntakeTests`. |
| IOS-02 | fixed | `SMSTarget` / `SMSTargetStore` in the App Group. Only owned ledgers can be chosen; the default is the first owned one. A stored choice the user no longer owns falls back. The intent, the share extension (which now shows "Uploading to …") and the pending-PDF flush all use it. Viewers don't get the Statements upload card. |
| IOS-03 | fixed | `DueStatus.describe` is used by both Overview (`AccountSummary.due`) and Statements (`StatementCycle.due(isLatest:)`). "Overdue" appears only for the latest statement when `paymentDetected == false`. Payment detection isn't available on iOS (nil), so a past date always reads "Was due …". |
| IOS-04 | fixed | Decodes `change_vs_prev_month_to_date`, `change_vs_avg_3m` and `accounts[].utilisation`; older servers without them decode as nil. The chip reads "52% below the same day last month". The 3-month average is shown as a figure only, and as a ratio only for completed months. All client ratio math is removed, and the hero eyebrow says "posted so far". Overview no longer calls `statement_cycles`. |
| IOS-05 | fixed | Hero uses `@ScaledMetric` and a `ViewThatFits` stack, so the unit never gets larger than the number. These layouts stack from xxxLarge via `AdaptiveRow` / `DynamicTypeSize.prefersStackedRows`: pending strip, ring and legend, card, statement and upload rows, Activity rows, Latest rows. `moneyLine()` keeps amounts on one line. Chips wrap only between words and are capped at accessibility2. Screenshots 11–17. Long category names can still hyphenate at AX5, but they are no longer truncated. |
| IOS-06 | fixed | `SMSAutomationGuide.keywords == ["Card"]`. "card" is in every purchase, refund and decline example in `20261008001000_sms_templates.sql`; checked by script and by `SMSGuideTests`. The guide keeps Notify When Run ON. Settings and the guide add "Last captured" (`CaptureLog`, which stores the outcome only) and "Send test" (`SMSIntake.selfTest`: a synthetic non-transaction message, dropped on the phone, plus a forced outbox flush). Still to confirm on a device: Shortcuts' "contains" is case-insensitive, which the ENBD refund's lowercase "card" relies on. |
| IOS-07 | fixed | New Review screen (`ReviewModel` / `ReviewPresentation`, `Ledger/Review/ReviewView.swift`). It is reached from Overview → Needs attention, which also shows the uncategorised count. Actions: link to a candidate, keep as new, dismiss, or register an unknown card to a same-bank account. Reasons the phone can't resolve offer only Dismiss and a note pointing to the web. Viewers get a read-only list. Shortcut lines for `unknown_card` and `held` point to "Overview → Needs review". A deep link from the Shortcut result is deferred. |
| IOS-08 | fixed | `Ledger/PrivacyInfo.xcprivacy` and `ShareExtension/PrivacyInfo.xcprivacy` declare UserDefaults (1C8F.1 App Group, CA92.1 `.standard` fallback), no tracking, and crash data (linked, app functionality) only. No file-timestamp, boot-time or disk-space APIs are used; Sentry ships its own manifest. If the app is distributed beyond personal use, add Financial Info, Email Address and Performance Data (Sentry tracing). |
| IOS-09 | fixed | `SharedKeychainStorage` records the write failure, which supabase-swift otherwise swallows. `SessionStore.phase(signedInAs:persistence:)` turns an unsaved session into signed-out with "Couldn't save your sign-in …" and a Sentry capture. Debug builds keep the session in memory instead, flagged in Settings → Debug. The no-access-group retry is now Debug-only. PostgREST 42501 and PGRST codes get friendly `LoadState` text. |
| Release tooling | fixed | `publish-build.sh` reads `SENTRY_AUTH_TOKEN` / `SENTRY_ORG` / `SENTRY_PROJECT` from the environment, or else from `Config/Secrets.Release.xcconfig`. It exports the token to `sentry-cli`, logs only where the token came from, and never prints the value. The rest of IOS-21 (Release including local `Secrets.xcconfig`, plist assertions, Sentry releases) is deferred. |
| IOS-10…31 | deferred | P2/P3, out of scope for this pass. These were touched along the way: IOS-12 (honest queued reasons; outbox still not cleared on sign-out), IOS-16 (PDFs follow the SMS ledger; a rejected PDF still blocks the queue), IOS-20 (filter and dismiss labels, 44 pt dismiss, combined rows), IOS-25 (serialised flush; the two compiler warnings remain). |

Everything still open, including the UX and iOS-native recommendations and the device checks
(Shortcuts case sensitivity, TestFlight privacy manifest, Release keychain), is in
[BACKLOG.md](BACKLOG.md).

**Backlog batch 1 (2026-10-13):** IOS-10, IOS-19r and IOS-20r are fixed; outcomes in
[BACKLOG.md](BACKLOG.md#done-backlog-batch-1-2026-10-13).
