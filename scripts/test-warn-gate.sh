#!/usr/bin/env bash
# Self-test for scripts/warn-gate.sh.
#
# WHY THIS FILE EXISTS
# The gate shipped broken and stayed broken for a day. Its diagnostic parser
# recognised only swiftc's OSC-8 hyperlink form, while the gate's own build
# passed `-no-color-diagnostics` — which emits plain `[#Name]`. Every warning
# parsed as `(unclassified)`, so the ALLOWLIST matched nothing and the gate
# reported its own approved entries as violations. It was permanently red.
#
# `scripts/lint-no-silent-catch.sh` had already been rewritten for the same
# reason ("a guardrail that always passes is worse than no guardrail" — and one
# that is always red is equally useless, because people learn to ignore it).
# So the rule here is: every guardrail that can silently stop discriminating
# needs a fixture that proves it still discriminates.
#
# These tests drive the SHIPPED functions from warn-gate.sh (sourced, not
# reimplemented), so a fix that only touched a copy here cannot make them pass.
#
# Run from repo root: bash scripts/test-warn-gate.sh
set -euo pipefail

# shellcheck source=warn-gate.sh
source "$(dirname "${BASH_SOURCE[0]}")/warn-gate.sh"

cd "$(dirname "${BASH_SOURCE[0]}")/.."
repo_root="$PWD"

pass=0
fail=0

