#!/usr/bin/env bash
# Per spec §6.6: SQL must be parameterized and secrets must not leak.
# Run from repo root: bash scripts/ci-guardrails.sh
set -euo pipefail

cd "$(dirname "$0")/.."

fail=0

# Rule 1: SQL string interpolation outside SQLBuilder.swift.
# Flag only strings that contain BOTH a SQL keyword AND Swift interpolation \(
# (plain fixture values like "u-\(uuid)" are not SQL).
if rg -n --pcre2 '"(?=[^"]*\b(?:SELECT|INSERT|UPDATE|DELETE)\b)(?=[^"]*\\\()' \
      Sources Tests 2>/dev/null \
   | rg -v "SQLBuilder.swift" > /tmp/lagoon-sql-hits.txt; then
  if [ -s /tmp/lagoon-sql-hits.txt ]; then
    echo "FAIL: SQL string interpolation detected outside SQLBuilder.swift" >&2
    cat /tmp/lagoon-sql-hits.txt >&2
    fail=1
  fi
fi

# Rule 3: raw to_vector() concatenation outside SQL comments / migrations
# Migration .sql files are schema definitions, not query building, and are
# allowed to call CREATE EXTENSION / define vector columns.
if rg -n --pcre2 'to_vector\(' Sources Tests 2>/dev/null \
   | rg -v '\.sql:' \
   | rg -v '^\s*--' > /tmp/lagoon-tovector.txt; then
  if [ -s /tmp/lagoon-tovector.txt ]; then
    echo "FAIL: raw to_vector() call found; use \$1::vector binding" >&2
    cat /tmp/lagoon-tovector.txt >&2
    fail=1
  fi
fi

# Rule 4: no tracked .env with secrets
if git ls-files 2>/dev/null | rg -q '^\.env$|^\.env\.[^e]|^\.env\.local'; then
  echo "FAIL: a filled .env file is tracked" >&2
  fail=1
fi

# Rule 6: vendor SDK imports outside Providers/ — deferred to M1 when LagoonAI lands.

if [ "$fail" -eq 0 ]; then
  echo "CI guardrails: OK"
fi
exit $fail