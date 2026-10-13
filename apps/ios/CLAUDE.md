# iOS: Bank Ledger for iPhone

Detail for work under `apps/ios/`. The canon is the root [`CLAUDE.md`](../../CLAUDE.md) §5, §6
and §11; layout and setup are in [README.md](README.md).

## Where code goes

- **LedgerKit decides, views draw.** Anything a person could describe as "the app does X" (what
  a badge says, which screen shows, when an SMS is dropped, whether Sentry starts) is a pure
  function or `@Observable` model in `LedgerKit/` with a `swift test` case. `Ledger/` and
  `ShareExtension/` hold layout, App Intent plumbing and nothing else.
- One screen or concern per file, ≤ ~350 lines.
- `project.yml` is the source of truth for `Ledger.xcodeproj`: change it, run
  `xcodegen generate`, commit both.
- `Theme/Tokens.swift` is generated (`pnpm tokens`); `pnpm tokens:check` fails on hand edits.

## Money, dates, wire

- Money is `Decimal` decoded from the API's strings, never `Double`. Format through LedgerKit's
  `Money/` helpers only.
- Date formatters pin `en_US_POSIX` and `Asia/Dubai`. "A day" is a Dubai calendar date.
- Never derive a total, pace or budget on the device; render what the RPC returns (root §2.2).

## SMS capture

- The App Intent drops only OTPs and empty input on the device; everything else goes to the
  server, whose templates classify it (debit/account alerts → `ignored`, unknown → `unparsed` +
  LLM fallback). A guess on the phone loses the message for good when it is wrong (2026-10-09:
  ENBD alerts skipped as "not a credit-card transaction"), so the phone doesn't guess. The OTP
  pattern (`SMSCapture.otpPatternSource`) is the server's `private.sms_otp_pattern()`, which
  `ingest_sms` uses as its defence-in-depth check, character for character. The fixture in
  `supabase/tests/38_sms_otp_filter.test.sql` pins both (pgTAP and `SMSOTPParityTests` read it)
  and lists every SMS template example as must-send: change all three together, in syntax both
  ICU and Postgres read the same way (no `\b`, `\d`, `\s` or `.`).
- Never log, print, breadcrumb or persist an SMS body outside the App Group outbox. Sentry
  scrubbing is tested in `TelemetryScrubberTests`.

## Secrets and config

- `Config/Secrets.xcconfig` (Debug, local stack) and `Config/Secrets.Release.xcconfig`
  (TestFlight) are gitignored; `Secrets.example.xcconfig` is the template. Never print or commit
  either; check shape only (`cut -d= -f1`, `grep -c '^KEY'`).
- **Release never falls back to a local value.** `Debug.xcconfig` holds the local defaults and
  includes `Secrets.xcconfig`; `Release.xcconfig` includes only `Secrets.Release.xcconfig`.
  Don't put backend values in `Base.xcconfig` or include `Secrets.xcconfig` from Release. A
  missing or local value fails the "Check release config" Run Script phase
  (`scripts/release-config-check.sh settings`), and the archive and the staged IPA are checked
  with `plutil` (app + share extension). Keep the phase's `showEnvVars: false`: otherwise the
  build log prints every build setting.
- The app holds only the publishable key (`LEDGER_SUPABASE_PUBLISHABLE_KEY`, `sb_publishable_…`);
  `LedgerConfig` refuses an `sb_secret_…` key, and so does the release check.
- `SENTRY_AUTH_TOKEN` lives in the shell or the login keychain item `ledger-sentry-auth-token`
  (`security add-generic-password -U -s ledger-sentry-auth-token -a "$USER" -w`, prompts), never
  an xcconfig, where it becomes an Xcode build setting visible in build logs (audit X-28,
  BACKLOG IOS-21r); `testflight.sh` refuses a `Secrets.Release.xcconfig` that defines it.
- Sentry never blocks a release: `scripts/sentry-release.sh` (dSYMs, then
  `ledger-ios@<version>+<build>` new / set-commits / finalize) warns on any failure. Test the
  release scripts with `scripts/release_checks_test.sh` (fixtures and fakes; never run
  `publish-build.sh` or a real `sentry-cli` to test them).

## App Store and TestFlight

- **No "iPhone", "iPad" or "Siri" in App Intent titles, descriptions, parameter text or App
  Shortcut phrases.** Build 2 was rejected in processing for that (ITMS-90626). Say "this
  device" or "your phone".
- **Beta App Review signs in with a username and password** (Guideline 2.1(a); builds 3 and 6
  were rejected without one). Keep *Sign in with a password* on the sign-in screen and the demo
  account in Beta App Review Information (PRODUCTION §7 step 5); `testflight-distribute.mjs`
  refuses to submit without it.
- Both the app and the share extension ship a `PrivacyInfo.xcprivacy`; keep them when adding
  required-reason APIs (ITMS-91053).
- **Releasing is a production action.** A push to `main` that changes the app makes the pre-push
  hook run `scripts/publish-build.sh` (test, archive, sign, check the release config, dSYMs and
  release to Sentry, stage the IPA,
  commit `build-number.json`), and `ios-testflight.yml` then uploads it and submits it to the
  external "Friends & Family" group. Ask before pushing; `SKIP_RELEASE=1 git push` skips the
  build only when the user says so. `testflight.sh` and `testflight-distribute.mjs` likewise
  upload: ask first.

## Sentry

`Telemetry.shouldStart` reports only for a Release build with a DSN and an environment outside
`local`/`development`/`dev`/`test`/`debug`, so the simulator never reports. Production events go
to `credit-card-ledger-apps`, tagged `app=ios` and `target`.

## Verify

```bash
cd apps/ios/LedgerKit && swift test        # the decisions (CI runs only this)
cd apps/ios && xcodebuild -project Ledger.xcodeproj -scheme Ledger -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build/DerivedData build
```

GitHub runs no macOS job (no macOS minutes): the pre-push hook runs `swift test` and the app + extension compile on the Mac, and blocks the push when they fail. Still build them yourself
when you touch them, then run the change in the simulator and look at it (README "Run in the
simulator"). A screen can build and test green and still be wrong on the device.
