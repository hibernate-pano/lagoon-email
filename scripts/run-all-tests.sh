#!/usr/bin/env bash
# Full local check: guardrails -> guardrail self-tests -> test -> build both
# executables. No Docker, no external database: the test harness opens a
# hermetic temp-file SQLite store per test (Tests/LagoonServerTests/
# TestDatabase.swift), so `swift test` alone is the whole verification story.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== Guardrails =="
bash scripts/ci-guardrails.sh

echo "== Guardrail self-tests =="
bash scripts/test-guardrails.sh

echo "== Test =="
swift test

echo "== Build server (CLI) =="
swift build --product LagoonServerCLI

echo "== Build app =="
swift build --product Lagoon

echo "ALL CHECKS PASSED"
