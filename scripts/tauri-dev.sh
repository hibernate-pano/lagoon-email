#!/usr/bin/env bash
# One-command dev run for the Tauri shell.
#
#   bash scripts/tauri-dev.sh                     # window, backend=rust
#   bash scripts/tauri-dev.sh selftest            # headless, no window
#   bash scripts/tauri-dev.sh build               # build only
#
# The shell supervises its own backend process (shell/README.md), so this
# script does NOT start one: it only checks the binary exists and forwards the
# remaining arguments to cargo run.
#
# The Swift backend is retired. `--backend swift` is refused with an
# explanation instead of silently falling back to something slower.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHELL_DIR="$ROOT/shell"
# The first argument is the mode unless it is an option: `--backend rust` on
# its own means "run", not "unknown mode --backend".
MODE="run"
if [ "$#" -gt 0 ] && [ "${1#-}" = "$1" ]; then
  MODE="$1"
  shift
fi

# Which backend: --backend wins, then LAGOON_V4_BACKEND, then rust.
BACKEND="${LAGOON_V4_BACKEND:-rust}"
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

# 1. The chosen backend binary must exist; the shell cannot build it.
case "$BACKEND" in
  rust)
    BIN="${LAGOON_V4_RUST_API:-$ROOT/crates/target/debug/lagoon-api}"
    if [ ! -x "$BIN" ]; then
      echo "ERROR: lagoon-api is not built at $BIN" >&2
      echo "       build it with: cargo build -p lagoon-api   (in crates/)" >&2
      exit 1
    fi
    export LAGOON_V4_RUST_API="$BIN"
    ;;
  swift)
    echo "ERROR: the Swift sidecar was retired with the Rust product." >&2
    echo "       Use the rust backend: bash scripts/tauri-dev.sh --backend rust" >&2
    exit 1
    ;;
  *)
    echo "ERROR: unknown backend '$BACKEND' (the only backend is rust)" >&2
    exit 2
    ;;
esac

echo "backend: $BACKEND"
echo "data dir: ${LAGOON_V4_DATA_DIR:-$ROOT/.dev/data}"

# 2. Run.
cd "$SHELL_DIR"
case "$MODE" in
  run)      exec cargo run -- "$@" ;;
  selftest) exec cargo run -- --selftest "$@" ;;
  build)    exec cargo build ;;
  *)
    echo "usage: $0 [run|selftest|build] [--backend rust]" >&2
    exit 2
    ;;
esac
