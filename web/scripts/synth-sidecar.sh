#!/usr/bin/env bash
# A throwaway sidecar seeded with the contract harness's SYNTHETIC store.
#
# Why this exists: the developer's own store (`.dev/`) is off limits - it holds
# the real mailbox, and the rule is that nothing here ever writes to it. The
# UI still has to be exercised end-to-end, so this spins a *separate* sidecar
# with its own SQLite file under web/.synth/ (gitignored), seeded by the same
# harness that produces the golden contract fixtures:
#
#   tests/contract/harness.py  ->  seed(db_path, body_key)
#
# Safety properties, inherited from the harness:
#   * the seeded account's credential blob is unreadable, so every provider path
#     fails at credential open -- no socket to any mail server is ever created;
#   * LAGOON_MAIL_PROVIDER=none, so the sidecar never even installs a provider;
#   * no real account, no real mail, nothing written outside web/.synth/.
#
#   bash web/scripts/synth-sidecar.sh start|stop|status|env
#
# Then point a dev server at it (LAGOON_WEB_ENV is read relative to the
# repository root - see web/vite.config.ts):
#   cd web && LAGOON_WEB_ENV=web/.synth/web.env npm run dev
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WEB="$ROOT/web"
SYNTH="${LAGOON_SYNTH_DIR:-$WEB/.synth}"
DB="$SYNTH/lagoon.sqlite"
KEYS="$SYNTH/keys.env"
ENVFILE="$SYNTH/web.env"
PIDFILE="$SYNTH/sidecar.pid"
LOG="$SYNTH/sidecar.log"
mkdir -p "$SYNTH"

sidecar_bin() {
  if [ -n "${LAGOON_SIDECAR_BIN:-}" ]; then echo "$LAGOON_SIDECAR_BIN"; return; fi
  local candidate="$ROOT/crates/target/debug/lagoon-api"
  if [ -x "$candidate" ]; then echo "$candidate"; return; fi
  echo "building the Rust backend (cargo build -p lagoon-api)..."
  (cd "$ROOT/crates" && cargo build --quiet -p lagoon-api)
  if [ -x "$candidate" ]; then echo "$candidate"; return; fi
  echo "ERROR: lagoon-api not built (cargo build --manifest-path crates/Cargo.toml -p lagoon-api)" >&2
  exit 1
}

free_port() {
  python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'
}

# Ephemeral per-run keys: never the developer's v4/.dev keys, never reused.
gen_keys() {
  umask 077
  : > "$KEYS"
  echo "TOKEN_KEY=$(openssl rand -base64 32)" >> "$KEYS"
  echo "BODY_KEY=$(openssl rand -base64 32)" >> "$KEYS"
  echo "API_TOKEN=$(openssl rand -hex 24)" >> "$KEYS"
  chmod 600 "$KEYS"
}

read_key() { sed -n "s/^$1=//p" "$KEYS"; }

healthy() { curl -sf -m 2 -o /dev/null -H "Authorization: Bearer $1" "http://127.0.0.1:$2/healthz"; }

wait_healthy() {
  local port="$1" token="$2" why="$3"
  for _ in $(seq 1 60); do
    if healthy "$token" "$port"; then return 0; fi
    sleep 0.25
  done
  echo "synth-sidecar: sidecar not healthy ($why); log:" >&2
  tail -20 "$LOG" >&2 || true
  return 1
}

stop_pid() {
  local pid="$1"
  kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.25; done
  kill -KILL "$pid" 2>/dev/null || true
}

case "${1:-start}" in
  start)
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      echo "already running (pid $(cat "$PIDFILE"))"; exit 0
    fi
    command -v openssl >/dev/null || { echo "openssl required" >&2; exit 1; }
    command -v python3 >/dev/null || { echo "python3 required" >&2; exit 1; }
    gen_keys
    TOKEN_KEY="$(read_key TOKEN_KEY)"
    BODY_KEY="$(read_key BODY_KEY)"
    API_TOKEN="$(read_key API_TOKEN)"
    BIN="$(sidecar_bin)"

    # Phase 1 -- let the backend create the schema (the seeder INSERTs into real tables).
    rm -f "$DB" "$DB-wal" "$DB-shm"
    PORT="$(free_port)"
    echo "phase 1: create schema on port $PORT"
    LAGOON_DB_PATH="$DB" LAGOON_SERVER_PORT="$PORT" \
    LAGOON_TOKEN_KEY="$TOKEN_KEY" LAGOON_BODY_KEY="$BODY_KEY" LAGOON_API_TOKEN="$API_TOKEN" \
    LAGOON_MAIL_PROVIDER=none \
      "$BIN" >"$LOG" 2>&1 &
    SCHEMA_PID=$!
    wait_healthy "$PORT" "$API_TOKEN" "schema"
    stop_pid "$SCHEMA_PID"
    wait "$SCHEMA_PID" 2>/dev/null || true

    # Phase 2 -- seed the synthetic account + messages + actions.
    echo "phase 2: seed via tests/contract/harness.py"
    PYTHONPATH="$ROOT/tests/contract" python3 - "$DB" "$BODY_KEY" <<'PY'
import sys
sys.dont_write_bytecode = True
import harness
harness.seed(sys.argv[1], sys.argv[2])
print("seeded", sys.argv[1])
PY

    # Phase 3 -- serve the seeded store.
    PORT="$(free_port)"
    echo "phase 3: serve on port $PORT"
    LAGOON_DB_PATH="$DB" LAGOON_SERVER_PORT="$PORT" \
    LAGOON_TOKEN_KEY="$TOKEN_KEY" LAGOON_BODY_KEY="$BODY_KEY" LAGOON_API_TOKEN="$API_TOKEN" \
    LAGOON_MAIL_PROVIDER=none \
      nohup "$BIN" >>"$LOG" 2>&1 &
    echo $! > "$PIDFILE"
    wait_healthy "$PORT" "$API_TOKEN" "serve"
    umask 077
    printf 'VITE_SIDECAR_URL=http://127.0.0.1:%s\nVITE_SIDECAR_TOKEN=%s\n' "$PORT" "$API_TOKEN" > "$ENVFILE"
    chmod 600 "$ENVFILE"
    echo "ready: http://127.0.0.1:$PORT (pid $(cat "$PIDFILE"), synthetic db $DB)"
    echo "run:  cd web && LAGOON_WEB_ENV=web/.synth/web.env npm run dev"
    ;;
  stop)
    if [ ! -f "$PIDFILE" ]; then echo "not running"; exit 0; fi
    stop_pid "$(cat "$PIDFILE")"
    rm -f "$PIDFILE"
    echo "stopped"
    ;;
  status)
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      PORT="$(sed -n 's|^VITE_SIDECAR_URL=http://127.0.0.1:\([0-9]*\)$|\1|p' "$ENVFILE")"
      TOKEN="$(sed -n 's|^VITE_SIDECAR_TOKEN=||p' "$ENVFILE")"
      if healthy "$TOKEN" "$PORT"; then echo "healthy (pid $(cat "$PIDFILE"), port $PORT, synthetic)"; exit 0; fi
      echo "running but unhealthy"; exit 1
    fi
    echo "not running"; exit 1
    ;;
  env)
    [ -f "$ENVFILE" ] || { echo "no $ENVFILE; run start first" >&2; exit 1; }
    cat "$ENVFILE"
    ;;
  *)
    echo "usage: $0 {start|stop|status|env}" >&2; exit 2;;
esac
