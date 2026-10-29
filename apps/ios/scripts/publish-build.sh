#!/usr/bin/env bash
#
# Build and sign Ledger on this Mac, then stage it on GitHub for the TestFlight
# workflow to pick up. The same flow as another app on the same Apple team, for one app.
#
# Why this split: a GitHub-hosted macOS runner bills at a 10x multiplier. The
# archive is the expensive part and your Mac does it for free, so it happens
# here and the runner is left with only the upload (a Linux job, App Store
# Connect API, no Xcode) and the distribution to testers.
#
# Signing also happens here, so the distribution certificate does not need to
# exist in GitHub for this path at all. Only the API key does.
#
# Normally invoked by the repo's pre-push hook for main pushes that change the
# iOS app; run it directly to stage a build without pushing:
#
#   apps/ios/scripts/publish-build.sh              # test, build, sign, check, Sentry, stage
#   apps/ios/scripts/publish-build.sh --keep-build # reuse the current build number
#
# To build AND upload straight from this Mac (no GitHub involved):
#
#   apps/ios/scripts/testflight.sh && node apps/ios/scripts/testflight-distribute.mjs
#
# The artifacts live on a single rolling prerelease rather than a per-commit
# tag, because a pre-push hook runs before the commit exists on the remote and
# GitHub cannot tag a commit it has not received yet.
#
# The repository is public, so the release is world-downloadable: the IPA is staged
# ENCRYPTED (Ledger.ipa.enc, scripts/ipa-crypt.sh) with a key that exists only here
# and in the `testflight` environment secret IPA_ENCRYPTION_KEY, and build-meta.json
# holds nothing sensitive (build number, commit, asset names, SHA-256s). The key
# comes from the environment (IPA_ENCRYPTION_KEY) or the login keychain item
# `ledger-ipa-encryption-key`; one-time setup in apps/ios/README.md ("TestFlight").
set -euo pipefail

cd "$(dirname "$0")/.."

# Not a generic `ios-staged`: this repository also ships web and backend, so the
# tag names the app it carries.
RELEASE_TAG="ios-ledger-staged"
KEYCHAIN_SERVICE="ledger-ipa-encryption-key"
PASSTHRU=()
for arg in "$@"; do
  case "$arg" in
    --keep-build) PASSTHRU+=("$arg") ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

command -v gh >/dev/null || { echo "error: gh CLI not installed" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "error: run 'gh auth login' first" >&2; exit 1; }

# ── encryption key (checked before the slow part, not after it) ────────────
# Held in a non-exported variable and dropped from the environment before the
# build: xcodebuild turns environment variables into build settings, which build
# phases and logs can see. It reaches openssl only through ipa-crypt.sh's env.
ENC_KEY="${IPA_ENCRYPTION_KEY:-}"
unset IPA_ENCRYPTION_KEY
if [[ -z "$ENC_KEY" ]]; then
  ENC_KEY="$(security find-generic-password -s "$KEYCHAIN_SERVICE" -w 2>/dev/null || true)"
fi
if [[ -z "$ENC_KEY" ]]; then
  cat >&2 <<MSG
error: no IPA encryption key. The staged IPA is encrypted because the release is public.
       Store the key once in the login keychain (and the same value in the testflight
       environment secret IPA_ENCRYPTION_KEY), as apps/ios/README.md "TestFlight" shows:
         security add-generic-password -U -s $KEYCHAIN_SERVICE -a "\$USER" -w
       or export IPA_ENCRYPTION_KEY in the shell.
MSG
  exit 1
