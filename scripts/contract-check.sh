#!/usr/bin/env bash
# Replay the golden fixtures against a sidecar and diff — the executable form of
# docs/api-contract.md.
#
#   bash scripts/contract-check.sh                      # throwaway instance: spawn + seed + replay
#   bash scripts/contract-check.sh <base_url> <token>   # replay against a running instance
#
# The no-argument form spawns a throwaway Rust backend (lagoon-api) with its
# own port, its own SQLite file under mktemp and fresh ephemeral keys, then
# replays against it. The two-argument form is for CI or a hand-started
# instance; it does NOT seed, so it only matches if that instance is a fresh,
# identically seeded store.
#
# Exit code: 0 when every fixture matches, 1 on the first mismatching batch
# (all mismatches are printed before exiting).
#
# Dependencies: bash + python3 + curl + openssl only.
set -euo pipefail

LAGOON_LABEL=contract-check
# shellcheck source=scripts/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

HARNESS="$LAGOON_ROOT/tests/contract/harness.py"
FIXTURES="${LAGOON_CONTRACT_FIXTURES:-$LAGOON_ROOT/tests/contract/fixtures}"
VERBOSE="${LAGOON_CONTRACT_VERBOSE:-0}"

[ -f "$HARNESS" ] || die "missing $HARNESS"
[ -f "$FIXTURES/fixtures.json" ] || die "missing $FIXTURES/fixtures.json; run: bash scripts/capture-contract.sh"
require_tool python3

if [ "$#" -ge 2 ]; then
  BASE_URL="$1"
  TOKEN="$2"
  echo "contract-check: replaying against $BASE_URL (no seeding; the instance must be fresh)"
  # Explicit-target mode = "validate an implementation against the contract":
  # contract_expected fixtures ARE asserted, and write-path fixtures are
  # skipped unless explicitly requested.
  args=(check --base-url "$BASE_URL" --token "$TOKEN" --fixtures "$FIXTURES")
  if [ "${LAGOON_CONTRACT_SKIP_CONTRACT_EXPECTED:-0}" != "1" ]; then
    args+=(--assert-contract-expected)
  fi
  if [ "${LAGOON_CONTRACT_INCLUDE_WRITE:-0}" = "1" ]; then
    args+=(--include-write)
  fi
  if [ "$VERBOSE" = "1" ]; then args+=(--verbose); fi
  exec python3 -B "$HARNESS" "${args[@]}"
fi

require_tool openssl
require_tool curl

BIN="$(sidecar_bin)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/lagoon-contract-check.XXXXXX")"
# No exec below: the EXIT trap must run so the throwaway sidecar is reaped.
trap cleanup_sidecar EXIT INT TERM
start_sidecar "$BIN" "$TMP"

echo "contract-check: throwaway sidecar on 127.0.0.1:$SIDECAR_PORT; fixtures from $FIXTURES"
# No-argument mode replays against the Rust backend, which is the
# implementation now. That means the write-path fixtures are asserted, and so
# are the two contract_expected ones: they are the responses the retired
# Swift sidecar could not produce (each carries its defect_evidence in
# fixtures.json), and this build is the one that has to satisfy them.
args=(check
  --base-url "http://127.0.0.1:$SIDECAR_PORT"
  --token "$API_TOKEN"
  --fixtures "$FIXTURES"
  --db "$TMP/lagoon.sqlite"
  --body-key "$BODY_KEY")
if [ "${LAGOON_CONTRACT_SKIP_WRITE:-0}" != "1" ]; then args+=(--include-write); fi
if [ "${LAGOON_CONTRACT_SKIP_CONTRACT_EXPECTED:-0}" != "1" ]; then
  args+=(--assert-contract-expected)
fi
if [ "$VERBOSE" = "1" ]; then args+=(--verbose); fi

status=0
python3 -B "$HARNESS" "${args[@]}" || status=$?
exit "$status"
