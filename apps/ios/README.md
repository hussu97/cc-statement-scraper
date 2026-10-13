# Bank Ledger for iPhone

SwiftUI app (iOS 18+) for Ledger v2: Overview (with Needs attention → Review), Activity,
Insights, Budgets and Settings (with Cards & statements → Statements)
on top of the Supabase backend. Overview, Insights and Budgets share a month switcher (back to the first
transaction's month, never past the current one); every long list scrolls page after page (100 rows
per request, `Paginator`), plus the **Log Bank SMS** and **Log Card Payment** App Intents and the
**Add to Bank Ledger** share extension, and Home and Lock Screen **widgets**.

- **Budgets** (tab): the month's `budget_status` per budget (spent of limit, % used, pace, Over),
  budgets not active that month, and create / edit / delete for owners (same table writes and
  validation as the web). Insights' budgets card links here with "See all budgets".
- **Statements** (Settings → Cards & statements → Statements): the toolbar `+` uploads PDFs one request each into a live per-file log
  (`document_events` over Realtime, plus a fetch and a slow poll): received → saved → waiting →
  reading → imported, or the failure with what to do (a wrong PDF password points at the web's
  Settings → Statement passwords). PDFs shared from another app that are still waiting show as
  "N PDFs waiting to upload" (Send now); one the server refused for good is set aside with its
  reason instead of blocking the rest. Tapping a cycle opens its **detail** (header, printed totals,
  reconciliation checks in sentences, debit and credit lines; a matched line opens the transaction
  sheet); tapping an upload opens its processing log.
- **Insights → Monthly spend** splits by None / Category / Bank / Merchant (`spend_breakdown`, top
  10 + Others): stacked bars, legend, tap a month for its callout (AED and share of the month), and
  each group's total and share for the range. Charts carry VoiceOver chart descriptors.
