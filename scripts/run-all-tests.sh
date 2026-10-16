#!/usr/bin/env bash
# Full local check: guardrails -> guardrail self-tests -> warning gate ->
# test -> build both executables. No Docker, no external database: the test
# harness opens a hermetic temp-file SQLite store per test (Tests/
# LagoonServerTests/TestDatabase.swift), so `swift test` alone is the whole
# verification story.
#
# SWIFT PACKAGE MANAGER FLAGS (Q-01 in docs/全方位审查报告-2026-10-16.md)
# Every `swift test` / `swift build` this script runs — and the build inside
# scripts/warn-gate.sh, which this script invokes — accepts extra flags
# through the `LAGOON_SWIFTPM_FLAGS` environment variable. Unset or empty
# means no extra flags, which is exactly what CI and a normal terminal get.
# A session that itself runs inside a *nested* sandbox (an agent harness
# where `sandbox-exec` cannot be applied) must run:
#
#   LAGOON_SWIFTPM_FLAGS=--disable-sandbox bash scripts/run-all-tests.sh
#
# Without the passthrough this script was unusable from such a session: the
# warning gate's own build died with `sandbox-exec: sandbox_apply: Operation
# not permitted` before the test step was ever reached.
set -euo pipefail
cd "$(dirname "$0")/.."

# The extra flags as an ARRAY, parsed from the environment variable. Word
# splitting a plain string is how one flag silently becomes several bogus
# arguments, and `read -a` (rather than mapfile) keeps this working on the
# bash 3.2 macOS ships at /bin/bash.
SWIFTPM_FLAGS=()
if [[ -n "${LAGOON_SWIFTPM_FLAGS:-}" ]]; then
  read -r -a SWIFTPM_FLAGS <<< "$LAGOON_SWIFTPM_FLAGS"
fi

# The suite must actually run. `swift test` exits 0 having executed nothing
# when a filter typos out, an environment skips wholesale, or a target stops
# being discovered — a success report that validates air. So the run total is
# parsed and compared against a floor. The floor only ever moves UP as the
# suite grows: lowering it is how a silently-shrinking suite becomes invisible.
#
# HOW THE TOTAL IS PARSED (measured against a real full run on this
# toolchain — Swift 6.4 / Xcode 27 — rather than assumed): there is **no
# single grand-total line**. Each of the four test bundles (Client / Server /
# Kit / AI) prints its own `Test Suite 'All tests' passed` block with an
# `Executed N tests` summary, so those four lines are summed — one per
# bundle, exactly. This is deliberately NOT "sum every Executed line", which
# would triple-count (the inner per-suite lines and the `X.xctest` bundle
# lines carry the same numbers as the 'All tests' block).
TEST_FLOOR=800

echo "== Guardrails =="
bash scripts/ci-guardrails.sh
bash scripts/lint-no-silent-catch.sh

echo "== Guardrail self-tests =="
bash scripts/test-guardrails.sh
# The warning gate shipped permanently red because its diagnostic parser only
# recognised swiftc's OSC-8 colour form while the gate itself builds with
# -no-color-diagnostics. It has no fixture of its own, so nothing noticed for a
# day. Its self-test is cheap (no swift build) and must run BEFORE the gate, so
# a parser regression fails here with a clear cause instead of surfacing later
# as three mysterious "unapproved warning(s)".
bash scripts/test-warn-gate.sh

# Before the tests, not after: on 2026-09-29 three live defects were found
# living inside warnings this suite had been discarding — an unsubscribe body
# cap whose delegate signature URLSession never called, a stored merge result
# that was computed and thrown away, and an over-eager read-state rescan.
# All three shipped with a fully green suite. See scripts/warn-gate.sh.
# The gate reads LAGOON_SWIFTPM_FLAGS itself (same contract as above).
echo "== Warning gate =="
bash scripts/warn-gate.sh

echo "== Test =="
test_log="$(mktemp)"
trap 'rm -f "$test_log"' EXIT
swift test ${SWIFTPM_FLAGS[@]+"${SWIFTPM_FLAGS[@]}"} 2>&1 | tee "$test_log"
summary_blocks="$(grep -c "Test Suite 'All tests' passed" "$test_log" || true)"
if [ "${summary_blocks:-0}" -eq 0 ]; then
  echo "❌ no \"Test Suite 'All tests' passed\" summary in the output — cannot verify the suite ran" >&2
  exit 1
fi
executed="$(grep -A1 "Test Suite 'All tests' passed" "$test_log" \
  | grep -oE 'Executed [0-9]+ tests?' | grep -oE '[0-9]+' | awk '{ total += $1 } END { print total + 0 }')"
if [ -z "$executed" ] || [ "$executed" -eq 0 ]; then
  echo "❌ could not parse any 'Executed N tests' total from the output" >&2
  exit 1
fi
if [ "$executed" -lt "$TEST_FLOOR" ]; then
  echo "❌ only $executed tests executed across $summary_blocks bundle(s) (floor $TEST_FLOOR) — a filter or a skipped target is hiding the suite" >&2
  exit 1
fi
echo "✅ test count: $executed executed across $summary_blocks bundle(s) (floor $TEST_FLOOR)"

echo "== Build server (CLI) =="
swift build --product LagoonServerCLI ${SWIFTPM_FLAGS[@]+"${SWIFTPM_FLAGS[@]}"}

echo "== Build app =="
swift build --product Lagoon ${SWIFTPM_FLAGS[@]+"${SWIFTPM_FLAGS[@]}"}

echo "ALL CHECKS PASSED"
