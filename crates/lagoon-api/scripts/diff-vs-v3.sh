#!/usr/bin/env bash
# Diff this Rust backend against the v3 Swift sidecar, byte for byte.
#
#   bash v4/crates/lagoon-api/scripts/diff-vs-v3.sh
#
# Both processes read the SAME synthetic store: a throwaway SQLite file the v3
# CLI migrates, seeded by v4/tests/contract/harness.py (the same seed the golden
# fixtures were captured from) with one shared test-vector body key, so the
# sealed body and draft open on both sides. The request list is every fixture in
# v4/tests/contract/fixtures that is not marked r2_skip, so it grows with the
# contract instead of with this script.
#
# Three phases, because v3's sync loop is not separable from its HTTP server:
#   A. one sidecar run on an empty file - that is what applies the migrations;
#   B. seed the migrated store, run the sidecar again so its sync loop actually
#      sees the account and parks it at needsReconnect (the seeded credentials
#      are deliberately unopenable), then snapshot the settled store twice;
#   C. run v3 on one copy and lagoon-api on the other and diff every request.
#
# One fixture can never match: v3.2.0's /api/search always answers 500 (its
# pass-B SQL references a.category without joining advice). The contract expects
# 200, this server implements 200, and the pair is reported as EXPLAINED rather
# than hidden or failed.
#
# Nothing here touches a real store, a real mailbox or a real key.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
CRATE="$ROOT/v4/crates"
HARNESS="$ROOT/v4/tests/contract/harness.py"
FIXTURES="$ROOT/v4/tests/contract/fixtures/fixtures.json"

die() { echo "diff-vs-v3: $*" >&2; exit 1; }

[ -f "$HARNESS" ] || die "missing $HARNESS"
[ -f "$FIXTURES" ] || die "missing $FIXTURES; run: bash v4/scripts/capture-contract.sh"
command -v python3 >/dev/null || die "python3 is required"
command -v curl >/dev/null || die "curl is required"

sidecar_bin() {
  if [ -n "${LAGOON_V4_SIDECAR:-}" ]; then echo "$LAGOON_V4_SIDECAR"; return; fi
  for candidate in "$ROOT/.build/release/LagoonServerCLI" "$ROOT/.build/debug/LagoonServerCLI"; do
    if [ -x "$candidate" ]; then echo "$candidate"; return; fi
  done
  die "LagoonServerCLI not built; run: swift build --product LagoonServerCLI"
}

free_port() {
  python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'
}

