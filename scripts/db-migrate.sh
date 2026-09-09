#!/usr/bin/env bash
set -euo pipefail
: "${DATABASE_URL:=postgres://lagoon:lagoon@127.0.0.1:5432/lagoon}"
MIG_DIR="$(dirname "$0")/../Sources/LagoonKit/Migrations"

# Parse host / port / user / db from DATABASE_URL
url_re='^postgres://([^:]+):[^@]+@([^:]+):([0-9]+)/([^?]+)'
if [[ "$DATABASE_URL" =~ $url_re ]]; then
  PGUSER="${BASH_REMATCH[1]}"
  PGHOST="${BASH_REMATCH[2]}"
  PGPORT="${BASH_REMATCH[3]}"
  PGDATABASE="${BASH_REMATCH[4]}"
fi

ls "$MIG_DIR"/*.sql 2>/dev/null | sort | while read -r f; do
  echo "Applying $f"
  # Prefer docker exec if lagoon-postgres container is up; otherwise use local psql.
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^lagoon-postgres$'; then
    docker exec -i lagoon-postgres psql -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 < "$f"
  else
    PGPASSWORD="${PGPASSWORD:-lagoon}" psql \
      -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" \
      -v ON_ERROR_STOP=1 -f "$f"
  fi
done