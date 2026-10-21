#!/usr/bin/env bash
# Upload the investment images (assets/investments/<metal>-<form>.jpg) to a Supabase project's
# public Storage bucket `investment-images`, under the same name (upsert).
#
#   SUPABASE_URL=… SUPABASE_SECRET_KEY=… scripts/brand/upload-investment-images.sh [--dry-run]
#
# Reads SUPABASE_URL and SUPABASE_SECRET_KEY from the environment (e.g. `set -a;
# . ./.env.cutover; set +a`). The key is sent as `apikey` only (plus a Bearer
# header when it is a legacy JWT key), passed to curl on stdin so it never
# appears in argv, and is never printed. The bucket and the image names come
# from a migration (holdings_valuation image_path); this script only writes the objects.
#
#   --dry-run   validate the files and print what would be uploaded; no requests
#
# Re-running is safe: every object is upserted (`x-upsert: true`).
# Bash 3.2 compatible (macOS /bin/bash).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOGO_DIR="$SCRIPT_DIR/../../assets/investments"
BUCKET="investment-images"
CACHE_CONTROL="max-age=86400"
DRY_RUN=0

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "${SUPABASE_URL:-}" ]; then
  echo "error: SUPABASE_URL is not set" >&2
  exit 1
fi
case "$SUPABASE_URL" in
  https://*|http://127.0.0.1:*|http://localhost:*) ;;
  *) echo "error: SUPABASE_URL must be https:// (or a local http://127.0.0.1 stack)" >&2; exit 1 ;;
esac
BASE_URL="${SUPABASE_URL%/}"
if [ "$DRY_RUN" -eq 0 ] && [ -z "${SUPABASE_SECRET_KEY:-}" ]; then
  echo "error: SUPABASE_SECRET_KEY is not set" >&2
  exit 1
fi

shopt -s nullglob
FILES=("$LOGO_DIR"/*.jpg)
if [ "${#FILES[@]}" -eq 0 ]; then
  echo "error: no JPEG files in $LOGO_DIR" >&2
  exit 1
fi

# Validate every file before uploading any of them.
for f in "${FILES[@]}"; do
  name="$(basename "$f")"
  if ! [[ "$name" =~ ^(gold|silver)-(bar|coin|jewellery)\.jpg$ ]]; then
    echo "error: $name is not named <gold|silver>-<bar|coin|jewellery>.jpg" >&2
    exit 1
  fi
  if [ "$(head -c 3 "$f" | od -An -tx1 | tr -d ' \n')" != "ffd8ff" ]; then
    echo "error: $name is not a JPEG" >&2
    exit 1
  fi
done

# curl config carrying the auth headers; fed on stdin so the key never reaches argv.
auth_config() {
  printf 'header = "apikey: %s"\n' "$SUPABASE_SECRET_KEY"
  case "$SUPABASE_SECRET_KEY" in
    eyJ*) printf 'header = "Authorization: Bearer %s"\n' "$SUPABASE_SECRET_KEY" ;;
  esac
}

echo "target: $BASE_URL/storage/v1/object/$BUCKET/ (${#FILES[@]} files)"

FAILED=0
for f in "${FILES[@]}"; do
  name="$(basename "$f")"
  url="$BASE_URL/storage/v1/object/$BUCKET/$name"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  [dry-run] POST $name ($(wc -c < "$f" | tr -d ' ') bytes)"
    continue
  fi
  status="$(
    auth_config | curl -sS -o /dev/null -w '%{http_code}' --config - \
      -X POST "$url" \
      -H "x-upsert: true" \
      -H "content-type: image/jpeg" \
      -H "cache-control: $CACHE_CONTROL" \
      --data-binary "@$f"
  )" || status="curl-error"
  if [ "$status" = "200" ]; then
    echo "  ✓ $name"
  else
    echo "  ✗ $name (HTTP $status)" >&2
    FAILED=$((FAILED + 1))
  fi
done

if [ "$FAILED" -gt 0 ]; then
  echo "$FAILED upload(s) failed" >&2
  exit 1
fi
[ "$DRY_RUN" -eq 1 ] || echo "public URL: $BASE_URL/storage/v1/object/public/$BUCKET/<metal>-<form>.jpg"
