#!/usr/bin/env bash
# Full local check: guardrails -> guardrail self-tests -> warning gate ->
# test -> build both executables. No Docker, no external database: the test
# harness opens a hermetic temp-file SQLite store per test (Tests/
# LagoonServerTests/TestDatabase.swift), so `swift test` alone is the whole
# verification story.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== Guardrails =="
bash scripts/ci-guardrails.sh
bash scripts/lint-no-silent-catch.sh

echo "== Guardrail self-tests =="
bash scripts/test-guardrails.sh

# Before the tests, not after: on 2026-09-29 three live defects were found
# living inside warnings this suite had been discarding — an unsubscribe body
# cap whose delegate signature URLSession never called, a stored merge result
# that was computed and thrown away, and an over-eager read-state rescan.
# All three shipped with a fully green suite. See scripts/warn-gate.sh.
echo "== Warning gate =="
bash scripts/warn-gate.sh

echo "== Test =="
swift test

echo "== Build server (CLI) =="
swift build --product LagoonServerCLI

echo "== Build app =="
swift build --product Lagoon

echo "ALL CHECKS PASSED"
