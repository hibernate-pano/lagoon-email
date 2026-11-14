#!/usr/bin/env python3
"""Lagoon v4 contract harness: seed a synthetic store, capture golden fixtures, replay and diff.

Standard library only (no third-party packages, no jq): this must run on a clean
machine that only has python3. The scripts that call it are:

    v4/scripts/capture-contract.sh   # spawn a temp sidecar, seed, capture fixtures
    v4/scripts/contract-check.sh     # replay fixtures against a fresh instance

Design rules (see v4/docs/api-contract.md):
  * Fixtures are REAL responses captured from a real LagoonServerCLI over HTTP.
  * The store is a throwaway SQLite file in a mktemp dir with SYNTHETIC seed rows.
  * Nothing here ever talks to a mail server: the seeded account has an
    unreadable credentials blob, so every provider path fails at credential
    open (MailError.notConfigured) before any socket is created.
  * Only volatile values are normalized, by key name, never by guessing.

Fixture file format (v4/tests/contract/fixtures/fixtures.json):
  {
    "version": 2,
    "note": "...",
    "normalized": ["lastFetchedAt", ...],
    "fixtures": [
      {"name": "...", "note": "...", "request": {...}, "response": {...}}
    ]
  }

A response is {"status": int, "content_type": str, "body_kind": "json|text|empty",
"body": <parsed JSON | string | null>}.
"""

from __future__ import annotations

import argparse
import base64
import datetime
import http.client
import json
import os
import sqlite3
import sys
import time
import uuid
from urllib.parse import urlparse, urlencode

# Importing the sibling module would otherwise drop a __pycache__/ next to the
# committed fixtures; the contract tree stays clean.
sys.dont_write_bytecode = True

import aesgcm  # noqa: E402  (must follow dont_write_bytecode)

FIXTURES_VERSION = 2

# --- synthetic identities (never real data) --------------------------------
ACCOUNT_ID = "11111111-1111-4111-8111-111111111111"
ACCOUNT_EMAIL = "contract-fixture@example.invalid"
MSG1 = "22222222-2222-4222-8222-222222222221"
MSG2 = "22222222-2222-4222-8222-222222222222"
MSG3 = "22222222-2222-4222-8222-222222222223"
REMOTE1, REMOTE2, REMOTE3 = "fixture-msg-1", "fixture-msg-2", "fixture-msg-3"
THREAD1, THREAD2, THREAD3 = "fixture-thread-1", "fixture-thread-2", "fixture-thread-3"
SENDER = "alice.fixture@example.invalid"
SENDER_NAME = "Alice Fixture"
SEED_AT = "2025-01-01 00:00:00.000"

# All seeded mail is older than the briefing window on purpose: the window is a
# 30-day sliding rule, and mail inside it would make the grouping depend on the
# day the fixture is replayed.
RECEIVED = ["2025-01-01 09:00:00.000", "2025-01-02 09:00:00.000", "2025-01-03 09:00:00.000"]

CAPABILITIES_JSON = json.dumps({
    "archiveFolder": False,
    "idle": False,
    "move": False,
    "serverSnippet": False,
    "uidplus": False,
    "sentFolder": False,
    "trashFolder": False,
}, separators=(",", ":"))

# 48 zero bytes: a well-formed AES-GCM container that cannot be opened with any
# key, so provider construction fails with MailError.notConfigured and no socket.
UNREADABLE_CREDENTIALS = bytes(48)

# --- a second, data-rich account (R2) --------------------------------------
#
# Account A above stays deliberately EMPTY for the queue-shaped surfaces
# (advice / stacks / reminders), so the "nothing here yet" payloads keep their
# fixtures. Account B is the populated counterpart: advice, stack rules,
# reminders, a sealed body cache, a sealed draft and an ai_actions history.
# Both accounts are synthetic: example.invalid, fixed UUIDs, fixed timestamps.
ACCOUNT_ID_B = "33333333-3333-4333-8333-333333333333"
ACCOUNT_EMAIL_B = "contract-fixture-b@example.invalid"
SENDER_B = "bob.fixture@example.invalid"
SENDER_NAME_B = "Bob Fixture"

MSG_B1 = "44444444-4444-4444-8444-444444444441"
MSG_B2 = "44444444-4444-4444-8444-444444444442"
REMOTE_B1, REMOTE_B2 = "fixture-b-msg-1", "fixture-b-msg-2"
THREAD_B1, THREAD_B2 = "fixture-b-thread-1", "fixture-b-thread-2"

# The sealed body exists so two R2 endpoints have a real 200 shape without a
# provider: GET /body answers from this cache, and /api/search can match text
# that only exists inside a sealed body ("sealedneedle" appears in no subject).
BODY_TEXT = "Contract fixture body: sealedneedle appears here."
BODY_HTML = "<p>Contract fixture body: <b>sealedneedle</b> appears here.</p>"
DRAFT_VARIANTS = [
    "Thanks, I will take a look.",
    "Could you share the thread?",
    "Let us set up a short call.",
]

# Account C exists only so the 409 account-exists fixture has a subject that
# is not entangled with the other surfaces' data. It is seeded in the "ok" state
# (a healthy, never-synced account) because that is exactly what the v3 route
# checks before answering 409 (AccountsRoutes.swift:112).
ACCOUNT_ID_C = "66666666-6666-4666-8666-666666666666"
ACCOUNT_EMAIL_C = "contract-fixture-c@example.invalid"

STACK_RULE_1 = "55555555-5555-4555-8555-555555555551"
STACK_RULE_2 = "55555555-5555-4555-8555-555555555552"
NOTICE_ID = "fixture-notice-1"

ADVICE_CREATED_PENDING = "2025-02-03 09:00:00.000"
ADVICE_CREATED_ACCEPTED = "2025-02-04 09:00:00.000"
ADVICE_DECIDED_ACCEPTED = "2025-02-05 09:00:00.000"

# GRDB stores a Swift UUID as 16 raw bytes, and the schema's id columns are
# BLOB. Seeding the 36-character text form would produce a row the server can
# never address (this exact encoding mismatch was a real v3 defect — see
# LagoonDatabase.accountIDRepairVersion), so every UUID column is seeded as a
# blob of the same UUID.
def _uuid_blob(value: str) -> bytes:
    return uuid.UUID(value).bytes

