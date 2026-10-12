#!/usr/bin/env bash
# Create the App Review demo account and its demo ledger (Guideline 2.1(a)).
#
#   scripts/cutover/create-review-demo.sh [--env-file PATH] [--email ADDRESS] [--yes]
#
# Defaults: --env-file .env.cutover (needs SUPABASE_URL, SUPABASE_SECRET_KEY,
#           LEDGER_DB_URL), --email app-review@<web-host>.
#
# 1. Creates the auth user with a generated password through the Auth admin API
#    (sign-ups stay disabled; the admin API works regardless). If the user exists,
#    its password is reset to the saved one.
# 2. Runs private.create_review_demo(user_id) as postgres: an "app-review" ledger
#    the user owns, filled with synthetic data through the real ingest paths.
#    Skipped when that ledger already exists.
# 3. Leaves LEDGER_REVIEW_EMAIL / LEDGER_REVIEW_PASSWORD in .env.review-demo
#    (gitignored, mode 600) for `testflight-distribute.mjs --review-account`.
#
# Against production this is a production action (CLAUDE.md §11.1). The password
# is never printed and never put on a command line.
#
# Bash 3.2 compatible (macOS /bin/bash).

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
ENV_FILE="$REPO_ROOT/.env.cutover"
OUT_FILE="$REPO_ROOT/.env.review-demo"
EMAIL="app-review@<web-host>"
YES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file) ENV_FILE="$2"; shift 2 ;;
    --email) EMAIL="$2"; shift 2 ;;
    --out) OUT_FILE="$2"; shift 2 ;;
    --yes) YES=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }
for bin in curl jq psql openssl; do command -v "$bin" >/dev/null || die "$bin is required"; done
[[ -f "$ENV_FILE" ]] || die "$ENV_FILE not found"

# The last assignment wins, as when the file is sourced.
val() { grep -E "^$1=" "$ENV_FILE" | tail -1 | cut -d= -f2- | sed -e 's/^["'\'']//' -e 's/["'\'']$//'; }
SUPABASE_URL="$(val SUPABASE_URL)"
SECRET_KEY="$(val SUPABASE_SECRET_KEY)"
DB_URL="$(val LEDGER_DB_URL)"
[[ -n "$SUPABASE_URL" && -n "$SECRET_KEY" && -n "$DB_URL" ]] \
  || die "$ENV_FILE needs SUPABASE_URL, SUPABASE_SECRET_KEY and LEDGER_DB_URL"
[[ "$SECRET_KEY" == sb_secret_* ]] || die "SUPABASE_SECRET_KEY is not an sb_secret_ key"
EMAIL="$(printf '%s' "$EMAIL" | tr '[:upper:]' '[:lower:]')"

umask 077
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ -f "$OUT_FILE" ]]; then
  PASSWORD="$(grep -E '^LEDGER_REVIEW_PASSWORD=' "$OUT_FILE" | tail -1 | cut -d= -f2-)"
  [[ -n "$PASSWORD" ]] || die "$OUT_FILE has no LEDGER_REVIEW_PASSWORD"
  echo "Using the password saved in $OUT_FILE"
else
  PASSWORD="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-24)"
  [[ ${#PASSWORD} -eq 24 ]] || die "could not generate a password"
fi

if [[ $YES -ne 1 ]]; then
  printf 'Create the review account %s on %s and seed its demo ledger? [y/N] ' "$EMAIL" "$SUPABASE_URL"
  read -r answer
  [[ "$answer" == y || "$answer" == Y ]] || die "aborted"
fi

{
  echo "# App Review demo account (scripts/cutover/create-review-demo.sh). Never commit."
  echo "LEDGER_REVIEW_EMAIL=$EMAIL"
  echo "LEDGER_REVIEW_PASSWORD=$PASSWORD"
} > "$OUT_FILE"
chmod 600 "$OUT_FILE"

auth() { # method path body-file → prints the HTTP status; body in $TMP/resp
  curl -sS -o "$TMP/resp" -w '%{http_code}' -X "$1" "$SUPABASE_URL/auth/v1$2" \
    -H "apikey: $SECRET_KEY" -H "Content-Type: application/json" --data-binary "@$3"
}
user_id() {
  psql "$DB_URL" -X -At -v ON_ERROR_STOP=1 -v email="$EMAIL" <<'SQL'
select id from auth.users where email = :'email';
SQL
}

jq -n --arg e "$EMAIL" --arg p "$PASSWORD" '{email: $e, password: $p, email_confirm: true}' > "$TMP/create.json"
status="$(auth POST /admin/users "$TMP/create.json")"
if [[ "$status" == 200 || "$status" == 201 ]]; then
  UID_="$(jq -r .id "$TMP/resp")"
  echo "Created auth user $EMAIL"
else
  UID_="$(user_id)"
  [[ -n "$UID_" ]] || die "creating the user failed (HTTP $status): $(jq -r '.msg // .message // .error_description // .' "$TMP/resp")"
  jq -n --arg p "$PASSWORD" '{password: $p, email_confirm: true}' > "$TMP/update.json"
  status="$(auth PUT "/admin/users/$UID_" "$TMP/update.json")"
  [[ "$status" == 200 ]] || die "resetting the password failed (HTTP $status)"
  echo "Auth user $EMAIL already existed; its password now matches $OUT_FILE"
fi

existing="$(psql "$DB_URL" -X -At -v ON_ERROR_STOP=1 -v uid="$UID_" <<'SQL'
select p.profile_code from public.profiles p
join public.profile_members m on m.profile_code = p.profile_code
where p.key = 'app-review' and m.user_id = :'uid'::uuid;
SQL
)"
if [[ -n "$existing" ]]; then
  echo "Demo ledger already exists ($existing); not reseeded"
else
  code="$(psql "$DB_URL" -X -At -q -v ON_ERROR_STOP=1 -v uid="$UID_" <<'SQL'
set client_min_messages = warning;
select private.create_review_demo(:'uid'::uuid);
SQL
)"
  echo "Seeded demo ledger $code"
fi

echo "Done. Next: set -a; . $OUT_FILE; set +a; node apps/ios/scripts/testflight-distribute.mjs --review-account"
