#!/usr/bin/env bash
# One command for browser-mode development: sidecar + web dev server.
#
#   bash v4/scripts/dev.sh
#
# The sidecar is the v3 CLI (dev-only scaffolding; see docs/ipc-contract.md §5).
# The web dev server proxies /api/* to it and adds the Bearer token, so the
# browser never holds a token.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

bash v4/scripts/sidecar-dev.sh start
bash v4/scripts/sidecar-dev.sh status

cd v4/web
if [ ! -d node_modules ]; then
  echo "== npm install =="
  npm install
fi
exec npm run dev -- --port 5173
