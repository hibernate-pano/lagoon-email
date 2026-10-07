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
# Asserts a fixture reports exactly one kind. Used to pin that the chain rule
# does not re-report what the literal rule already caught: a single
# "SELECT ... \(x)" literal satisfies the chain union too, so without the
# parts>1 gate it would be reported twice under two names.
expect_sql_kinds() {
  local name="$1" file="$2" want="$3"
  local out
  out="$(sql_hits_for_files "$file" || true)"
  local got
  got="$(printf '%s\n' "$out" | sed -n 's/.*: \([a-z-]*\)$/\1/p' | sort -u | paste -sd, -)"
  if [ "$got" = "$want" ]; then ok "$name reports exactly [$want]"
  else bad "$name reported [$got], expected [$want]"; fi
}

expect_imap_caught() {
  local name="$1" file="$2"
  if imap_command_hits_for_files "$file" >/dev/null; then ok "imap/$name caught"; else bad "imap/$name NOT caught"; fi
}
expect_imap_clean() {
  local name="$1" file="$2"
  local rc=0
  imap_command_hits_for_files "$file" >/dev/null || rc=$?
  if [ "$rc" -eq 1 ]; then ok "imap/$name clean"; else bad "imap/$name unexpectedly hit (rc=$rc)"; fi
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

# One report, one kind. Without the parts>1 gate the chain rule re-reports this
# same literal under a second name, which would train a reader to ignore one of
# the two lines.
expect_sql_kinds "one-line reports once" "$tmp/one_line.swift" "sql-interpolation"
expect_sql_caught "one-line"          "$tmp/one_line.swift"
expect_sql_caught "multi-line"        "$tmp/multi_line.swift"
expect_sql_caught "concatenation"     "$tmp/concat.swift"
expect_sql_caught "concat-with-var"   "$tmp/concat_var.swift"
expect_sql_caught "lowercase keyword" "$tmp/lowercase.swift"
expect_sql_caught "raw-string interp" "$tmp/raw_string.swift"
expect_sql_caught "bare concat"       "$tmp/concat_bare.swift"
expect_sql_clean  "clean fixture"     "$tmp/clean.swift"

# ---------------------------------------------------------------------------
# Raw-string delimiters decide what an interpolation is.
#
# A guard that cries wolf on the repository own tests gets ignored, and this one
# did: Tests/LagoonTests/RefreshGateTests.swift holds a table of regexes used to
# spot mutating calls, and every entry ends in an escaped open-paren. Inside a
# raw string that backslash-paren is REGEX, not interpolation -- Swift only
# interpolates on backslash-HASH-paren there -- so the whole table was reported
# as interpolated SQL. The rule used to treat both spellings as interpolation.
#
# Each fixture below is one side of that boundary, and the pairs matter more
# than any single one: a "fix" that simply stopped recognising backslash-paren
# would pass the clean cases while quietly disarming plain strings.
# ---------------------------------------------------------------------------
# MUST STAY CLEAN: a raw regex that mentions a paren. No SQL, no interpolation,
# no concatenation -- this is the reported false positive, verbatim in shape.
cat > "$tmp/raw_regex_paren.swift" <<'SWIFT'
let calls = [
    #"\.insert\s*\("#,
    #"\.removeAll\s*\("#,
]
SWIFT
# MUST STAY CLEAN: a raw string with a real backslash-paren AND a SQL keyword.
# The keyword alone must not be enough, or the rule is only accidentally right.
cat > "$tmp/raw_regex_with_sql_word.swift" <<'SWIFT'
let re = #"WHERE \(column\) SELECT"#
SWIFT
# MUST STAY CAUGHT: a plain string interpolation is still an interpolation. This
# is the fixture that dies if someone "fixes" the false positive by narrowing the
# match to backslash-hash-paren only, which would disarm every ordinary string.
cat > "$tmp/plain_string_interp.swift" <<'SWIFT'
let sql = "SELECT * FROM t WHERE id = \(userInput)"
SWIFT
# MUST STAY CAUGHT: a genuine raw-string interpolation, spelled with the hash.
cat > "$tmp/raw_real_interp.swift" <<'SWIFT'
let sql = #"SELECT * FROM t WHERE id = \#(userInput)"#
SWIFT
# MUST STAY CAUGHT: two hashes demand two. Backslash-hash-paren is literal here,
# so if this ever stops being reported the hash count is no longer being honoured.
cat > "$tmp/raw_two_hash_interp.swift" <<'SWIFT'
let sql = ##"SELECT * FROM t WHERE id = \##(userInput)"##
SWIFT
# MUST STAY CAUGHT: a chain that hides the keyword in a variable still has to be
# found, and the operand it splices is an ordinary plain-string interpolation.
cat > "$tmp/chain_var_plain_interp.swift" <<'SWIFT'
let kw = "DELETE"
let sql = kw + " FROM accounts WHERE x = " + userInput
SWIFT

expect_sql_clean "raw string regex paren"          "$tmp/raw_regex_paren.swift"
expect_sql_clean "raw regex containing a SQL word" "$tmp/raw_regex_with_sql_word.swift"
expect_sql_caught "plain string interpolation"     "$tmp/plain_string_interp.swift"
expect_sql_caught "raw string real interpolation"  "$tmp/raw_real_interp.swift"
expect_sql_caught "raw string 2-hash interpolation" "$tmp/raw_two_hash_interp.swift"
expect_sql_caught "chain var + plain interpolation" "$tmp/chain_var_plain_interp.swift"
# MUST STAY CLEAN: the same split, but across a pair of raw literals joined by
# `+`. The SQL keyword and the backslash-paren live in DIFFERENT literals, so
# this only tests the adjacent-pair rule; the point is that the pair rule asks
# each literal what ITS delimiter means rather than scanning the joined text for
# a backslash-paren, which would resurrect the false positive one layer up.
cat > "$tmp/raw_pair_regex.swift" <<'SWIFT'
let a = #"SELECT * "#
let sql = a + #"FROM accounts WHERE n = \(col\)"#
SWIFT
# MUST STAY CAUGHT: the same pair shape, but with a genuine raw interpolation.
# Together with the fixture above this pins the pair rule from both sides.
cat > "$tmp/raw_pair_real_interp.swift" <<'SWIFT'
let a = #"SELECT * "#
let sql = a + #"FROM accounts WHERE x = \#(userInput)"#
SWIFT
expect_sql_clean "raw pair: regex across a + pair"   "$tmp/raw_pair_regex.swift"
expect_sql_caught "raw pair: real interp in a + pair" "$tmp/raw_pair_real_interp.swift"
# A raw MULTI-LINE string has its own tokenizer branch, because the one-hash
# raw branch also matches the first two characters of the three-quote opener and
# would mis-bound the literal. Without that branch the delimiter recorded for the
# literal is wrong, and since the delimiter is what decides whether a
# backslash-paren is an interpolation, everything downstream is judged by the
# wrong rule. These two pin it from both sides.
cat > "$tmp/raw_multiline_real_interp.swift" <<'SWIFT'
let m = #"""
    SELECT * FROM accounts WHERE id = \#(userInput)
    """#
SWIFT
cat > "$tmp/raw_multiline_regex.swift" <<'SWIFT'
let m = #"""
    let hits = lines.filter { \(line) in line.hasPrefix(".insert") }
    """#
SWIFT
expect_sql_caught "raw multi-line real interpolation" "$tmp/raw_multiline_real_interp.swift"
expect_sql_clean "raw multi-line regex paren"       "$tmp/raw_multiline_regex.swift"

# ---------------------------------------------------------------------------
# Chain-union rule: the keyword never appears inside a single literal.
#
# These are the two shapes the old scanner could not see at all. Both were
# confirmed bypasses before this rule existed:
#   C: the keyword is split across two literals ("SEL" + "ECT ..."), so no
#      literal matches \bSELECT\b and the adjacent-pair loop sees neither half.
#   D: the keyword is parked in a variable (`let kw = "DELETE"`), so it is not a
#      literal at all and the tokenizer never emits it.
# Both are caught only because the rule evaluates the UNION of the chain.
# ---------------------------------------------------------------------------
cat > "$tmp/chain_split_keyword.swift" <<'SWIFT'
let sql = "SEL" + "ECT * FROM accounts WHERE x = " + userInput
SWIFT
cat > "$tmp/chain_keyword_in_var.swift" <<'SWIFT'
let kw = "DELETE"
let sql = kw + " FROM accounts WHERE x = " + userInput
SWIFT
cat > "$tmp/chain_split_three.swift" <<'SWIFT'
let sql = "SEL" + "ECT * " + "FROM accounts WHERE x = " + userInput
SWIFT
expect_sql_caught "chain keyword split across literals" "$tmp/chain_split_keyword.swift"
expect_sql_caught "chain keyword parked in a variable"   "$tmp/chain_keyword_in_var.swift"
expect_sql_caught "chain keyword split over 3 literals"   "$tmp/chain_split_three.swift"

# The negative half. A rule that only proved it can catch things proves nothing:
# these are the shapes that made an earlier, looser draft of this rule report
# 11 false positives on the real tree. Each one is safe, and each must stay
# silent or the rule is useless.
cat > "$tmp/chain_clean_no_interp.swift" <<'SWIFT'
// Parameterized multi-line SQL assembled from a column constant plus a
// boolean suffix. No user value reaches the string; this is the shape that
// AccountStore/MessageStore actually use.
let columns = """
    SELECT id, provider, oauth_user, email
    FROM accounts
    """
let sql = columns + "\n            WHERE is_active = TRUE"
SWIFT
cat > "$tmp/chain_clean_multi_statement.swift" <<'SWIFT'
// Two independent statements whose literals are separated by real code, not by
// a `+` expression. A gap that crosses a newline is not a concatenation.
func run(db: DB) throws {
    try db.execute(sql: "SELECT id FROM accounts WHERE id = ?", arguments: [a])
    try db.execute(sql: "DELETE FROM accounts WHERE id = ?", arguments: [b])
}
SWIFT
cat > "$tmp/chain_clean_no_context_marker.swift" <<'SWIFT'
// A chain whose union carries a SQL keyword but NO context marker is not a
// statement, so the chain rule must stay silent. The operands are on separate
// lines so the pre-existing same-line bare-concat rule cannot claim it either:
// what is pinned here is specifically the chain rule's FROM|WHERE|VALUES|SET
// gate, which is the thing that keeps this from becoming a false positive.
let sql = "delete"
    + " everything the user typed"
SWIFT
cat > "$tmp/chain_clean_keyword_only_var.swift" <<'SWIFT'
// A bare keyword constant with no chain at all -- the shape of
// IMAPClient.selectVerb. It must stay silent under BOTH rules.
static let selectVerb = "SELECT"
let q = "\(Self.selectVerb) \(quoted)"
SWIFT
# The next two are MUTATION-VERIFIED, which is the only reason to trust them.
# Each was checked by breaking the implementation on purpose and confirming the
# fixture turns red; a negative fixture that no mutation can turn red is
# decoration. See the note above the fixture bodies for what each one kills.
cat > "$tmp/chain_neg_no_context_marker.swift" <<'SWIFT'
// Kills the FROM|WHERE|VALUES|SET gate. The union carries a SQL keyword AND a
// genuinely spliced runtime value, but no context marker, so it is not a
// statement. Dropping the $CTX gate from the rule makes this file report.
//
// The trailing `+ userTyped` is what makes this fixture bite: with only
// `v + "..."` the chain has no spliced value, so the $splices gate would keep
// it quiet even with $CTX removed, and the fixture would prove nothing.
let v = "delete"
let sql = v + " everything " + userTyped
SWIFT
cat > "$tmp/chain_neg_no_splice.swift" <<'SWIFT'
// Kills the value-splice gate. Union = "SELECT * FROM accounts WHERE id = 1":
// it has BOTH a SQL keyword and a context marker, but not one runtime value is
// spliced in -- the operands are a constant and a literal. Dropping the
// $splices gate from the rule makes this file report, which is why the gate has
// to exist: without it every parameterized SQL built from a constant would fire.
let prefix = "SELECT * FROM"
let sql = prefix + " accounts WHERE id = 1"
SWIFT
expect_sql_clean "chain: parameterized multi-line SQL"   "$tmp/chain_clean_no_interp.swift"
expect_sql_clean "chain: statements split by code"        "$tmp/chain_clean_multi_statement.swift"
expect_sql_clean "chain: keyword without context marker"  "$tmp/chain_clean_no_context_marker.swift"
expect_sql_clean "chain: bare keyword constant (selectVerb)" "$tmp/chain_clean_keyword_only_var.swift"
expect_sql_clean "chain NEG(mutation): no context marker" "$tmp/chain_neg_no_context_marker.swift"
expect_sql_clean "chain NEG(mutation): no value spliced"  "$tmp/chain_neg_no_splice.swift"

# SQLBuilder.swift is the one allowed home for interpolation; the main scan
# filters it out, so the rule must still flag it.
if [ -f Sources/LagoonKit/SQLBuilder.swift ]; then
  expect_sql_caught "SQLBuilder.swift (excluded by main scan)" Sources/LagoonKit/SQLBuilder.swift
fi

echo "== IMAP command assembly rule (rule 1b) =="

# The channel: `execute("...")` writes the literal straight to the socket, so an
# interpolated value that is not RFC 3501 quoted can end the command with CRLF
# and start a second one against a real mailbox.
cat > "$tmp/imap_unquoted_store.swift" <<'SWIFT'
func store(uid: Int64, _ userControlled: String) async throws {
    _ = try await connection.execute("STORE \(userControlled)")
}
SWIFT
cat > "$tmp/imap_unquoted_create.swift" <<'SWIFT'
func createMailbox(_ name: String) async throws {
    _ = try await connection.execute("CREATE \(name)")
}
SWIFT
# Kills the paren-depth-aware literal scan. An interpolation whose expression
# contains a string literal puts an UNESCAPED quote inside the command literal.
# A flat "quote ends the literal" matcher splits the line there, so the command
# verb ends up in one fragment and the unsafe operand that follows lands in
# another fragment that no longer looks like a command at all -- the operand
# becomes invisible. Confirmed: with the depth test removed this fixture is
# reported clean, which is exactly the blind spot the rule exists to close.
cat > "$tmp/imap_nested_quote_operand.swift" <<'SWIFT'
func run(_ flag: (String) -> String, _ userTyped: String) async throws {
    _ = try await connection.execute("CREATE \(flag("x", userTyped)) EXTRA \(userTyped)")
}
SWIFT
expect_imap_caught "operand after a nested quoted interpolation" "$tmp/imap_nested_quote_operand.swift"

expect_imap_caught "STORE with a raw string operand" "$tmp/imap_unquoted_store.swift"
expect_imap_caught "CREATE with a raw string operand" "$tmp/imap_unquoted_create.swift"

# The negative half. Every one of these is a real shape in IMAPClient.swift, and
# each is safe for a reason the rule must be able to see:
cat > "$tmp/imap_clean_quoted.swift" <<'SWIFT'
func move(uid: Int64, to mailbox: String) async throws {
    let quoted = try Self.quoted(mailbox)
    _ = try await connection.execute("UID MOVE \(uid) \(quoted)")
}
SWIFT
cat > "$tmp/imap_clean_uid_flags.swift" <<'SWIFT'
func store(uid: Int64, add: [String] = [], remove: [String] = []) async throws {
    if !add.isEmpty {
        _ = try await connection.execute("UID STORE \(uid) +FLAGS (\(add.joined(separator: " ")))")
    }
}
SWIFT
cat > "$tmp/imap_clean_base64.swift" <<'SWIFT'
func login(username: String, authCode: String) async throws {
    let quotedUser = try Self.quoted(username)
    let payload = Data("\0\(username)\0\(authCode)".utf8).base64EncodedString()
    _ = try await connection.execute("AUTHENTICATE PLAIN \(payload)")
}
SWIFT
cat > "$tmp/imap_clean_select_literal.swift" <<'SWIFT'
// IMAPClient.swift:93, verbatim in shape. A pure literal with no interpolation
// is what keeps the SQL rule from claiming IMAP SELECT is a query; neither rule
// may touch it.
static let selectVerb = "SELECT"
func select(_ mailbox: String) async throws -> IMAPSelected {
    let quoted = try Self.quoted(mailbox)
    let responses = try await connection.execute("\(Self.selectVerb) \(quoted)")
}
SWIFT
# These two pin the shape-based exemptions. Without them the exemptions are
# untested code that only happens to be right today: a name-based draft of this
# rule passed while carrying an allowlist nobody was checking.
#
# Kills the `.joined(...)` exemption: the flag list is a token list, so a
# `+` or CRLF inside a flag element is not something this call site can produce
# (IMAPProvider only ever passes "\Seen" / "\Deleted").
cat > "$tmp/imap_clean_joined_var.swift" <<'SWIFT'
func fetchHeaders(uids: [Int64], fields: [String]) async throws -> [Header] {
    let fieldList = fields.joined(separator: " ")
    let set = uids.map(String.init).joined(separator: ",")
    let responses = try await connection.execute(
        "UID FETCH \(set) (UID FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS (\(fieldList))])"
    )
}
SWIFT
# Kills the numeric-parameter exemption: `octets` and `uid` are integers, and an
# integer cannot carry a quote or a CRLF.
cat > "$tmp/imap_clean_numeric_param.swift" <<'SWIFT'
func fetchTextSnippets(uid: Int64, uids: [Int64], octets: Int = 512) async throws {
    let set = uids.map(String.init).joined(separator: ",")
    let responses = try await connection.execute("UID FETCH \(set) (UID BODY.PEEK[]<0.\(octets)>)")
    let more = try await connection.execute("UID STORE \(uid) +FLAGS (\\Seen)")
}
SWIFT
expect_imap_clean "joined()/numeric-param exemptions" "$tmp/imap_clean_joined_var.swift"
expect_imap_clean "numeric-param exemption"           "$tmp/imap_clean_numeric_param.swift"
# The next three each kill exactly ONE line of the exemption list. Without them
# the exemption list is untested code that merely happens to be right today --
# which is how a name-based draft of this rule passed while carrying an
# allowlist nobody was checking. Each was confirmed by deleting that line and
# watching exactly this fixture start reporting.
#
# The first is also the reason the rule uses a paren-depth-aware literal scan:
# a flat quote matcher truncates this very line at the quote before the space in
# `separator: " "`, so the operand would never be examined at all.
cat > "$tmp/imap_clean_inline_joined.swift" <<'SWIFT'
func store(uid: Int64, add: [String]) async throws {
    _ = try await connection.execute("UID STORE \(uid) +FLAGS (\(add.joined(separator: " ")))")
}
SWIFT
# Kills the `.count` exemption: an integer byte length cannot carry a quote.
cat > "$tmp/imap_clean_inline_count.swift" <<'SWIFT'
func append(mailbox: String, message: Data) async throws {
    _ = try await connection.execute("APPEND \(quotedMailbox) {\(message.count)}")
}
SWIFT
# Kills the UID/tag-name exemption: the command tag is a generated counter token.
cat > "$tmp/imap_clean_tag_prefix.swift" <<'SWIFT'
func noop(tag: String) async throws {
    _ = try await connection.execute("\(tag) FETCH 1:* (UID)")
}
SWIFT
# Kills the inline `.base64EncodedString()` exemption: the base64 alphabet
# cannot contain CR, LF or a quote, so an encoded argument cannot end the line.
cat > "$tmp/imap_clean_inline_base64.swift" <<'SWIFT'
func fetch(uid: Int64, blob: Data) async throws {
    _ = try await connection.execute("UID FETCH \(uid) (BODY.PEEK[]<0.\(blob.base64EncodedString())>)")
}
SWIFT
expect_imap_clean "inline .joined() operand"   "$tmp/imap_clean_inline_joined.swift"
expect_imap_clean "inline .base64EncodedString()" "$tmp/imap_clean_inline_base64.swift"
expect_imap_clean "inline .count operand"      "$tmp/imap_clean_inline_count.swift"
expect_imap_clean "command-tag prefix operand" "$tmp/imap_clean_tag_prefix.swift"
expect_imap_clean "quoted() operand"          "$tmp/imap_clean_quoted.swift"
expect_imap_clean "uid + joined flag list"     "$tmp/imap_clean_uid_flags.swift"
expect_imap_clean "base64 payload"             "$tmp/imap_clean_base64.swift"
expect_imap_clean "selectVerb literal"        "$tmp/imap_clean_select_literal.swift"

# The two rules must not claim each other's territory: the selectVerb file is
# clean under rule 1 as well, which is the whole reason that constant exists.
expect_sql_clean "selectVerb under rule 1 too" "$tmp/imap_clean_select_literal.swift"

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

# A guardrail that cannot fail is worse than no guardrail: it reads like
# coverage while checking nothing. The silent-catch lint's first version was
# a line-based grep that reported success over 47 `catch {` occurrences
# without examining one, so it ships with a fixture that proves it fires.
# The fixture is scanned by the shipped parser (a copy of the real script
# with only its input glob swapped), not by a second implementation.
echo "== silent-catch lint fires (scripts/lint-no-silent-catch.sh) =="

silent_fixture="$(mktemp -d)"
lint_copy="$(mktemp)"
cleanup_fixtures() { rm -rf "$silent_fixture" "$lint_copy"; }
trap cleanup_fixtures EXIT

cat > "$silent_fixture/Fixture.swift" <<'FIXTURE'
struct F {
    func swallowed() {
        do { try a() } catch {
        }
    }
    func swallowedWithComment() {
        do { try a() } catch {
            // best effort
        }
    }
    func handledInline() {
        do { try a() } catch { return }
    }
    func handled() {
        do { try a() } catch {
            banner = .init()
        }
    }
    // The single-line empty catch is the shape spec §6.5 actually names, and
    // the parser used to pass it: `$tail` starts at `catch`, so the enclosing
    // `}` in `} catch { }` left the net depth at -1 rather than 0 and the
    // "body ends on this line" branch never ran. These three pin it.
    func swallowedInline() { do { try a() } catch { } }
    func swallowedInlineComment() { do { try a() } catch { /* best effort */ } }
    func handledInlineAssign() { do { try a() } catch { banner = nil } }
}
FIXTURE

sed "s#Sources/Lagoon/Views/\*\.swift#${silent_fixture}/*.swift#" \
    scripts/lint-no-silent-catch.sh > "$lint_copy"
lint_out="$(bash "$lint_copy" 2>&1 || true)"

expect_flagged() {
  if printf '%s' "$lint_out" | grep -q "Fixture.swift:$1"; then
    ok "silent catch reported at fixture line $1"
  else
    bad "silent catch NOT reported at fixture line $1"
  fi
}
expect_not_flagged() {
  if printf '%s' "$lint_out" | grep -q "Fixture.swift:$1"; then
    bad "fixture line $1 wrongly reported as a silent catch"
  else
    ok "fixture line $1 correctly not reported"
  fi
}
expect_flagged 3
expect_flagged 7
expect_not_flagged 10
expect_not_flagged 13
expect_flagged 23
expect_flagged 24
expect_not_flagged 25

echo
echo "guardrail self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
