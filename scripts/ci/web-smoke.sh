#!/usr/bin/env bash
# Smoke-test a deployed Ledger web app (default: production).
#
#   scripts/ci/web-smoke.sh [base-url]
#
# The repository names no production host: the base URL comes from the argument,
# $PRODUCTION_URL (a CI secret) or `git config ledger.webUrl`, and the Supabase ref
# from $SUPABASE_PROJECT_REF_PUBLIC or `git config ledger.supabaseRef` (optional).
#
# Checks, each with retries for a just-promoted deployment:
#   * /            200, <title>Bank Ledger</title>, security headers (CSP header allowing
#                  *.supabase.co, the build's meta CSP pinning the one Supabase host,
#                  X-Frame-Options, nosniff, HSTS) and no indexing (X-Robots-Tag)
#   * crawlers     /robots.txt disallows everything; a crawler user agent is sent there
#   * /activity    200 HTML (SPA deep link served by the vercel.json rewrite)
#   * a hashed /assets/*.js from index.html: 200 and cached immutable
#   * /assets/<missing>.js: 404 (the rewrite must not turn assets into HTML)
# Used by .github/workflows/web-smoke.yml; safe to run from a laptop (GETs only).

# ok() only echoes, so `test && ok || bad` cannot run both branches.
# shellcheck disable=SC2015

set -euo pipefail

BASE="${1:-${PRODUCTION_URL:-$(git config --get ledger.webUrl || true)}}"
BASE="${BASE%/}"
[ -n "$BASE" ] || { echo "usage: $0 <base-url> (or set PRODUCTION_URL / git config ledger.webUrl)" >&2; exit 2; }
PROJECT_REF="${SUPABASE_PROJECT_REF_PUBLIC:-$(git config --get ledger.supabaseRef || true)}"
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
  grep -Eq "connect-src[^;]*https://\*\.supabase\.co" <<<"$csp" || bad "CSP connect-src does not allow https://*.supabase.co"
  # Bank logos load from the public bank-logos Storage bucket.
  grep -Eq "img-src[^;]*https://\*\.supabase\.co" <<<"$csp" || bad "CSP img-src does not allow https://*.supabase.co (bank logos)"
  grep -q "frame-ancestors 'none'" <<<"$csp" || bad "CSP lacks frame-ancestors 'none'"
fi
# The build pins Supabase to one host in a meta CSP (apps/web/scripts/deploy-config.ts).
# Vite writes the quotes as &#39;, whose ';' would end a directive: decode it first.
meta="$(grep -o '<meta http-equiv="Content-Security-Policy" content="[^"]*"' "$TMP/index.body" | sed "s/&#39;/'/g" || true)"
ref_re="$PROJECT_REF"
[ -n "$ref_re" ] || ref_re='[a-z0-9]{20}'
host_re="https://$ref_re\.supabase\.co"
if grep -Eq "connect-src[^;]*$host_re" <<<"$meta" && grep -Eq "img-src[^;]*$host_re" <<<"$meta"; then
  ok "meta CSP pins the Supabase host"
else
  bad "index.html has no meta CSP pinning connect-src/img-src to the Supabase host"
fi
grep -q noindex <<<"$(header index x-robots-tag)" && ok "X-Robots-Tag noindex" || bad "X-Robots-Tag lacks noindex"
grep -q '<meta name="robots" content="noindex' "$TMP/index.body" && ok "robots meta noindex" || bad "index.html has no robots noindex meta"
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

code="$(fetch /robots.txt robots)"
[ "$code" = 200 ] && grep -q '^Disallow: /$' "$TMP/robots.body" && ok "robots.txt disallows everything" || bad "robots.txt returned $code or does not disallow /"
bot="$(curl -sS --max-time 20 -o /dev/null -w '%{http_code} %{redirect_url}' -A 'Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)' "$BASE/" || echo 000)"
[[ "$bot" =~ ^30[78]\ .*/robots\.txt$ ]] && ok "crawler user agent -> robots.txt" || bad "a crawler user agent got '$bot', not a redirect to robots.txt"

code="$(fetch /assets/__ledger-smoke-missing__.js missing)"
[ "$code" = 404 ] && ok "missing asset -> 404" || bad "missing asset returned $code (SPA rewrite swallowing /assets?)"

if [ "$FAILS" -gt 0 ]; then
  echo "web smoke: $FAILS check(s) failed for $BASE"
  exit 1
fi
echo "web smoke: all checks passed for $BASE"
