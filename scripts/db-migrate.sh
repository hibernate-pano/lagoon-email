#!/usr/bin/env bash
set -euo pipefail
: "${DATABASE_URL:?DATABASE_URL not set}"
MIG_DIR="$(dirname "$0")/../Sources/LagoonKit/Migrations"
ls "$MIG_DIR"/*.sql 2>/dev/null | sort | while read -r f; do
  echo "Applying $f"
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
done