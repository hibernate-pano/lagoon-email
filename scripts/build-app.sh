#!/usr/bin/env bash
# Build a locally runnable .app bundle from the SwiftPM executable.
# This is ad-hoc signed for local use; distribution still requires Developer ID
# signing and notarization.
set -euo pipefail

cd "$(dirname "$0")/.."

# `--disable-sandbox` is not optional on this machine: without it SwiftPM dies
# in the manifest step with `sandbox-exec: sandbox_apply: Operation not
# permitted`, before compiling anything. CI runners permit the sandbox and
# ignore the flag, so it is unconditional rather than probed for.
swift build --disable-sandbox -c release --product Lagoon

APP="dist/Lagoon.app"
CONTENTS="$APP/Contents"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp ".build/release/Lagoon" "$CONTENTS/MacOS/Lagoon"
cp "Support/Info.plist" "$CONTENTS/Info.plist"

# The AI provider registry (model routing + cost rates) is bundled so the
# embedded server finds it without a repo checkout; the embedded runtime
# points LAGOON_PROVIDER_CONFIG at this copy.
cp "config/providers.json" "$CONTENTS/Resources/providers.json"

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

# Signing: ad-hoc, deliberately. Signing with the local Apple Development
# identity (stable TeamIdentifier, fixes the Keychain ACL prompt loop) was
# tried on 2026-09-28 and macOS XProtect immediately flagged the bundle as
# malware and moved it to Trash on launch — personal-team certs are on a
# blocklist. The ad-hoc cost: every rebuild mints a new cdhash, so the first
# launch after a rebuild may pop Keychain consent dialogs for the lagoon.*
# secrets (click 始终允许; an unanswered dialog looks like a blank hang).
# The real fix is Developer ID signing + notarization at distribution time.
if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$APP"
fi

echo "Built $APP"
