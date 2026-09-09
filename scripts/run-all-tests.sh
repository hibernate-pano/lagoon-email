#!/usr/bin/env bash
# Full local check: guardrails -> migrate -> test -> build both executables.
set -euo pipefail
cd "$(dirname "$0")/.."

export DATABASE_URL="${DATABASE_URL:-postgres://lagoon:lagoon@127.0.0.1:5433/lagoon}"

echo "== Guardrails =="
bash scripts/ci-guardrails.sh

echo "== Migrate =="
bash scripts/db-migrate.sh

echo "== Test =="
swift test

echo "== Build server =="
swift build --product LagoonServer

echo "== Build app =="
swift build --product Lagoon

echo "ALL CHECKS PASSED"