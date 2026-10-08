#!/usr/bin/env bash
#
# Build and sign Ledger (app + "Add to Ledger" share extension) on this Mac,
# upload its dSYMs to Sentry, and optionally ship it to TestFlight or stage the
# IPA on GitHub for a workflow to upload. Modeled on another app/scripts/publish-build.sh.
#
# Why local: a GitHub-hosted macOS runner bills at a 10x multiplier and the
# archive is the expensive part. Signing also happens here, so the distribution
# certificate never has to live in GitHub.
#
# Usage (from anywhere):
#   apps/ios/scripts/publish-build.sh               # test, archive, export, dSYMs → Sentry
#   apps/ios/scripts/publish-build.sh --upload      # … and upload the IPA to TestFlight
#   apps/ios/scripts/publish-build.sh --stage       # … and stage the IPA on the `ios-staged` GitHub release
#   apps/ios/scripts/publish-build.sh --keep-build  # reuse the current build number
#
# Needs:
#   * An "Apple Distribution" identity in the keychain (Xcode → Settings → Accounts).
#   * Config/Secrets.Release.xcconfig with the production Supabase URL/anon key and
#     Sentry DSN (Release builds never fall back to the local 127.0.0.1 config).
#   * Optional dSYM upload: SENTRY_AUTH_TOKEN, SENTRY_ORG, SENTRY_PROJECT (default ledger-apps),
#     from the environment or, when unset there, from Config/Secrets.Release.xcconfig;
#     and `sentry-cli` on PATH (brew install getsentry/tools/sentry-cli). The token is
#     passed to sentry-cli through the environment and never printed.
#   * --upload: ASC_KEY_ID, ASC_ISSUER_ID and ~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8
#   * --stage: the gh CLI, authenticated.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
BUILD_DIR="$ROOT/build/testflight"
PROJECT="Ledger.xcodeproj"
SCHEME="Ledger"
RELEASE_TAG="ios-ledger-staged"

UPLOAD=0
STAGE=0
BUMP=1
for arg in "$@"; do
  case "$arg" in
    --upload) UPLOAD=1 ;;
    --stage) STAGE=1 ;;
    --keep-build) BUMP=0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# ── preflight ──────────────────────────────────────────────────────────────
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

if [[ $STAGE -eq 1 ]]; then
  command -v gh >/dev/null || { echo "error: gh CLI not installed" >&2; exit 1; }
  gh auth status >/dev/null 2>&1 || { echo "error: run 'gh auth login' first" >&2; exit 1; }
fi

# ── build number ───────────────────────────────────────────────────────────
# App Store Connect rejects a build number it has already accepted.
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

echo "==> Archiving"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
  CURRENT_PROJECT_VERSION="$BUILD"

echo "==> Exporting"
# Xcode 15.4 renamed the App Store export method; fall back for older Xcode.
write_export_options "app-store-connect"
if ! xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
      -exportPath "$BUILD_DIR/export" -allowProvisioningUpdates; then
  echo "==> Retrying export with the legacy 'app-store' method"
  write_export_options "app-store"
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
    -exportPath "$BUILD_DIR/export" -allowProvisioningUpdates
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
  command -v sentry-cli >/dev/null || { echo "error: SENTRY_AUTH_TOKEN set but sentry-cli not installed" >&2; exit 1; }
  : "${SENTRY_ORG:?set SENTRY_ORG}"
  echo "==> Uploading dSYMs to Sentry ($SENTRY_ORG/${SENTRY_PROJECT:-ledger-apps})"
  sentry-cli debug-files upload --include-sources \
    --org "$SENTRY_ORG" --project "${SENTRY_PROJECT:-ledger-apps}" \
    "$ARCHIVE/dSYMs"
else
  echo "==> SENTRY_AUTH_TOKEN not set — dSYMs NOT uploaded; crashes from build $BUILD will be unsymbolicated."
fi

# ── TestFlight upload (optional) ───────────────────────────────────────────
if [[ $UPLOAD -eq 1 ]]; then
  KEY_FILE="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID:-none}.p8"
  if [[ -z "${ASC_KEY_ID:-}" || -z "${ASC_ISSUER_ID:-}" || ! -f "$KEY_FILE" ]]; then
    echo "error: --upload needs ASC_KEY_ID, ASC_ISSUER_ID and $KEY_FILE" >&2
    exit 1
  fi
  # altool prints "Failed to upload package" and still exits 0; judge it by its output.
  for action in validate-app upload-app; do
    LOG="$BUILD_DIR/altool-$action.log"
    echo "==> altool --$action"
    xcrun altool "--$action" --type ios --file "$IPA" \
      --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" 2>&1 | tee "$LOG"
    if grep -qE 'Failed to (upload|validate) package|VERIFY FAILED|ERROR: \[altool' "$LOG"; then
      echo "error: altool --$action reported failure" >&2
      exit 1
    fi
  done
fi

# ── stage on GitHub (optional) ─────────────────────────────────────────────
if [[ $STAGE -eq 1 ]]; then
  COMMIT=$(git rev-parse HEAD)
  META="$BUILD_DIR/build-meta.json"
  python3 - "$META" "$BUILD" "$COMMIT" "$BUNDLE_PREFIX" <<'PY'
import json, sys
path, build, commit, bundle = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
json.dump({"build": build, "commit": commit,
           "apps": [{"scheme": "Ledger", "ipa": "Ledger.ipa", "bundle_id": bundle}]},
          open(path, "w"), indent=2)
PY
  gh release view "$RELEASE_TAG" >/dev/null 2>&1 || \
    gh release create "$RELEASE_TAG" --title "Staged Ledger iOS build" --prerelease \
      --notes "Rolling artifact for the TestFlight upload. Replaced on every release build."
  gh release upload "$RELEASE_TAG" "$IPA" "$META" --clobber
fi

cat <<DONE

Ledger build $BUILD is at $IPA.
build-number.json now says $BUILD — commit it so the number is never reused:
  git commit --only apps/ios/build-number.json --author="Hussain Abbasi <h_abbasi97@hotmail.com>" -m "Ledger iOS build $BUILD"
DONE
