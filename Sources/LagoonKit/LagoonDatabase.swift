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
/// Dates are stored as TEXT in GRDB's default `Date` format
/// `"yyyy-MM-dd HH:mm:ss.SSS"` (UTC, `en_US_POSIX` locale), which is also what
/// SQLite's `strftime('%Y-%m-%d %H:%M:%f','now')` produces, so SQL-side
/// expressions like `strftime('%Y-%m-%d %H:%M:%f','now','-30 days')` agree
/// with Swift-side `Date()`. (GRDB 7 offers no alternate encoding strategy
/// here; a REAL Julian day would not be read back as the same instant.)
/// Bools are INTEGER 1/0 (SQLite understands `TRUE`/`FALSE` literals since
/// 3.23, so existing query text keeps them). JSON columns are TEXT holding
/// `JSONEncoder` output. UUIDs are 16-byte BLOBs (GRDB default).
public enum LagoonDatabase {
    /// The schema migration. A fresh SQLite install starts here directly.
    /// The historical 19 Postgres migrations were consolidated — remote
    /// mail is re-syncable, so no data migrates.
    public static let currentVersion = "lagoon-v1"
    /// Index-only follow-up. See `indexReconciliation`.
    public static let indexVersion = "lagoon-v2"

    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration(currentVersion) { db in
            // GRDB's execute runs every statement in the string; the
            // `-- statement` markers are layout, not parsing.
            try db.execute(sql: Self.schema)
        }
        migrator.registerMigration(indexVersion) { db in
            try db.execute(sql: Self.indexReconciliation)
        }
        return migrator
    }

    /// GRDB records applied migrations by *identifier*, not by content, so
    /// editing `lagoon-v1`'s body does nothing for a database that already
    /// ran it — the index changes would have been silently absent from every
    /// existing install while looking correct in a fresh test database.
    /// This migration is the reconciliation, and it is written to be safe on
    /// both paths: `lagoon-v1` already omits the dropped indexes on a fresh
    /// install, so every statement here is `IF EXISTS` / `IF NOT EXISTS`.
    ///
    /// Indexes only — no table or column changes — so this stays cheap and
    /// cannot lose mail.
    static let indexReconciliation = """
        CREATE INDEX IF NOT EXISTS message_headers_account_sender_idx
            ON message_headers (account_id, from_address, received_at DESC)
            WHERE is_deleted = FALSE;
        -- statement
        CREATE INDEX IF NOT EXISTS message_headers_unread_idx
            ON message_headers (account_id)
            WHERE is_deleted = FALSE AND is_archived = FALSE AND is_read = FALSE;
        -- statement
        CREATE INDEX IF NOT EXISTS message_headers_list_unsubscribe_idx
            ON message_headers (account_id) WHERE list_unsubscribe = TRUE;
        -- statement
        CREATE INDEX IF NOT EXISTS ai_actions_undo_of_idx
            ON ai_actions (account_id, json_extract(payload, '$.undoOf'))
            WHERE kind = 'undo';
        -- statement
        DROP INDEX IF EXISTS message_headers_thread_idx;
        -- statement
        DROP INDEX IF EXISTS accounts_provider_idx;
        -- statement
        DROP INDEX IF EXISTS ai_actions_expires_idx;
    """

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
        CREATE INDEX message_headers_account_deleted_idx
            ON message_headers (account_id, received_at DESC) WHERE is_deleted = FALSE;
        -- statement
        -- Sender lens: MessageStore.recent's `from_address = ?` branch. The
        -- index is already ordered by received_at DESC, so the ORDER BY needs
        -- no sort; `is_archived` is not in the predicate because the archived
        -- view of the same lens reuses this index.
        CREATE INDEX message_headers_account_sender_idx
            ON message_headers (account_id, from_address, received_at DESC)
            WHERE is_deleted = FALSE;
        -- statement
        -- Unread count: MessageStore.unreadCount counts exactly these rows, so
        -- the index holds only unread headers and the count is a pure scan of
        -- a small tree instead of the whole account.
        CREATE INDEX message_headers_unread_idx
            ON message_headers (account_id)
            WHERE is_deleted = FALSE AND is_archived = FALSE AND is_read = FALSE;
        -- statement
        -- Unsubscribe candidates: MessageStore.listUnsubscribeIds. Most mail
        -- carries no List-Unsubscribe header, so this partial index is small.
        CREATE INDEX message_headers_list_unsubscribe_idx
            ON message_headers (account_id) WHERE list_unsubscribe = TRUE;
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
        -- Undo lookup: AIActionStore.timeSavedEvents runs a correlated
        -- NOT EXISTS per candidate row over `undo` actions. Without this the
        -- probe is a scan of every undo row in the account, so the cost is
        -- quadratic in actions; with it each probe is one index seek.
        CREATE INDEX ai_actions_undo_of_idx
            ON ai_actions (account_id, json_extract(payload, '$.undoOf'))
            WHERE kind = 'undo';
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
