//! The slice of v3's schema the R1 reads depend on.
//!
//! Copied column for column from a store the v3 sidecar migrated to
//! "lagoon-v10" (the dump in the R1 report), plus v4's `remote_uid` column
//! (`lagoon-v11`), which production adds by running the migration chain.
//! Only the five tables R1 selects
//! from are created, plus "grdb_migrations" so the startup probe sees the full
//! migration chain. Creating the whole twelve-table schema here would be a
//! second copy of v3's DDL that nothing keeps honest - and the point of the dev
//! store test (tests/dev_store.rs) is to run against the real one.

use rusqlite::Connection;

pub const DDL: &str = "
CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);

CREATE TABLE accounts (
    id              BLOB PRIMARY KEY,
    provider        TEXT NOT NULL CHECK (provider IN ('gmail','qq')),
    oauth_user      TEXT NOT NULL,
    email           TEXT NOT NULL,
    credentials     BLOB,
    sync_state      TEXT NOT NULL DEFAULT '{}',
    capabilities    TEXT NOT NULL DEFAULT '{}',
    is_active       INTEGER NOT NULL DEFAULT 0,
    sync_status     TEXT NOT NULL DEFAULT 'ok',
    last_sync_at    TEXT,
    last_sync_error TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f','now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f','now')),
    UNIQUE (provider, oauth_user)
);

CREATE TABLE message_headers (
    id                 BLOB PRIMARY KEY,
    account_id         BLOB NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    remote_id          TEXT NOT NULL,
    thread_id          TEXT NOT NULL,
    from_address       TEXT NOT NULL,
    from_name          TEXT,
    subject            TEXT,
    snippet_cipher     TEXT,
    received_at        TEXT NOT NULL,
    is_read            INTEGER NOT NULL DEFAULT FALSE,
    is_archived        INTEGER NOT NULL DEFAULT FALSE,
    fetched_at         TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f','now')),
    list_unsubscribe   INTEGER NOT NULL DEFAULT FALSE,
    message_id_header  TEXT,
    in_reply_to        TEXT,
    references_header  TEXT,
    unsubscribe_links  TEXT NOT NULL DEFAULT '[]',
    is_deleted         INTEGER NOT NULL DEFAULT FALSE,
    is_sent            INTEGER NOT NULL DEFAULT FALSE,
    remote_uid         INTEGER,
    UNIQUE (account_id, remote_id)
);

CREATE TABLE message_pins (
    account_id BLOB NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    remote_id  TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f','now')),
    PRIMARY KEY (account_id, remote_id)
);

CREATE TABLE message_bodies (
    account_id       BLOB NOT NULL,
    remote_id        TEXT NOT NULL,
    body_cipher      TEXT NOT NULL DEFAULT '',
    body_html_cipher TEXT,
    has_more         INTEGER NOT NULL DEFAULT FALSE,
    attachments      TEXT NOT NULL DEFAULT '[]',
    to_addresses     TEXT NOT NULL DEFAULT '[]',
    cc_addresses     TEXT NOT NULL DEFAULT '[]',
    fetched_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f','now')),
    PRIMARY KEY (account_id, remote_id),
    FOREIGN KEY (account_id, remote_id)
        REFERENCES message_headers(account_id, remote_id)
        ON DELETE CASCADE
);

CREATE TABLE stack_rules (
    id         BLOB PRIMARY KEY,
    account_id BLOB NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    name       TEXT NOT NULL,
    kind       TEXT NOT NULL CHECK (kind IN ('sender', 'keyword')),
    value      TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f','now'))
);

CREATE TABLE advice (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id BLOB NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    remote_id  TEXT NOT NULL,
    action     TEXT NOT NULL,
    category   TEXT,
    confidence TEXT NOT NULL DEFAULT 'medium',
    rationale  TEXT,
    due_text   TEXT,
    source     TEXT NOT NULL DEFAULT 'heuristic',
    model      TEXT,
    decision   TEXT NOT NULL DEFAULT 'pending',
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f','now')),
    decided_at TEXT,
    UNIQUE (account_id, remote_id),
    FOREIGN KEY (account_id, remote_id)
        REFERENCES message_headers(account_id, remote_id)
        ON DELETE CASCADE
);

CREATE TABLE ai_actions (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id BLOB NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    kind       TEXT NOT NULL,
    payload    TEXT NOT NULL DEFAULT '{}',
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f','now')),
    expires_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f','now','+30 days'))
);

CREATE TABLE draft_replies (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id     BLOB NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    remote_id      TEXT NOT NULL,
    variants       TEXT NOT NULL,
    chosen_variant INTEGER,
    created_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f','now'))
);

CREATE TABLE ai_overrides (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id BLOB NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    remote_id  TEXT NOT NULL,
    from_group TEXT NOT NULL,
    to_group   TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f','now')),
    scope TEXT NOT NULL DEFAULT 'sender',
    from_address TEXT
);

CREATE TABLE reminders (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id   BLOB NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    remote_id    TEXT NOT NULL,
    due_at       TEXT NOT NULL,
    note         TEXT,
    created_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f','now')),
    dismissed_at TEXT,
    UNIQUE (account_id, remote_id),
    FOREIGN KEY (account_id, remote_id)
        REFERENCES message_headers(account_id, remote_id)
        ON DELETE CASCADE
);

CREATE TABLE store_notices (
    id         TEXT PRIMARY KEY,
    detail     TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f','now'))
);

CREATE TABLE usage_log (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    year_month        TEXT NOT NULL,
    account_email     TEXT NOT NULL,
    capability        TEXT NOT NULL,
    model             TEXT NOT NULL,
    prompt_tokens     INTEGER NOT NULL,
    completion_tokens INTEGER NOT NULL,
    cost_micro_usd    INTEGER NOT NULL,
    created_at        TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f','now'))
);
";

/// The migration chain a v3.2.0 store carries, in registration order.
pub const MIGRATIONS: &[&str] = &[
    "lagoon-v1",
    "lagoon-v2",
    "lagoon-v3",
    "lagoon-v4",
    "lagoon-v5",
    "lagoon-v5b",
    "lagoon-v6",
    "lagoon-v7",
    "lagoon-v8",
    "lagoon-v9",
    "lagoon-v10",
    "lagoon-v11",
];

/// Create the schema and record the migration chain.
pub fn create(connection: &Connection) -> rusqlite::Result<()> {
    connection.execute_batch(DDL)?;
    let mut statement =
        connection.prepare("INSERT INTO grdb_migrations (identifier) VALUES (?)")?;
    for migration in MIGRATIONS {
        statement.execute([migration])?;
    }
    Ok(())
}
