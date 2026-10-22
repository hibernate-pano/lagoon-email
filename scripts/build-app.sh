#!/usr/bin/env bash
# Build a locally runnable .app bundle from the SwiftPM executable.
# This is ad-hoc signed for local use; distribution still requires Developer ID
# signing and notarization.
set -euo pipefail

cd "$(dirname "$0")/.."

# The version comes from Support/VERSION — the one place it is written down.
# It is stamped into the bundle's Info.plist at build time, so the shipped
# .app can never disagree with the repo about what version it is. See
# scripts/check-version.sh for the drift guard.
VERSION="$(tr -d '[:space:]' < Support/VERSION)"

swift build -c release --product Lagoon

APP="dist/Lagoon.app"
CONTENTS="$APP/Contents"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp ".build/release/Lagoon" "$CONTENTS/MacOS/Lagoon"
cp "Support/Info.plist" "$CONTENTS/Info.plist"

# Stamp the version into the bundle. PlistBuddy writes the plist in place and
# preserves everything it does not touch, so the checked-in plist stays the
# template and the bundle carries the authoritative value.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS/Info.plist"
# The build number is the git revision, so two builds of the same source
# still differ. `git describe` is unavailable in a tarball checkout, so this
# falls back to a counter-free "1" rather than failing the build.
if git rev-parse --short HEAD >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-parse --short HEAD)" "$CONTENTS/Info.plist"
fi

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

# Signing.
#
# The signature identity decides whether the user's saved secrets survive
# the next rebuild, so this is not a packaging detail:
#
#   * ad-hoc  → the designated requirement is this build's cdhash. A rebuild
#     mints a new one, the stored Keychain access lists stop matching, and
#     macOS asks a background SecurityAgent for permission it can never
#     show. The read blocks forever: the app sits on 「服务器启动中」 with
#     no window and no listening port. This is the reported hang.
#   * signed with a certificate → the requirement is
#     `identifier "com.lagoon.email" and anchor apple generic and
#     certificate leaf[subject.CN] = "…"` — stable across rebuilds, so the
#     Keychain items keep matching and nothing prompts.
#
# The old comment here said that signing with the local Apple Development
# identity made XProtect flag the bundle as malware. That was not what was
# happening: the machine carries **two** certificates with the same
# "Apple Development" name, and the one that was picked by name was
# **revoked**. An app signed with a revoked certificate is killed by the OS
# (SIGKILL) the moment it touches the Keychain — which looks like a crash
# and reads like a malware verdict. scripts/sign-app.sh now selects the
# identity by SHA-1 fingerprint and checks revocation with the system's own
# evaluator before using it.
#
# See scripts/sign-app.sh for the full reasoning; it falls back to ad-hoc
# with a loud warning when no usable certificate exists.
if command -v codesign >/dev/null 2>&1; then
  bash scripts/sign-app.sh "$APP"
else
  echo "WARNING: codesign not found — $APP is unsigned and will not run." >&2
fi

echo "Built $APP (version $VERSION)"