fi
(( ${#ENC_KEY} >= 32 )) || { echo "error: the IPA encryption key is shorter than 32 characters (openssl rand -base64 32)" >&2; exit 1; }

# Build and sign, but do not upload to Apple from here — the runner does that,
# so the push is what ships, not the hook.
./scripts/testflight.sh --no-upload ${PASSTHRU[@]+"${PASSTHRU[@]}"}

BUILD=$(python3 -c "import json; print(json.load(open('build-number.json'))['ios'])")
COMMIT=$(git rev-parse HEAD)

IPA=$(find build/testflight/export -name '*.ipa' | head -1)
[[ -n "$IPA" ]] || { echo "error: no .ipa for Ledger" >&2; exit 1; }
[[ "$(basename "$IPA")" == "Ledger.ipa" ]] || { echo "error: expected Ledger.ipa, got $(basename "$IPA")" >&2; exit 1; }

# testflight.sh checked the archive; this checks the IPA that is about to ship
# (app + share extension Info.plists: https non-local URL, `production`, keys
# present). Shape only, no value printed. A failure stages nothing.
./scripts/release-config-check.sh archive "$IPA"

# Encrypt, then prove the round trip before anything leaves this Mac: a staged
# file the workflow cannot decrypt would only fail after the push.
ENC=build/testflight/Ledger.ipa.enc
CHECK_IPA=build/testflight/roundtrip.ipa
rm -f "$ENC" "$CHECK_IPA"
IPA_ENCRYPTION_KEY="$ENC_KEY" ./scripts/ipa-crypt.sh encrypt "$IPA" "$ENC"
IPA_ENCRYPTION_KEY="$ENC_KEY" ./scripts/ipa-crypt.sh decrypt "$ENC" "$CHECK_IPA"
unset ENC_KEY
sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
IPA_SHA="$(sha256 "$IPA")"
ENC_SHA="$(sha256 "$ENC")"
[[ "$(sha256 "$CHECK_IPA")" == "$IPA_SHA" ]] || { echo "error: the encrypted IPA does not decrypt to the original" >&2; exit 1; }
rm -f "$CHECK_IPA"

# The workflow refuses to ship artifacts that do not belong to the commit that
# triggered it. Without this, a push made from a machine that did not build
# would silently re-ship whatever was staged last. Public, so nothing sensitive:
# no bundle id or team (the workflow reads LEDGER_BUNDLE_ID from the testflight
# environment). `enc_sha256` checks the download before decrypting; `ipa_sha256`
# (of the plaintext) checks the decryption, and since only the key holder can
# make a ciphertext that decrypts to a matching IPA, it also stands in for the
# authentication CBC lacks.
META=build/testflight/build-meta.json
python3 - "$META" "$BUILD" "$COMMIT" "$IPA_SHA" "$ENC_SHA" <<'PY'
import json, sys
path, build, commit, ipa_sha, enc_sha = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]
json.dump({
    "build": build,
    "commit": commit,
    "apps": [
        {
            "scheme": "Ledger",
            "asset": "Ledger.ipa.enc",
            "ipa": "Ledger.ipa",
            "encryption": "aes-256-cbc, pbkdf2-sha256 200000 (scripts/ipa-crypt.sh)",
            "enc_sha256": enc_sha,
            "ipa_sha256": ipa_sha,
        },
    ],
}, open(path, "w"), indent=2)
PY

echo
echo "==> Staging Ledger build $BUILD ($COMMIT) on release $RELEASE_TAG"
gh release view "$RELEASE_TAG" >/dev/null 2>&1 || \
  gh release create "$RELEASE_TAG" \
    --title "Staged Ledger iOS build" \
    --notes "Rolling artifacts consumed by the Ledger TestFlight workflow. Replaced on every release build; not a version history." \
    --prerelease

gh release upload "$RELEASE_TAG" "$ENC" "$META" --clobber
# Builds staged before encryption left a plaintext Ledger.ipa on the release.
if gh release view "$RELEASE_TAG" --json assets --jq '.assets[].name' | grep -qx 'Ledger.ipa'; then
  gh release delete-asset "$RELEASE_TAG" Ledger.ipa --yes
fi

# ── record the number that was just spent ──────────────────────────────────
#
# App Store Connect rejects a build number it has already accepted, so the
# counter has to survive this machine. Committed here, and only once the
# artifacts are actually staged: a build that failed spent no number, and
# reusing it next time is correct.
#
# Do not rely on which push this commit rides. Current git re-resolves the ref
# after the pre-push hook returns, so it usually goes out with the push that
# created it — and the workflow then runs for the counter commit, not for the
# commit these artifacts name. The workflow must therefore accept staged
# artifacts whose commit differs from the pushed one ONLY by
# apps/ios/build-number.json (a file nothing compiles), and that file must be in
# its paths-ignore and out of the pre-push filter, so on its own it ships
# nothing and builds nothing. Another app on the same team lost several releases to this.
if [[ -n "$(git status --porcelain -- build-number.json)" ]]; then
  # `--only`, so a tree with other work in progress does not get swept in.
  if git commit --only build-number.json --quiet \
      --author="Hussain Abbasi <h_abbasi97@hotmail.com>" \
      -m "Ledger iOS build $BUILD — staged for TestFlight

Bumped by apps/ios/scripts/publish-build.sh. Committed so the number is not
spent twice: App Store Connect rejects one it has already accepted." 2>/dev/null; then
    COUNTER_NOTE="Recorded build $BUILD in a commit."
  else
    COUNTER_NOTE="WARNING: could not commit apps/ios/build-number.json. Commit it by hand,
or the next clone of this repo will try to reuse build $BUILD."
  fi
else
  COUNTER_NOTE="Build number unchanged (--keep-build), nothing to record."
fi

cat <<DONE

Staged Ledger build $BUILD for commit ${COMMIT:0:8}.

The push to main triggers the TestFlight workflow, which downloads it from the
$RELEASE_TAG release, uploads it to App Store Connect, and runs
apps/ios/scripts/testflight-distribute.mjs to release it to "Friends & Family".

$COUNTER_NOTE
DONE
