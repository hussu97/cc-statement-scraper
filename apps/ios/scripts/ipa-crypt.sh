#!/usr/bin/env bash
#
# Encrypts the IPA that publish-build.sh stages on the public `ios-ledger-staged`
# release, and decrypts it again in ios-testflight.yml. The release is
# world-downloadable on a public repository; the encrypted asset is useless without
# the key, which exists only in this Mac's login keychain (or the shell) and in the
# `testflight` environment secret IPA_ENCRYPTION_KEY.
#
#   IPA_ENCRYPTION_KEY=… ipa-crypt.sh encrypt Ledger.ipa Ledger.ipa.enc
#   IPA_ENCRYPTION_KEY=… ipa-crypt.sh decrypt Ledger.ipa.enc Ledger.ipa
#
# The key comes only from the environment and reaches openssl as `-pass env:…`, so
# it is never on a command line (`ps`) or in a log. One definition of the cipher for
# both ends: AES-256-CBC, key and IV from PBKDF2-HMAC-SHA256 (200 000 iterations)
# over the key and a random salt. Works with macOS LibreSSL and OpenSSL 3 alike.
# CBC is not authenticated: the workflow compares the decrypted IPA's SHA-256 with
# build-meta.json's `ipa_sha256`, which a party without the key cannot forge.
#
# One-time key setup: README "TestFlight" and docs/ci-cd.md.
set -euo pipefail

usage() { echo "usage: IPA_ENCRYPTION_KEY=… $0 encrypt|decrypt IN OUT" >&2; exit 2; }
[[ $# -eq 3 ]] || usage
mode="$1" in="$2" out="$3"
[[ -f "$in" ]] || { echo "error: $in does not exist" >&2; exit 2; }

if [[ -z "${IPA_ENCRYPTION_KEY:-}" ]]; then
  echo "error: IPA_ENCRYPTION_KEY is not set (keychain item ledger-ipa-encryption-key locally," >&2
  echo "       the testflight environment secret in CI)" >&2
  exit 1
fi
# A typed passphrase is too weak for a file anyone can download and attack offline.
if (( ${#IPA_ENCRYPTION_KEY} < 32 )); then
  echo "error: IPA_ENCRYPTION_KEY is shorter than 32 characters; generate one with" >&2
  echo "       openssl rand -base64 32" >&2
  exit 1
fi

OPENSSL="${OPENSSL:-openssl}"
args=(enc -aes-256-cbc -pbkdf2 -iter 200000 -md sha256 -pass env:IPA_ENCRYPTION_KEY -in "$in" -out "$out")
case "$mode" in
  encrypt) "$OPENSSL" "${args[@]}" -salt ;;
  decrypt)
    # A wrong key usually fails the padding check ("bad decrypt"); never leave a
    # half-written file that a later step could pick up.
    if ! "$OPENSSL" "${args[@]}" -d 2>/dev/null; then
      rm -f "$out"
      echo "error: could not decrypt $(basename "$in") (wrong IPA_ENCRYPTION_KEY, or a damaged file)" >&2
      exit 1
    fi
    ;;
  *) usage ;;
esac
