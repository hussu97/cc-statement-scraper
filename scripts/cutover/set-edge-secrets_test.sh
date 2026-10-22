#!/usr/bin/env bash
# Tests for set-edge-secrets.sh, run with --dry-run against fixture env files: it never calls
# `supabase`, so nothing reaches production.
#
#   bash scripts/cutover/set-edge-secrets_test.sh

set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/set-edge-secrets.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/edge-secrets-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
CRON="cron0123456789abcdef0123456789abcdef"
SECRET="GOCSPX-abcdefghijklmnopqrstuvwxyz12"

valid_file() {
  cat <<EOF
CRON_SECRET=$CRON
PARSER_URL=https://ccs-parser-example.a.run.app
PARSER_SECRET=parser-secret-value
GMAIL_OAUTH_CLIENT_SECRET=$SECRET
GMAIL_SENTRY_ALERTS=on
EOF
}

# expect NAME WANT_EXIT WANT_TEXT ENV_FILE: exit status and an output fragment; never a value.
expect() {
  local name="$1" want_exit="$2" want_text="$3" file="$4" out code=0
  out="$(bash "$SCRIPT" --dry-run --env-file "$file" 2>&1)" || code=$?
  local ok=1
  [ "$code" -eq "$want_exit" ] || ok=0
  [[ "$out" == *"$want_text"* ]] || ok=0
  case "$out" in *"$SECRET"*|*"$CRON"*) ok=0 ;; esac
  if [ "$ok" -eq 1 ]; then
    echo "ok   $name"
  else
    echo "FAIL $name (exit $code, want $want_exit)"
    printf '%s\n' "$out" | grep -v -e "$SECRET" -e "$CRON" | sed 's/^/     /'
    FAILS=$((FAILS + 1))
  fi
}

valid_file > "$TMP/valid.env"
expect "a valid file passes the dry run" 0 "Dry run: nothing pushed." "$TMP/valid.env"

# The 2026-10-21 incident: GMAIL_SENTRY_ALERTS=on appended without a newline before it.
valid_file | sed '/^GMAIL_SENTRY_ALERTS=/d' | sed "s/^GMAIL_OAUTH_CLIENT_SECRET=.*/GMAIL_OAUTH_CLIENT_SECRET=${SECRET}GMAIL_SENTRY_ALERTS=on/" \
  > "$TMP/glued.env"
expect "a value with another KEY= glued on is refused" 1 \
  "GMAIL_OAUTH_CLIENT_SECRET: value contains a KEY=" "$TMP/glued.env"

valid_file | sed "s/^PARSER_SECRET=.*/PARSER_SECRET=\"quoted-value\"MS_OAUTH_TENANT=consumers/" > "$TMP/glued-quoted.env"
expect "a glued KEY= after a quoted value is refused" 1 "PARSER_SECRET: value contains a KEY=" "$TMP/glued-quoted.env"

# Values may hold '=' and capitals on their own (base64 padding, URLs with query strings).
{ valid_file; echo "LLM_MODEL=claude-opus-5-5"; echo "SENTRY_DSN=https://abc@o1.ingest.sentry.io/2?A=b"; echo "ANTHROPIC_API_KEY=sk-ABCdef0123=="; } > "$TMP/equals.env"
expect "a value with '=' but no KEY= passes" 0 "Dry run: nothing pushed." "$TMP/equals.env"

valid_file | sed "s|^PARSER_URL=.*|PARSER_URL=http://127.0.0.1:8080|" > "$TMP/local.env"
expect "a local PARSER_URL is refused" 1 "PARSER_URL: must be the https://" "$TMP/local.env"

if [ "$FAILS" -gt 0 ]; then
  echo "$FAILS failure(s)"
  exit 1
fi
echo "all passed"