# --- normalization ----------------------------------------------------------

# Volatile by nature: wall-clock timestamps. Everything else is seeded and must
# match byte for byte (that is the point of the fixture).
TIMESTAMP_KEYS = {
    "lastFetchedAt", "fetchedAt", "lastSyncAt", "createdAt", "updatedAt",
    "decidedAt", "dueAt", "expiresAt", "lastErrorAt", "startedAt",
    # TimeSavedDay.date: the local midnight of an aggregated day. It moves with
    # the run date, so it is normalized like every other wall-clock value.
    "date",
}
NORMALIZED_VALUE = "<timestamp>"


def _looks_iso(value: str) -> bool:
    return (
        len(value) >= 20
        and value[4:5] == "-"
        and value[7:8] == "-"
        and (value[10:11] == "T" or value[10:11] == " ")
    )


def normalize(value):
    """Replace wall-clock timestamps with a marker, by key name only."""
    if isinstance(value, dict):
        out = {}
        for key, item in value.items():
            if key in TIMESTAMP_KEYS and isinstance(item, str) and _looks_iso(item):
                out[key] = NORMALIZED_VALUE
            else:
                out[key] = normalize(item)
        return out
    if isinstance(value, list):
        return [normalize(item) for item in value]
    return value


# --- the health the 409 fixture depends on -----------------------------------
#
# The v3 sync loop flips a seeded account from 'ok' to 'needsReconnect' as soon
# as it tries (and fails) to reach the mailbox: the credentials blob cannot be
# opened, so the loop parks the account as needing a reconnect. The 409
# account-exists route answers ONLY for a healthy row (AccountsRoutes.swift:112),
# so the fixture has to restore 'ok' immediately before that request.
#
# Restoring it right before the request is what makes the fixture deterministic:
# the account is 'ok' for the whole replay, and the flip is invisible because no
# other fixture reads account C's health.
def restore_healthy_account(db_path: str, account_id: str) -> None:
    if not db_path:
        return
    connection = sqlite3.connect(db_path, timeout=20)
    try:
        connection.execute("PRAGMA busy_timeout = 15000")
        connection.execute(
            "UPDATE accounts SET sync_status = 'ok', last_sync_error = NULL WHERE id = ?",
            (_uuid_blob(account_id),),
        )
        connection.commit()
    finally:
        connection.close()


# Pre-request hooks, addressed BY NAME: a fixture file is JSON, so it cannot
# carry a callable. The name in the file is resolved here.
PRE_HOOKS = {
    # The 409 account-exists fixture needs its subject to be healthy.
    "restore-account-c-ok": lambda db: restore_healthy_account(db, ACCOUNT_ID_C),
}


def run_pre_hook(name, db_path) -> None:
    hook = PRE_HOOKS.get(name)
    if hook is None:
        raise SystemExit("unknown pre-request hook: %r" % name)
    hook(db_path)


# --- HTTP -------------------------------------------------------------------

def http_request(base_url: str, fixture: dict, token: str):
    parsed = urlparse(base_url)
    host = parsed.hostname or "127.0.0.1"
    port = parsed.port or 80
    request = fixture["request"]
    path = request["path"]
    query = request.get("query") or {}
    if query:
        path = path + "?" + urlencode(list(query.items()))
    headers = {"Accept": "application/json"}
    auth = request.get("auth", "token")
    if auth == "token":
        headers["Authorization"] = "Bearer " + token
    elif auth == "bad-token":
        headers["Authorization"] = "Bearer definitely-not-the-token"
    for name, value in (request.get("headers") or {}).items():
        headers[name] = value
    payload = None
    if request.get("raw_body") is not None:
        payload = request["raw_body"].encode("utf-8")
        headers["Content-Type"] = "application/json"
    elif request.get("json") is not None:
        payload = json.dumps(request["json"]).encode("utf-8")
        headers["Content-Type"] = "application/json"
    connection = http.client.HTTPConnection(host, port, timeout=30)
    try:
        connection.request(request["method"], path, body=payload, headers=headers)
        response = connection.getresponse()
        data = response.read()
        content_type = response.getheader("Content-Type") or ""
        status = response.getcode()
    finally:
        connection.close()
    return describe_response(status, content_type, data)


def describe_response(status: int, content_type: str, data: bytes) -> dict:
    described = {"status": status, "content_type": content_type, "body_kind": "empty", "body": None}
    if not data:
        return described
    if "application/json" in content_type.lower():
        try:
            described["body_kind"] = "json"
            described["body"] = normalize(json.loads(data.decode("utf-8")))
            return described
        except (UnicodeDecodeError, json.JSONDecodeError):
            pass
    described["body_kind"] = "text"
    described["body"] = data.decode("utf-8", "replace")
    return described


# --- seed -------------------------------------------------------------------

SEED_ACCOUNT = {
    "id": _uuid_blob(ACCOUNT_ID),
    "provider": "qq",
    "oauth_user": ACCOUNT_EMAIL,
    "email": ACCOUNT_EMAIL,
    "sync_state": "{}",
    "capabilities": CAPABILITIES_JSON,
    "is_active": 1,
    "sync_status": "ok",
    "created_at": SEED_AT,
    "updated_at": SEED_AT,
}

SEED_MESSAGES = [
    {
        "id": _uuid_blob(MSG1), "remote_id": REMOTE1, "thread_id": THREAD1,
        "subject": "Contract fixture one", "snippet": "",
        "received_at": RECEIVED[0], "is_read": 1, "is_archived": 0,
        "is_deleted": 0, "is_sent": 0, "list_unsubscribe": 0,
        "message_id_header": "<fixture-1@example.invalid>",
        "in_reply_to": None, "references_header": None,
    },
    {
        "id": _uuid_blob(MSG2), "remote_id": REMOTE2, "thread_id": THREAD2,
        "subject": "Contract fixture two (archived, pinned)", "snippet": "",
        "received_at": RECEIVED[1], "is_read": 1, "is_archived": 1,
        "is_deleted": 0, "is_sent": 0, "list_unsubscribe": 0,
        "message_id_header": "<fixture-2@example.invalid>",
        "in_reply_to": "<fixture-1@example.invalid>",
        "references_header": "<fixture-1@example.invalid>",
    },
    {
        "id": _uuid_blob(MSG3), "remote_id": REMOTE3, "thread_id": THREAD3,
        "subject": "Contract fixture three (unread)", "snippet": "",
        "received_at": RECEIVED[2], "is_read": 0, "is_archived": 0,
        "is_deleted": 0, "is_sent": 0, "list_unsubscribe": 0,
        "message_id_header": "<fixture-3@example.invalid>",
        "in_reply_to": None, "references_header": None,
    },
]

