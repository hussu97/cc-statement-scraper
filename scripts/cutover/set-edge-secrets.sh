#!/usr/bin/env bash
# Push the production Edge Function secrets from ONE validated env file.
#
#   scripts/cutover/set-edge-secrets.sh [--env-file PATH] [--project-ref REF]
#                                       [--sentry-release SHA] [--dry-run] [--yes]
#
# Defaults: --env-file supabase/functions/.env.production (gitignored),
#           --project-ref $SUPABASE_PROJECT_REF or nkmylznisjcnmqbxosey.
#
# The script refuses to push anything if:
#   - any value is empty or still a placeholder (contains `<...>`),
#   - a required key (CRON_SECRET, PARSER_URL, PARSER_SECRET) is missing,
#   - PARSER_URL is not an https:// URL (local Docker/localhost URLs are rejected),
#   - CRON_SECRET is shorter than 32 characters,
#   - a local-only key (PARSER_DOCUMENT_BASE_URL, LEDGER_E2E) or a reserved
#     SUPABASE_* key is present, or a key appears twice,
#   - a value contains another KEY= (two lines glued by a missing newline).
# API keys are not needed here: the runtime injects SUPABASE_SECRET_KEYS /
# SUPABASE_PUBLISHABLE_KEYS. SB_SECRET_KEY / SB_PUBLISHABLE_KEY are optional
# overrides read by _shared/supabase.ts (custom names cannot start with SUPABASE_).
# It then calls `supabase secrets set --env-file` with exactly the keys in the
# file, via a private temp copy. Values are never printed: only key names.
#
# Re-running is safe: every run pushes the complete, validated file, so it can
# never overwrite a good secret with a placeholder (PRODUCTION.md §10, X-01).
#
# Bash 3.2 compatible (macOS /bin/bash).

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
ENV_FILE="$REPO_ROOT/supabase/functions/.env.production"
PROJECT_REF="${SUPABASE_PROJECT_REF:-nkmylznisjcnmqbxosey}"
SENTRY_RELEASE_OVERRIDE=""
DRY_RUN=0
ASSUME_YES=0

REQUIRED_KEYS="CRON_SECRET PARSER_URL PARSER_SECRET"
RECOMMENDED_KEYS="ALLOWED_ORIGINS GMAIL_PUSH_AUDIENCE GMAIL_PUSH_SA_EMAIL GMAIL_PUBSUB_TOPIC GMAIL_OAUTH_CLIENT_ID GMAIL_OAUTH_CLIENT_SECRET MS_OAUTH_CLIENT_ID MS_OAUTH_CLIENT_SECRET SENTRY_DSN SENTRY_ENVIRONMENT SENTRY_RELEASE"
FORBIDDEN_KEYS="PARSER_DOCUMENT_BASE_URL LEDGER_E2E"

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --env-file) ENV_FILE="${2:?--env-file needs a path}"; shift 2 ;;
    --project-ref) PROJECT_REF="${2:?--project-ref needs a ref}"; shift 2 ;;
    --sentry-release) SENTRY_RELEASE_OVERRIDE="${2:?--sentry-release needs a value}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ ! -f "$ENV_FILE" ]; then
  echo "error: env file not found: $ENV_FILE" >&2
  exit 1
fi
if ! [[ "$PROJECT_REF" =~ ^[a-z0-9]{20}$ ]]; then
  echo "error: project ref '$PROJECT_REF' does not look like a Supabase ref" >&2
  exit 1
fi
if [ -n "$SENTRY_RELEASE_OVERRIDE" ] && [[ "$SENTRY_RELEASE_OVERRIDE" == *"<"* ]]; then
  echo "error: --sentry-release is a placeholder" >&2
  exit 1
fi

TMP_FILE="$(mktemp "${TMPDIR:-/tmp}/edge-secrets.XXXXXX")"
chmod 600 "$TMP_FILE"
cleanup() { rm -f "$TMP_FILE"; }
trap cleanup EXIT INT TERM

