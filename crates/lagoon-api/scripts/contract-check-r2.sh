#!/usr/bin/env bash
# Run the contract fixtures against THIS server, the way the lead checks it.
#
#   bash v4/crates/lagoon-api/scripts/contract-check-r2.sh
#
# Steps, all in a throwaway directory:
#   1. copy the schema out of v4/.dev/data/lagoon.sqlite (the v3 sidecar's
#      migrated store - it is the schema authority until R3 takes migration
#      ownership);
#   2. seed it with v4/tests/contract/harness.py and the same test-vector body
#      key this server is about to use, so the sealed body and draft open;
#   3. start lagoon-api on an ephemeral port;
#   4. run "bash v4/scripts/contract-check.sh <base_url> <token>".
#
# The schema copy goes through SQLite's backup API: the dev store keeps most of
# its content in the WAL, so a plain cp would carry a 4 KiB file and no tables.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
CRATE="$ROOT/v4/crates"
HARNESS="$ROOT/v4/tests/contract/harness.py"
DEV_DB="$ROOT/v4/.dev/data/lagoon.sqlite"

die() { echo "contract-check-r2: $*" >&2; exit 1; }

[ -f "$HARNESS" ] || die "missing $HARNESS"
[ -f "$DEV_DB" ] || die "missing $DEV_DB - run: bash v4/scripts/sidecar-dev.sh start"

echo "== building lagoon-api"
(cd "$CRATE" && cargo build --offline --quiet)
BIN="$CRATE/target/debug/lagoon-api"
[ -x "$BIN" ] || die "missing $BIN"

BODY_KEY="$(printf '0123456789abcdef0123456789abcdef' | base64)"
TOKEN_KEY="$(printf 'fedcba9876543210fedcba9876543210' | base64)"
TOKEN="$(openssl rand -hex 16)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/lagoon-r2-check.XXXXXX")"
PID=""
cleanup() {
  if [ -n "$PID" ]; then
    kill -TERM "$PID" 2>/dev/null || true
    for _ in $(seq 1 20); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
    kill -KILL "$PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

echo "== copying the migrated schema"
python3 - "$DEV_DB" "$TMP/rust.sqlite" <<'PY'
import sqlite3, sys
source, target = sys.argv[1:3]
# Schema only: the dev store may hold rows from a previous experiment, and the
# fixtures were captured against a freshly seeded store. Copying rows would
# double-add accounts and pins.
src = sqlite3.connect("file:%s?mode=ro" % source, uri=True)
dst = sqlite3.connect(target)
for typ, name, sql in src.execute(
    "SELECT type, name, sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY rowid"
):
    if typ == "table" and name == "sqlite_sequence":
        continue
    dst.execute(sql)
# The migration bookkeeping is schema, not user data: without it the server
# refuses the store as un-migrated.
for (identifier,) in src.execute("SELECT identifier FROM grdb_migrations ORDER BY rowid"):
    dst.execute("INSERT INTO grdb_migrations (identifier) VALUES (?)", (identifier,))
dst.commit()
dst.close()
src.close()
PY

echo "== seeding with the contract harness (body key = the test vector)"
python3 "$HARNESS" seed --db "$TMP/rust.sqlite" --body-key "$BODY_KEY"
# The harness may seed accounts newer fixtures will use; the fixtures file
# being replayed is the oracle, so keep exactly the accounts its seed names.
python3 - "$ROOT/v4/tests/contract/fixtures/fixtures.json" "$TMP/rust.sqlite" <<'PY'
import json, sqlite3, sys, uuid
seed = json.load(open(sys.argv[1]))["seed"]
ids = []
for key in ("accountId", "accountIdB", "accountIdC"):
    if seed.get(key):
        ids.append(uuid.UUID(seed[key]).bytes)
placeholders = ",".join("?" * len(ids))
conn = sqlite3.connect(sys.argv[2])
conn.execute("PRAGMA foreign_keys = ON")
conn.execute("DELETE FROM accounts WHERE id NOT IN (%s)" % placeholders, ids)
conn.commit()
conn.close()
PY

PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
echo "== starting lagoon-api on :$PORT"
LAGOON_BODY_KEY="$BODY_KEY" LAGOON_TOKEN_KEY="$TOKEN_KEY" LAGOON_API_TOKEN="$TOKEN" \
  "$BIN" --db "$TMP/rust.sqlite" --port "$PORT" >"$TMP/rust.log" 2>&1 &
PID=$!
for _ in $(seq 1 120); do
  curl -sf -m 2 -o /dev/null "http://127.0.0.1:$PORT/healthz" && break
  kill -0 "$PID" 2>/dev/null || { echo "server died:"; cat "$TMP/rust.log"; exit 1; }
  sleep 0.25
done
curl -sf -m 2 -o /dev/null "http://127.0.0.1:$PORT/healthz" || { echo "server never became healthy:"; cat "$TMP/rust.log"; exit 1; }

echo
status=0
bash "$ROOT/v4/scripts/contract-check.sh" "http://127.0.0.1:$PORT" "$TOKEN" || status=$?
exit "$status"