SEED_MESSAGES_B = [
    {
        "id": _uuid_blob(MSG_B1), "remote_id": REMOTE_B1, "thread_id": THREAD_B1,
        "subject": "Body match fixture (sealed)", "snippet": "",
        "received_at": "2025-02-01 09:00:00.000", "is_read": 1, "is_archived": 0,
        "is_deleted": 0, "is_sent": 0, "list_unsubscribe": 0,
        "message_id_header": "<fixture-b-1@example.invalid>",
        "in_reply_to": None, "references_header": None,
    },
    {
        "id": _uuid_blob(MSG_B2), "remote_id": REMOTE_B2, "thread_id": THREAD_B2,
        "subject": "Second fixture for advice", "snippet": "",
        "received_at": "2025-02-02 09:00:00.000", "is_read": 0, "is_archived": 0,
        "is_deleted": 0, "is_sent": 0, "list_unsubscribe": 0,
        "message_id_header": "<fixture-b-2@example.invalid>",
        "in_reply_to": None, "references_header": None,
    },
]


def _columns(connection: sqlite3.Connection, table: str):
    rows = connection.execute("PRAGMA table_info(%s)" % table).fetchall()
    if not rows:
        raise SystemExit("seed: table %s does not exist; is the sidecar running against this DB?" % table)
    return {row[1] for row in rows}


def _insert(connection: sqlite3.Connection, table: str, values: dict, aliases: dict):
    """Insert only the columns the live schema actually has (schema-rev tolerant)."""
    columns = _columns(connection, table)
    resolved = {}
    for name, value in values.items():
        if name in columns:
            resolved[name] = value
        elif aliases.get(name) in columns:
            resolved[aliases[name]] = value
    names = list(resolved)
    sql = "INSERT OR REPLACE INTO %s (%s) VALUES (%s)" % (
        table, ", ".join(names), ", ".join(["?"] * len(names))
    )
    connection.execute(sql, [resolved[name] for name in names])


def _body_key(body_key_b64: str) -> bytes:
    try:
        key = base64.b64decode(body_key_b64)
    except Exception:
        raise SystemExit("seed: --body-key is not valid base64")
    if len(key) != 32:
        raise SystemExit("seed: --body-key must decode to exactly 32 bytes")
    return key


def _seal(key: bytes, plaintext: str) -> str:
    """The v3 store's envelope: lgb1: + base64(nonce || ciphertext || tag)."""
    return aesgcm.seal_envelope(key, plaintext)


def _action_times() -> tuple:
    """Two ai_actions timestamps that stay inside today's local window."""
    midnight = datetime.datetime.now().astimezone().replace(
        hour=0, minute=30, second=0, microsecond=0
    )
    formatter = lambda moment: moment.astimezone(datetime.timezone.utc).strftime(
        "%Y-%m-%d %H:%M:%S.000"
    )
    return formatter(midnight), formatter(midnight + datetime.timedelta(minutes=1))
