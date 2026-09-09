#!/usr/bin/env bash
set -euo pipefail
: "${DATABASE_URL:=postgres://lagoon:lagoon@127.0.0.1:5433/lagoon}"
MIG_DIR="$(dirname "$0")/../Sources/LagoonKit/Migrations"

# Parse host / port / user / db from DATABASE_URL
url_re='^postgres://([^:]+):[^@]+@([^:]+):([0-9]+)/([^?]+)'
PGUSER="lagoon"; PGHOST="127.0.0.1"; PGPORT="5433"; PGDATABASE="lagoon"
if [[ "$DATABASE_URL" =~ $url_re ]]; then
  PGUSER="${BASH_REMATCH[1]}"
  PGHOST="${BASH_REMATCH[2]}"
  PGPORT="${BASH_REMATCH[3]}"
  PGDATABASE="${BASH_REMATCH[4]}"
fi

# Prefer docker exec when the lagoon-postgres container is running; otherwise local psql.
run_psql() {
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^lagoon-postgres$'; then
    docker exec -i lagoon-postgres psql -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 "$@"
  else
    PGPASSWORD="${PGPASSWORD:-lagoon}" psql \
      -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" \
      -v ON_ERROR_STOP=1 "$@"
  fi
}

run_psql -c "CREATE TABLE IF NOT EXISTS schema_migrations (name TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT now())" > /dev/null

for f in "$MIG_DIR"/*.sql; do
  [ -e "$f" ] || exit 0
  name="$(basename "$f")"
  applied="$(run_psql -tAc "SELECT 1 FROM schema_migrations WHERE name = '$name'")"
  if [ "$applied" = "1" ]; then
    echo "Skipping $name (already applied)"
  else
    echo "Applying $name"
    run_psql -f - < "$f" > /dev/null
    # name comes from our own loop variable, never user input.
    run_psql -c "INSERT INTO schema_migrations (name) VALUES ('$name')" > /dev/null
  fi
done
echo "Migrations up to date."