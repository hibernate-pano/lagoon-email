#!/usr/bin/env bash
# Build the v4 product: a self-contained Lagoon.app that needs NO Apple
# development environment to build (no Xcode, no Swift toolchain) - only
# rustc/cargo and node. The Swift sidecar is NOT part of this product.
#
#   bash v4/scripts/build-product.sh
#
# Output: v4/dist/Lagoon.app
#
# Layout:
#   Contents/MacOS/Lagoon          the Tauri shell (web assets embedded)
#   Contents/MacOS/lagoon-api      the Rust backend, spawned by the shell
#   Contents/Resources/Lagoon.icns the icon
#
# Data & keys at runtime: ~/Library/Application Support/ (Lagoon-v4 dir),
# created on first launch; keys generated once, mode 0600, never printed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIST="$ROOT/v4/dist"
APP="$DIST/Lagoon.app"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: $1 is required but not on PATH" >&2; exit 1; }; }
need cargo
need rustc
need node
need npm

echo "== 1/4 web bundle =="
cd "$ROOT/v4/web"
[ -d node_modules ] || npm install
npm run build

echo "== 2/4 rust backend (lagoon-api, release) =="
cd "$ROOT/v4/crates"
cargo build --release -p lagoon-api

echo "== 3/4 rust shell (tauri, release; web assets embedded at compile time) =="
cd "$ROOT/v4/shell"
cargo build --release

echo "== 4/4 assemble Lagoon.app =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/v4/shell/target/release/lagoon-v4-shell" "$APP/Contents/MacOS/Lagoon"
cp "$ROOT/v4/crates/target/release/lagoon-api" "$APP/Contents/Resources/lagoon-api"
if [ -f "$ROOT/Support/Lagoon.icns" ]; then
  cp "$ROOT/Support/Lagoon.icns" "$APP/Contents/Resources/Lagoon.icns"
else
  echo "note: Support/Lagoon.icns missing; the app runs with a generic icon"
fi
cp "$ROOT/v4/scripts/Lagoon-Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature: keeps the build self-consistent without any developer
# certificate. A real Developer ID signature is M4 work.
if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 \
    && echo "ad-hoc signed" \
    || echo "note: codesign failed; the unsigned app still runs locally"
fi

du -sh "$APP"
echo "PRODUCT READY: $APP"