def seed(db_path: str, body_key_b64: str) -> None:
    key = _body_key(body_key_b64)
    if not os.path.exists(db_path):
        raise SystemExit("seed: %s does not exist" % db_path)
    connection = sqlite3.connect(db_path, timeout=20)
    try:
        connection.execute("PRAGMA busy_timeout = 15000")

        # --- account A: the deliberately empty, list-shaped mailbox ---------
        _insert(connection, "accounts", dict(SEED_ACCOUNT, credentials=UNREADABLE_CREDENTIALS),
                aliases={})
        for message in SEED_MESSAGES:
            row = dict(message, account_id=_uuid_blob(ACCOUNT_ID), from_address=SENDER,
                       from_name=SENDER_NAME, fetched_at=SEED_AT,
                       references_header=message.get("references_header"),
                       unsubscribe_links="[]")
            _insert(connection, "message_headers", row,
                    aliases={"snippet": "snippet_cipher"})
        _insert(connection, "message_pins",
                {"account_id": _uuid_blob(ACCOUNT_ID), "remote_id": REMOTE2, "created_at": SEED_AT},
                aliases={})

        # --- account B: the populated R2 counterpart ------------------------
        _insert(connection, "accounts", {
            "id": _uuid_blob(ACCOUNT_ID_B),
            "provider": "qq",
            "oauth_user": ACCOUNT_EMAIL_B,
            "email": ACCOUNT_EMAIL_B,
            "credentials": UNREADABLE_CREDENTIALS,
            "sync_state": "{}",
            "capabilities": CAPABILITIES_JSON,
            "is_active": 0,
            "sync_status": "ok",
            "created_at": SEED_AT,
            "updated_at": SEED_AT,
        }, aliases={})
        # --- account C: the 409 account-exists subject ----------------------
        # sync_status stays 'ok' on purpose: the route answers 409 only when the
        # existing row is healthy, and it reports the conflict BEFORE any network
        # work (no probe, no socket).
        _insert(connection, "accounts", {
            "id": _uuid_blob(ACCOUNT_ID_C),
            "provider": "qq",
            "oauth_user": ACCOUNT_EMAIL_C,
            "email": ACCOUNT_EMAIL_C,
            "credentials": UNREADABLE_CREDENTIALS,
            "sync_state": "{}",
            "capabilities": CAPABILITIES_JSON,
            "is_active": 0,
            "sync_status": "ok",
            "created_at": SEED_AT,
            "updated_at": SEED_AT,
        }, aliases={})

        for message in SEED_MESSAGES_B:
            row = dict(message, account_id=_uuid_blob(ACCOUNT_ID_B), from_address=SENDER_B,
                       from_name=SENDER_NAME_B, fetched_at=SEED_AT,
                       references_header=message.get("references_header"),
                       unsubscribe_links="[]")
            _insert(connection, "message_headers", row,
                    aliases={"snippet": "snippet_cipher"})

        # advice: one pending suggestion and one the user already accepted.
        _insert(connection, "advice", {
            "account_id": _uuid_blob(ACCOUNT_ID_B), "remote_id": REMOTE_B1,
            "action": "archive", "category": "marketing", "confidence": "high",
            "rationale": "You have not opened this sender in months.",
            "due_text": None, "source": "ai", "model": "contract-fixture-model",
            "decision": "pending", "created_at": ADVICE_CREATED_PENDING,
            "decided_at": None,
        }, aliases={})
        _insert(connection, "advice", {
            "account_id": _uuid_blob(ACCOUNT_ID_B), "remote_id": REMOTE_B2,
            "action": "reply", "category": "work", "confidence": "medium",
            "rationale": "A colleague is waiting on you.",
            "due_text": "2025-02-10", "source": "heuristic", "model": None,
            "decision": "accepted", "created_at": ADVICE_CREATED_ACCEPTED,
            "decided_at": ADVICE_DECIDED_ACCEPTED,
        }, aliases={})

        # stack rules: one sender rule, one subject keyword rule.
        _insert(connection, "stack_rules", {
            "id": _uuid_blob(STACK_RULE_1), "account_id": _uuid_blob(ACCOUNT_ID_B),
            "name": "Sender to archive", "kind": "sender", "value": SENDER_B,
            "created_at": "2025-02-05 09:00:00.000",
        }, aliases={})
        _insert(connection, "stack_rules", {
            "id": _uuid_blob(STACK_RULE_2), "account_id": _uuid_blob(ACCOUNT_ID_B),
            "name": "Subject keyword", "kind": "keyword", "value": "fixture",
            "created_at": "2025-02-05 09:01:00.000",
        }, aliases={})

        # reminders: one still waiting, one dismissed (includeDismissed=true).
        _insert(connection, "reminders", {
            "account_id": _uuid_blob(ACCOUNT_ID_B), "remote_id": REMOTE_B1,
            "due_at": "2025-03-01 09:00:00.000", "note": "Follow up on the contract",
            "created_at": "2025-02-06 09:00:00.000", "dismissed_at": None,
        }, aliases={})
        _insert(connection, "reminders", {
            "account_id": _uuid_blob(ACCOUNT_ID_B), "remote_id": REMOTE_B2,
            "due_at": "2025-03-02 09:00:00.000", "note": None,
            "created_at": "2025-02-06 09:01:00.000", "dismissed_at": "2025-02-07 09:00:00.000",
        }, aliases={})

        # a sealed draft (DraftCipher seals the JSON array as ONE envelope).
        _insert(connection, "draft_replies", {
            "account_id": _uuid_blob(ACCOUNT_ID_B), "remote_id": REMOTE_B2,
            "variants": _seal(key, json.dumps(DRAFT_VARIANTS, separators=(",", ":"),
                                             ensure_ascii=False)),
            "chosen_variant": None, "created_at": "2025-02-07 09:00:00.000",
        }, aliases={})

        # a sealed body cache: the only way to reach /body 200 and the sealed
        # arm of /api/search without a provider (and without a mail server).
        _insert(connection, "message_bodies", {
            "account_id": _uuid_blob(ACCOUNT_ID_B), "remote_id": REMOTE_B1,
            "body_cipher": _seal(key, BODY_TEXT),
            "body_html_cipher": _seal(key, BODY_HTML),
            "has_more": 0, "attachments": "[]",
            "to_addresses": json.dumps([ACCOUNT_EMAIL_B]),
            "cc_addresses": "[]",
            "fetched_at": "2025-02-01 09:30:00.000",
        }, aliases={})

        # ai_actions: a sent reply and a pin, dated inside today's window so
        # /api/time-saved has a non-zero shape to assert.
        send_at, pin_at = _action_times()
        _insert(connection, "ai_actions", {
            "account_id": _uuid_blob(ACCOUNT_ID_B), "kind": "send",
            "payload": json.dumps({"remoteId": REMOTE_B2,
                                   "providerMessageId": "<fixture-b-sent@example.invalid>"},
                                  separators=(",", ":")),
            "created_at": send_at,
        }, aliases={})
        _insert(connection, "ai_actions", {
            "account_id": _uuid_blob(ACCOUNT_ID_B), "kind": "pin",
            "payload": json.dumps({"remoteId": REMOTE_B1}, separators=(",", ":")),
            "created_at": pin_at,
        }, aliases={})

        # one store notice (global): the "one-shot notice" surface has data.
        _insert(connection, "store_notices", {
            "id": NOTICE_ID, "detail": "1",
            "created_at": "2025-02-08 09:00:00.000",
        }, aliases={})

        connection.commit()
        counts = {
            table: connection.execute("SELECT COUNT(*) FROM %s" % table).fetchone()[0]
            for table in (
                "accounts", "message_headers", "message_pins", "advice",
                "stack_rules", "reminders", "draft_replies", "message_bodies",
                "ai_actions", "store_notices",
            )
        }
    finally:
        connection.close()
    print("seed: %s" % json.dumps(counts, sort_keys=True))


# --- scenario ---------------------------------------------------------------

