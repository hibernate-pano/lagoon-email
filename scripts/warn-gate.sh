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
# A blanket `-warnings-as-errors` is not installed: the deprecations that are
# deliberate and documented live in the allowlist below, and failing on those
# would mean either lying in the allowlist forever or refactoring the TLS read
# pump for no user-visible gain. So this gate names the exceptions instead of
# pretending they do not exist, and fails on everything else.
#
# WHY THERE IS A SELF-TEST (scripts/test-warn-gate.sh)
# This gate shipped broken and nobody noticed for a full day. Its diagnostic-name
# parser only recognised the OSC-8 hyperlink form swiftc emits when colour is
# on (`…[#\e]8;;URL\e\Name\e]8;;\e\]`), but the build below passes
# `-no-color-diagnostics`, under which this toolchain emits plain
# `[#DeprecatedDeclaration]` with zero ESC bytes. Every warning therefore parsed
# as `(unclassified)`, the allowlist could never match anything, and the gate
# reported its OWN approved entries as unapproved — permanently red. A red gate
# gets ignored, which is the exact state this gate exists to prevent. The
# parser is now a pure function (`warn_diagnostic_name`) covered by fixtures
# that feed it both forms, so a regression in either is a test failure.
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

# ---------------------------------------------------------------------------
# warn_diagnostic_name — extract the diagnostic name from one warning line.
#
# Two output shapes are possible and BOTH must work:
#
#   1. Plain (this is what the gate actually sees today):
#        …: warning: 'x' was deprecated [#DeprecatedDeclaration]
#      Fixed-width `warning:` and a trailing `[#Name]`.
#
#   2. OSC-8 hyperlink (colour diagnostics on):
#        …: warning: 'x' was deprecated [#\e]8;;URL\e\DeprecatedDeclaration\e]8;;\e\]
#      The name sits between the hyperlink's opening terminator (`\e]8;;`) and
#      its closing `\e]8;;\e\]`. Stripping escapes first glues the URL onto the
#      name — and `URL` ends in a letter — so the boundary must be matched
#      directly.
#
# Falls back to the fixed-width column so an unfamiliar toolchain still gets a
# best-effort name instead of silently becoming `(unclassified)`. Prints
# nothing when no name can be found, so the caller can substitute its own
# placeholder.
#
# Pure function: takes stdin, prints the name, no side effects. The self-test
# sources this file and calls it directly.
warn_diagnostic_name() {
  perl -ne '
    # OSC-8 form first — it is the only place the name is not plain text.
    if (/\e\]8;;[^\e]*\e\\([A-Za-z]+)\e\]8;;/) { print "$1\n"; next }
    # Plain form: the `[#Name]` group at the end of the diagnostic.
    if (/\[#([A-Za-z]+)\]/) { print "$1\n"; next }
    # Last resort: everything after the fixed-width "warning: " column.
    if (/warning:\s(.*)$/) {
      my $rest = $1;
      $rest =~ s/\s+$//;
      # Keep only a bare identifier-ish token; drop URLs and sentences.
      if ($rest =~ m{^([A-Za-z]+)\b}) { print "$1\n" }
    }
  '
}

# warn_is_allowlisted — 0 when (file, diagnostic) matches ALLOWED, 1 otherwise.
# `file` is matched as a suffix fragment so an absolute build path still hits the
# repo-relative entry. Pure function over the global ALLOWED array.
warn_is_allowlisted() {
  local file="$1" diagnostic="$2" entry path_part rest diag_part
  for entry in "${ALLOWED[@]}"; do
    # entry is `path|diagnostic|reason` — reason kept in the file on purpose,
    # so an allowlist entry can never be a bare unexplained shrug.
    path_part="${entry%%|*}"
    rest="${entry#*|}"
    diag_part="${rest%%|*}"
    if [[ "$file" == *"$path_part"* && "$diagnostic" == "$diag_part" ]]; then
      return 0
    fi
  done
  return 1
}

# run_warn_gate — the real gate. Kept separate from the `BASH_SOURCE` guard so
# the self-test can drive it against a synthetic build log without a 2-minute
# `swift build`. Args: path to a build log on stdin-compatible file $1.
run_warn_gate() {
  local build_log="${1:?build log path required}"
  local repo_root="$PWD"

  # `file:line:col: warning: message [#DiagnosticName]`
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
  local violations=0 warning file diagnostic
  while IFS= read -r warning; do
    [ -n "$warning" ] || continue
    file="${warning%%:*}"
    diagnostic="$(printf '%s' "$warning" | warn_diagnostic_name)"
    [ -n "$diagnostic" ] || diagnostic="(unclassified)"
    if warn_is_allowlisted "$file" "$diagnostic"; then
      continue
    fi
    case "$file" in
      "$repo_root"/Sources/*) ;;
      "$repo_root"/Tests/*)
        case "$diagnostic" in
          NoUsage|UnnecessaryEffectMarker) ;;
          *) continue ;;
        esac
        ;;
      *) continue ;;
    esac
    echo "$warning" >&2
    violations=$((violations + 1))
  done < <(grep -E '^/.*warning:' "$build_log" | sort -u)

  if [ "$violations" -ne 0 ]; then
    echo >&2
    echo "❌ $violations unapproved compiler warning(s)." >&2
    echo "   Sources/: fix it, or allowlist it in ALLOWED with a reason." >&2
    echo "   Tests/: only NoUsage and UnnecessaryEffectMarker are gated." >&2
    return 1
  fi

  echo "✅ warning gate: no unapproved warnings"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  build_log="$(mktemp)"
  scratch="$(mktemp -d)"
  trap 'rm -f "$build_log"; rm -rf "$scratch"' EXIT

  # SwiftPM passes `-no-color-diagnostics` through, and on this toolchain that
  # is the whole diagnostic — the OSC-8 form warn_diagnostic_name also accepts
  # only appears with colour enabled. The flag is kept because it makes the
  # rest of the line plain and the log stable to grep.
  if ! swift build --build-tests --scratch-path "$scratch" -Xswiftc -no-color-diagnostics > "$build_log" 2>&1; then
    cat "$build_log" >&2
    echo "❌ build failed" >&2
    exit 1
  fi

  run_warn_gate "$build_log"
fi
