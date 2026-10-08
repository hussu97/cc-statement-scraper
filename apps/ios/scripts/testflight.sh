#!/usr/bin/env bash
#
# Build and sign Ledger (app + "Add to Ledger" share extension) on this Mac,
# upload its dSYMs to Sentry, and optionally ship it to TestFlight.
#
# The same script as mm-pos/scripts/testflight.sh, for one app instead of two.
# Your Mac does this for free; a GitHub-hosted macOS runner bills at 10x. See
# scripts/publish-build.sh for the split this exists to serve.
#
# Usage (from anywhere):
#   apps/ios/scripts/testflight.sh               # test, archive, export, dSYMs, upload
#   apps/ios/scripts/testflight.sh --no-upload   # test, archive, export, dSYMs only
#   apps/ios/scripts/testflight.sh --keep-build  # reuse the current build number
#
# Needs:
#   * An "Apple Distribution" identity in the keychain (Xcode → Settings → Accounts).
#   * Config/Secrets.Release.xcconfig with the production Supabase URL/anon key and
#     Sentry DSN (a Release build never falls back to the local 127.0.0.1 config).
#   * dSYMs: SENTRY_AUTH_TOKEN, SENTRY_ORG, SENTRY_PROJECT (default ledger-apps), from
#     the environment or, when unset there, Config/Secrets.Release.xcconfig; and
#     sentry-cli (brew install getsentry/tools/sentry-cli). The token reaches
#     sentry-cli through the environment and is never printed.
#   * Upload — an App Store Connect API key, no password, no 2FA prompt:
#       ASC_KEY_ID, ASC_ISSUER_ID and ~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8
#     ASC_KEY_ID defaults to the one key in that directory, ASC_ISSUER_ID to the
#     team's issuer — the same key mm-pos uses.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
BUILD_DIR="$ROOT/build/testflight"
PROJECT="Ledger.xcodeproj"
SCHEME="Ledger"

UPLOAD=1
BUMP=1
for arg in "$@"; do
  case "$arg" in
    --no-upload)  UPLOAD=0 ;;
    --keep-build) BUMP=0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# ── team id + bundle ───────────────────────────────────────────────────────
# Both are pinned in Config/Base.xcconfig, so this only has to agree with it.
# The Team ID is the certificate's OU field, not the ten characters in its
# common name ("Apple Distribution: Name (XXXXXXXXXX)" names the certificate).
APPLE_TEAM_ID="${APPLE_TEAM_ID:-$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' Config/Base.xcconfig)}"
BUNDLE_PREFIX="$(sed -n 's/^LEDGER_BUNDLE_PREFIX *= *//p' Config/Base.xcconfig)"
echo "==> Team $APPLE_TEAM_ID, bundle $BUNDLE_PREFIX"

if ! security find-identity -p codesigning -v | grep -q "Apple Distribution"; then
  echo "error: no Apple Distribution identity in your keychain." >&2
  echo "       Xcode → Settings → Accounts → Manage Certificates → + Apple Distribution." >&2
  exit 1
fi

if [[ ! -f Config/Secrets.Release.xcconfig ]]; then
  echo "error: Config/Secrets.Release.xcconfig is missing — a Release build would point at" >&2
  echo "       the local Supabase. Copy Config/Secrets.example.xcconfig and fill in production values." >&2
  exit 1
fi
if grep -Eq '127\.0\.0\.1|localhost' Config/Secrets.Release.xcconfig; then
  echo "error: Config/Secrets.Release.xcconfig points at a local Supabase." >&2
  exit 1
fi