def scenario() -> list:
    """The captured contract surface.

    Order matters: fixtures that mutate local state come last, so every read
    fixture sees the same store on every replay.
    """
    fixtures = []

    def add(name, note, method, path, query=None, auth="token", headers=None, body=None,
            known_defect=None, r2_skip=None, raw_body=None, pre=None, mutates_store=False):
        entry = {
            "name": name,
            "note": note,
            "request": {
                "method": method,
                "path": path,
                "query": query or {},
                "auth": auth,
                "headers": headers or {},
                "json": body,
                # raw_body sends an exact byte string instead of a JSON object;
                # it is how the "empty body" case is expressed.
                "raw_body": raw_body,
            },
        }
        if pre:
            entry["pre"] = pre  # a hook NAME, resolved by run_pre_hook()
        if known_defect:
            entry["known_defect"] = known_defect
        if r2_skip:
            entry["r2_skip"] = r2_skip
        if mutates_store:
            entry["mutates_store"] = True
        fixtures.append(entry)

    # Transport / auth / host guard
    add("healthz", "Ungated health probe; plain text, no JSON envelope.",
        "GET", "/healthz", auth="none")
    add("accounts.list", "ConnectedAccount[]; capabilities echo the negotiated store.",
        "GET", "/api/accounts")
    add("auth.missing-token", "APIAuthMiddleware is fail-closed: no bearer, no route.",
        "GET", "/api/accounts", auth="none")
    add("auth.bad-token", "A wrong bearer is the same 401 as a missing one.",
        "GET", "/api/accounts", auth="bad-token")
    add("host.forbidden", "Loopback Host guard (DNS-rebinding defence) answers 403.",
        "GET", "/api/accounts", headers={"Host": "evil.example"})

    # List + filters
    add("messages.list", "Default inbox lens: archived=false, deleted=false.",
        "GET", "/api/messages", query={"accountId": ACCOUNT_ID})
    add("messages.list.limit", "limit is a ceiling; totalCount ignores it.",
        "GET", "/api/messages", query={"accountId": ACCOUNT_ID, "limit": "1"})
    add("messages.list.archived", "档案柜 lens.",
        "GET", "/api/messages", query={"accountId": ACCOUNT_ID, "archived": "true"})
    add("messages.list.pinned", "置顶 lens (a lens of its own).",
        "GET", "/api/messages", query={"accountId": ACCOUNT_ID, "pinned": "true"})
    add("messages.list.unread", "未读 lens.",
        "GET", "/api/messages", query={"accountId": ACCOUNT_ID, "unread": "true"})
    add("messages.list.sender", "发件人归集 lens (exact from_address).",
        "GET", "/api/messages", query={"accountId": ACCOUNT_ID, "sender": SENDER})
    add("messages.list.malformed-account", "accountId must parse as a UUID.",
        "GET", "/api/messages", query={"accountId": "not-a-uuid"})
    add("messages.list.missing-account", "accountId is required.",
        "GET", "/api/messages")
    add("messages.list.b", "The populated account: two headers, newest first.",
        "GET", "/api/messages", query={"accountId": ACCOUNT_ID_B})

    # Local read-only surfaces
    add("folder-counts", "Sidebar tallies: live/unread/archived/pinned/deleted/sent.",
        "GET", "/api/folder-counts", query={"accountId": ACCOUNT_ID})
    add("senders", "Sender ranking over the local store.",
        "GET", "/api/senders", query={"accountId": ACCOUNT_ID})
    add("senders.data", "One sender, two messages, one unread.",
        "GET", "/api/senders", query={"accountId": ACCOUNT_ID_B})
    add("export.index", "Export index: every header, oldest first, no limit.",
        "GET", "/api/export/index", query={"accountId": ACCOUNT_ID})
    add("advice.list", "Read-only advice queue (account A is deliberately empty).",
        "GET", "/api/advice", query={"accountId": ACCOUNT_ID})
    add("advice.list.data", "The default queue lens: pending suggestions only.",
        "GET", "/api/advice", query={"accountId": ACCOUNT_ID_B})
    add("advice.list.all", "decision=any returns every verdict, newest first.",
        "GET", "/api/advice", query={"accountId": ACCOUNT_ID_B, "decision": "any"})
    add("advice.accepted-stats", "The read-only learning signal: accepted (category, action) shapes.",
        "GET", "/api/advice/accepted-stats", query={"accountId": ACCOUNT_ID_B})
    add("stacks.list", "聚合规则 list (account A is deliberately empty).",
        "GET", "/api/stacks", query={"accountId": ACCOUNT_ID})
    add("stacks.list.data", "Two rules with their live counts (sender + keyword).",
        "GET", "/api/stacks", query={"accountId": ACCOUNT_ID_B})
    add("reminders.list", "Reminders (account A is deliberately empty).",
        "GET", "/api/reminders", query={"accountId": ACCOUNT_ID})
    add("reminders.list.data", "Only the reminder still waiting.",
        "GET", "/api/reminders", query={"accountId": ACCOUNT_ID_B})
    add("reminders.list.with-dismissed", "includeDismissed=true returns the dismissed row too.",
        "GET", "/api/reminders",
        query={"accountId": ACCOUNT_ID_B, "includeDismissed": "true"})
    add("time-saved", "Derived from ai_actions; zeros for the account with no history.",
        "GET", "/api/time-saved", query={"accountId": ACCOUNT_ID})
    add("time-saved.data", "One sent reply today: minutes/handled/byDay are non-zero.",
        "GET", "/api/time-saved", query={"accountId": ACCOUNT_ID_B})
    add("actions.list.data", "The undo history: a pin and a sent reply, newest first.",
        "GET", "/api/actions", query={"accountId": ACCOUNT_ID_B})
    add("usage", "Monthly AI spend; zero calls, no cap configured.",
        "GET", "/api/usage")
    add("ai-status", "Global AI degraded signal: unconfigured in a fresh sidecar.",
        "GET", "/api/ai-status")
    add("store-notices", "Store notices (empty: the body key was present).",
        "GET", "/api/store-notices")
    add("briefing", "Briefing feed; the seeded mail is older than the 30-day window.",
        "GET", "/api/briefing", query={"accountId": ACCOUNT_ID})
    # /api/search is NOT captured live: v3.2.0 always answers 500 (the pass-B SQL
    # references a.category without JOINing advice). Its fixtures are synthesized
    # in capture() from the contract + the headers this store already produced,
    # and marked "contract_expected" - see synthesize_contract_expected().

    # Provider-backed reads: the credentials blob cannot be opened, so these
    # answer 503 provider-not-configured without opening any socket.
    add("body.provider-unconfigured", "Body read needs a provider; credentials are unreadable.",
        "GET", "/api/messages/%s/body" % REMOTE1, query={"accountId": ACCOUNT_ID})
    add("body.cached", "A sealed body cache answers 200 without touching the provider.",
        "GET", "/api/messages/%s/body" % REMOTE_B1, query={"accountId": ACCOUNT_ID_B})
    add("summary.provider-unconfigured", "Summary needs a body; the provider is unconfigured.",
        "GET", "/api/messages/%s/summary" % REMOTE1, query={"accountId": ACCOUNT_ID})
    add("draft.generate.provider-unconfigured",
        "Draft generation needs a body first; the provider is unconfigured.",
        "POST", "/api/messages/%s/draft" % REMOTE1, query={"accountId": ACCOUNT_ID})
    add("drafts.list.data", "One stored draft (variants are sealed at rest).",
        "GET", "/api/messages/%s/drafts" % REMOTE_B2, query={"accountId": ACCOUNT_ID_B})
    add("inline-images.provider-unconfigured", "Inline images parse one message once.",
        "GET", "/api/messages/%s/inline-images" % REMOTE1, query={"accountId": ACCOUNT_ID})
    add("raw-eml.provider-unconfigured", "Original RFC5322 bytes come from the provider.",
        "GET", "/api/messages/%s/raw.eml" % REMOTE1, query={"accountId": ACCOUNT_ID})
    add("sent.stale", "已发送: the local list answers even when the refresh failed.",
        "GET", "/api/sent", query={"accountId": ACCOUNT_ID})

    # Capability gate: seeded capabilities.archiveFolder == false -> 409.
    add("archive.capability-gate", "A settled archiveFolder=false answers 409 before any write.",
        "POST", "/api/messages/%s/archive" % REMOTE1, query={"accountId": ACCOUNT_ID})
    add("unknown-account", "A well-formed but unknown account id is a 404, not a 400.",
        "GET", "/api/folder-counts", query={"accountId": "99999999-9999-4999-8999-999999999999"})

    # --- account connect + sync (R3) ------------------------------------
    # POST /api/accounts/imap is the only endpoint that takes an account
    # credential, so its early answers are the ones that matter: they are
    # decided BEFORE any network work, which is why these fixtures never open a
    # socket even though the route normally probes IMAP.
    add("accounts.imap.empty-body",
        "An empty body cannot be decoded into the request struct: 400 missing-field.",
        "POST", "/api/accounts/imap", raw_body="")
    add("accounts.imap.missing-field",
        "A body without authCode cannot be decoded: 400 missing-field.",
        "POST", "/api/accounts/imap", body={"provider": "qq", "email": ACCOUNT_EMAIL_C})
    add("accounts.imap.unknown-provider",
        "provider must be a kind this build knows (qq): 400 missing-field.",
        "POST", "/api/accounts/imap",
        body={"provider": "gmail", "email": ACCOUNT_EMAIL_C, "authCode": "fixture"})
    add("accounts.imap.exists",
        "An email that is already connected and healthy: 409 account-exists, "
        "reported BEFORE any probe (no socket).",
        "POST", "/api/accounts/imap",
        body={"provider": "qq", "email": ACCOUNT_EMAIL_C, "authCode": "fixture"},
        pre="restore-account-c-ok")

    # Routing fallbacks
    add("unknown-route", "An unrouted path is Hummingbird's bare 404, not the error envelope.",
        "GET", "/api/definitely-not-a-route")
    add("unknown-route.v2", "Path spelling that looks like an API route still 404s.",
        "GET", "/api/messages/%s/nope" % REMOTE1, query={"accountId": ACCOUNT_ID})

    # Mutations last: they change local state, and nothing after them is read.
    write_skip = "write-path: Rust R2 is READ_ONLY; assert with LAGOON_CONTRACT_INCLUDE_WRITE=1"
    add("read.mark-read", "POST /read defaults to isRead=true; answers 204 with no body.",
        "POST", "/api/messages/%s/read" % REMOTE3, query={"accountId": ACCOUNT_ID},
        r2_skip=write_skip, mutates_store=True)
    add("read.recorded", "record=true returns the audit row id (actionId).",
        "POST", "/api/messages/%s/read" % REMOTE3, query={"accountId": ACCOUNT_ID, "record": "true"},
        r2_skip=write_skip, mutates_store=True)
    add("pin.set", "Pin toggles join the undo log; response carries the action id.",
        "POST", "/api/messages/%s/pin" % REMOTE1, query={"accountId": ACCOUNT_ID, "pinned": "true"},
        r2_skip=write_skip, mutates_store=True)

    # POST /api/sync: asks the engine for an immediate round. It answers 204
    # with no body, and it mutates local state like the writes above - it
    # restarts the sync loop, which is exactly what flips a seeded account to
    # needsReconnect - so replay runs it after every read.
    add("sync.request", "Wake the sync engine: 204, no body, no content-type.",
        "POST", "/api/sync", mutates_store=True)
    return fixtures


