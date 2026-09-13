#!/usr/bin/env bash
# Build a locally runnable .app bundle from the SwiftPM executable.
# This is ad-hoc signed for local use; distribution still requires Developer ID
# signing and notarization.
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release --product Lagoon

APP="dist/Lagoon.app"
CONTENTS="$APP/Contents"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp ".build/release/Lagoon" "$CONTENTS/MacOS/Lagoon"
cp "Support/Info.plist" "$CONTENTS/Info.plist"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP"
fi

echo "Built $APP"
