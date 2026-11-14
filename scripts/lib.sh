#!/usr/bin/env bash
# Shared helpers for the contract scripts: capture-contract.sh and
# contract-check.sh.
#
# Sourced, never executed. These functions were duplicated line for line in
# both scripts, and the copies had already drifted once (one of them still
# looked for the retired Swift binary). One copy, one place to fix.

LAGOON_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The prefix every message carries; each script sets it before sourcing.
LAGOON_LABEL="${LAGOON_LABEL:-lagoon}"

die() { echo "$LAGOON_LABEL: $*" >&2; exit 1; }

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

# The backend the contract is checked against: a built lagoon-api, or a fresh
# debug build of it. The Swift sidecar is retired.
sidecar_bin() {
  for candidate in "$LAGOON_ROOT/crates/target/release/lagoon-api" \
                   "$LAGOON_ROOT/crates/target/debug/lagoon-api"; do
    if [ -x "$candidate" ]; then echo "$candidate"; return; fi
  done
  echo "$LAGOON_LABEL: building lagoon-api (debug)..." >&2
  (cd "$LAGOON_ROOT/crates" && cargo build --quiet -p lagoon-api) || die "cannot build lagoon-api"
  if [ -x "$LAGOON_ROOT/crates/target/debug/lagoon-api" ]; then
    echo "$LAGOON_ROOT/crates/target/debug/lagoon-api"
    return
  fi
  die "lagoon-api was not built at $LAGOON_ROOT/crates/target/debug/lagoon-api"
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

healthy() {
  curl -sf -m 2 -o /dev/null -H "Authorization: Bearer $1" "http://127.0.0.1:$2/healthz"
}

# Stops the throwaway sidecar `start_sidecar` spawned, then removes its temp
# dir. Installed as the EXIT trap by both scripts.
cleanup_sidecar() {
  if [ -n "${SIDECAR_PID:-}" ] && kill -0 "$SIDECAR_PID" 2>/dev/null; then
    kill -TERM "$SIDECAR_PID" 2>/dev/null || true
    for _ in $(seq 1 20); do kill -0 "$SIDECAR_PID" 2>/dev/null || break; sleep 0.25; done
    kill -KILL "$SIDECAR_PID" 2>/dev/null || true
  fi
  if [ -n "${SIDECAR_TMP:-}" ]; then rm -rf "$SIDECAR_TMP"; fi
}

# Starts a throwaway instance: own port, own SQLite file under $2, fresh
# ephemeral keys. Sets SIDECAR_PID, SIDECAR_PORT, SIDECAR_TMP, and exports the
# credentials the harness needs: TOKEN_KEY, BODY_KEY, API_TOKEN.
start_sidecar() {
  local bin="$1"
  local tmp="$2"
  SIDECAR_TMP="$tmp"
  SIDECAR_PID=""
  SIDECAR_PORT=""

  # Ephemeral keys, inside the temp dir's lifetime: never .dev/keys.json.
  TOKEN_KEY="$(openssl rand -base64 32)"
  BODY_KEY="$(openssl rand -base64 32)"
  API_TOKEN="$(openssl rand -hex 24)"

  local started=0
  for _attempt in 1 2 3; do
    SIDECAR_PORT="$(pick_port)"
    LAGOON_DB_PATH="$tmp/lagoon.sqlite" \
    LAGOON_SERVER_PORT="$SIDECAR_PORT" \
    LAGOON_TOKEN_KEY="$TOKEN_KEY" \
    LAGOON_BODY_KEY="$BODY_KEY" \
    LAGOON_API_TOKEN="$API_TOKEN" \
      "$bin" >"$tmp/sidecar.log" 2>&1 &
    SIDECAR_PID=$!
    for _ in $(seq 1 80); do
      if healthy "$API_TOKEN" "$SIDECAR_PORT"; then started=1; break 2; fi
      if ! kill -0 "$SIDECAR_PID" 2>/dev/null; then break; fi
      sleep 0.25
    done
    kill -TERM "$SIDECAR_PID" 2>/dev/null || true
    wait "$SIDECAR_PID" 2>/dev/null || true
    SIDECAR_PID=""
  done

  if [ "$started" -ne 1 ]; then
    echo "$LAGOON_LABEL: sidecar did not become healthy; last log lines:" >&2
    tail -20 "$tmp/sidecar.log" >&2 || true
    exit 1
  fi
}
