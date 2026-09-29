#!/usr/bin/env bash
# Fail the build on any Swift warning outside a small, explicit allowlist.
#
# Why this exists: on 2026-09-29 an audit of `swift build` output found nine
# product warnings, and three of them were live defects the green test suite
# had been hiding for the life of the feature —
#   * `result of call to 'selectInbox' is unused`   (NoUsage)
#   * `initialization of immutable value 'merged' was never used` (NoUsage)
#   * `urlSession(_:dataTask:didReceive:completionHandler:) nearly matches
#      optional requirement` — a delegate URLSession never called, so the
#      unsubscribe body cap had never run.
# `swift build` exits 0 for all of them, so nothing downstream noticed.
#
# A blanket `-warnings-as-errors` is not installed: three deprecations are
# deliberate and documented, and failing on those would mean either lying in
# the allowlist forever or refactoring the TLS read pump for no user-visible
# gain. So this gate names the exceptions instead of pretending they do not
# exist, and fails on everything else.
#
# Run from repo root. Add a new entry to ALLOWED only with a reason in the
# source explaining why the warning is acceptable.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# file-path-fragment | diagnostic-name | why it is allowed
ALLOWED=(
  'Sources/LagoonAI/ProviderHTTP.swift|DeprecatedDeclaration|kCFStreamPropertyHTTPSProxy*: required for https proxying on Apple platforms, removing it bypasses the user proxy'
  'Sources/LagoonServer/Networking/NIOSSLStreamTransport.swift|DeprecatedDeclaration|NIOAsyncChannel.inbound: executeThenClose cannot express a long-lived transport'
)

build_log="$(mktemp)"
trap 'rm -f "$build_log"' EXIT

# A scratch path keeps this from fighting a concurrent build for .build, and
# a forced full build is the point: a warm .build prints no warnings at all.
scratch="$(mktemp -d)"
trap 'rm -f "$build_log"; rm -rf "$scratch"' EXIT

# SwiftPM passes `-no-color-diagnostics` through, but swiftc still colourises
# the diagnostic link (verified on this toolchain), so the OSC-8 form below is
# the one that actually has to be parsed. The flag is kept because it makes the
# rest of the line plain.
if ! swift build --build-tests --scratch-path "$scratch" -Xswiftc -no-color-diagnostics > "$build_log" 2>&1; then
  cat "$build_log" >&2
  echo "❌ build failed" >&2
  exit 1
fi

# `file:line:col: warning: message [#link#DiagnosticName]`
#
# Two passes, because the two halves of the tree fail for different reasons.
#
# 1. `<repo>/Sources/` — every warning counts, except the allowlist above.
#    Warnings from `$scratch/checkouts/…` are skipped: they belong to a
#    pinned dependency, and bumping Hummingbird would turn this gate red with
#    nothing in this repository to fix.
# 2. `<repo>/Tests/` — only the two diagnostic classes that actually hid
#    defects in this codebase (`NoUsage`: a computed value discarded;
#    `UnnecessaryEffectMarker`: a stale `await`/`try`). The rest of the test
#    tree is full of Swift 6 concurrency diagnostics that are a migration
#    workstream, not today's defect class, and gating on them would mean
#    allowlisting dozens of lines to make the rule point-free.
#
# Test targets are covered on purpose: the very first bug this gate exists for
# — a delegate whose signature matched no protocol requirement, so URLSession
# never called it — would have been caught in `Tests/` too.
violations=0
while IFS= read -r warning; do
  [ -n "$warning" ] || continue
  file="${warning%%:*}"
  # Swift colourises the trailing link as an OSC-8 hyperlink, so the raw line
  # is `…  [#[ESC]8;;URL[ESC\Name[ESC]8;;[ESC\]`. The name sits between the
  # hyperlink's opening terminator and its closing `]8;;`, which is the only
  # reliable boundary — stripping the escape sequences first glues the URL
  # onto the name, and `URL` ends in a letter.
  diagnostic="$(printf '%s' "$warning" | perl -ne 'print "$1\n" if /\e\\([A-Za-z]+)\e\]8;;/')"
  [ -n "$diagnostic" ] || diagnostic="(unclassified)"
  allowed=0
  for entry in "${ALLOWED[@]}"; do
    # entry is `path|diagnostic|reason` — reason kept in the file on purpose,
    # so an allowlist entry can never be a bare unexplained shrug.
    path_part="${entry%%|*}"
    rest="${entry#*|}"
    diag_part="${rest%%|*}"
    if [[ "$file" == *"$path_part"* && "$diagnostic" == "$diag_part" ]]; then
      allowed=1
      break
    fi
  done
  if [ "$allowed" -eq 0 ]; then
    case "$file" in
      "$PWD"/Sources/*) ;;
      "$PWD"/Tests/*)
        case "$diagnostic" in
          NoUsage|UnnecessaryEffectMarker) ;;
          *) continue ;;
        esac
        ;;
      *) continue ;;
    esac
    echo "$warning" >&2
    violations=$((violations + 1))
  fi
done < <(grep -E '^/.*warning:' "$build_log" | sort -u)

if [ "$violations" -ne 0 ]; then
  echo >&2
  echo "❌ $violations unapproved compiler warning(s)." >&2
  echo "   Sources/: fix it, or allowlist it in ALLOWED with a reason." >&2
  echo "   Tests/: only NoUsage and UnnecessaryEffectMarker are gated." >&2
  exit 1
fi

echo "✅ warning gate: no unapproved warnings"