# --- contract-expected fixtures ---------------------------------------------

def synthesize_contract_expected(captured: dict) -> list:
    """Fixtures whose expected value comes from the CONTRACT, not from v3.

    /api/search is the only one: v3.2.0 answers 500 for every search (pass-B
    references a.category without JOINing advice), so capturing it would bake a
    bug into the oracle. The expected 200 SearchResponse below is built from
    (a) docs/api-contract.md 4.8, and (b) MessageHeader objects this same store
    really produced (export.index / messages.list.b) - the header bytes are not
    guessed.
    """
    def header(messages, remote):
        for message in messages:
            if message.get("remoteId") == remote:
                return message
        raise SystemExit("synthesize: %s missing from the captured headers" % remote)

    export_messages = captured["export.index"]["response"]["body"]["messages"]  # oldest first
    b_messages = captured["messages.list.b"]["response"]["body"]["messages"]    # newest first
    defect = (
        "v3.2.0 answers 500 internal-error for GET /api/search: the pass-B scan "
        "queries COALESCE((... a.category ...)) but only JOINs message_bodies, so "
        "SQLite raises 'no such column: a.category'. This fixture is NOT captured "
        "from v3; it is the contract's 200 SearchResponse shape."
    )
    common = {"truncated": False, "bodyScanSkipped": 0, "bodyScanLimit": 1000}
    return [
        {
            "name": "search.contract",
            "note": "Subject search on the list account: three hits, newest first.",
            "contract_expected": True,
            "defect_evidence": defect,
            "expected_source": "api-contract.md 4.8 + MessageHeader[] from export.index",
            "request": {"method": "GET", "path": "/api/search",
                        "query": {"q": "fixture", "accountId": ACCOUNT_ID},
                        "auth": "token", "headers": {}, "json": None},
            "response": {"status": 200,
                         "content_type": "application/json; charset=utf-8",
                         "body_kind": "json",
                         "body": dict({"results": list(reversed(export_messages)),
                                       "query": "fixture", "totalCount": 3}, **common)},
        },
        {
            "name": "search.contract.sealed-body",
            "note": "A query that matches only inside a sealed body: exactly one hit.",
            "contract_expected": True,
            "defect_evidence": defect,
            "expected_source": "api-contract.md 4.8 + MessageHeader[] from messages.list.b",
            "request": {"method": "GET", "path": "/api/search",
                        "query": {"q": "sealedneedle", "accountId": ACCOUNT_ID_B},
                        "auth": "token", "headers": {}, "json": None},
            "response": {"status": 200,
                         "content_type": "application/json; charset=utf-8",
                         "body_kind": "json",
                         "body": dict({"results": [header(b_messages, REMOTE_B1)],
                                       "query": "sealedneedle", "totalCount": 1}, **common)},
        },
    ]


