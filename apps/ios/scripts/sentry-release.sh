#!/usr/bin/env bash
#
# Sentry for an archived Ledger build: upload its dSYMs, then create the release
# the app reports (`ledger-ios@<version>+<build>`, LedgerKit Telemetry.releaseName),
# associate its commits and finalize it (BACKLOG IOS-21r).
#
#   apps/ios/scripts/sentry-release.sh build/testflight/Ledger.xcarchive
#
# Never fails a release: Sentry being down, a missing token or a missing
# sentry-cli is a loud warning and exit 0. The token is never printed and never
# put on a command line (sentry-cli reads it from the environment).
#
# Where each value comes from (first one set wins):
#   SENTRY_AUTH_TOKEN  the environment, else the login keychain item
#                      `ledger-sentry-auth-token` (scripts/testflight.sh header has
#                      the command). Never an xcconfig: there it is an Xcode build
#                      setting, visible to every build phase and in build logs.
#   SENTRY_ORG         the environment, else SENTRY_ORG in Config/Secrets.Release.xcconfig
#   SENTRY_PROJECT     the environment, else SENTRY_PROJECT in that file, else the
#                      project id at the end of the archived app's LedgerSentryDSN
#                      (credit-card-ledger-apps), else `credit-card-ledger-apps`
set -euo pipefail

cd "$(dirname "$0")/.."

ARCHIVE="${1:-}"
[[ -n "$ARCHIVE" && -d "$ARCHIVE" ]] || { echo "usage: $0 PATH.xcarchive" >&2; exit 2; }
KEYCHAIN_SERVICE="${SENTRY_KEYCHAIN_SERVICE:-ledger-sentry-auth-token}"
# LEDGER_RELEASE_XCCONFIG: release_checks_test.sh points this at a fixture.
RELEASE_XCCONFIG="${LEDGER_RELEASE_XCCONFIG:-Config/Secrets.Release.xcconfig}"

warn() { echo "==> WARNING (Sentry): $*" >&2; }

# `KEY = value` from the release xcconfig (last assignment wins); prints nothing else.
release_setting() {
  [[ -f "$RELEASE_XCCONFIG" ]] || return 0
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$RELEASE_XCCONFIG" | tail -1 | sed 's/[[:space:]]*$//'
}

shopt -s nullglob; apps=("$ARCHIVE"/Products/Applications/*.app); shopt -u nullglob
[[ ${#apps[@]} -eq 1 ]] || { warn "expected one .app in $(basename "$ARCHIVE"); Sentry skipped"; exit 0; }
INFO="${apps[0]}/Info.plist"
info_value() { plutil -extract "$1" raw -o - "$INFO" 2>/dev/null || true; }

TOKEN_SOURCE="environment"
if [[ -z "${SENTRY_AUTH_TOKEN:-}" ]]; then
  TOKEN_SOURCE="keychain item $KEYCHAIN_SERVICE"
  SENTRY_AUTH_TOKEN="$(security find-generic-password -s "$KEYCHAIN_SERVICE" -w 2>/dev/null || true)"
fi
if [[ -z "${SENTRY_AUTH_TOKEN:-}" ]]; then
  warn "no SENTRY_AUTH_TOKEN in the environment or the keychain ($KEYCHAIN_SERVICE): dSYMs NOT"
  warn "uploaded and no release created; crashes from this build will be unsymbolicated."
  exit 0
fi
export SENTRY_AUTH_TOKEN
echo "==> Sentry token from the $TOKEN_SOURCE"

if ! command -v sentry-cli >/dev/null; then
  warn "sentry-cli not installed (brew install getsentry/tools/sentry-cli): dSYMs NOT uploaded, no release."
  exit 0
fi

SENTRY_ORG="${SENTRY_ORG:-$(release_setting SENTRY_ORG)}"
SENTRY_PROJECT="${SENTRY_PROJECT:-$(release_setting SENTRY_PROJECT)}"
if [[ -z "$SENTRY_PROJECT" ]]; then
  SENTRY_PROJECT="$(info_value LedgerSentryDSN | sed -n 's|.*/\([0-9][0-9]*\)$|\1|p')"
fi
SENTRY_PROJECT="${SENTRY_PROJECT:-credit-card-ledger-apps}"
if [[ -z "$SENTRY_ORG" ]]; then
  warn "SENTRY_ORG not set (environment or $RELEASE_XCCONFIG): dSYMs NOT uploaded, no release."
  exit 0
fi

VERSION="$(info_value CFBundleShortVersionString)"
BUILD="$(info_value CFBundleVersion)"
RELEASE="ledger-ios@${VERSION:-0.0.0}+${BUILD:-0}"

STATUS_DSYMS="failed"
STATUS_RELEASE="failed"

echo "==> Uploading dSYMs to Sentry ($SENTRY_ORG/$SENTRY_PROJECT)"
if sentry-cli debug-files upload --include-sources \
    --org "$SENTRY_ORG" --project "$SENTRY_PROJECT" "$ARCHIVE/dSYMs"; then
  STATUS_DSYMS="uploaded"
else
  warn "dSYM upload failed (Sentry unreachable or the token lacks project:write); the build continues."
fi

echo "==> Sentry release $RELEASE"
if ! sentry-cli releases new --org "$SENTRY_ORG" --project "$SENTRY_PROJECT" "$RELEASE"; then
  warn "could not create release $RELEASE; the build continues."
else
  # --auto reads this repository's remote and HEAD; it needs the GitHub
  # integration in Sentry. Commits are a nicety: a failure only warns.
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "$REPO_ROOT" ]] && (cd "$REPO_ROOT" && sentry-cli releases set-commits --org "$SENTRY_ORG" \
        "$RELEASE" --auto --ignore-missing); then
    :
  else
    warn "could not associate commits with $RELEASE (is the GitHub integration set up in Sentry?)."
  fi
  if sentry-cli releases finalize --org "$SENTRY_ORG" "$RELEASE"; then
    STATUS_RELEASE="finalized"
  else
    warn "could not finalize $RELEASE; the build continues."
  fi
fi

echo "==> Sentry: dSYMs $STATUS_DSYMS, release $RELEASE $STATUS_RELEASE"
exit 0
