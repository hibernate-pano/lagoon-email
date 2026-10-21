#!/usr/bin/env bash
# The version lives in exactly one place: Support/VERSION.
#
# Why this check exists: the version used to be a literal in
# Support/Info.plist and nowhere else, which is fine until someone bumps the
# plist and forgets the DMG, the About box, or the release note. Then the
# product claims two different versions in two places, and a user screenshot
# becomes evidence against you.
#
# So: Support/VERSION is the source, `scripts/build-app.sh` stamps it into the
# bundle at build time, and this script refuses to let the checked-in
# Info.plist drift away from it. The plist keeps a copy because AppKit reads
# CFBundleShortVersionString from the bundle, not from a text file — the copy
# is a checked-in convenience, and this check is what keeps it honest.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION_FILE="Support/VERSION"
PLIST="Support/Info.plist"

if [[ ! -f "$VERSION_FILE" ]]; then
  echo "❌ $VERSION_FILE is missing — the version has no source of truth" >&2
  exit 1
fi

version="$(tr -d '[:space:]' < "$VERSION_FILE")"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "❌ $VERSION_FILE contains '$version', which is not a MAJOR.MINOR.PATCH version" >&2
  exit 1
fi

plist_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null || true)"
if [[ "$plist_version" != "$version" ]]; then
  echo "❌ version drift: $PLIST says '$plist_version', $VERSION_FILE says '$version'" >&2
  echo "   Fix: set CFBundleShortVersionString in $PLIST to $version (or bump $VERSION_FILE)." >&2
  exit 1
fi

# The About box reads the version out of the bundle, so the bundle has to
# carry the same one. `build-app.sh` stamps it; this is the belt to that
# braces, checked after a build.
if [[ -n "${1:-}" && -d "$1" ]]; then
  built_plist="$1/Contents/Info.plist"
  built_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$built_plist" 2>/dev/null || true)"
  if [[ "$built_version" != "$version" ]]; then
    echo "❌ built bundle says '$built_version', expected '$version'" >&2
    exit 1
  fi
fi

echo "✅ version $version (source: $VERSION_FILE, mirrored in $PLIST)"
