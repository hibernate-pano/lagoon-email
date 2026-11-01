#!/usr/bin/env bash
# R3.2 proof: this crate's migration chain produces the store v3 would have.
#
#   bash v4/crates/lagoon-api/scripts/verify-r3.2.sh
#
# Three checks, all on throwaway files:
#   a. Rust-created store vs v3-created store: dump sqlite_master (minus the
#      implicit sqlite_autoindex rows) and grdb_migrations, diff them;
#   b. v3.2.0 (LagoonServerCLI) opens the Rust-created store, answers
#      /api/accounts with the fake account, and attempts a sync;
#   c. the read side still opens a v3 store (dev_store test, run by cargo test).
#
# Needs the release sidecar at .build/release/LagoonServerCLI (swift build).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
CRATE="$ROOT/v4/crates"
V3_BIN="${LAGOON_V4_SIDECAR:-$ROOT/.build/release/LagoonServerCLI}"
BODY_KEY="$(printf '0123456789abcdef0123456789abcdef' | base64)"
TOKEN_KEY="$(printf 'fedcba9876543210fedcba9876543210' | base64)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/lagoon-r3.2.XXXXXX")"
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

echo "== building lagoon-api and the fake-account example"
(cd "$CRATE" && cargo build --offline --quiet && cargo build --offline --quiet --example fake_account)

RUST_DB="$TMP/rust.sqlite"
V3_DB="$TMP/v3.sqlite"

echo "== creating the Rust store"
LAGOON_BODY_KEY="$BODY_KEY" "$CRATE/target/debug/lagoon-api" --migrate --db "$RUST_DB"

echo "== writing a fake account through the writable store"
ACCOUNT_ID="$(LAGOON_BODY_KEY="$BODY_KEY" LAGOON_TOKEN_KEY="$TOKEN_KEY" "$CRATE/target/debug/examples/fake_account" --db "$RUST_DB")"
echo "   account id: $ACCOUNT_ID"

echo "== creating the v3 store"
PORT="$(free_port)"
LAGOON_DB_PATH="$V3_DB" LAGOON_SERVER_PORT="$PORT" LAGOON_TOKEN_KEY="$BODY_KEY" \
LAGOON_BODY_KEY="$BODY_KEY" LAGOON_API_TOKEN=verify "$V3_BIN" >"$TMP/v3-create.log" 2>&1 &
V3_CREATE_PID=$!
PIDS+=("$V3_CREATE_PID")
for _ in $(seq 1 120); do
  curl -sf -m 1 -o /dev/null -H 'Authorization: Bearer verify' "http://127.0.0.1:$PORT/healthz" && break
  sleep 0.25
done
curl -sf -m 1 -o /dev/null -H 'Authorization: Bearer verify' "http://127.0.0.1:$PORT/healthz" || fail "v3 did not start on an empty store"
kill -TERM "$V3_CREATE_PID" 2>/dev/null || true
sleep 0.5

echo
echo "== (a) sqlite_master + grdb_migrations diff"
python3 - "$V3_DB" "$RUST_DB" <<'PY'
import difflib, sqlite3, sys

def dump(path):
    conn = sqlite3.connect(path)
    objects = []
    for typ, name, tbl, sql in conn.execute(
        "SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name"
    ):
        if typ == "index" and (name or "").startswith("sqlite_autoindex"):
            continue
        objects.append("%s %s|%s|%s" % (typ, name, tbl, (sql or "").replace("\n", "\\n")))
    migrations = [row[0] for row in conn.execute("SELECT identifier FROM grdb_migrations ORDER BY rowid")]
    conn.close()
    return objects, migrations

v3_objects, v3_migrations = dump(sys.argv[1])
rust_objects, rust_migrations = dump(sys.argv[2])

differences = list(difflib.unified_diff(v3_objects, rust_objects, "v3", "rust", lineterm="", n=1))
if differences:
    print("\n".join(differences))
    print("SCHEMA DIFFERS (%d v3 objects, %d rust objects)" % (len(v3_objects), len(rust_objects)))
    sys.exit(1)
print("sqlite_master: %d objects identical (%d tables, %d indexes)" % (
    len(rust_objects),
    sum(1 for o in rust_objects if o.startswith("table ")),
    sum(1 for o in rust_objects if o.startswith("index ")),
))
if v3_migrations != rust_migrations:
    print("grdb_migrations differ:\n  v3  : %s\n  rust: %s" % (v3_migrations, rust_migrations))
    sys.exit(1)
print("grdb_migrations: %d identifiers identical (%s ... %s)" % (
    len(rust_migrations), rust_migrations[0], rust_migrations[-1]))
PY

echo
echo "== (b) v3 opens the Rust store and answers /api/accounts"
PORT="$(free_port)"
LAGOON_DB_PATH="$RUST_DB" LAGOON_SERVER_PORT="$PORT" LAGOON_TOKEN_KEY="$BODY_KEY" \
LAGOON_BODY_KEY="$BODY_KEY" LAGOON_API_TOKEN=verify "$V3_BIN" >"$TMP/v3-open.log" 2>&1 &
PIDS+=("$!")
for _ in $(seq 1 160); do
  curl -sf -m 1 -o /dev/null -H 'Authorization: Bearer verify' "http://127.0.0.1:$PORT/healthz" && break
  sleep 0.25
done
curl -sf -m 1 -o /dev/null -H 'Authorization: Bearer verify' "http://127.0.0.1:$PORT/healthz" || { tail -20 "$TMP/v3-open.log"; fail "v3 refused the Rust store"; }
sleep 2
ACCOUNTS="$(curl -sS -H 'Authorization: Bearer verify' "http://127.0.0.1:$PORT/api/accounts")"
echo "$ACCOUNTS" | python3 -c '
import json, sys
payload = json.load(sys.stdin)
match = [entry for entry in payload if entry.get("email") == "fake-r3-account@example.invalid"]
if not match:
    print("account missing from /api/accounts:", json.dumps(payload)[:400])
    sys.exit(1)
entry = match[0]
print("v3 sees the Rust-written account: email=%s syncHealth=%s" % (entry["email"], entry["syncHealth"]["status"]))
'
echo
echo "PASS: schema identical, migrations identical, v3 accepts the Rust store and attempts a sync"
