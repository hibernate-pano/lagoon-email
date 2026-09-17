#!/usr/bin/env bash
#
# Lint guard from spec §6.5: no `catch { }` / silent-comment catches are
# allowed inside the client view layer. All failures must surface as
# `ErrorBanner`, `ErrorCenter.shared.report(...)`, or a `throw` so the UI
# never silently swallows user actions.
#
# Run from the repo root, or wire into an Xcode build phase to fail the build
# when a new silent catch lands. Exit code 0 = clean, 1 = violation found.

set -euo pipefail

hits=$(grep -rnE 'catch \{\s*\}|catch \{ /\* (silently|non-fatal|leave the row|swallow) ' \
    Sources/Lagoon/Views/ 2>/dev/null || true)

if [[ -n "$hits" ]]; then
    echo "❌ Silent catch detected in Views (spec §6.5):"
    echo "$hits"
    echo ""
    echo "Allowed alternatives: ErrorBanner, ErrorCenter.shared.report(...), or throw."
    exit 1
fi

echo "✅ No silent catches in Sources/Lagoon/Views/"