# --- capture ----------------------------------------------------------------

def capture(base_url: str, token: str, db_path: str, body_key: str, out_dir: str) -> int:
    seed(db_path, body_key)
    fixtures = []
    for fixture in scenario():
        pre = fixture.get("pre")
        if pre:
            run_pre_hook(pre, db_path)
        response = http_request(base_url, fixture, token)
        fixture = dict(fixture)
        fixture["response"] = response
        fixtures.append(fixture)
        print("captured %-42s %s -> %s" % (
            fixture["name"], fixture["request"]["method"] + " " + fixture["request"]["path"],
            response["status"]))
    captured = {fixture["name"]: fixture for fixture in fixtures}
    synthesized = synthesize_contract_expected(captured)
    fixtures.extend(synthesized)
    for fixture in synthesized:
        print("expected %-42s %s -> 200 (contract_expected)" % (
            fixture["name"], fixture["request"]["path"]))

    payload = {
        "version": FIXTURES_VERSION,
        "note": ("Golden HTTP fixtures for the Lagoon v4 sidecar API. Captured from a real "
                 "LagoonServerCLI process on a throwaway SQLite store seeded with synthetic "
                 "rows; /api/search entries are contract_expected (v3 cannot answer them). "
                 "Regenerate with: bash v4/scripts/capture-contract.sh"),
        "normalized": sorted(TIMESTAMP_KEYS),
        "seed": {
            "accountId": ACCOUNT_ID,
            "accountEmail": ACCOUNT_EMAIL,
            "remoteIds": [REMOTE1, REMOTE2, REMOTE3],
            "accountIdB": ACCOUNT_ID_B,
            "accountEmailB": ACCOUNT_EMAIL_B,
            "remoteIdsB": [REMOTE_B1, REMOTE_B2],
            # Account C is the subject of the 409 account-exists fixture. It has
            # to be NAMED here: a replay prunes every account the seed block
            # does not list, so an unnamed C would be deleted before the
            # request (observed 2026-10-29: the Rust replay answered
            # missing-field where v3 answers account-exists).
            "accountIdC": ACCOUNT_ID_C,
            "accountEmailC": ACCOUNT_EMAIL_C,
            "stackRuleIds": [STACK_RULE_1, STACK_RULE_2],
            "noticeId": NOTICE_ID,
        },
        "fixtures": fixtures,
    }
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, "fixtures.json")
    # sort_keys=True is not cosmetic: Foundation's JSONEncoder emits object keys
    # in a per-process-random order (no .sortedKeys on the server), so without
    # canonical ordering two captures of identical data would differ byte-wise
    # and a fixture diff could never be read as a real change.
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")
    live = len(fixtures) - len(synthesized)
    print("wrote %s (%d fixtures: %d captured + %d contract_expected)" % (
        path, len(fixtures), live, len(synthesized)))
    return 0


# --- check ------------------------------------------------------------------

def _type_name(value) -> str:
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "bool"
    if isinstance(value, dict):
        return "object"
    if isinstance(value, list):
        return "array"
    if isinstance(value, (int, float)):
        return "number"
    return "string"


def diff_values(expected, actual, path: str, out: list) -> None:
    if _type_name(expected) != _type_name(actual):
        out.append("%s: expected %s, actual %s" % (path, _type_name(expected), _type_name(actual)))
        return
    if isinstance(expected, dict):
        for key in expected:
            if key not in actual:
                out.append("%s.%s: missing in actual (fixture has it)" % (path, key))
            else:
                diff_values(expected[key], actual[key], "%s.%s" % (path, key), out)
        for key in actual:
            if key not in expected:
                out.append("%s.%s: unexpected in actual (not in fixture)" % (path, key))
        return
    if isinstance(expected, list):
        if len(expected) != len(actual):
            out.append("%s: expected %d items, actual %d" % (path, len(expected), len(actual)))
        for index, (left, right) in enumerate(zip(expected, actual)):
            diff_values(left, right, "%s[%d]" % (path, index), out)
        return
    if expected != actual:
        out.append("%s: expected %s, actual %s" % (
            path, json.dumps(expected, ensure_ascii=False),
            json.dumps(actual, ensure_ascii=False)))


def compare_fixture(fixture: dict, response: dict) -> list:
    problems = []
    expected = fixture["response"]
    if expected.get("status") != response.get("status"):
        problems.append("status: expected %s, actual %s" % (expected.get("status"), response.get("status")))
    expected_ct = (expected.get("content_type") or "").strip().lower()
    actual_ct = (response.get("content_type") or "").strip().lower()
    if expected_ct != actual_ct:
        problems.append("content_type: expected %r, actual %r" % (expected_ct, actual_ct))
    if expected.get("body_kind") != response.get("body_kind"):
        problems.append("body_kind: expected %r, actual %r" % (
            expected.get("body_kind"), response.get("body_kind")))
    diff_values(expected.get("body"), response.get("body"), "$.body", problems)
    return problems


