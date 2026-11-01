#!/usr/bin/env bash
# Browser-mode development: Rust backend + Vite dev server (one command).
#
#   bash scripts/dev.sh
#
# The backend is lagoon-api (Rust). Vite proxies /api/* to it and adds the
# Bearer token, so the browser never holds one (docs/ipc-contract.md §5).
# Data & keys: .dev/ (0600, gitignored). MAIL provider is "none": development
# never talks to a real mail server; connect flows are exercised with the
# synthetic seeded store.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEV="$ROOT/.dev"
mkdir -p "$DEV/data"
chmod 700 "$DEV" 2>/dev/null || true

# 1) keys (generated once, 0600)
KEYS="$DEV/keys.json"
if [ ! -f "$KEYS" ]; then
  umask 077
  printf '{"tokenKey":"%s","bodyKey":"%s","apiToken":"%s"}\n' \
    "$(openssl rand -base64 32)" "$(openssl rand -base64 32)" "$(openssl rand -hex 24)" > "$KEYS"
  chmod 600 "$KEYS"
  echo "generated $KEYS"
fi
TOKEN_KEY=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['tokenKey'])" "$KEYS")
BODY_KEY=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['bodyKey'])" "$KEYS")
API_TOKEN=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['apiToken'])" "$KEYS")

# 2) backend (fresh store auto-migrates at startup)
cd "$ROOT/crates" && cargo build --quiet -p lagoon-api
cd "$ROOT"
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
LAGOON_DB_PATH="$DEV/data/lagoon.sqlite" \
LAGOON_SERVER_PORT="$PORT" \
LAGOON_TOKEN_KEY="$TOKEN_KEY" \
LAGOON_BODY_KEY="$BODY_KEY" \
LAGOON_API_TOKEN="$API_TOKEN" \
LAGOON_MAIL_PROVIDER=none \
  nohup crates/target/debug/lagoon-api > "$DEV/backend.log" 2>&1 &
echo $! > "$DEV/backend.pid"
for _ in $(seq 1 40); do
  curl -sf -m 2 -o /dev/null "http://127.0.0.1:$PORT/healthz" && break
  sleep 0.25
done
echo "backend ready: http://127.0.0.1:$PORT"

# 3) web dev server (proxies /api/* to the backend)
umask 077
printf 'VITE_SIDECAR_URL=http://127.0.0.1:%s\nVITE_SIDECAR_TOKEN=%s\n' "$PORT" "$API_TOKEN" > "$DEV/web.env"
cd "$ROOT/web"
[ -d node_modules ] || npm install
exec npm run dev -- --port 5173
