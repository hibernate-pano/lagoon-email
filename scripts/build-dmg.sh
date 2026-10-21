#!/usr/bin/env bash
# Package dist/Lagoon.app into a distributable .dmg.
#
# Why this exists: the repo had one .dmg (v3.0.1) sitting in dist/ that no
# script could reproduce. A DMG you cannot rebuild is a DMG you cannot
# re-sign, cannot re-notarize, and cannot trust — and the version on the disk
# drifts from the version in the source without anyone noticing.
#
# The layout is the one people expect from a Mac app: the app on the left,
# an /Applications alias on the right, and a window sized so the two icons
# do not sit in a sea of empty space.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="$(tr -d '[:space:]' < Support/VERSION)"
APP="dist/Lagoon.app"
DMG="dist/Lagoon-${VERSION}.dmg"
STAGE="dist/.dmg-stage"

if [[ ! -d "$APP" ]]; then
  echo "❌ $APP not found — run scripts/build-app.sh first" >&2
  exit 1
fi

# The bundle must be signed before it is packaged: `hdiutil` does not care,
# but a DMG whose payload is unsigned cannot be notarized later, and
# notarization is the only path to a DMG that Gatekeeper opens silently.
/usr/bin/codesign --verify --deep --strict "$APP" 2>/dev/null \
  || echo "WARNING: $APP is not signed (or not verifiably) — notarization will not be possible." >&2

rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/Lagoon.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
# -format UDZO: compressed, read-only. -fs HFS+ would be the old format;
# APFS is the default and what modern macOS expects.
hdiutil create \
  -volname "Lagoon ${VERSION}" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$DMG" >/dev/null

# The window layout is a nicety, not a correctness requirement: the osascript
# step needs Finder to be scriptable and can fail behind a locked screen.
# A failure here must not fail the build — the DMG is already made.
if ! osascript <<'APPLESCRIPT' 2>/dev/null
on run argv
  set dmgPath to item 1 of argv
  tell application "Finder"
    tell disk "Lagoon"
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set the bounds of container window to {200, 150, 800, 500}
      set viewOptions to the icon view options of container window
      set arrangement of viewOptions to not arranged
      set icon size of viewOptions to 96
      set position of item "Lagoon.app" of container window to {140, 180}
      set position of item "Applications" of container window to {400, 180}
      close
      open disk dmgPath
      update
      delay 2
    end tell
  end tell
end run
APPLESCRIPT
then
  echo "WARNING: could not set the DMG window layout (Finder not scriptable?) — the image is fine, the arrangement is default." >&2
fi

rm -rf "$STAGE"

echo "✅ $DMG"
echo "   sha256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo
echo "   Notarization (needs a Developer ID identity) is a separate step:"
echo "     xcrun notarytool submit \"$DMG\" --keychain-profile \"lagoon\" --wait"
echo "     xcrun stapler staple \"$DMG\""
