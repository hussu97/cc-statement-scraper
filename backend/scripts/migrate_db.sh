#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -z "${CCS_PLATFORM_DATABASE_URL:-}" ]]; then
  echo "CCS_PLATFORM_DATABASE_URL is not set."
  echo "Example for Postgres:"
  echo "  export CCS_PLATFORM_DATABASE_URL='postgresql+psycopg://USER:PASS@HOST:5432/DB'"
  exit 1
fi

export PYTHONPATH="${PYTHONPATH:-$ROOT_DIR/src}"

alembic upgrade head

echo "Migration completed against configured database."
