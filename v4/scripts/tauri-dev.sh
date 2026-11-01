#!/usr/bin/env bash
# One-command dev run for the Tauri shell (M1, two backends since R3.6).
#
#   bash v4/scripts/tauri-dev.sh                       # window, backend=swift (default)
#   bash v4/scripts/tauri-dev.sh run --backend rust    # window, backend=rust
#   bash v4/scripts/tauri-dev.sh selftest              # headless, every available backend
#   bash v4/scripts/tauri-dev.sh build                 # build only
#
# The shell supervises its own backend process (v4/shell/README.md), so this
# script does NOT start one: it only checks the binary exists and forwards the
# remaining arguments to cargo run. The dev sidecar started by
# v4/scripts/sidecar-dev.sh is for the browser mode (v4/web) and is untouched.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SHELL_DIR="$ROOT/v4/shell"
MODE="${1:-run}"
shift || true

# Which backend: --backend wins, then LAGOON_V4_BACKEND, then swift.
BACKEND="${LAGOON_V4_BACKEND:-swift}"
ARGS=("$@")
index=0
while [ "$index" -lt "${#ARGS[@]}" ]; do
  argument="${ARGS[$index]}"
  case "$argument" in
    --backend)
      if [ "$((index + 1))" -lt "${#ARGS[@]}" ]; then
        BACKEND="${ARGS[$((index + 1))]}"
      fi
      ;;
    --backend=*) BACKEND="${argument#--backend=}" ;;
  esac
  index="$((index + 1))"
done

# 1. The dev sidecar script must exist (the contract's dev-time companion).
if [ ! -f "$ROOT/v4/scripts/sidecar-dev.sh" ]; then
  echo "ERROR: v4/scripts/sidecar-dev.sh is missing (expected for dev mode)" >&2
  exit 1
fi

# 2. The chosen backend binary must exist; the shell cannot build it.
case "$BACKEND" in
  rust)
    BIN="${LAGOON_V4_RUST_API:-$ROOT/v4/crates/target/debug/lagoon-api}"
    if [ ! -x "$BIN" ]; then
      echo "ERROR: lagoon-api is not built at $BIN" >&2
      echo "       build it with: cargo build -p lagoon-api   (in v4/crates)" >&2
      exit 1
    fi
    export LAGOON_V4_RUST_API="$BIN"
    ;;
  swift)
    if [ -z "${LAGOON_V4_SIDECAR:-}" ]; then
      FOUND=""
      for candidate in "$ROOT/.build/release/LagoonServerCLI" "$ROOT/.build/debug/LagoonServerCLI"; do
        if [ -x "$candidate" ]; then FOUND="$candidate"; break; fi
      done
      if [ -z "$FOUND" ]; then
        echo "ERROR: LagoonServerCLI is not built." >&2
        echo "       build the v3 sidecar with: swift build -c release --product LagoonServerCLI" >&2
        echo "       (or point LAGOON_V4_SIDECAR at an existing binary)" >&2
        exit 1
      fi
      export LAGOON_V4_SIDECAR="$FOUND"
    fi
    ;;
  *)
    echo "ERROR: unknown backend '$BACKEND' (use swift or rust)" >&2
    exit 2
    ;;
esac

echo "backend: $BACKEND"
echo "data dir: ${LAGOON_V4_DATA_DIR:-$ROOT/v4/.dev/data}"

# 3. Run.
cd "$SHELL_DIR"
case "$MODE" in
  run)      exec cargo run -- "$@" ;;
  selftest) exec cargo run -- --selftest "$@" ;;
  build)    exec cargo build ;;
  *)
    echo "usage: $0 [run|selftest|build] [--backend swift|rust]" >&2
    exit 2
    ;;
esac