- **More App Intents** (Shortcuts, Spotlight, voice): *Month Spend* ("How much have I spent this
  month in Bank Ledger"), *What's Due* and *Categorise Last Transaction* (a `CategoryEntity`
  picker; files the newest purchase of the ledger on screen, that transaction only). They answer
  for the ledger the app shows, from `rpc('overview')`, or offline from the widget snapshot ("Offline,
  as of 14:05: …"). Each needs the device unlocked (`.requiresAuthentication`): they read money
  aloud. Words and choices are `LedgerQuestions` (LedgerKit). App Shortcuts need a team-signed
  build: an ad-hoc simulator build lists them but linkd refuses to run them.
- **Controls** (Control Center, Lock Screen, Action button; in the widget extension): *Open
  Uncategorised* (Activity filtered to this month's uncategorised rows) and *Add Statement*
  (Settings → Statements with the PDF picker open; a viewer gets Statements without it). Their
  intents (`Shared/OpenLinkIntents.swift`, in both targets) open the app and hand an `AppLink` to
  `AppLinkInbox`; `TabRouter` routes it, waiting for a ledger when the app is on sign-in or the
  picker. The same routes are deep links: `ledger://uncategorised`, `ledger://add-statement`.
- **Widgets** (`LedgerWidgets` extension): *Month spend* (spend so far and the server's pace
  against the same day last month), *Next due* (the soonest upcoming statement, its balance and
  minimum) and *Utilisation* (each card's latest statement against its limit), on the Home Screen
  (small, medium) and the Lock Screen (rectangular, inline, circular). They draw a snapshot the app
  writes to the App Group (`widget-snapshot.json`) whenever Overview loads the current month, and
  make no network calls; a new snapshot reloads their timelines, sign-out deletes it. With
  Settings → Require Face ID on, Lock Screen widgets show no amounts (`WidgetPrivacy`).
- **Bank logos** replace bank codes on every screen (`BankLogo`, accessibility label = the bank's
  name). Every seeded bank is bundled (`Assets.xcassets/Bank/<CODE>`, from `assets/banks/`);
  any other bank loads `banks.logo_path` from the public `bank-logos` bucket, else a monogram. The
  navy/blue/purple marks (ENBD, SIB, EIB, FAB) sit on a light chip in dark mode.

## Layout

```
apps/ios/
├── project.yml              XcodeGen spec (source of truth for Ledger.xcodeproj)
├── Ledger.xcodeproj         generated, committed so a clone opens without XcodeGen
├── Config/                  Base/Debug/Release.xcconfig, Secrets.example.xcconfig
├── LedgerKit/               Swift package: every decision the app makes (swift test)
│   ├── Sources/LedgerKit/
│   │   ├── API/             LedgerAPI protocol, SupabaseLedgerAPI (+Review, +Statements), LedgerJSON
│   │   ├── Banks/           BankDirectory / BankCatalog (names, bundled vs bucket logos, dark chip)
│   │   ├── Auth/            SessionStore (email OTP), SharedKeychainStorage
│   │   ├── Config/          LedgerConfig (Info.plist), LedgerServices (composition root)
│   │   ├── Dates/           CalendarDay, en_US_POSIX + Asia/Dubai formatting
│   │   ├── Models/          LedgerTransaction, Overview, analytics rows, records
│   │   ├── Money/           exact Decimal decoding + formatting (never Double)
│   │   ├── Outbox/          App Group SMS queue: backoff, failure classes, parked messages
│   │   ├── SMS/             SMSCapture (OTP + credit-card filter), SMSIntake (the intent's path),
│   │   │                    SMSTarget ("SMS go to" ledger), CaptureLog ("Last captured")
│   │   ├── Screens/         @Observable screen models (LedgerScreens), routing, Paginator,
│   │   │                    MonthSelection, LiveUpdates (Realtime + backoff), presentation helpers
│   │   ├── Telemetry/       Sentry start + PII scrubber
│   │   ├── Theme/           Tokens.swift (GENERATED by packages/tokens), Typography
│   │   ├── Upload/          statements-upload client, UploadSession (live per-file log),
│   │   │                    DocumentLogModel, share-extension offline queue (+ quarantine)
│   │   └── Widgets/         WidgetSnapshot (+ App Group store), what each widget says, privacy
│   └── Tests/LedgerKitTests/
├── Ledger/                  app target — layout only (+ App Intents in Intents/, PrivacyInfo.xcprivacy)
├── ShareExtension/          "Add to Bank Ledger" (PDFs → statements-upload, + PrivacyInfo.xcprivacy)
├── Widgets/                 Home and Lock Screen widgets and Controls — layout only (+ PrivacyInfo.xcprivacy)
├── Shared/                  the Controls' intents, compiled into the app and the widgets
└── scripts/                testflight.sh (archive → export → dSYMs → upload), publish-build.sh
                             (stage for CI), testflight-distribute.mjs (external testers)
```

Views hold layout only; any rule (what a badge says, which screen to show, when a
message is dropped) lives in LedgerKit and is unit-tested.

## Targets and identifiers

| Target | Bundle id | Notes |
|---|---|---|
| Ledger (app) | `$(LEDGER_BUNDLE_PREFIX)` = `com.hussu97.ledger` | hosts the App Intent |
| LedgerShare (share extension) | `com.hussu97.ledger.share` | PDFs only |
| LedgerWidgets (WidgetKit extension) | `com.hussu97.ledger.widgets` | App Group only, no keychain, no network |

All three share the App Group `group.com.hussu97.ledger` (SMS outbox, viewed ledger, "SMS go to"
ledger, last capture, pending uploads, the widget snapshot); the app and the share extension also
share the keychain group `<TeamID>.com.hussu97.ledger.shared` (Supabase
session). The widgets' App ID needs the App Group capability with the same group. Change the prefix in `Config/Base.xcconfig`; register the App Group in the
developer portal (automatic signing does it on first archive).

## Setup

```bash
brew install xcodegen
supabase start                                 # from the repo root
cp apps/ios/Config/Secrets.example.xcconfig apps/ios/Config/Secrets.xcconfig
supabase status -o json | jq -r .PUBLISHABLE_KEY # paste into LEDGER_SUPABASE_PUBLISHABLE_KEY
cd apps/ios && xcodegen generate && open Ledger.xcodeproj
```

### Secrets (`Config/Secrets.xcconfig`, gitignored)

| Key | Local | Production (`Config/Secrets.Release.xcconfig`) |
|---|---|---|
| `LEDGER_SUPABASE_URL` | `http:/$()/127.0.0.1:54321` | `https:/$()/<ref>.supabase.co` |
| `LEDGER_SUPABASE_PUBLISHABLE_KEY` | `supabase status` → `PUBLISHABLE_KEY` | dashboard → API Keys → publishable (`sb_publishable_…`; the app refuses `sb_secret_…`) |
| `LEDGER_SENTRY_DSN` | empty (Sentry off) | Sentry project `credit-card-ledger-apps` DSN (shared with web; events tagged `app=ios`) |
| `LEDGER_ENVIRONMENT` | `local` | `production` (set by Release.xcconfig) |

Sentry starts only in a Release build with a DSN and an environment other than
`local`/`development`/`dev`/`test` (`Telemetry.shouldStart`), so simulator and local runs never report.

`//` starts an xcconfig comment, hence `$()` between the slashes. The simulator reaches
the Mac's `127.0.0.1`; `NSAllowsLocalNetworking` permits plain HTTP to it. Only Debug builds
carry that key (`project.yml` → "Debug ATS" script); Release is HTTPS only.

## Tests

```bash
cd apps/ios/LedgerKit && swift test        # macOS, no simulator
```

Covers money decoding (JSON numbers and decimal strings, `0.1 + 0.2`, `1234567.89`),
formatting, Dubai dates, the SMS filter (OTP and debit/account cases), the outbox
(persistence, backoff, batching, two processes, permanent-vs-transient failures, bisecting a
bad message, parking, retry/delete), the App Intent path and its dialogs with a stub API,
"SMS go to" resolution, due-date and comparison wording, Review options, the Sentry gate and
scrubber, the upload client (stub `URLProtocol`), routing and wire fixtures, including
`statement_detail`, `spend_breakdown`, `document_events` and `banks` in the backend's exact shapes
(statement detail wording and recon sentences, split colours / callout / chart descriptor data,
the per-file upload log and its advice, the pending-upload quarantine, logo sources).

## Run in the simulator

```bash
cd apps/ios
xcodebuild -project Ledger.xcodeproj -scheme Ledger -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build/DerivedData build
xcrun simctl install booted build/DerivedData/Build/Products/Debug-iphonesimulator/Ledger.app
# Debug builds sign in with a password when these are set (seeded demo user):
SIMCTL_CHILD_LEDGER_DEV_EMAIL=demo@ledger.local SIMCTL_CHILD_LEDGER_DEV_PASSWORD=ledger-demo-pass \
  xcrun simctl launch booted com.hussu97.ledger
```

Sign-in is otherwise an email one-time code (local codes land in Inbucket,
`http://127.0.0.1:54324`) or a passkey. *Sign in with a password* on the sign-in screen is for
the App Review demo account (PRODUCTION §7 step 5); locally the seed users and an account made
with `scripts/cutover/create-review-demo.sh --env-file <local env>` work there too. Sign in with Apple is stubbed behind
`SessionStore.appleSignInEnabled`.

## SMS capture

iOS gives apps no access to messages. The supported route is ONE Shortcuts **personal
automation**: *Message → Message contains "Card" → Run Immediately (Notify When Run on) →
Log Bank SMS (Message = Shortcut Input's Content, Sender = Shortcut Input's Sender)*. Every
credit-card alert of ADCB, FAB, Emirates NBD, SIB, Emirates Islamic and Wio in the template seed
contains "card" (Wio's in lower case: it needs Shortcuts' "contains" to ignore case);
more keywords would fire the action two or three times per alert. Settings → *Set up SMS
capture* walks through it, shows **Last captured**, **Recent captures** (the last 20 runs:
outcome, sender and message length, never the text, so a Shortcut passing the wrong field shows)
and has **Send test** (the intent's path with a synthetic one-time passcode, dropped on the phone,
plus an outbox flush).

Messages go to the **SMS go to** ledger (Settings): owned ledgers only, defaulting to the
first one you own — never simply the ledger on screen. PDFs shared to "Add to Bank Ledger" go there too.

`LogBankSMSIntent` (`openAppWhenRun = false`) runs `SMSIntake`:
1. `SMSCapture.classify` drops OTPs and empty input — on the phone. Everything else is sent; the
   server's templates classify it (debit-card and account alerts are stored `ignored`).
2. The message is written to the App Group outbox with a fresh `client_msg_id`.
3. The outbox flushes through `rpc('ingest_sms')` with the session from the shared keychain.
   No connection (no data, airplane mode, timeouts) is not an attempt: the message waits until
   a connection is back (parked only after 7 days). Other transient failures (5xx, a busy
   database) back off (30 s doubling, capped at 1 h) for at most 8 attempts; permanent ones (42501 not an owner, 22023 invalid, 4xx) and per-message
   `invalid` statuses park only the affected messages (a failing batch is split until the bad
   one is alone). Parked messages wait under Settings → **Not sent** (Retry / Delete).
   `client_msg_id` makes retries idempotent server-side.
4. Saved but unsent, it is sent later without opening the app: the moment the connection
   returns while the process runs (`NWPathMonitor`), or by a background task iOS starts once
   there is a network (`OutboxSync`; Info.plist `BGTaskSchedulerPermittedIdentifiers`,
   `UIBackgroundModes` fetch + processing). `received_at` stays the time the Shortcut ran.
5. Shortcuts shows a one-line result naming the ledger and, for unknown cards or held
   matches, "Needs a look in Review" (Overview → Needs attention). The body is never logged,
   echoed or sent to Sentry. The intent never opens the app: it runs in the background for every
   alert. To jump to the screen, open `ledger://review` (deep link, handled by `AppLink`): in
   Shortcuts, add **Open URL** with `ledger://review` (e.g. after an **If** on the intent's
   result being `delivered_unknown_card` or `delivered_held`), or tap it from Notes or Safari.

## Card payment capture

Tap-to-pay payments reach Bank Ledger through a second Shortcuts personal automation that runs
**Log Card Payment** (`LogCardPaymentIntent`, `openAppWhenRun = false`). Set it up once per card:

1. Shortcuts → Automation → + → **Transaction**. Choose the card(s) (e.g. the Wio card), "When I
   tap", and **Run Immediately**. Tap Next.
2. Create New Shortcut → add **Log Card Payment** (search Ledger). Set **Amount** to Shortcut
   Input's Amount, **Merchant** to Shortcut Input's Merchant and **Card** to Shortcut Input's Card
   or Pass.
3. In Bank Ledger, Settings → **Card names for payment shortcut** → Card names: type each card's
   name exactly as the phone's card shows it (capitals don't matter). If a payment arrives first,
   Shortcuts shows "no card is named “…”" with the name it passed; setting that name files the
   waiting payment on the card.

Enabling it for a card that also sends SMS alerts is safe: the server links the alert and the
payment (same account, amount and currency, within 30 minutes) as two pieces of evidence for one
transaction, not two transactions.

`WalletIntake` mirrors `SMSIntake`: `WalletCapture.payment` checks on the phone what the server
would refuse (amount above zero, rounded half-up to cents; a 3-letter currency, uppercased;
merchant ≤ 200 and card name ≤ 64 characters, trimmed). The amount is a `Decimal` from the
intent's currency amount and goes to `rpc('ingest_wallet_transactions')` as a decimal string.
Payments go to the **SMS go to** ledger and share the SMS outbox (each entry has a `kind`; one
flush sends each profile's SMS and payments to their own RPC), so a payment made offline at the
till is sent when a connection is back, and a refused one waits under Settings → **Not sent**.
The merchant is never logged or sent to Sentry. Card names (`cards.wallet_name`) are owner-edited;
a view-only ledger shows them read-only.

## TestFlight

Same flow as mm-pos (`mm-pos/ci/README.md`): build and sign on the Mac, upload over the
App Store Connect API key (no Apple ID password), release to two groups. The App Store
Connect / TestFlight name and the home-screen name are both **Bank Ledger** (share extension:
**Add to Bank Ledger**).

| Group | Kind | How a build reaches it |
|---|---|---|
| **Bank Ledger Internal** | internal, automatic distribution | as soon as processing finishes |
| **Friends & Family** | external, public link | `testflight-distribute.mjs` attaches it and submits it for Beta App Review |

```bash
apps/ios/scripts/testflight.sh                 # test, archive, export, dSYMs → Sentry, upload
apps/ios/scripts/testflight.sh --no-upload     # … without the upload
apps/ios/scripts/testflight.sh --keep-build    # reuse the build number after a failed upload
node apps/ios/scripts/testflight-distribute.mjs [--build N] [--what-to-test "…"] [--no-submit]
apps/ios/scripts/publish-build.sh [--keep-build]  # testflight.sh --no-upload, stage on the
                                               # `ios-ledger-staged` release, commit build-number.json
```

* **Signing**: team `2F94NY8R3T`, automatic, `-allowProvisioningUpdates` (needs an Apple
  Distribution identity in the keychain). Bundle ids `com.hussu97.ledger` and
  `com.hussu97.ledger.share` are registered with App Groups enabled; Xcode assigns
  `group.com.hussu97.ledger` to both on the first archive.
* **API key**: `ASC_KEY_ID` / `ASC_ISSUER_ID` and `~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8`
  (CI: `ASC_KEY_P8`). Both scripts default to the single key in that directory and the
  team's issuer, i.e. the key mm-pos uses.
* **Sentry** (`scripts/sentry-release.sh`): dSYMs, then release `ledger-ios@<version>+<build>`
  (`releases new` / `set-commits --auto` / `finalize`); needs `sentry-cli`. `SENTRY_AUTH_TOKEN`
  from the environment or the login keychain item `ledger-sentry-auth-token`
  (`security add-generic-password -U -s ledger-sentry-auth-token -a "$USER" -w`, prompts),
  never an xcconfig. `SENTRY_ORG` / `SENTRY_PROJECT` (default: the DSN's project,
  `credit-card-ledger-apps`) from the environment or `Config/Secrets.Release.xcconfig`. The token
  is never printed; Sentry failing only warns.
* **Release config**: Release reads only `Config/Secrets.Release.xcconfig` (the local
  `Secrets.xcconfig` is Debug-only), so a missing key fails the "Check release config" build
  phase instead of shipping a local value. `testflight.sh` refuses to run without the file, if
  it points at 127.0.0.1 or still defines `SENTRY_AUTH_TOKEN`, and after archiving
  `scripts/release-config-check.sh` asserts on the app and share-extension Info.plists
  (`publish-build.sh` again on the IPA). Tests: `scripts/release_checks_test.sh`.
* **Build number**: `build-number.json`, bumped on every build. `publish-build.sh` commits it
  (`--only`, authored as Hussain Abbasi) once the IPA is staged; run `testflight.sh` directly
  and commit it yourself. `ITSAppUsesNonExemptEncryption = NO`, so uploads never stop on
  export compliance.
* **"What to Test"**: `--what-to-test`, else `$LEDGER_WHAT_TO_TEST`, else the last commit
  subject touching `apps/ios`.
* **CI contract** (`publish-build.sh` → workflow): release `ios-ledger-staged` holds
  `Ledger.ipa` + `build-meta.json` (`{build, commit, apps:[{scheme, ipa, bundle_id}]}`). The
  workflow ships it only if `commit` equals the pushed sha or differs from it **only** by
  `apps/ios/build-number.json`, uploads with the API key, then runs
  `node apps/ios/scripts/testflight-distribute.mjs --build <build> --timeout 35` with
  `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`.
