#!/usr/bin/env bash
# Smoke-test a deployed Ledger web app (default: production).
#
#   scripts/ci/web-smoke.sh [base-url]
#
# Checks, each with retries for a just-promoted deployment:
#   * /            200, <title>Bank Ledger</title>, security headers (CSP pointing at
#                  the Supabase project, X-Frame-Options, nosniff, HSTS)
#   * /activity    200 HTML (SPA deep link served by the vercel.json rewrite)
#   * a hashed /assets/*.js from index.html: 200 and cached immutable
#   * /assets/<missing>.js: 404 (the rewrite must not turn assets into HTML)
# Used by .github/workflows/web-smoke.yml; safe to run from a laptop (GETs only).

# ok() only echoes, so `test && ok || bad` cannot run both branches.
# shellcheck disable=SC2015

set -euo pipefail

BASE="${1:-https://cc-statement-scraper.vercel.app}"
BASE="${BASE%/}"
PROJECT_REF="${SUPABASE_PROJECT_REF_PUBLIC:-nkmylznisjcnmqbxosey}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
ok() { echo "  ok    $*"; }
bad() { echo "::error::web smoke: $*"; FAILS=$((FAILS + 1)); }

# fetch <path> <name>: body -> $TMP/<name>.body, headers -> $TMP/<name>.h, prints status
fetch() {
  local path="$1" name="$2" code attempt
  for attempt in 1 2 3 4 5; do
    code="$(curl -sS --max-time 20 -D "$TMP/$name.h" -o "$TMP/$name.body" -w '%{http_code}' "$BASE$path" || echo 000)"
    case "$code" in 5*|000) sleep $((attempt * 3)) ;; *) break ;; esac
  done
  echo "$code"
}

header() { grep -i "^$2:" "$TMP/$1.h" | head -1 | cut -d: -f2- | tr -d '\r' | sed 's/^ *//'; }

echo "Smoke-testing $BASE"

code="$(fetch / index)"
[ "$code" = 200 ] && ok "/ -> 200" || bad "/ returned $code"
grep -q '<title>Bank Ledger</title>' "$TMP/index.body" && ok "title is Bank Ledger" || bad "/ has no <title>Bank Ledger</title>"
csp="$(header index content-security-policy)"
if [ -z "$csp" ]; then
  bad "Content-Security-Policy header missing"
else
  ok "CSP present"
  grep -q "default-src 'self'" <<<"$csp" || bad "CSP lacks default-src 'self'"
  grep -q "https://$PROJECT_REF.supabase.co" <<<"$csp" || bad "CSP connect-src does not allow https://$PROJECT_REF.supabase.co"
# Bank logos load from the public bank-logos Storage bucket.
grep -Eq "img-src[^;]*https://$PROJECT_REF\.supabase\.co" <<<"$csp" || bad "CSP img-src does not allow https://$PROJECT_REF.supabase.co (bank logos)"
  grep -q "frame-ancestors 'none'" <<<"$csp" || bad "CSP lacks frame-ancestors 'none'"
fi
[ "$(header index x-frame-options)" = DENY ] && ok "X-Frame-Options DENY" || bad "X-Frame-Options is not DENY"
[ "$(header index x-content-type-options)" = nosniff ] && ok "nosniff" || bad "X-Content-Type-Options is not nosniff"
[ -n "$(header index strict-transport-security)" ] && ok "HSTS" || bad "Strict-Transport-Security missing"

code="$(fetch /activity deeplink)"
ctype="$(header deeplink content-type)"
if [ "$code" = 200 ] && [[ "$ctype" == text/html* ]] && grep -q '<title>Bank Ledger</title>' "$TMP/deeplink.body"; then
  ok "/activity deep link -> 200 HTML"
else
  bad "/activity deep link returned $code ($ctype)"
fi

asset="$(grep -oE '/assets/[A-Za-z0-9._-]+\.js' "$TMP/index.body" | head -1 || true)"
if [ -z "$asset" ]; then
  bad "index.html references no /assets/*.js"
else
  code="$(fetch "$asset" asset)"
  cache="$(header asset cache-control)"
  [ "$code" = 200 ] && ok "$asset -> 200" || bad "$asset returned $code"
  grep -q immutable <<<"$cache" && ok "asset cached immutable" || bad "$asset cache-control is '$cache'"
fi

code="$(fetch /assets/__ledger-smoke-missing__.js missing)"
[ "$code" = 404 ] && ok "missing asset -> 404" || bad "missing asset returned $code (SPA rewrite swallowing /assets?)"

if [ "$FAILS" -gt 0 ]; then
  echo "web smoke: $FAILS check(s) failed for $BASE"
  exit 1
fi
echo "web smoke: all checks passed for $BASE"
