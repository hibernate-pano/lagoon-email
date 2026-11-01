#!/usr/bin/env bash
# R3.3 proof: credentials sealed by this crate are v3's format, both ways, and
# v3 can use an account this crate wrote.
#
#   bash v4/crates/lagoon-api/scripts/verify-r3.3.sh
#
# 1. CryptoKit (the primitive v3's AccessTokenCipher calls) opens a blob sealed
#    by this crate, and this crate opens a blob sealed by CryptoKit.
# 2. A store created by this crate, with the fake account's credentials sealed
#    by this crate, is opened by LagoonServerCLI: /api/accounts shows the
#    account and the sync loop attempts IMAP.
# 3. Negative control: the same store with a garbage credential blob makes v3
#    park the account as "not-configured" instead. That is what proves the
#    positive case really decrypted, rather than merely failing later for the
#    same reason.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
CRATE="$ROOT/v4/crates"
V3_BIN="${LAGOON_V4_SIDECAR:-$ROOT/.build/release/LagoonServerCLI}"
BODY_KEY="$(printf '0123456789abcdef0123456789abcdef' | base64)"
TOKEN_KEY="$(printf 'fedcba9876543210fedcba9876543210' | base64)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/lagoon-r3.3.XXXXXX")"
PIDS=()
cleanup() {
  for pid in "${PIDS[@]:-}"; do kill -TERM "$pid" 2>/dev/null || true; done
  sleep 0.4
  for pid in "${PIDS[@]:-}"; do kill -KILL "$pid" 2>/dev/null || true; done
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
fail() { echo "FAIL: $*" >&2; exit 1; }

[ -x "$V3_BIN" ] || fail "missing $V3_BIN (swift build --product LagoonServerCLI)"
command -v swiftc >/dev/null || fail "swiftc is required for the CryptoKit side"

echo "== building lagoon-api, the examples and the CryptoKit tool"
(cd "$CRATE" && cargo build -p lagoon-api --offline --quiet --examples)
swiftc -O "$CRATE/lagoon-api/scripts/token-tool.swift" -o "$TMP/token-tool" 2>/dev/null

RUST_TOOL="$CRATE/target/debug/examples/token_tool"
FAKE_ACCOUNT="$CRATE/target/debug/examples/fake_account"
[ -x "$RUST_TOOL" ] || fail "missing $RUST_TOOL"
[ -x "$FAKE_ACCOUNT" ] || fail "missing $FAKE_ACCOUNT"

echo
echo "== (1a) CryptoKit opens a blob sealed by this crate"
PLAINTEXT='{"kind":"imap","username":"cross@example.invalid","authCode":"cross-code"}'
RUST_BLOB="$("$RUST_TOOL" seal "$TOKEN_KEY" "$PLAINTEXT")"
SWIFT_PLAINTEXT="$("$TMP/token-tool" open "$TOKEN_KEY" "$RUST_BLOB")"
[ "$SWIFT_PLAINTEXT" = "$PLAINTEXT" ] || fail "CryptoKit could not read the Rust blob: $SWIFT_PLAINTEXT"
echo "   ok: $SWIFT_PLAINTEXT"

echo "== (1b) this crate opens a blob sealed by CryptoKit"
SWIFT_BLOB="$("$TMP/token-tool" seal "$TOKEN_KEY" "$PLAINTEXT")"
RUST_PLAINTEXT="$("$RUST_TOOL" open "$TOKEN_KEY" "$SWIFT_BLOB")"
[ "$RUST_PLAINTEXT" = "$PLAINTEXT" ] || fail "Rust could not read the CryptoKit blob: $RUST_PLAINTEXT"
echo "   ok: $RUST_PLAINTEXT"

echo
echo "== (2) v3 opens a store written by this crate and uses its account"
RUST_DB="$TMP/rust.sqlite"
LAGOON_BODY_KEY="$BODY_KEY" "$CRATE/target/debug/lagoon-api" --migrate --db "$RUST_DB" >/dev/null
ACCOUNT_ID="$(LAGOON_BODY_KEY="$BODY_KEY" LAGOON_TOKEN_KEY="$TOKEN_KEY" "$FAKE_ACCOUNT" --db "$RUST_DB")"
echo "   account id: $ACCOUNT_ID"
PORT="$(free_port)"
LAGOON_DB_PATH="$RUST_DB" LAGOON_SERVER_PORT="$PORT" LAGOON_TOKEN_KEY="$TOKEN_KEY" \
LAGOON_BODY_KEY="$BODY_KEY" LAGOON_API_TOKEN=verify "$V3_BIN" >"$TMP/v3.log" 2>&1 &
PIDS+=("$!")
for _ in $(seq 1 160); do
  curl -sf -m 1 -o /dev/null -H 'Authorization: Bearer verify' "http://127.0.0.1:$PORT/healthz" && break
  sleep 0.25
done
curl -sf -m 1 -o /dev/null -H 'Authorization: Bearer verify' "http://127.0.0.1:$PORT/healthz" || { tail -20 "$TMP/v3.log"; fail "v3 refused the store"; }
sleep 2
curl -sS -H 'Authorization: Bearer verify' "http://127.0.0.1:$PORT/api/accounts" | python3 -c '
import json, sys
payload = json.load(sys.stdin)
match = [entry for entry in payload if entry.get("email") == "fake-r3-account@example.invalid"]
if not match:
    print("account missing from /api/accounts:", json.dumps(payload)[:400]); sys.exit(1)
print("   v3 sees the account: syncHealth=%s" % match[0]["syncHealth"]["status"])
'
if grep -q "not-configured" "$TMP/v3.log"; then
  echo "   v3 log:"; tail -20 "$TMP/v3.log"
  fail "v3 treated the Rust-sealed credentials as unreadable"
fi
echo "   ok: v3 decrypted the credentials (no not-configured in its log)"
kill -TERM "${PIDS[0]}" 2>/dev/null || true

echo
echo "== (3) negative control: a garbage credential blob is 'not-configured'"
BROKEN_DB="$TMP/broken.sqlite"
LAGOON_BODY_KEY="$BODY_KEY" "$CRATE/target/debug/lagoon-api" --migrate --db "$BROKEN_DB" >/dev/null
python3 - "$BROKEN_DB" <<'PY'
import sqlite3, sys, uuid
conn = sqlite3.connect(sys.argv[1])
conn.execute(
    "INSERT INTO accounts (id, provider, oauth_user, email, credentials, is_active, sync_status) "
    "VALUES (?, 'qq', 'broken@example.invalid', 'broken@example.invalid', ?, 1, 'ok')",
    (uuid.uuid4().bytes, b"not-a-sealed-blob"),
)
conn.commit()
conn.close()
PY
PORT="$(free_port)"
LAGOON_DB_PATH="$BROKEN_DB" LAGOON_SERVER_PORT="$PORT" LAGOON_TOKEN_KEY="$TOKEN_KEY" \
LAGOON_BODY_KEY="$BODY_KEY" LAGOON_API_TOKEN=verify "$V3_BIN" >"$TMP/v3-broken.log" 2>&1 &
PIDS+=("$!")
for _ in $(seq 1 160); do
  curl -sf -m 1 -o /dev/null -H 'Authorization: Bearer verify' "http://127.0.0.1:$PORT/healthz" && break
  sleep 0.25
done
sleep 2
if ! grep -q "not-configured" "$TMP/v3-broken.log"; then
  echo "   v3 log:"; tail -20 "$TMP/v3-broken.log"
  fail "expected v3 to report not-configured for a garbage credential blob"
fi
echo "   ok: the control reports not-configured, so check (2) is meaningful"

echo
echo "PASS: credential cipher interoperates both ways, and v3 uses a Rust-written account"
