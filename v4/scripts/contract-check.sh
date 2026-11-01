#!/usr/bin/env bash
# Replay the golden fixtures against a sidecar and diff — the executable form of
# v4/docs/api-contract.md.
#
#   bash v4/scripts/contract-check.sh                      # throwaway instance: spawn + seed + replay
#   bash v4/scripts/contract-check.sh <base_url> <token>   # replay against a running instance
#
# The no-argument form is the canonical one: it starts a throwaway
# LagoonServerCLI with a mktemp SQLite store and seeds it exactly like
# capture-contract.sh did, so the only variable left is the code under test.
# The two-argument form is for CI or a hand-started instance; it does NOT seed,
# so it only matches if that instance is a fresh, identically seeded store.
#
# Exit code: 0 when every fixture matches, 1 on the first mismatching batch
# (all mismatches are printed before exiting).
#
# Dependencies: bash + python3 + curl + openssl only.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HARNESS="$ROOT/v4/tests/contract/harness.py"
FIXTURES="${LAGOON_CONTRACT_FIXTURES:-$ROOT/v4/tests/contract/fixtures}"
VERBOSE="${LAGOON_CONTRACT_VERBOSE:-0}"

die() { echo "contract-check: $*" >&2; exit 1; }

[ -f "$HARNESS" ] || die "missing $HARNESS"
[ -f "$FIXTURES/fixtures.json" ] || die "missing $FIXTURES/fixtures.json; run: bash v4/scripts/capture-contract.sh"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

if [ "$#" -ge 2 ]; then
  BASE_URL="$1"
  TOKEN="$2"
  echo "contract-check: replaying against $BASE_URL (no seeding; the instance must be fresh)"
  # Explicit-target mode = "validate an implementation against the contract":
  # contract_expected fixtures ARE asserted (a v3 sidecar cannot satisfy them),
  # and write-path fixtures are skipped unless explicitly requested.
  # bash 3.2 (macOS) refuses an empty array under "set -u", so the optional
  # flags are a plainly split string instead.
  extra=""
  if [ "${LAGOON_CONTRACT_SKIP_CONTRACT_EXPECTED:-0}" != "1" ]; then
    extra="--assert-contract-expected"
  fi
  if [ "${LAGOON_CONTRACT_INCLUDE_WRITE:-0}" = "1" ]; then
    extra="$extra --include-write"
  fi
  if [ "$VERBOSE" = "1" ]; then
    exec python3 -B "$HARNESS" check --base-url "$BASE_URL" --token "$TOKEN" \
      --fixtures "$FIXTURES" $extra --verbose
  fi
  exec python3 -B "$HARNESS" check --base-url "$BASE_URL" --token "$TOKEN" \
    --fixtures "$FIXTURES" $extra
fi

sidecar_bin() {
  if [ -n "${LAGOON_V4_SIDECAR:-}" ]; then echo "$LAGOON_V4_SIDECAR"; return; fi
  for candidate in "$ROOT/.build/release/LagoonServerCLI" "$ROOT/.build/debug/LagoonServerCLI"; do
    if [ -x "$candidate" ]; then echo "$candidate"; return; fi
  done
  die "LagoonServerCLI not built; set LAGOON_V4_SIDECAR or run: swift build --product LagoonServerCLI"
}

pick_port() {
  python3 - <<'PY'
import socket
sock = socket.socket()
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
}

command -v openssl >/dev/null 2>&1 || die "openssl is required"
command -v curl >/dev/null 2>&1 || die "curl is required"

BIN="$(sidecar_bin)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/lagoon-contract-check.XXXXXX")"
PID=""
PORT=""

cleanup() {
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    kill -TERM "$PID" 2>/dev/null || true
    for _ in $(seq 1 20); do kill -0 "$PID" 2>/dev/null || break; sleep 0.25; done
    kill -KILL "$PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

healthy() {
  curl -sf -m 2 -o /dev/null -H "Authorization: Bearer $1" "http://127.0.0.1:$2/healthz"
}

TOKEN_KEY="$(openssl rand -base64 32)"
BODY_KEY="$(openssl rand -base64 32)"
API_TOKEN="$(openssl rand -hex 24)"

started=0
for _attempt in 1 2 3; do
  PORT="$(pick_port)"
  LAGOON_DB_PATH="$TMP/lagoon.sqlite" \
  LAGOON_SERVER_PORT="$PORT" \
  LAGOON_TOKEN_KEY="$TOKEN_KEY" \
  LAGOON_BODY_KEY="$BODY_KEY" \
  LAGOON_API_TOKEN="$API_TOKEN" \
    "$BIN" >"$TMP/sidecar.log" 2>&1 &
  PID=$!
  for _ in $(seq 1 80); do
    if healthy "$API_TOKEN" "$PORT"; then started=1; break 2; fi
    if ! kill -0 "$PID" 2>/dev/null; then break; fi
    sleep 0.25
  done
  kill -TERM "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true
  PID=""
done

if [ "$started" -ne 1 ]; then
  echo "contract-check: sidecar did not become healthy; last log lines:" >&2
  tail -20 "$TMP/sidecar.log" >&2 || true
  exit 1
fi

echo "contract-check: throwaway sidecar on 127.0.0.1:$PORT; fixtures from $FIXTURES"
# No exec here: the EXIT trap must run so the throwaway sidecar is reaped.
# No-argument mode = "the v3 reference implementation": it does support the
# write-path fixtures, so they are asserted here. contract_expected fixtures
# stay skipped, because v3 cannot satisfy them (each one carries its
# defect_evidence in fixtures.json).
extra="--include-write"
if [ "${LAGOON_CONTRACT_SKIP_WRITE:-0}" = "1" ]; then extra=""; fi
status=0
if [ "$VERBOSE" = "1" ]; then
  python3 -B "$HARNESS" check \
    --base-url "http://127.0.0.1:$PORT" \
    --token "$API_TOKEN" \
    --fixtures "$FIXTURES" \
    --db "$TMP/lagoon.sqlite" \
    --body-key "$BODY_KEY" \
    $extra --verbose || status=$?
else
  python3 -B "$HARNESS" check \
    --base-url "http://127.0.0.1:$PORT" \
    --token "$API_TOKEN" \
    --fixtures "$FIXTURES" \
    --db "$TMP/lagoon.sqlite" \
    --body-key "$BODY_KEY" \
    $extra || status=$?
fi
exit "$status"
