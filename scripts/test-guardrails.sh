#!/usr/bin/env bash
# Self-test for scripts/ci-guardrails.sh.
#
# Proves the rules actually fire, especially the previously-bypassing SQL
# interpolation cases. Run from repo root: bash scripts/test-guardrails.sh
set -euo pipefail

# shellcheck source=ci-guardrails.sh
source "$(dirname "${BASH_SOURCE[0]}")/ci-guardrails.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0

ok()   { echo "  ok: $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail + 1)); }

expect_sql_caught() {
  local name="$1" file="$2"
  if sql_hits_for_files "$file" >/dev/null; then ok "$name caught"; else bad "$name NOT caught"; fi
}
expect_sql_clean() {
  local name="$1" file="$2"
  local rc=0
  sql_hits_for_files "$file" >/dev/null || rc=$?
  if [ "$rc" -eq 1 ]; then ok "$name clean"; else bad "$name unexpectedly hit (rc=$rc)"; fi
}
expect_secret_caught() {
  local name="$1" file="$2"
  if secret_hits_for_files "$file" >/dev/null; then ok "secret/$name caught"; else bad "secret/$name NOT caught"; fi
}
expect_secret_clean() {
  local name="$1" file="$2"
  local rc=0
  secret_hits_for_files "$file" >/dev/null || rc=$?
  if [ "$rc" -eq 1 ]; then ok "secret/$name clean"; else bad "secret/$name unexpectedly hit (rc=$rc)"; fi
}

echo "== SQL interpolation rule (rule 1) =="

cat > "$tmp/one_line.swift" <<'SWIFT'
let sql = "SELECT * FROM t WHERE id = \(id)"
SWIFT
cat > "$tmp/multi_line.swift" <<'SWIFT'
let sql = """
    SELECT * FROM t
    WHERE id = \(id)
    """
SWIFT
cat > "$tmp/concat.swift" <<'SWIFT'
let sql = "SELECT * FROM t WHERE id = " + "\(id)"
SWIFT
cat > "$tmp/concat_var.swift" <<'SWIFT'
let sql = "SELECT * FROM t WHERE id = " + id + " AND x = \(y)"
SWIFT
cat > "$tmp/lowercase.swift" <<'SWIFT'
let sql = "select * from t where id = \(id)"
SWIFT
cat > "$tmp/raw_string.swift" <<'SWIFT'
let sql = #"SELECT * FROM t WHERE id = \#(id)"#
SWIFT
cat > "$tmp/concat_bare.swift" <<'SWIFT'
let sql = "SELECT * FROM t WHERE id = " + id
SWIFT
cat > "$tmp/clean.swift" <<'SWIFT'
let label = "user-\(uuid)"
let sql = """
    SELECT id FROM accounts WHERE oauth_user = $1
    """
let concatClean = "prefix" + "\(value)"
let rawClean = #"hello \#(name)"#
let comment = "SELECT is only text here" // \(not interpolation)
let separate = "SELECT"
let other = x + y
SWIFT

expect_sql_caught "one-line"          "$tmp/one_line.swift"
expect_sql_caught "multi-line"        "$tmp/multi_line.swift"
expect_sql_caught "concatenation"     "$tmp/concat.swift"
expect_sql_caught "concat-with-var"   "$tmp/concat_var.swift"
expect_sql_caught "lowercase keyword" "$tmp/lowercase.swift"
expect_sql_caught "raw-string interp" "$tmp/raw_string.swift"
expect_sql_caught "bare concat"       "$tmp/concat_bare.swift"
expect_sql_clean  "clean fixture"     "$tmp/clean.swift"

# SQLBuilder.swift is the one allowed home for interpolation; the main scan
# filters it out, so the rule must still flag it.
if [ -f Sources/LagoonKit/SQLBuilder.swift ]; then
  expect_sql_caught "SQLBuilder.swift (excluded by main scan)" Sources/LagoonKit/SQLBuilder.swift
fi

echo "== Secret scan (rule 2) =="

# Fixtures are assembled from fragments so this tracked script never contains a
# full secret-shaped literal (the scan would otherwise flag itself).
aws_prefix='AKIA';        aws_body='ABCDEFGHIJKLMNOP'
gcp_prefix='AIza';        gcp_body='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijk'
gocspx_prefix='GOCSPX-';  gocspx_body='ABCDEFGHIJKLMNOPQRST'
gh_prefix='ghp_';         gh_body='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijkl'
sk_prefix='sk-';          sk_body='ABCDEFGHIJKLMNOPQRSTUVWX'
printf '%s%s\n' "$aws_prefix"    "$aws_body"    > "$tmp/aws.txt"
printf '%s%s\n' "$gcp_prefix"    "$gcp_body"    > "$tmp/gcp.txt"
printf '%s%s\n' "$gocspx_prefix" "$gocspx_body" > "$tmp/gocspx.txt"
printf '%s%s\n' "$gh_prefix"     "$gh_body"     > "$tmp/github.txt"
printf '%s%s%s\n' '-----BEGIN ' 'RSA PRIVATE KEY' '-----' > "$tmp/private_key.txt"
printf '%s%s\n' "$sk_prefix"     "$sk_body"     > "$tmp/openai.txt"
printf 'nothing secret here\n' > "$tmp/clean.txt"

expect_secret_caught "aws-access-key-id"       "$tmp/aws.txt"
expect_secret_caught "google-api-key"          "$tmp/gcp.txt"
expect_secret_caught "google-oauth-secret"     "$tmp/gocspx.txt"
expect_secret_caught "github-token"            "$tmp/github.txt"
expect_secret_caught "private-key-block"       "$tmp/private_key.txt"
expect_secret_caught "openai-key"              "$tmp/openai.txt"
expect_secret_clean  "clean fixture"           "$tmp/clean.txt"

# Never echo a full secret value.
secret_out="$(secret_hits_for_files "$tmp/aws.txt" || true)"
if printf '%s' "$secret_out" | grep -q "$aws_prefix$aws_body"; then
  bad "secret value printed in full"
else
  ok "secret value redacted"
fi

echo "== .env tracking rule (rule 4) =="

expect_env_forbidden() {
  if env_path_forbidden "$1"; then ok ".env forbidden: $1"; else bad ".env NOT forbidden: $1"; fi
}
expect_env_allowed() {
  if env_path_forbidden "$1"; then bad ".env wrongly forbidden: $1"; else ok ".env allowed: $1"; fi
}
expect_env_forbidden ".env"
expect_env_forbidden "docs/.env"
expect_env_forbidden "a/b/.env"
expect_env_forbidden "src/.env.local"
expect_env_forbidden ".env.production"
expect_env_allowed   ".env.example"
expect_env_allowed   "docs/.env.example"

echo
echo "guardrail self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
