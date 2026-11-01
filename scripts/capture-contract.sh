#!/usr/bin/env bash
# Capture the golden HTTP fixtures for the v4 sidecar API contract.
#
# Spawns a throwaway LagoonServerCLI (own port, own SQLite file under mktemp,
# fresh ephemeral keys), seeds it with synthetic rows, records the *real*
# responses into tests/contract/fixtures/, then stops the sidecar.
#
#   bash scripts/capture-contract.sh
#   LAGOON_V4_SIDECAR=/path/to/LagoonServerCLI bash scripts/capture-contract.sh
#   LAGOON_CONTRACT_FIXTURES=/tmp/my-fixtures bash scripts/capture-contract.sh
#
# Guarantees:
#   * never reads or writes .dev/data, the user's store, or any mail server;
#   * no network egress: the seeded account's credentials blob is unreadable, so
#     every provider path fails at credential decryption before a socket exists;
#   * no third-party dependencies: bash + python3 + curl + openssl only.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HARNESS="$ROOT/tests/contract/harness.py"
FIXTURES="${LAGOON_CONTRACT_FIXTURES:-$ROOT/tests/contract/fixtures}"

die() { echo "capture-contract: $*" >&2; exit 1; }

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

command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v openssl >/dev/null 2>&1 || die "openssl is required"
command -v curl >/dev/null 2>&1 || die "curl is required"
[ -f "$HARNESS" ] || die "missing $HARNESS"

BIN="$(sidecar_bin)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/lagoon-contract-capture.XXXXXX")"
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

# Ephemeral keys, inside the temp dir's lifetime: never v4/.dev/keys.json.
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
  echo "capture-contract: sidecar did not become healthy; last log lines:" >&2
  tail -20 "$TMP/sidecar.log" >&2 || true
  exit 1
fi

echo "capture-contract: sidecar on 127.0.0.1:$PORT (temp db, ephemeral keys)"
python3 -B "$HARNESS" capture \
  --base-url "http://127.0.0.1:$PORT" \
  --token "$API_TOKEN" \
  --db "$TMP/lagoon.sqlite" \
  --body-key "$BODY_KEY" \
  --out "$FIXTURES"

echo "capture-contract: done. Verify with: bash scripts/contract-check.sh"
