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

# Copy the .icns into Resources/ so Finder / Dock / cmd-tab pick it up.
# The iconset is gitignored (it's a 10-PNG build artefact); `build-icon.py`
# regenerates it from `scripts/build-icon.py`. If the .icns is missing the
# app falls back to the default Xcode white document icon — a build-time
# warning makes the failure obvious rather than silent.
if [[ -f "Support/Lagoon.icns" ]]; then
  cp "Support/Lagoon.icns" "$CONTENTS/Resources/Lagoon.icns"
else
  echo "WARNING: Support/Lagoon.icns missing — run scripts/build-icon.py first" >&2
fi

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP"
fi

echo "Built $APP"
