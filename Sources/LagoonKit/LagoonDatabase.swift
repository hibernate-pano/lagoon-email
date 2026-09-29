import Foundation
import GRDB

/// The embedded SQLite database that replaces the Docker Postgres install
/// (storage v1, V3 rebuild). One file, owned by the app, under Application
/// Support. Nothing leaves the machine: mail bodies, credentials blobs and
/// the AI audit log all live here.
///
/// Concurrency model: a WAL `DatabasePool` is shared by every sync loop,
/// route and store. The old "one in-flight query per Postgres connection"
/// constraint is gone — GRDB serializes writes and pools readers, so the
/// per-loop `makeDB` indirection now returns the same pool.
///
/// Dates are stored as Julian-day REALs, which is both GRDB's default `Date`
/// codec and what SQLite's `strftime('%Y-%m-%d %H:%M:%f','now')` produces, so SQL-side
/// expressions like `strftime('%Y-%m-%d %H:%M:%f','now','-30 days')` agree with Swift-side `Date()`.
/// Bools are INTEGER 1/0 (SQLite understands `TRUE`/`FALSE` literals since
/// 3.23, so existing query text keeps them). JSON columns are TEXT holding
/// `JSONEncoder` output. UUIDs are 16-byte BLOBs (GRDB default).
public enum LagoonDatabase {
    /// The single migration for the embedded schema: a fresh SQLite install
    /// starts here directly. The historical 19 Postgres migrations were
    /// consolidated — remote mail is re-syncable, so no data migrates.
    public static let currentVersion = "lagoon-v1"

    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration(currentVersion) { db in
            // GRDB's execute runs every statement in the string; the
            // `-- statement` markers are layout, not parsing.
            try db.execute(sql: Self.schema)
        }
        return migrator
    }

    /// Opens (creating if needed) and migrates the database at `path`.
    public static func open(path: String) throws -> DatabasePool {
        let directory = (path as NSString).deletingLastPathComponent
        if !directory.isEmpty {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true
            )
        }
        var configuration = Configuration()
        // GRDB 7 enables foreign keys by default; stated explicitly because
        // the schema leans on ON DELETE CASCADE for reconciliation semantics.
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(path: path, configuration: configuration)
        try migrator.migrate(pool)
        return pool
    }

    // MARK: - Schema (SQLite dialect)

    /// The final state of migrations 001–019 expressed for SQLite.
    static let schema = """
        CREATE TABLE accounts (
            id              BLOB PRIMARY KEY,
            -- 'gmail' stays in the whitelist on purpose: rewriting a CHECK means
            -- rebuilding this table (7 foreign keys reference it), which buys
            -- nothing — the QQ-only app never writes the value, and a future
            -- provider re-adds it without a migration.
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
        -- statement
        CREATE INDEX accounts_provider_idx ON accounts (provider);
        -- statement
        CREATE TABLE message_headers (
            id                 BLOB PRIMARY KEY,
            account_id         BLOB NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            remote_id          TEXT NOT NULL,
            thread_id          TEXT NOT NULL,
            from_address       TEXT NOT NULL,
            from_name          TEXT,
            subject            TEXT,
            snippet            TEXT,
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
            UNIQUE (account_id, remote_id)
        );
        -- statement
        CREATE INDEX message_headers_account_received_idx
            ON message_headers (account_id, received_at DESC);
        -- statement
        CREATE INDEX message_headers_thread_idx
            ON message_headers (account_id, thread_id);
        -- statement
        CREATE INDEX message_headers_account_deleted_idx
            ON message_headers (account_id, received_at DESC) WHERE is_deleted = FALSE;
        -- statement
        CREATE TABLE message_pins (
            account_id BLOB NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            remote_id  TEXT NOT NULL,
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f','now')),
            PRIMARY KEY (account_id, remote_id)
        );
        -- statement
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
        -- statement
        CREATE INDEX usage_log_year_month_idx ON usage_log(year_month);
        -- statement
        CREATE TABLE ai_actions (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            account_id BLOB NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            kind       TEXT NOT NULL,
            payload    TEXT NOT NULL DEFAULT '{}',
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f','now')),
            expires_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f','now','+30 days'))
        );
        -- statement
        CREATE INDEX ai_actions_account_created_idx
            ON ai_actions(account_id, created_at DESC);
        -- statement
        CREATE INDEX ai_actions_expires_idx ON ai_actions(expires_at);
        -- statement
        -- Send idempotency (migration 009): one send per client requestId.
        CREATE UNIQUE INDEX ai_actions_send_request_idx
            ON ai_actions (account_id, json_extract(payload, '$.requestId'))
            WHERE kind = 'send' AND json_extract(payload, '$.requestId') IS NOT NULL;
        -- statement
        CREATE TABLE draft_replies (
            id             INTEGER PRIMARY KEY AUTOINCREMENT,
            account_id     BLOB NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            remote_id      TEXT NOT NULL,
            variants       TEXT NOT NULL,
            chosen_variant INTEGER,
            created_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f','now'))
        );
        -- statement
        CREATE INDEX draft_replies_remote_id_idx
            ON draft_replies(remote_id, created_at DESC);
        -- statement
        CREATE TABLE ai_overrides (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            account_id BLOB NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            remote_id  TEXT NOT NULL,
            from_group TEXT NOT NULL,
            to_group   TEXT NOT NULL,
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f','now'))
        );
        -- statement
        CREATE INDEX ai_overrides_remote_id_idx ON ai_overrides(remote_id);
        -- statement
        CREATE TABLE message_bodies (
            account_id    BLOB NOT NULL,
            remote_id     TEXT NOT NULL,
            body_text     TEXT NOT NULL DEFAULT '',
            body_html     TEXT,
            has_more      INTEGER NOT NULL DEFAULT FALSE,
            attachments   TEXT NOT NULL DEFAULT '[]',
            to_addresses  TEXT NOT NULL DEFAULT '[]',
            cc_addresses  TEXT NOT NULL DEFAULT '[]',
            fetched_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f','now')),
            PRIMARY KEY (account_id, remote_id),
            FOREIGN KEY (account_id, remote_id)
                REFERENCES message_headers(account_id, remote_id)
                ON DELETE CASCADE
        );
        -- statement
        CREATE TABLE auto_archive_rules (
            id             INTEGER PRIMARY KEY AUTOINCREMENT,
            account_id     BLOB NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            sender_address TEXT NOT NULL,
            created_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f','now')),
            UNIQUE (account_id, sender_address)
        );
        -- statement
        CREATE TABLE stack_rules (
            id         BLOB PRIMARY KEY,
            account_id BLOB NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            name       TEXT NOT NULL,
            kind       TEXT NOT NULL CHECK (kind IN ('sender', 'keyword')),
            value      TEXT NOT NULL,
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f','now'))
        );
        -- statement
        CREATE INDEX stack_rules_account_idx ON stack_rules (account_id);
        """
}