healthy() { curl -sf -m 2 -o /dev/null -H "Authorization: Bearer $2" "http://127.0.0.1:$1/healthz"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/lagoon-diff.XXXXXX")"
PIDS=()
cleanup() {
  for pid in "${PIDS[@]:-}"; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  for pid in "${PIDS[@]:-}"; do
    for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    kill -KILL "$pid" 2>/dev/null || true
  done
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

BODY_KEY="$(printf '0123456789abcdef0123456789abcdef' | base64)"
TOKEN="$(openssl rand -hex 16)"

echo "== building lagoon-api"
(cd "$CRATE" && cargo build --offline --quiet)
RUST_BIN="$CRATE/target/debug/lagoon-api"
[ -x "$RUST_BIN" ] || die "missing $RUST_BIN"
V3_BIN="$(sidecar_bin)"

V3_PID=""
# The port is published through STARTED_PORT, not stdout: `$(start_v3 …)` would
# run the function in a subshell, where PIDS+= never reaches the parent — the
# sidecar then survives the trap (observed 2026-10-29: three leaked processes
# after two runs).
STARTED_PORT=""
start_v3() {
  local db="$1" log="$2" port
  port="$(free_port)"
  LAGOON_DB_PATH="$db" LAGOON_SERVER_PORT="$port" \
  LAGOON_TOKEN_KEY="$BODY_KEY" LAGOON_BODY_KEY="$BODY_KEY" LAGOON_API_TOKEN="$TOKEN" \
    "$V3_BIN" >"$log" 2>&1 &
  V3_PID=$!
  PIDS+=("$V3_PID")
  for _ in $(seq 1 120); do
    healthy "$port" "$TOKEN" && break
    kill -0 "$V3_PID" 2>/dev/null || die "sidecar died; log: $(tail -5 "$log")"
    sleep 0.25
  done
  healthy "$port" "$TOKEN" || die "sidecar did not become healthy"
  STARTED_PORT="$port"
}

echo "== phase A: apply the v3 migrations to a throwaway store"
SCHEMA_DB="$TMP/schema.sqlite"
start_v3 "$SCHEMA_DB" "$TMP/schema.log"
kill -TERM "$V3_PID" 2>/dev/null || true
wait "$V3_PID" 2>/dev/null || true

SEED_DB="$TMP/seed.sqlite"
python3 - "$SCHEMA_DB" "$SEED_DB" <<'PY'
import sqlite3, sys
source, target = sys.argv[1:3]
src = sqlite3.connect("file:%s?mode=ro" % source, uri=True)
dst = sqlite3.connect(target)
src.backup(dst)
dst.close()
src.close()
PY

echo "== phase B: seed it, let v3 park its sync loop, snapshot the settled store"
python3 "$HARNESS" seed --db "$SEED_DB" --body-key "$BODY_KEY"
start_v3 "$SEED_DB" "$TMP/seed.log"
SEED_PORT="$STARTED_PORT"
python3 - "$SEED_PORT" "$TOKEN" <<'PY'
import json, sys, time, urllib.request
port, token = sys.argv[1], sys.argv[2]
def accounts():
    request = urllib.request.Request(
        "http://127.0.0.1:%s/api/accounts" % port,
        headers={"Authorization": "Bearer " + token},
    )
    with urllib.request.urlopen(request, timeout=5) as response:
        return json.loads(response.read())
previous = None
deadline = time.time() + 30
while time.time() < deadline:
    current = accounts()
    parked = any(entry["syncHealth"]["status"] != "ok" for entry in current)
    if parked and current == previous:
        statuses = sorted({entry["syncHealth"]["status"] for entry in current})
        print("   sync loop parked at %s; payload stable" % ", ".join(statuses))
        sys.exit(0)
    previous = current
    time.sleep(0.25)
print("   warning: the sync loop did not park within 30s; comparing anyway")
PY
python3 - "$SEED_DB" "$TMP/v3.sqlite" "$TMP/rust.sqlite" <<'PY'
import shutil, sqlite3, sys
source, v3_copy, rust_copy = sys.argv[1:4]
snapshot = source + ".snapshot"
src = sqlite3.connect("file:%s?mode=ro" % source, uri=True)
dst = sqlite3.connect(snapshot)
src.backup(dst)
dst.close()
src.close()
for target in (v3_copy, rust_copy):
    shutil.copyfile(snapshot, target)
PY
kill -TERM "$V3_PID" 2>/dev/null || true
wait "$V3_PID" 2>/dev/null || true

echo "== phase C: v3 on one copy, lagoon-api on the other"
start_v3 "$TMP/v3.sqlite" "$TMP/v3.log"
V3_PORT="$STARTED_PORT"
RUST_PORT="$(free_port)"
LAGOON_BODY_KEY="$BODY_KEY" LAGOON_API_TOKEN="$TOKEN" \
  "$RUST_BIN" --db "$TMP/rust.sqlite" --port "$RUST_PORT" >"$TMP/rust.log" 2>&1 &
PIDS+=("$!")
for _ in $(seq 1 120); do
  curl -sf -m 2 -o /dev/null "http://127.0.0.1:$RUST_PORT/healthz" && break
  sleep 0.25
done
curl -sf -m 2 -o /dev/null "http://127.0.0.1:$RUST_PORT/healthz" || die "lagoon-api did not become healthy"

echo
python3 - "$FIXTURES" "$V3_PORT" "$RUST_PORT" "$TOKEN" <<'PY'
import json, sys, urllib.error, urllib.parse, urllib.request

fixtures_path, v3_port, rust_port, token = sys.argv[1:5]
v3_port, rust_port = int(v3_port), int(rust_port)

TIMESTAMP_KEYS = {
    "date", "lastFetchedAt", "fetchedAt", "lastSyncAt", "createdAt", "updatedAt",
    "decidedAt", "dueAt", "expiresAt", "lastErrorAt", "startedAt",
}

EXPLAINED = {
    "search.contract": "v3.2.0 answers 500 (pass-B SQL references a.category without JOIN advice); the contract is 200",
    "search.contract.sealed-body": "same defect; the sealed arm is implemented here",
}

def normalize(value):
    if isinstance(value, dict):
        return {
            key: ("<timestamp>" if key in TIMESTAMP_KEYS and isinstance(item, str)
                  and len(item) >= 20 and item[4:5] == "-"
                  else normalize(item))
            for key, item in value.items()
        }
    if isinstance(value, list):
        return [normalize(item) for item in value]
    return value

def path_of(fixture):
    request = fixture["request"]
    path = request["path"]
    if request.get("query"):
        pairs = ["%s=%s" % (urllib.parse.quote(key, safe=""), urllib.parse.quote(str(value), safe=""))
                 for key, value in request["query"].items()]
        path = path + "?" + "&".join(pairs)
    return path

def fetch(port, fixture):
    request = fixture["request"]
    headers = {"Accept": "application/json"}
    auth = request.get("auth", "token")
    if auth == "token":
        headers["Authorization"] = "Bearer " + token
    elif auth == "bad-token":
        headers["Authorization"] = "Bearer definitely-not-the-token"
    headers.update(request.get("headers") or {})
    req = urllib.request.Request(
        "http://127.0.0.1:%d%s" % (port, path_of(fixture)),
        headers=headers,
        method=request["method"],
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            status, content_type, data = response.status, response.headers.get("Content-Type") or "", response.read()
    except urllib.error.HTTPError as error:
        status, content_type, data = error.code, error.headers.get("Content-Type") or "", error.read()
    if data and "application/json" in content_type.lower():
        body = normalize(json.loads(data.decode("utf-8")))
    elif data:
        body = data.decode("utf-8", "replace")
    else:
        body = None
    return {"status": status, "content_type": content_type, "body": body}

fixtures = [f for f in json.load(open(fixtures_path))["fixtures"] if "r2_skip" not in f]

same = 0
explained = 0
differences = 0
print("%-40s %-6s %-6s %s" % ("fixture", "v3", "rust", "verdict"))
for fixture in fixtures:
    name = fixture["name"]
    left = fetch(v3_port, fixture)
    right = fetch(rust_port, fixture)
    if left == right:
        same += 1
        print("%-40s %-6s %-6s SAME" % (name, left["status"], right["status"]))
        continue
    if name in EXPLAINED and left["status"] == 500 and right["status"] == 200:
        explained += 1
        print("%-40s %-6s %-6s EXPLAINED" % (name, left["status"], right["status"]))
        continue
    differences += 1
    print("%-40s %-6s %-6s DIFF" % (name, left["status"], right["status"]))
    print("  v3  : " + json.dumps(left, sort_keys=True, ensure_ascii=False))
    print("  rust: " + json.dumps(right, sort_keys=True, ensure_ascii=False))

print()
print("%d/%d identical, %d explained by a documented v3 defect, %d different"
      % (same, len(fixtures), explained, differences))
sys.exit(0 if differences == 0 else 1)
PY