def load_fixtures(fixtures_dir: str) -> dict:
    path = os.path.join(fixtures_dir, "fixtures.json")
    with open(path, encoding="utf-8") as handle:
        payload = json.load(handle)
    if payload.get("version") != FIXTURES_VERSION:
        raise SystemExit("fixtures version %r is not supported (expected %d)" % (
            payload.get("version"), FIXTURES_VERSION))
    return payload


def check(
    base_url: str,
    token: str,
    fixtures_dir: str,
    db_path,
    body_key,
    verbose: bool,
    include_write: bool = False,
    assert_contract_expected: bool = False,
) -> int:
    payload = load_fixtures(fixtures_dir)
    if db_path:
        seed(db_path, body_key)
    failures = 0
    total = 0
    skipped = []
    include_known_defects = os.environ.get("LAGOON_CONTRACT_KNOWN_DEFECTS") == "1"
    # The write-path fixtures change the store on purpose: `read.mark-read`
    # marks fixture-msg-3 as read, and the search fixture that follows it
    # asserts the PRISTINE state (that message is unread). Replaying them in
    # file order therefore made the search fixture fail against a correct
    # implementation - the store it looked at had already been written to.
    #
    # So fixtures that mutate the store go last, and each class keeps its own
    # file order (`read.recorded` still has to run after `read.mark-read`).
    # `mutates_store` is the key; `r2_skip` is honoured as a fallback because
    # every fixture captured so far that carries it is a write.
    def mutates(fixture):
        return fixture.get("mutates_store") or fixture.get("r2_skip")

    ordered = [f for f in payload["fixtures"] if not mutates(f)]
    ordered += [f for f in payload["fixtures"] if mutates(f)]
    for fixture in ordered:
        if fixture.get("known_defect") and not include_known_defects:
            skipped.append((fixture["name"], "known defect; LAGOON_CONTRACT_KNOWN_DEFECTS=1"))
            continue
        if fixture.get("r2_skip") and not include_write:
            skipped.append((fixture["name"], fixture["r2_skip"]))
            continue
        if fixture.get("contract_expected") and not assert_contract_expected:
            skipped.append((
                fixture["name"],
                "contract_expected: the retired Swift sidecar could not produce it; "
                "run with --assert-contract-expected (contract-check does this by default)",
            ))
            continue
        total += 1
        pre = fixture.get("pre")
        if pre:
            run_pre_hook(pre, db_path)
        response = http_request(base_url, fixture, token)
        problems = compare_fixture(fixture, response)
        request = fixture["request"]
        label = "%s %s" % (request["method"], request["path"])
        query = request.get("query") or {}
        if query:
            label += "?" + urlencode(list(query.items()))
        if problems:
            failures += 1
            print("FAIL  %s  [%s]" % (fixture["name"], label))
            for problem in problems:
                print("        " + problem)
        elif verbose:
            print("ok    %s  [%s]" % (fixture["name"], label))
    print("")
    for name, reason in skipped:
        print("SKIP  %s (%s)" % (name, reason))
    if failures:
        print("%d of %d fixtures FAILED (%d skipped)" % (failures, total, len(skipped)))
        return 1
    suffix = " (%d skipped)" % len(skipped) if skipped else ""
    print("%d/%d fixtures match%s" % (total, total, suffix))
    return 0


# --- CLI --------------------------------------------------------------------

def main(argv) -> int:
    parser = argparse.ArgumentParser(description="Lagoon v4 contract harness (stdlib only)")
    subparsers = parser.add_subparsers(dest="command", required=True)

    seed_parser = subparsers.add_parser("seed", help="insert synthetic rows into a store")
    seed_parser.add_argument("--db", required=True)
    seed_parser.add_argument("--body-key", required=True,
                             help="base64 of the store's 32-byte body key (seals body/draft rows)")

    capture_parser = subparsers.add_parser("capture", help="capture fixtures from a live sidecar")
    capture_parser.add_argument("--base-url", required=True)
    capture_parser.add_argument("--token", required=True)
    capture_parser.add_argument("--db", required=True)
    capture_parser.add_argument("--body-key", required=True)
    capture_parser.add_argument("--out", required=True)

    check_parser = subparsers.add_parser("check", help="replay fixtures and diff")
    check_parser.add_argument("--base-url", required=True)
    check_parser.add_argument("--token", required=True)
    check_parser.add_argument("--fixtures", required=True)
    check_parser.add_argument("--db", default=None, help="seed this store before replaying")
    check_parser.add_argument("--body-key", default=None)
    check_parser.add_argument("--verbose", action="store_true")
    check_parser.add_argument("--include-write", action="store_true",
                              help="also replay write-path fixtures (R2 implementations skip them)")
    check_parser.add_argument("--assert-contract-expected", action="store_true",
                              help="assert fixtures whose expected value is the contract, not v3")

    # Running one pre-request hook by name. The Rust replay needs it too: the
    # 409 fixture's account must be healthy at request time, and the hook is
    # what makes that true regardless of whether a sync loop ran.
    pre_parser = subparsers.add_parser("pre", help="run one pre-request hook by name")
    pre_parser.add_argument("--hook", required=True)
    pre_parser.add_argument("--db", required=True)

    args = parser.parse_args(argv)
    if args.command == "seed":
        seed(args.db, args.body_key)
        return 0
    if args.command == "pre":
        run_pre_hook(args.hook, args.db)
        return 0
    if args.command == "capture":
        return capture(args.base_url, args.token, args.db, args.body_key, args.out)
    if args.db and not args.body_key:
        parser.error("check --db requires --body-key (the seed seals a body and a draft)")
    return check(
        args.base_url, args.token, args.fixtures, args.db, args.body_key,
        args.verbose, args.include_write, args.assert_contract_expected,
    )


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
