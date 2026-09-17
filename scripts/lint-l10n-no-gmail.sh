#!/usr/bin/env python3
"""
L10n hygiene lint (spec §6.5, corrected).

Rule: user-facing copy inside `pick(zh, en)` must not contain "Gmail" /
"gmail" except for the explicitly Gmail-only features (OAuth connect, Gmail
drafts push, provider switch, the LLM API key example).

The spec's reference regex (`grep 'Gmail|gmail'`) trips on key *names* and on
the "viaProvider" / "aiNotConfigured" copy that mentions provider names
without referencing Gmail. This script inspects only the *first* `pick()`
argument (the user-facing string) and pairs it with the key on the
declaration line, so the whitelist can be keyed by symbol rather than
substring.

Exit 0 = clean, 1 = violation(s) found, 2 = internal error.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
L10N_FILE = REPO / "Sources" / "Lagoon" / "Localization" / "L10n.swift"

# Whitelisted keys whose user-facing copy is allowed to mention Gmail.
# Keep this list tight: every entry is a feature that is intrinsically
# Gmail-specific (OAuth, drafts push, the LLM env-var example).
WHITELIST_KEYS = {
    "connectGmail",
    "pushToGmailDrafts",
    "chooseAndSendToGmail",
    "gmailProvider",
    "providerName",
    "aiNotConfigured",
}

# Match `public var name` or `public func name(...)` declarations.
DECL_RE = re.compile(
    r"public\s+(?:var|func)\s+([A-Za-z_][A-Za-z0-9_]*)"
)

# Match a `pick("...", "...")` call and capture the first argument verbatim.
# Strings are simple (no embedded escapes — true for every entry in L10n).
PICK_RE = re.compile(r'pick\(\s*"((?:[^"\\]|\\.)*)"')


def main() -> int:
    if not L10N_FILE.is_file():
        print(f"❌ {L10N_FILE} not found", file=sys.stderr)
        return 2

    text = L10N_FILE.read_text(encoding="utf-8")
    lines = text.splitlines()

    violations: list[str] = []
    current_key: str | None = None

    for line_no, line in enumerate(lines, start=1):
        decl = DECL_RE.search(line)
        if decl:
            current_key = decl.group(1)
        for m in PICK_RE.finditer(line):
            if current_key in WHITELIST_KEYS:
                continue
            arg = m.group(1)
            if "Gmail" in arg or "gmail" in arg:
                violations.append(
                    f"  {L10N_FILE.name}:{line_no}  key=`{current_key}`  "
                    f"copy=`{arg}`"
                )

    if violations:
        print("❌ L10n user-facing copy still mentions Gmail:")
        for v in violations:
            print(v)
        print("")
        print(f"Whitelist keys (allowed to say Gmail): {sorted(WHITELIST_KEYS)}")
        print("If this is a real Gmail-only feature, add its key to the whitelist.")
        return 1

    print("✅ L10n user-facing copy is clean of stale Gmail references")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