ERRORS=0
SEEN_KEYS=""
err() { echo "  ✗ $1" >&2; ERRORS=$((ERRORS + 1)); }
has_key() { case " $SEEN_KEYS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

LINE_NO=0
while IFS= read -r line || [ -n "$line" ]; do
  LINE_NO=$((LINE_NO + 1))
  line="${line%$'\r'}"
  # Skip blanks and comments.
  case "$line" in ''|\#*) continue ;; esac
  trimmed="${line#"${line%%[![:space:]]*}"}"
  case "$trimmed" in ''|\#*) continue ;; esac
  trimmed="${trimmed#export }"
  if [[ "$trimmed" != *=* ]]; then
    err "line $LINE_NO: not KEY=VALUE"
    continue
  fi
  key="${trimmed%%=*}"
  key="${key%"${key##*[![:space:]]}"}"
  value="${trimmed#*=}"
  raw_value="$value"   # written to the temp file unchanged (keeps dotenv quoting)
  # Strip one pair of matching surrounding quotes for validation only.
  if [[ "$value" =~ ^\"(.*)\"$ ]] || [[ "$value" =~ ^\'(.*)\'$ ]]; then
    value="${BASH_REMATCH[1]}"
  fi

  if ! [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
    err "line $LINE_NO: invalid key name"
    continue
  fi
  if has_key "$key"; then
    err "$key: appears more than once"
    continue
  fi
  SEEN_KEYS="$SEEN_KEYS $key"

  case "$key" in SUPABASE_*) err "$key: SUPABASE_* secrets are injected by Supabase and cannot be set"; continue ;; esac
  case " $FORBIDDEN_KEYS " in *" $key "*) err "$key: local-only, must never be set in production"; continue ;; esac

  if [ "$key" = "SENTRY_RELEASE" ] && [ -n "$SENTRY_RELEASE_OVERRIDE" ]; then
    continue   # replaced below
  fi
  if [ -z "$value" ]; then
    err "$key: empty value"
    continue
  fi
  if [[ "$value" == *"<"*">"* ]]; then
    err "$key: placeholder value (<...>)"
    continue
  fi
  # A line appended without a newline before it ends up inside the previous value. On
  # 2026-10-21 GMAIL_OAUTH_CLIENT_SECRET was pushed with GMAIL_SENTRY_ALERTS=on stuck to its end,
  # and every Gmail token refresh failed with invalid_client.
  if [[ "$value" =~ [A-Z][A-Z0-9]+(_[A-Z0-9]+)+= ]]; then
    err "$key: value contains a KEY= (two lines glued together? put each KEY=value on its own line)"
    continue
  fi
  case "$key" in
    PARSER_URL)
      if ! [[ "$value" =~ ^https://[^/]+ ]]; then
        err "PARSER_URL: must be the https:// Cloud Run URL printed by the parser deploy"
        continue
      fi
      case "$value" in *localhost*|*127.0.0.1*|*host.docker.internal*)
        err "PARSER_URL: points at a local host"; continue ;; esac
      ;;
    CRON_SECRET)
      if [ "${#value}" -lt 32 ]; then
        err "CRON_SECRET: shorter than 32 characters (use: openssl rand -hex 32)"
        continue
      fi
      ;;
  esac
  printf '%s=%s\n' "$key" "$raw_value" >> "$TMP_FILE"
done < "$ENV_FILE"

if [ -n "$SENTRY_RELEASE_OVERRIDE" ]; then
  printf 'SENTRY_RELEASE=%s\n' "$SENTRY_RELEASE_OVERRIDE" >> "$TMP_FILE"
  has_key SENTRY_RELEASE || SEEN_KEYS="$SEEN_KEYS SENTRY_RELEASE"
fi

for k in $REQUIRED_KEYS; do
  has_key "$k" || err "$k: required key missing"
done

if [ "$ERRORS" -gt 0 ]; then
  echo "Refusing to push: $ERRORS problem(s) in $ENV_FILE (values not shown)." >&2
  exit 1
fi

MISSING=""
for k in $RECOMMENDED_KEYS; do
  has_key "$k" || MISSING="$MISSING $k"
done

echo "Project: $PROJECT_REF"
echo "Source:  $ENV_FILE"
echo "Keys to set:"
cut -d= -f1 "$TMP_FILE" | sed 's/^/  - /'
if [ -n "$MISSING" ]; then
  echo "Not in file (left unchanged in production):$MISSING"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "Dry run: nothing pushed."
  exit 0
fi

if [ "$ASSUME_YES" -ne 1 ]; then
  printf 'Type the project ref to push these secrets: '
  read -r answer
  if [ "$answer" != "$PROJECT_REF" ]; then
    echo "Confirmation did not match; nothing pushed." >&2
    exit 1
  fi
fi

supabase secrets set --project-ref "$PROJECT_REF" --env-file "$TMP_FILE"
echo "Done. Verify names (digests only) with: supabase secrets list --project-ref $PROJECT_REF"
