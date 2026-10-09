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
  'Sources/LagoonServer/Networking/NIOSSLStreamTransport.swift|DeprecatedDeclaration|NIOAsyncChannel.inbound: executeThenClose cannot express a long-lived transport'
)

# ---------------------------------------------------------------------------
# warn_diagnostic_name — extract the diagnostic name from one warning line.
#
# Two output shapes are possible and BOTH must work:
#
#   1. Plain, with a trailing fixed-name marker:
#        …: warning: 'x' was deprecated [#DeprecatedDeclaration]
#      Emitted by Swift 6.2+ when diagnostics reach the terminal without the
#      hyperlink form. Not what THIS gate sees today (see the -no-color-diagnostics
#      note at the bottom of the file), but it is the shape CI logs have shown
#      and the shape the Swift 6.1 fallback below cannot see.
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
    my $line = $_;
    chomp $line;

    # Strip the fixed-width prefix so only the message remains:
    #   <file>:<line>:<col>: warning: <message>
    #
    # A line with no "warning:" marker is not a diagnostic at all and must
    # yield nothing: the old fallback regex would happily turn arbitrary text
    # ("not a diagnostic line") into the bogus class "not". That is a hole in
    # the safe direction, so the marker is required before anything else runs.
    my $msg;
    if ($line =~ /warning:\s*(.*)$/) { $msg = $1 } else { next }

    # 1. Swift 6.2+ appends the diagnostic name: `... [#DeprecatedDeclaration]`.
    #    When present it is authoritative — no guessing.
    if ($line =~ /\[#([A-Za-z_][A-Za-z0-9_]*)\]/) { print "$1\n"; next }

    # 2. OSC-8 hyperlink form (colour diagnostics on). The name sits between
    #    the opening terminator and the closing `\e]8;;`; matched directly
    #    because stripping escapes first glues the URL onto the name.
    if ($line =~ /\e\]8;;[^\e]*\e\\([A-Za-z_][A-Za-z0-9_]*)\e\]8;;/) {
      print "$1\n"; next;
    }

    # 3. Swift 6.1 and earlier print NO name at all, so the class has to be
    #    derived from the message text. Only the gated classes need to be
    #    recognised here; anything else stays "unclassified" and is reported,
    #    which is the safe direction.
    #
    #    These patterns are deliberately anchored to the wording the compiler
    #    actually emits. Verified against the real Swift 6.1.2 output captured
    #    from CI (see scripts/test-warn-gate.sh, which pins these strings).
    if ($msg =~ /^initialization of\s+(?:immutable|variable)\s+.+?\s+was never used/) {
      print "NoUsage\n"; next;
    }
    if ($msg =~ /^variable\s+.+?\s+was never used/) {
      print "NoUsage\n"; next;
    }
    if ($msg =~ /^result of call to\s+.+?\s+is unused/) {
      print "NoUsage\n"; next;
    }
    if ($msg =~ /^immutable value\s+.+?\s+was never used/) {
      print "NoUsage\n"; next;
    }
    if ($msg =~ /^no\s+.async.\s+operations occur within\s+.await./) {
      print "UnnecessaryEffectMarker\n"; next;
    }
    # The sibling of the above, and the one that hid for a whole CI generation:
    #   no calls to throwing functions occur within 'try' expression
    # Without this arm the fallback below reads its first word and returns the
    # bogus class "no", which is not in the Tests/ gate list, so a stale `try`
    # in the test tree passes the gate on any marker-less toolchain. `try` on a
    # non-throwing call is the same defect family as `await` on a non-async one:
    # the effect marker is lying about what the code does.
    if ($msg =~ /^no calls to throwing functions occur within\s+.\w+.\s+expression/) {
      print "UnnecessaryEffectMarker\n"; next;
    }
    # Deprecations on Swift 6.1 look like:
    #   'kCFStreamPropertyHTTPSProxyHost' was deprecated in macOS 10.11: ...
    #   'inbound' is deprecated: Use the executeThenClose scoped method instead.
    if ($msg =~ /^.+?\s+(?:was|is)\s+deprecated\b/) {
      print "DeprecatedDeclaration\n"; next;
    }

    # 4. Fallback: a bare identifier as the first token (old behaviour, kept
    #    for diagnostic shapes not covered above). Quoted messages start with
    #    a quote and therefore fall through to "unclassified", which the gate
    #    reports rather than silently allowing.
    if ($msg =~ /^([A-Za-z_][A-Za-z0-9_]*)\b/) { print "$1\n" }
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
  # Must be RESOLVED, not $PWD. swiftc prints the physical path in its
  # diagnostics; comparing them against a logical $PWD means a repo reached
  # through a symlink (/tmp -> /private/tmp, a linked worktree, a checkout
  # under mktemp) matches NO warning, every line falls through the `*) continue`
  # arm, and this hard gate reports ✅ over real violations — the silent no-op
  # failure mode, the mirror image of the permanently-red gate that already
  # cost this repo a day. Covered by scripts/test-warn-gate.sh.
  local repo_root="$(pwd -P)"

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

  # The flag is passed because it is documented to stabilise the diagnostic
  # text, but on this toolchain (Swift 6.4) it does NOT strip colour: the build
  # log still carries ANSI and OSC-8 hyperlink escapes (measured: 581 lines with
  # ESC bytes). Real diagnostics therefore arrive as
  #   `... [#<OSC-8>]DeprecatedDeclaration<OSC-8>]`
  # and are classified by warn_diagnostic_name's OSC-8 branch, not the plain
  # `[#Name]` branch. Both shapes are matched and both are covered by
  # scripts/test-warn-gate.sh fixtures — do NOT delete either branch on the
  # assumption that only one is live; the allowlist entry depends on the OSC-8
  # branch actually firing.
  if ! swift build --build-tests --scratch-path "$scratch" -Xswiftc -no-color-diagnostics > "$build_log" 2>&1; then
    cat "$build_log" >&2
    echo "❌ build failed" >&2
    exit 1
  fi

  run_warn_gate "$build_log"
fi
