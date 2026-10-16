#!/usr/bin/env bash
#
# Tests for release-config-check.sh, sentry-release.sh and asc-retry.mjs against fixture
# Info.plists and fake `sentry-cli` / `security` binaries: nothing here reaches
# Sentry, the keychain or a real build. macOS only (plutil).
#
#   apps/ios/scripts/release_checks_test.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CHECK="$HERE/release-config-check.sh"
SENTRY="$HERE/sentry-release.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

PASS=0
FAILS=0
ok() { PASS=$((PASS + 1)); }
bad() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }

# Distinctive fixture values: no output may ever contain them.
URL_OK="https://fixtureref0123.supabase.co"
KEY_OK="sb_publishable_FIXTUREKEY0123456789"
DSN_OK="https://fixturedsnpublic0123@o1.ingest.sentry.io/4242"
TOKEN="sntrys_FIXTURETOKEN0123456789"
SECRETS=("fixtureref0123" "FIXTUREKEY0123456789" "fixturedsnpublic0123" "FIXTURETOKEN0123456789")

no_values() { # FILE LABEL
  local s
  for s in "${SECRETS[@]}"; do
    if grep -q "$s" "$1"; then bad "$2: output contains a fixture value"; return; fi
  done
  ok
}

# plist PATH [KEY=VALUE ...]; a KEY with no `=` is left out.
plist() {
  local path="$1" kv; shift
  mkdir -p "$(dirname "$path")"
  plutil -create xml1 "$path"
  plutil -insert CFBundleShortVersionString -string 1.0.0 "$path"
  plutil -insert CFBundleVersion -string 42 "$path"
  for kv in "$@"; do
    [[ "$kv" == *=* ]] || continue
    plutil -insert "${kv%%=*}" -string "${kv#*=}" "$path"
  done
}
good_kv() {
  echo "LedgerSupabaseURL=$URL_OK"
  echo "LedgerSupabasePublishableKey=$KEY_OK"
  echo "LedgerSentryDSN=$DSN_OK"
  echo "LedgerEnvironment=production"
}
# archive NAME [override KEY=VALUE for the app] -- [override for the appex]
archive() {
  local name="$1"; shift
  local a="$T/$name.xcarchive" app_over=() ext_over=() side=app kv
  for kv in "$@"; do
    if [[ "$kv" == -- ]]; then side=ext; continue; fi
    if [[ $side == app ]]; then app_over+=("$kv"); else ext_over+=("$kv"); fi
  done
  local app="$a/Products/Applications/Ledger.app"
  # shellcheck disable=SC2046
  plist "$app/Info.plist" $(merge "${app_over[@]+"${app_over[@]}"}")
  # shellcheck disable=SC2046
  plist "$app/PlugIns/LedgerShare.appex/Info.plist" $(merge "${ext_over[@]+"${ext_over[@]}"}")
  mkdir -p "$a/dSYMs"
  echo "$a"
}
# The good values with overrides applied (KEY= removes, KEY=v replaces). No spaces in values.
merge() {
  local line key over found
  while read -r line; do
    key="${line%%=*}"; found=""
    for over in "$@"; do
      if [[ "${over%%=*}" == "$key" ]]; then found=1; [[ -n "${over#*=}" ]] && echo "$over"; fi
    done
    [[ -n "$found" ]] || echo "$line"
  done < <(good_kv)
}

expect() { # pass|fail LABEL GREP-IN-OUTPUT -- CMD...
  local want="$1" label="$2" pattern="$3"; shift 4
  local out="$T/out.$PASS.$FAILS" rc=0
  "$@" >"$out" 2>&1 || rc=$?
  if [[ $want == pass && $rc -ne 0 ]]; then bad "$label: exit $rc"; sed 's/^/    /' "$out" >&2; return; fi
  if [[ $want == fail && $rc -eq 0 ]]; then bad "$label: expected failure"; sed 's/^/    /' "$out" >&2; return; fi
  if [[ -n "$pattern" ]] && ! grep -q -- "$pattern" "$out"; then bad "$label: output lacks '$pattern'"; sed 's/^/    /' "$out" >&2; return; fi
  ok
  no_values "$out" "$label"
}

# ── release-config-check.sh archive ───────────────────────────────────────
A="$(archive good)"
expect pass "good archive" "Release config OK" -- "$CHECK" archive "$A"
expect pass "good .app" "Release config OK" -- "$CHECK" archive "$A/Products/Applications/Ledger.app"

