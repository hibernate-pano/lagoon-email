#!/usr/bin/env bash
# Full local check: guardrails -> guardrail self-tests -> test DB bootstrap ->
# migrate -> test -> build both executables.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== Guardrails =="
bash scripts/ci-guardrails.sh

echo "== Guardrail self-tests =="
bash scripts/test-guardrails.sh

echo "== Test DB bootstrap =="
# Tests clean up row-scoped (`DELETE ... WHERE id` / `oauth_user` via
# TestDatabase); they never wipe whole tables. Pointing DATABASE_URL at the dev
# database would still let a buggy test touch real data, so tests always use a
# dedicated lagoon_test database and never fall back to dev.
#
# ponytail: single shared test DB (lagoon_test), no per-run schema isolation.
# Ceiling: two concurrent test runs stomp on each other; give each run its own
# database/schema once CI needs parallelism.
TEST_DB="lagoon_test"
TEST_DATABASE_URL="postgres://lagoon:lagoon@127.0.0.1:5433/${TEST_DB}"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^lagoon-postgres$'; then
  # Container path keeps existing volumes working; ignore already-exists.
  docker exec lagoon-postgres createdb -U lagoon "$TEST_DB" 2>/dev/null || true
elif command -v createdb >/dev/null 2>&1; then
  PGPASSWORD=lagoon createdb -h 127.0.0.1 -p 5433 -U lagoon "$TEST_DB" 2>/dev/null || true
else
  PGPASSWORD=lagoon psql -h 127.0.0.1 -p 5433 -U lagoon -d postgres \
    -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"$TEST_DB\"" >/dev/null 2>&1 || true
fi
export DATABASE_URL="$TEST_DATABASE_URL"

echo "== Migrate (test DB) =="
bash scripts/db-migrate.sh

echo "== Test =="
swift test

echo "== Build server =="
swift build --product LagoonServer

echo "== Build app =="
swift build --product Lagoon

echo "ALL CHECKS PASSED"