ok()  { echo "  ok: $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $1"; fail=$((fail + 1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ---------------------------------------------------------------------------
echo "== diagnostic-name parser (both output shapes) =="

# The plain form is what the gate ACTUALLY receives today. If this ever stops
# parsing, the allowlist silently dies again — this is the regression test for
# the exact production bug.
name="$(printf '%s\n' \
  "/r/Sources/LagoonAI/ProviderHTTP.swift:31:17: warning: 'kCFStreamPropertyHTTPSProxyHost' was deprecated in macOS 10.11: Use NSURLSession API for http requests [#DeprecatedDeclaration]" \
  | warn_diagnostic_name)"
if [ "$name" = "DeprecatedDeclaration" ]; then
  ok "plain [#Name] form parsed (the production shape)"
else
  bad "plain [#Name] form parsed — got '$name', want 'DeprecatedDeclaration'"
fi

# The caret-annotation line the compiler also prints. It carries the same
# trailing marker and must not produce a second, different name.
name="$(printf '%s\n' \
  "   |                 \`- warning: 'x' was deprecated [#DeprecatedDeclaration]" \
  | warn_diagnostic_name)"
if [ "$name" = "DeprecatedDeclaration" ]; then
  ok "caret-annotation line parsed"
else
  bad "caret-annotation line parsed — got '$name', want 'DeprecatedDeclaration'"
fi

# The OSC-8 form. Built with printf escapes so the fixture holds real ESC bytes
# exactly as swiftc emits them.
osc8_line="$(printf '/r/Sources/A.swift:1:1: warning: x [#\033]8;;https://e\033\\DeprecatedDeclaration\033]8;;\033\\]')"
name="$(printf '%s\n' "$osc8_line" | warn_diagnostic_name)"
if [ "$name" = "DeprecatedDeclaration" ]; then
  ok "OSC-8 hyperlink form parsed"
else
  bad "OSC-8 hyperlink form parsed — got '$name', want 'DeprecatedDeclaration'"
fi

# The two other diagnostic classes the Tests/ pass gates on.
name="$(printf '%s\n' "/r/Sources/A.swift:9:9: warning: initialization of immutable value 'x' was never used [#NoUsage]" | warn_diagnostic_name)"
if [ "$name" = "NoUsage" ]; then ok "NoUsage parsed"; else bad "NoUsage parsed — got '$name'"; fi

name="$(printf '%s\n' "/r/Tests/A.swift:9:9: warning: no 'async' operations occur within 'await' expression [#UnnecessaryEffectMarker]" | warn_diagnostic_name)"
if [ "$name" = "UnnecessaryEffectMarker" ]; then ok "UnnecessaryEffectMarker parsed"; else bad "UnnecessaryEffectMarker parsed — got '$name'"; fi

# A line with no marker at all must fall back to the fixed-width column rather
# than silently becoming empty (which the caller would relabel "(unclassified)"
# and then let through the Tests/ branch).
name="$(printf '%s\n' "/r/Sources/A.swift:1:1: warning: result of call to 'x' is unused" | warn_diagnostic_name)"
if [ "$name" = "result" ]; then
  ok "marker-less line falls back to the warning: column"
else
  bad "marker-less line falls back to the warning: column — got '$name'"
fi

# A totally unparseable line yields nothing, so the caller substitutes its own
# placeholder. Must not print garbage.
name="$(printf '%s\n' "not a diagnostic line at all" | warn_diagnostic_name)"
if [ -z "$name" ]; then ok "unparseable line yields empty (caller supplies placeholder)"; else bad "unparseable line yields empty — got '$name'"; fi

# ---------------------------------------------------------------------------
echo "== allowlist matching =="

# The regression itself: the two real, currently-approved warnings must be
# allowlisted. Before the parser fix BOTH of these failed.
if warn_is_allowlisted "$repo_root/Sources/LagoonAI/ProviderHTTP.swift" "DeprecatedDeclaration"; then
  ok "ProviderHTTP deprecation is allowlisted (this failed before the fix)"
else
  bad "ProviderHTTP deprecation is allowlisted (this failed before the fix)"
fi
if warn_is_allowlisted "$repo_root/Sources/LagoonServer/Networking/NIOSSLStreamTransport.swift" "DeprecatedDeclaration"; then
  ok "NIOSSLStreamTransport deprecation is allowlisted"
else
  bad "NIOSSLStreamTransport deprecation is allowlisted"
fi

# A warning in an allowlisted FILE but a different diagnostic must NOT pass.
# Otherwise the allowlist becomes a whole-file exemption.
if warn_is_allowlisted "$repo_root/Sources/LagoonAI/ProviderHTTP.swift" "NoUsage"; then
  bad "same file + different diagnostic still rejected"
else
  ok "same file + different diagnostic still rejected"
fi

# A different file with an allowlisted diagnostic must NOT pass.
if warn_is_allowlisted "$repo_root/Sources/LagoonServer/Routes/MessageRoutes.swift" "DeprecatedDeclaration"; then
  bad "different file + same diagnostic still rejected"
else
  ok "different file + same diagnostic still rejected"
fi

# ---------------------------------------------------------------------------
echo "== gate verdicts (synthetic build log) =="

# Only the two allowlisted warnings → clean, exit 0.
cat > "$tmp/clean.log" <<LOG
$repo_root/Sources/LagoonAI/ProviderHTTP.swift:31:17: warning: 'kCFStreamPropertyHTTPSProxyHost' was deprecated in macOS 10.11: Use NSURLSession API for http requests [#DeprecatedDeclaration]
$repo_root/Sources/LagoonAI/ProviderHTTP.swift:32:17: warning: 'kCFStreamPropertyHTTPSProxyPort' was deprecated in macOS 10.11: Use NSURLSession API for http requests [#DeprecatedDeclaration]
$repo_root/Sources/LagoonServer/Networking/NIOSSLStreamTransport.swift:98:48: warning: 'inbound' is deprecated: Use the executeThenClose scoped method instead. [#DeprecatedDeclaration]
LOG
rc=0
run_warn_gate "$tmp/clean.log" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then
  ok "only-allowlisted warnings → exit 0 (THE production failure: this returned 1)"
else
  bad "only-allowlisted warnings → exit 0 (THE production failure) — got exit $rc"
fi

# A genuinely new Sources/ warning → dirty, exit 1, and it must be ECHOED so the
# developer can see what to fix.
cat > "$tmp/dirty.log" <<LOG
$repo_root/Sources/LagoonServer/Routes/MessageRoutes.swift:12:9: warning: variable 'x' was never used [#NoUsage]
LOG
rc=0
out="$(run_warn_gate "$tmp/dirty.log" 2>&1)" || rc=$?
if [ "$rc" -eq 1 ]; then
  ok "new Sources/ warning → exit 1"
else
  bad "new Sources/ warning → exit 1 — got exit $rc"
fi
if printf '%s' "$out" | grep -q 'MessageRoutes.swift:12:9'; then
  ok "violating warning is echoed with file:line:col"
else
  bad "violating warning is echoed with file:line:col"
fi

# A new warning in a dependency checkout (outside Sources/ and Tests/) must be
# IGNORED — bumping Hummingbird must not turn this gate red.
cat > "$tmp/dependency.log" <<LOG
/tmp/scratch/checkouts/hummingbird/Sources/HB/Response.swift:5:5: warning: something deprecated [#DeprecatedDeclaration]
LOG
rc=0
run_warn_gate "$tmp/dependency.log" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then
  ok "dependency-checkout warning ignored"
else
  bad "dependency-checkout warning ignored — got exit $rc"
fi

# Tests/: only the two defect-class diagnostics are gated; a Swift-concurrency
# diagnostic there is a migration workstream and must not fail the build.
cat > "$tmp/tests_other.log" <<LOG
$repo_root/Tests/LagoonTests/Foo.swift:3:3: warning: sending 'x' risks causing data races [#Sendable]
LOG
rc=0
run_warn_gate "$tmp/tests_other.log" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then
  ok "Tests/ non-gated diagnostic ignored"
else
  bad "Tests/ non-gated diagnostic ignored — got exit $rc"
fi

cat > "$tmp/tests_gated.log" <<LOG
$repo_root/Tests/LagoonTests/Foo.swift:3:3: warning: initialization of immutable value 'y' was never used [#NoUsage]
LOG
rc=0
run_warn_gate "$tmp/tests_gated.log" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 1 ]; then
  ok "Tests/ NoUsage gated → exit 1"
else
  bad "Tests/ NoUsage gated → exit 1 — got exit $rc"
fi

# Empty log → clean.
: > "$tmp/empty.log"
rc=0
run_warn_gate "$tmp/empty.log" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then
  ok "empty log → exit 0"
else
  bad "empty log → exit 0 — got exit $rc"
fi

# ---------------------------------------------------------------------------
echo
if [ "$fail" -ne 0 ]; then
  echo "❌ warn-gate self-test: $pass passed, $fail FAILED" >&2
  exit 1
fi
echo "✅ warn-gate self-test: $pass passed, 0 failed"