A="$(archive appex-local -- LedgerSupabaseURL=http://127.0.0.1:54321)"
expect fail "appex on the local stack" "LedgerShare.appex: LedgerSupabaseURL is not https" -- "$CHECK" archive "$A"

# Every .appex is checked, not only the share extension: the widgets (N-2) too.
A="$(archive widgets-local)"
# shellcheck disable=SC2046
plist "$A/Products/Applications/Ledger.app/PlugIns/LedgerWidgets.appex/Info.plist" \
  $(merge LedgerSupabaseURL=http://127.0.0.1:54321)
expect fail "widgets appex on the local stack" "LedgerWidgets.appex: LedgerSupabaseURL is not https" -- "$CHECK" archive "$A"
A="$(archive widgets-good)"
# shellcheck disable=SC2046
plist "$A/Products/Applications/Ledger.app/PlugIns/LedgerWidgets.appex/Info.plist" $(merge)
expect pass "app, share extension and widgets" "Release config OK" -- "$CHECK" archive "$A"

A="$(archive env-local LedgerEnvironment=local)"
expect fail "app environment local" "Ledger.app: LedgerEnvironment is not" -- "$CHECK" archive "$A"

A="$(archive dsn-missing -- LedgerSentryDSN=)"
expect fail "appex DSN missing" "LedgerShare.appex: LedgerSentryDSN is empty" -- "$CHECK" archive "$A"

A="$(archive key-missing LedgerSupabasePublishableKey=)"
expect fail "app key missing" "Ledger.app: LedgerSupabasePublishableKey is empty" -- "$CHECK" archive "$A"

for host in localhost 127.0.0.1 10.0.0.4 192.168.1.20 172.20.0.1 mac.local "[::1]" dev.test; do
  A="$(archive "host-$host" "LedgerSupabaseURL=https://$host:54321")"
  expect fail "https but local host $host" "local or private host" -- "$CHECK" archive "$A"
done

A="$(archive secret-key LedgerSupabasePublishableKey=sb_secret_FIXTUREKEY0123456789)"
expect fail "secret key" "is a secret key" -- "$CHECK" archive "$A"

A="$(archive placeholder "LedgerSupabasePublishableKey=<sb_publishable_key>")"
expect fail "example placeholder" "placeholder" -- "$CHECK" archive "$A"

A="$(archive unresolved "LedgerSupabaseURL=https:/\$()/x.supabase.co")"
expect fail "unresolved \$()" "placeholder" -- "$CHECK" archive "$A"

A="$(archive no-appex)"
rm -rf "$A/Products/Applications/Ledger.app/PlugIns"
expect fail "no appex" "no embedded .appex" -- "$CHECK" archive "$A"

# The IPA publish-build.sh stages.
A="$(archive ipa-good)"
mkdir -p "$T/ipa-good/Payload" && cp -R "$A/Products/Applications/Ledger.app" "$T/ipa-good/Payload/"
(cd "$T/ipa-good" && zip -qr "$T/Ledger.ipa" Payload)
expect pass "good IPA" "Release config OK" -- "$CHECK" archive "$T/Ledger.ipa"
A="$(archive ipa-bad -- LedgerEnvironment=local)"
mkdir -p "$T/ipa-bad/Payload" && cp -R "$A/Products/Applications/Ledger.app" "$T/ipa-bad/Payload/"
(cd "$T/ipa-bad" && zip -qr "$T/Bad.ipa" Payload)
expect fail "IPA appex environment local" "LedgerShare.appex: LedgerEnvironment" -- "$CHECK" archive "$T/Bad.ipa"

# ── release-config-check.sh settings (the Xcode Run Script phase) ─────────
settings() { env -i PATH="$PATH" CONFIGURATION=Release TARGET_NAME=Ledger "$@" "$CHECK" settings; }
expect pass "settings good" "Release config OK" -- settings \
  LEDGER_SUPABASE_URL="$URL_OK" LEDGER_SUPABASE_PUBLISHABLE_KEY="$KEY_OK" \
  LEDGER_SENTRY_DSN="$DSN_OK" LEDGER_ENVIRONMENT=production
expect fail "settings: URL dropped from Secrets.Release" "LedgerSupabaseURL is empty" -- settings \
  LEDGER_SUPABASE_URL="" LEDGER_SUPABASE_PUBLISHABLE_KEY="$KEY_OK" \
  LEDGER_SENTRY_DSN="$DSN_OK" LEDGER_ENVIRONMENT=production
expect fail "settings: no secrets file at all" "release config problem" -- settings LEDGER_ENVIRONMENT=production

# ── sentry-release.sh (fake sentry-cli and security) ─────────────────────
FAKE="$T/bin"; mkdir -p "$FAKE"
cat > "$FAKE/sentry-cli" <<'SH'
#!/usr/bin/env bash
# Records argv and whether a token arrived through the environment.
echo "argv: $* | token-in-env: $([[ -n "${SENTRY_AUTH_TOKEN:-}" ]] && echo yes || echo no)" >> "$FAKE_LOG"
[[ "${FAKE_SENTRY_FAIL:-0}" == 1 ]] && { echo "error: API request failed (fake: unreachable)" >&2; exit 1; }
exit 0
SH
cat > "$FAKE/security" <<'SH'
#!/usr/bin/env bash
echo "security $*" >> "$FAKE_LOG"
[[ -n "${FAKE_KEYCHAIN_TOKEN:-}" ]] || exit 44
printf '%s\n' "$FAKE_KEYCHAIN_TOKEN"
SH
chmod +x "$FAKE/sentry-cli" "$FAKE/security"
XC="$T/Secrets.Release.xcconfig"
printf 'SENTRY_ORG = fixture-org\n' > "$XC"
A="$(archive sentry)"
sentry_run() { # ENV... — runs with the fakes first on PATH and a fresh log
  : > "$T/fake.log"
  env -u SENTRY_AUTH_TOKEN -u SENTRY_ORG -u SENTRY_PROJECT PATH="$FAKE:$PATH" FAKE_LOG="$T/fake.log" \
    LEDGER_RELEASE_XCCONFIG="$XC" "$@" "$SENTRY" "$A"
}
log_has() { if grep -q -- "$1" "$T/fake.log"; then ok; else bad "$2: sentry-cli log lacks '$1'"; sed 's/^/    /' "$T/fake.log" >&2; fi; }

expect pass "sentry: token from env" "token from the environment" -- sentry_run SENTRY_AUTH_TOKEN="$TOKEN"
log_has "debug-files upload --include-sources --org fixture-org --project 4242" "dSYMs"
log_has "releases new --org fixture-org --project 4242 ledger-ios@1.0.0+42" "release new"
log_has "releases set-commits --org fixture-org ledger-ios@1.0.0+42 --auto --ignore-missing" "set-commits"
log_has "releases finalize --org fixture-org ledger-ios@1.0.0+42" "finalize"
log_has "token-in-env: yes" "token reaches sentry-cli via env"
no_values "$T/fake.log" "sentry argv"

expect pass "sentry: token from keychain" "token from the keychain item ledger-sentry-auth-token" -- \
  sentry_run FAKE_KEYCHAIN_TOKEN="$TOKEN"
log_has "security find-generic-password -s ledger-sentry-auth-token -w" "keychain lookup"
log_has "token-in-env: yes" "keychain token reaches sentry-cli via env"

expect pass "sentry unreachable never fails the release" "WARNING (Sentry): dSYM upload failed" -- \
  sentry_run SENTRY_AUTH_TOKEN="$TOKEN" FAKE_SENTRY_FAIL=1
expect pass "sentry unreachable: release warned" "could not create release ledger-ios@1.0.0+42" -- \
  sentry_run SENTRY_AUTH_TOKEN="$TOKEN" FAKE_SENTRY_FAIL=1

expect pass "no token anywhere: warn, skip" "no SENTRY_AUTH_TOKEN" -- sentry_run
if grep -q "^argv:" "$T/fake.log"; then bad "no token: sentry-cli was called"; else ok; fi

printf '// no org\n' > "$XC"
expect pass "no org: warn, skip" "SENTRY_ORG not set" -- sentry_run SENTRY_AUTH_TOKEN="$TOKEN"
expect pass "org + project from env" "credit-card-ledger-apps" -- \
  sentry_run SENTRY_AUTH_TOKEN="$TOKEN" SENTRY_ORG=env-org SENTRY_PROJECT=credit-card-ledger-apps
log_has "releases new --org env-org --project credit-card-ledger-apps ledger-ios@1.0.0+42" "env org/project"

# testflight-distribute.mjs's App Store Connect retries (no network).
if node --test "$HERE/asc-retry.test.mjs" > "$T/node-test.log" 2>&1; then ok; else cat "$T/node-test.log" >&2; bad "asc-retry.test.mjs"; fi

echo "release_checks_test: $PASS passed, $FAILS failed"
[[ $FAILS -eq 0 ]]