# ── App Store Connect key (checked before the slow part, not after it) ─────
# Used for the upload. Signing uses the Apple ID signed in to Xcode (Settings →
# Accounts), as mm-pos does; with none, archive fails with "No Accounts".
# ASC_SIGN_WITH_KEY=1 hands the API key to xcodebuild instead (needs an Admin
# key; with Xcode 27 and this key it failed with "Authentication failed").
KEY_DIR="$HOME/.appstoreconnect/private_keys"
if [[ -z "${ASC_KEY_ID:-}" ]]; then
  shopt -s nullglob; keys=("$KEY_DIR"/AuthKey_*.p8); shopt -u nullglob
  if [[ ${#keys[@]} -eq 1 ]]; then
    ASC_KEY_ID="$(basename "${keys[0]}" .p8)"; ASC_KEY_ID="${ASC_KEY_ID#AuthKey_}"
  fi
fi
ASC_ISSUER_ID="${ASC_ISSUER_ID:-c43e9dbf-d873-4aa3-b89d-b5ef25d6accd}"
KEY_FILE="$KEY_DIR/AuthKey_${ASC_KEY_ID:-none}.p8"
SIGN_AUTH=()
if [[ -n "${ASC_KEY_ID:-}" && -f "$KEY_FILE" ]]; then
  export ASC_KEY_ID ASC_ISSUER_ID
  [[ "${ASC_SIGN_WITH_KEY:-0}" == 1 ]] && SIGN_AUTH=(-authenticationKeyPath "$KEY_FILE" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
elif [[ $UPLOAD -eq 1 ]]; then
  cat >&2 <<MSG
error: no App Store Connect API key.
  export ASC_KEY_ID=XXXXXXXXXX ASC_ISSUER_ID=<issuer-uuid>
  and place the key at ~/.appstoreconnect/private_keys/AuthKey_\$ASC_KEY_ID.p8
  — or pass --no-upload.
MSG
  exit 1
fi

# ── build number ───────────────────────────────────────────────────────────
# App Store Connect rejects a build number it has already accepted, so every
# upload needs a fresh one. scripts/publish-build.sh commits the bump once the
# build is staged; run directly, commit apps/ios/build-number.json yourself.
if [[ $BUMP -eq 1 ]]; then
  BUILD=$(python3 - <<'PY'
import json
p = 'build-number.json'
d = json.load(open(p))
d['ios'] = int(d['ios']) + 1
with open(p, 'w') as f:
    json.dump(d, f, indent=2)
    f.write('\n')
print(d['ios'])
PY
)
else
  BUILD=$(python3 -c "import json; print(json.load(open('build-number.json'))['ios'])")
fi
echo "==> Build number $BUILD"

# ── project + kit ──────────────────────────────────────────────────────────
if command -v xcodegen >/dev/null; then
  echo "==> xcodegen generate"
  xcodegen generate --quiet
fi

# Cheap, needs no simulator, and catches what a tester would otherwise find.
echo "==> swift test (LedgerKit)"
(cd LedgerKit && swift test)

# ── archive + export ───────────────────────────────────────────────────────
write_export_options() {
  cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>$1</string>
  <key>teamID</key><string>$APPLE_TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>export</string>
  <key>uploadSymbols</key><true/>
</dict>
</plist>
PLIST
}

rm -rf "$BUILD_DIR/export"
mkdir -p "$BUILD_DIR"
ARCHIVE="$BUILD_DIR/$SCHEME.xcarchive"
rm -rf "$ARCHIVE"

echo
echo "==> Archiving Ledger"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates ${SIGN_AUTH[@]+"${SIGN_AUTH[@]}"} \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
  CURRENT_PROJECT_VERSION="$BUILD"

echo "==> Exporting Ledger"
# Xcode 15.4 renamed the App Store export method; fall back for older Xcode.
write_export_options "app-store-connect"
if ! xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
      -exportPath "$BUILD_DIR/export" -allowProvisioningUpdates ${SIGN_AUTH[@]+"${SIGN_AUTH[@]}"}; then
  echo "==> Retrying export with the legacy 'app-store' method"
  write_export_options "app-store"
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
    -exportPath "$BUILD_DIR/export" -allowProvisioningUpdates ${SIGN_AUTH[@]+"${SIGN_AUTH[@]}"}
fi

IPA=$(find "$BUILD_DIR/export" -name '*.ipa' | head -1)
[[ -n "$IPA" ]] || { echo "error: no .ipa produced" >&2; exit 1; }
echo "==> Built $IPA"

# ── dSYMs → Sentry ─────────────────────────────────────────────────────────
# Crash reports from the app, the intent and the share extension are only
# readable with these. Skipped (loudly) when not configured.
# `KEY = value` from the release xcconfig (last assignment wins); prints nothing else.
release_setting() {
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" Config/Secrets.Release.xcconfig | tail -1 | sed 's/[[:space:]]*$//'
}
SENTRY_TOKEN_SOURCE="environment"
if [[ -z "${SENTRY_AUTH_TOKEN:-}" ]]; then
  SENTRY_AUTH_TOKEN="$(release_setting SENTRY_AUTH_TOKEN)"
  SENTRY_TOKEN_SOURCE="Config/Secrets.Release.xcconfig"
fi
SENTRY_ORG="${SENTRY_ORG:-$(release_setting SENTRY_ORG)}"
SENTRY_PROJECT="${SENTRY_PROJECT:-$(release_setting SENTRY_PROJECT)}"
export SENTRY_AUTH_TOKEN
if [[ -n "${SENTRY_AUTH_TOKEN:-}" ]]; then
  echo "==> Sentry token from $SENTRY_TOKEN_SOURCE"
  command -v sentry-cli >/dev/null || {
    echo "error: SENTRY_AUTH_TOKEN set but sentry-cli not installed (brew install getsentry/tools/sentry-cli)" >&2; exit 1; }
  : "${SENTRY_ORG:?set SENTRY_ORG}"
  echo "==> Uploading dSYMs to Sentry ($SENTRY_ORG/${SENTRY_PROJECT:-ledger-apps})"
  sentry-cli debug-files upload --include-sources \
    --org "$SENTRY_ORG" --project "${SENTRY_PROJECT:-ledger-apps}" \
    "$ARCHIVE/dSYMs"
else
  echo "==> SENTRY_AUTH_TOKEN not set — dSYMs NOT uploaded; crashes from build $BUILD will be unsymbolicated."
fi

if [[ $UPLOAD -eq 0 ]]; then
  echo
  echo "==> Skipping upload (--no-upload). IPA is $IPA."
  exit 0
fi

# ── upload ─────────────────────────────────────────────────────────────────
# altool's exit status cannot be trusted: it prints "Failed to upload package",
# lists the errors, and exits 0. Judge it by what it actually said.
run_altool() {
  local action="$1" log status=0
  log="$BUILD_DIR/altool-$action.log"
  xcrun altool "--$action" --type ios --file "$IPA" \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" 2>&1 | tee "$log" || status=$?
  if [[ $status -ne 0 ]]; then
    echo "error: altool --$action exited $status" >&2
    return 1
  fi
  if grep -qE 'Failed to (upload|validate) package|VERIFY FAILED|ERROR: \[altool' "$log"; then
    echo "error: altool --$action reported failure (it exits 0 regardless)" >&2
    return 1
  fi
}

echo
echo "==> Validating Ledger"
run_altool validate-app
echo "==> Uploading Ledger"
run_altool upload-app

cat <<DONE

Uploaded Ledger build $BUILD.

Apple processes it in roughly 5-15 minutes, then it is offered to the
"Ledger Internal" group automatically.

External testers are not automatic. To release it to them as well:

  node apps/ios/scripts/testflight-distribute.mjs --build $BUILD
DONE
