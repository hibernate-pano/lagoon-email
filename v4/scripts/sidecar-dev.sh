#!/usr/bin/env bash
# Start/stop the v3 Swift server as a standalone sidecar for v4 development.
#
#   bash v4/scripts/sidecar-dev.sh start     # spawn + write v4/.dev/web.env
#   bash v4/scripts/sidecar-dev.sh stop      # SIGTERM, wait, SIGKILL after 5s
#   bash v4/scripts/sidecar-dev.sh status    # exit 0 if healthy
#   bash v4/scripts/sidecar-dev.sh env       # print VITE_SIDECAR_URL / token (dev only)
#
# Keys live in v4/.dev/keys.json (0600, gitignored) and are generated once.
# The sidecar gets them through the environment — the same contract the CLI has
# always had. Nothing is written outside v4/.dev/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEV="$ROOT/v4/.dev"
DATA="$DEV/data"
KEYS="$DEV/keys.json"
ENVFILE="$DEV/web.env"
PIDFILE="$DEV/sidecar.pid"
LOG="$DEV/sidecar.log"
mkdir -p "$DATA"
chmod 700 "$DEV" "$DATA" 2>/dev/null || true

sidecar_bin() {
  if [ -n "${LAGOON_V4_SIDECAR:-}" ]; then echo "$LAGOON_V4_SIDECAR"; return; fi
  for candidate in "$ROOT/.build/release/LagoonServerCLI" "$ROOT/.build/debug/LagoonServerCLI"; do
    if [ -x "$candidate" ]; then echo "$candidate"; return; fi
  done
  echo "ERROR: LagoonServerCLI not built. Run: swift build --product LagoonServerCLI" >&2
  exit 1
}

gen_keys() {
  if [ -f "$KEYS" ]; then return; fi
  umask 077
  printf '{"tokenKey":"%s","bodyKey":"%s","apiToken":"%s"}\n' \
    "$(openssl rand -base64 32)" "$(openssl rand -base64 32)" "$(openssl rand -hex 24)" > "$KEYS"
  chmod 600 "$KEYS"
  echo "generated $KEYS"
}

read_key() {
  # No jq dependency: the file is written by this script, one key per line.
  python3 - "$KEYS" "$1" <<'PY'
import json,sys
with open(sys.argv[1]) as f: print(json.load(f)[sys.argv[2]])
PY
}

free_port() {
  python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'
}

healthy() {
  local port="$1" token="$2"
  curl -sf -m 2 -o /dev/null -H "Authorization: Bearer $token" "http://127.0.0.1:$port/healthz"
}

case "${1:-start}" in
  start)
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      echo "already running (pid $(cat "$PIDFILE"))"; exit 0
    fi
    gen_keys
    TOKEN_KEY="$(read_key tokenKey)"
    BODY_KEY="$(read_key bodyKey)"
    API_TOKEN="$(read_key apiToken)"
    PORT="$(free_port)"
    BIN="$(sidecar_bin)"
    LAGOON_DB_PATH="$DATA/lagoon.sqlite" \
    LAGOON_SERVER_PORT="$PORT" \
    LAGOON_TOKEN_KEY="$TOKEN_KEY" \
    LAGOON_BODY_KEY="$BODY_KEY" \
    LAGOON_API_TOKEN="$API_TOKEN" \
      nohup "$BIN" >"$LOG" 2>&1 &
    echo $! > "$PIDFILE"
    for _ in $(seq 1 40); do
      if healthy "$PORT" "$API_TOKEN"; then
        umask 077
        printf 'VITE_SIDECAR_URL=http://127.0.0.1:%s\nVITE_SIDECAR_TOKEN=%s\n' "$PORT" "$API_TOKEN" > "$ENVFILE"
        chmod 600 "$ENVFILE"
        echo "ready: http://127.0.0.1:$PORT (pid $(cat "$PIDFILE"), db $DATA/lagoon.sqlite)"
        exit 0
      fi
      if ! kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "sidecar exited during startup; log:" >&2; tail -20 "$LOG" >&2; exit 1
      fi
      sleep 0.25
    done
    echo "sidecar did not become healthy in 10s; log:" >&2; tail -20 "$LOG" >&2; exit 1
    ;;
  stop)
    if [ ! -f "$PIDFILE" ]; then echo "not running"; exit 0; fi
    PID="$(cat "$PIDFILE")"
    if kill -0 "$PID" 2>/dev/null; then
      kill -TERM "$PID" 2>/dev/null || true
      for _ in $(seq 1 20); do kill -0 "$PID" 2>/dev/null || break; sleep 0.25; done
      kill -KILL "$PID" 2>/dev/null || true
    fi
    rm -f "$PIDFILE"
    echo "stopped"
    ;;
  status)
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      PORT="$(sed -n 's|^VITE_SIDECAR_URL=http://127.0.0.1:\([0-9]*\)$|\1|p' "$ENVFILE" 2>/dev/null)"
      TOKEN="$(sed -n 's|^VITE_SIDECAR_TOKEN=||p' "$ENVFILE" 2>/dev/null)"
      if [ -n "$PORT" ] && healthy "$PORT" "$TOKEN"; then echo "healthy (pid $(cat "$PIDFILE"), port $PORT)"; exit 0; fi
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
