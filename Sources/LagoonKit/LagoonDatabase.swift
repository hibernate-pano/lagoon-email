import Foundation
import GRDB
import Logging

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
    /// Drops the whitelist auto-archive table. Advisory-only constitution §2
    /// rule 5: no rule may execute on its own, so the table has no reader left.
    public static let advisoryOnlyVersion = "lagoon-v3"
    /// Adds the read-only advice store (constitution §3).
    public static let adviceVersion = "lagoon-v4"
    /// Adds `is_sent` so the Sent folder can be listed (R1).
    ///
    /// ## Why a column and not a separate table
    ///
    /// A sent message is still a message: it has headers, a body, a thread, and
    /// it belongs in the same store so search, thread walk and the detail view
    /// work on it unchanged. A separate `sent_messages` table would duplicate
    /// every one of those and create a second thing to keep in sync — the exact
    /// shape that produced the "orphaned mail in no list" bug when 废纸篓 and
    /// 档案柜 each filtered on their own axis.
    ///
    /// The alternative — treating Sent as "messages whose from_address is me" —
    /// was rejected: it cannot distinguish a reply I sent from a message *to*
    /// me from the same person, and it breaks the moment the account has a
    /// second identity.
    public static let sentFolderVersion = "lagoon-v5"
    /// Seals the mail body at rest.
    ///
    /// The body used to be stored as plain TEXT while the spec (§6.6 rule 5)
    /// said it would be ciphertext. This migration renames the body columns
    /// so the schema can no longer be misread — `body_cipher` cannot be
    /// mistaken for a body — and seals every value that is still in the
    /// clear. See `BodyCipher` for what is sealed and what is deliberately
    /// left as metadata.
    public static let encryptedBodiesVersion = "lagoon-v6"
    /// Adds the reminder table, so the AI's "remind" suggestion is backed by
    /// something that actually happens.
    ///
    /// ## Why a table and not a notification scheduled on the spot
    ///
    /// A local notification is scheduled with the system, and the system
    /// forgets it: a reboot, a logout, a reinstall, and the reminder is
    /// gone. A row in the app's own store survives all of those, and the
    /// client re-arms the pending notifications on every launch. The
    /// notification is the delivery mechanism; the row is the truth.
    ///
    /// ## Why it is not part of `ai_actions`
    ///
    /// `ai_actions` is the undo history: every row there is something the
    /// user *did* to their mailbox, and every one of them can be undone.
    /// A reminder changes nothing about the mail — it is a note to
    /// yourself. Putting it in the undo history would make "撤销" offer to
    /// undo a note, and the audit view would claim the user did something
    /// they did not.
    public static let reminderVersion = "lagoon-v7"
    /// Tells an override how far it reaches: one mail, or one sender.
    ///
    /// ## Why this column and not a second table
    ///
    /// An override used to mean exactly one thing — "this sender's mail goes
    /// to that group" — because the row was keyed by a mail and *resolved*
    /// to a sender by a join. The user acted on one mail and the product
    /// moved every mail from that sender, silently (audit P2-13).
    ///
    /// The narrow case needs somewhere to live, and a **separate table** was
    /// the alternative. A second table would have been worse: two tables, two
    /// ranking rules, two undo paths, and two places for a future reader to
    /// look when a mail sits in an unexpected group. One table with an
    /// explicit `scope` keeps every override in one place, and the ranking
    /// query reads both scopes out of it.
    ///
    /// ## Why `scope` is absent from `schema`
    ///
    /// SQLite has no `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`, so a column
    /// that appears in `schema` (which only `lagoon-v1` runs, on a fresh
    /// install) would make this statement fail with "duplicate column name"
    /// on every fresh install while succeeding on every existing one — the
    /// same trap `is_sent` documented. Absent from `schema`, the ALTER is the
    /// first and only time the column is added, on both paths.
    ///
    /// ## Why the default is `sender`
    ///
    /// Every row that exists today is a sender-level override, and that is
    /// what it meant when it was written. Defaulting the new column to
    /// `sender` makes an existing install behave exactly as it did before the
    /// migration — no silent re-filing of a mailbox.
    public static let overrideScopeVersion = "lagoon-v8"
    /// Seals the AI-generated reply drafts at rest.
    ///
    /// ## Why the drafts had to be sealed too
    ///
    /// `lagoon-v6` sealed the body, the HTML body and the snippet, and the
    /// user's manual then listed exactly what stayed in the clear: sender,
    /// subject, time, attachment names. The drafts were in neither list — and
    /// they were in the clear.
    ///
    /// A draft is *generated from* the mail: "关于贵方提出的开源维护者合作方
    /// 案" is the substance of somebody else's email, reproduced verbatim in
    /// a column the product never sealed. So the guarantee the manual
    /// described was true for the body and false for a column holding body
    /// text, and a reader of the backup file would have found it.
    ///
    /// ## Why a new migration and not a change to `lagoon-v6`
    ///
    /// GRDB records applied migrations by *identifier*, not by content, so
    /// editing `lagoon-v6` would do nothing for every install that already
    /// ran it — the sealing would be silently absent from every existing
    /// install while looking correct in a fresh test database. The same
    /// reason `indexReconciliation` and `advisoryOnlyReconciliation` exist.
    ///
    /// ## Why it also creates `store_notices`
    ///
    /// The fail-closed path (no key) **deletes** the drafts that cannot be
    /// sealed, because a plaintext draft is exactly what this migration
    /// exists to remove and a draft is regenerable. But deleting the user's
    /// work without saying so is not acceptable: the deletion is recorded in
    /// `store_notices` so the app can tell the user their drafts are gone.
    public static let sealedDraftsVersion = "lagoon-v9"
    /// Normalises an `accounts.id` that is stored in the wrong *encoding*.
    ///
    /// ## The defect
    ///
    /// `accounts.id` is `BLOB PRIMARY KEY`, and GRDB stores a `UUID` as 16
    /// raw bytes. One install had the same UUID in **two encodings**: the
    /// parent row held the 36-character UTF-8 text, while every child table
    /// held the 16-byte binary form. SQLite compares BLOB and TEXT as
    /// different values, so the parent row was unreachable by every
    /// `WHERE id = ?` the server issues.
    ///
    /// The consequences reached all the way to the screen: the account could
    /// not be found, so the sync failed, so the row's `sync_status` became
    /// `needsReconnect` — and the user was told their **authorization code
    /// had expired**, which was a lie. The code was fine; the row was
    /// unfindable. `ON DELETE CASCADE` stopped matching too, so deleting the
    /// account left 356 headers, 246 `ai_actions` and 124 `advice` rows
    /// behind as orphans, and `PRAGMA foreign_key_check` reported 727
    /// violations.
    ///
    /// ## Why the repair is a migration and not a lookup fallback
    ///
    /// A "find the account by trying both encodings" query would make the
    /// account findable while leaving the store corrupt: the cascade would
    /// still not fire and the violations would still be there. The encoding
    /// has to be *fixed*.
    ///
    /// ## Why the binary form is the target
    ///
    /// Because every query in the server binds a `UUID`, and GRDB encodes a
    /// `UUID` as 16 bytes. A row whose id is the text form is unreachable
    /// whatever the other rows hold. So the repair normalises the parent
    /// **and** any child row still holding the text form onto the binary
    /// form. See `AccountIDRepair` for the full argument.
    ///
    /// ## Why it must run *before* `lagoon-v6`
    ///
    /// This is the part that is easy to get wrong, and it is not a detail.
    ///
    /// GRDB runs `PRAGMA foreign_key_check` at the end of every deferred
    /// migration, and aborts the migration if it finds a violation. `lagoon-v6`
    /// is a deferred migration, so on a store that still carries the
    /// mismatched id — 727 violations, as the real install had — **the app
    /// cannot open its own database at all**: the open fails with a SQLite
    /// constraint error before a single query is served.
    ///
    /// The repair therefore has to be registered *before* `lagoon-v6`, not
    /// after it. A migration registered later would be correct in every
    /// other respect and still useless: the store would never get far enough
    /// to run it.
    ///
    /// The identifier is `lagoon-v5b` rather than a later `lagoon-vN`
    /// because the number here is not a position in the chain — it is
    /// chosen to read as "after v5, before v6", which is exactly where it
    /// runs. GRDB orders migrations by *registration*, not by identifier, so
    /// the identifier is documentation, not a schedule.
    public static let accountIDRepairVersion = "lagoon-v5b"
    /// Gives an override the sender it is about.
    ///
    /// ## The defect
    ///
    /// An override row was keyed by the **mail** the user acted on, and the
    /// sender it applied to was recovered by joining `message_headers`. That
    /// join is an inner join, so the rule stopped existing the moment its
    /// sample mail was deleted — silently, with nothing said, and without
    /// the user's 「把这个发件人的邮件归到 X 组」 gesture anywhere in the
    /// product. The row was still in the table; it had simply stopped
    /// applying to anything.
    ///
    /// ## Why a column and not a second table
    ///
    /// The rule is about a **sender**; the mail was only ever the sample the
    /// user acted on. Storing the sender makes the rule stand on its own,
    /// which is the only way it can outlive the sample.
    ///
    /// ## Why the column is absent from `schema`
    ///
    /// SQLite has no `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`, so a column
    /// that appears in `schema` (which only `lagoon-v1` runs, on a fresh
    /// install) would make this statement fail with "duplicate column name"
    /// on every fresh install while succeeding on every existing one — the
    /// same trap `is_sent` and `scope` documented.
    ///
    /// ## Why the backfill cannot save every row
    ///
    /// The address is recovered from the sample mail, so a row whose sample
    /// is already gone stays unattributed. That rule was lost before this
    /// migration ran; what this migration stops is the next one from being
    /// lost the same way. The backfill says so in the log rather than
    /// pretending the row is whole.
    public static let overrideSenderVersion = "lagoon-v10"

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
        migrator.registerMigration(advisoryOnlyVersion) { db in
            try db.execute(sql: Self.advisoryOnlyReconciliation)
        }
        migrator.registerMigration(adviceVersion) { db in
            try db.execute(sql: Self.adviceReconciliation)
        }
        migrator.registerMigration(sentFolderVersion) { db in
            try db.execute(sql: Self.sentFolderReconciliation)
        }
        // Registered *before* `lagoon-v6` on purpose: GRDB runs a foreign
        // key check at the end of every deferred migration, and `lagoon-v6`
        // is one. On a store that still carries the mismatched id, that
        // check aborts the migration — and the app cannot open its own
        // database. Repairing the id first is what lets the store open.
        migrator.registerMigration(accountIDRepairVersion) { db in
            // The repair is data, not schema, and it needs the foreign key
            // checks to be deferred while it moves a parent key that its
            // children point at. `defer_foreign_keys` is scoped to the
            // transaction, so it is switched on here and off again in the
            // same breath — it must not leak into the next migration.
            try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
            let outcomes = try AccountIDRepair.repairAccountIDs(in: db)
            try db.execute(sql: "PRAGMA defer_foreign_keys = OFF")
            for outcome in outcomes {
                Logger(label: "lagoon.database").warning(
                    "store.accountIDRepaired",
                    metadata: [
                        "account": .string(outcome.uuid.uuidString),
                        "from": .string(String(describing: outcome.from)),
                        "children": .string("\(outcome.childRowsRewritten)"),
                        "skipped": .string("\(outcome.childRowsSkipped)"),
                    ]
                )
            }
        }
        migrator.registerMigration(encryptedBodiesVersion) { db in
            try db.execute(sql: Self.encryptedBodiesReconciliation)
            // The rename is schema; the sealing is data, and it needs the
            // key. It runs here, inside the migration, so a store is never
            // left half-sealed: either every body is an envelope or the
            // migration rolls back and the app refuses to open the store.
            try BodyCipher.sealLegacyRows(in: db)
        }
        migrator.registerMigration(reminderVersion) { db in
            try db.execute(sql: Self.reminderReconciliation)
        }
        migrator.registerMigration(overrideScopeVersion) { db in
            try db.execute(sql: Self.overrideScopeReconciliation)
        }
        migrator.registerMigration(sealedDraftsVersion) { db in
            try db.execute(sql: Self.sealedDraftsReconciliation)
            // The sealing is data, and it needs the key. It runs here,
            // inside the migration, so a store is never left half-sealed:
            // either every draft is an envelope or the migration rolls back.
            try DraftCipher.sealLegacyRows(in: db)
        }
        migrator.registerMigration(overrideSenderVersion) { db in
            try db.execute(sql: Self.overrideSenderReconciliation)
        }
        return migrator
    }

    /// Creates the table the store uses to tell the user about something it
    /// did on their behalf.
    ///
    /// `IF NOT EXISTS` keeps a fresh install — whose `lagoon-v1` body
    /// already creates the table — on the same path, exactly as every other
    /// reconciliation here does.
    public static let sealedDraftsReconciliation = """
        CREATE TABLE IF NOT EXISTS store_notices (
            id         TEXT PRIMARY KEY,
            detail     TEXT,
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f','now'))
        );
    """

    /// Adds the override scope column to an already-migrated install.
    ///
    /// `ADD COLUMN ... DEFAULT 'sender'` is safe on every path: SQLite fills
    /// the default into the existing rows, so the overrides an install
    /// already has keep the meaning they had.
    public static let overrideScopeReconciliation = """
        ALTER TABLE ai_overrides ADD COLUMN scope TEXT NOT NULL DEFAULT 'sender';
    """

    /// Gives every override the sender it is about, and indexes the lookups.
    ///
    /// The backfill reads the address off the sample mail the rule was
    /// written from. A rule whose sample is already gone cannot be
    /// attributed — the address was never stored anywhere else — so it stays
    /// unattributed, and the sender-level lookup skips it. That rule was
    /// lost before this migration ran; what this migration stops is the
    /// next one from being lost the same way.
    ///
    /// The index carries the columns the sender-level lookup reads
    /// (`account_id`, `scope`, `from_address`, `created_at`, `to_group`),
    /// so the ranking runs off the index instead of scanning the table and
    /// sorting what it finds.
    public static let overrideSenderReconciliation = """
        ALTER TABLE ai_overrides ADD COLUMN from_address TEXT;
        -- statement
        UPDATE ai_overrides
        SET from_address = (
            SELECT m.from_address
            FROM message_headers m
            WHERE m.account_id = ai_overrides.account_id
              AND m.remote_id = ai_overrides.remote_id
        )
        WHERE from_address IS NULL;
        -- statement
        CREATE INDEX IF NOT EXISTS ai_overrides_account_scope_idx
            ON ai_overrides (account_id, scope, from_address, created_at, to_group);
    """

    /// Adds the reminder table to an already-migrated install.
    ///
    /// `IF NOT EXISTS` keeps a fresh install — whose `lagoon-v1` body
    /// creates the table — on the same path, exactly as every other
    /// reconciliation here does.
    public static let reminderReconciliation = """
        CREATE TABLE IF NOT EXISTS reminders (
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
        -- statement
        -- The list the client opens: the reminders still waiting, soonest
        -- first. `dismissed_at IS NULL` is the "still waiting" half, and
        -- the index carries it so the query does not scan the whole table.
        CREATE INDEX IF NOT EXISTS reminders_pending_idx
            ON reminders (account_id, dismissed_at, due_at);
    """

    /// Renames the body columns so the schema cannot be misread.
    ///
    /// A `RENAME COLUMN` is the whole of it: SQLite rewrites the table
    /// definition in place, keeps the composite primary key and the foreign
    /// key into `message_headers` intact, and leaves the *values* alone —
    /// which is what lets the sealing step that follows find them.
    ///
    /// The names are deliberately not "body_text" any more. A column called
    /// `body_text` that holds ciphertext is a trap for the next person who
    /// reads the schema, and it is exactly the kind of drift that let the
    /// spec and the implementation disagree for this long.
    static let encryptedBodiesReconciliation = """
        ALTER TABLE message_bodies RENAME COLUMN body_text TO body_cipher;
        -- statement
        ALTER TABLE message_bodies RENAME COLUMN body_html TO body_html_cipher;
        -- statement
        ALTER TABLE message_headers RENAME COLUMN snippet TO snippet_cipher;
    """

    /// R1: `is_sent` plus the index the Sent list reads through.
    ///
    /// `is_sent` is deliberately **absent from `schema`**, so this migration is
    /// the only thing that ever adds it — which is what makes it safe on both
    /// paths. SQLite has no `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`, so a
    /// column present in `schema` would make this statement fail with
    /// "duplicate column name" on every fresh install while succeeding on every
    /// existing one. Absent from `schema`, a fresh database simply has not run
    /// `lagoon-v5` yet, so the ALTER is the first and only time it executes.
    public static let sentFolderReconciliation = """
        ALTER TABLE message_headers ADD COLUMN is_sent INTEGER NOT NULL DEFAULT FALSE;
        -- statement
        CREATE INDEX IF NOT EXISTS message_headers_account_sent_idx
            ON message_headers (account_id, received_at DESC) WHERE is_sent = TRUE;
    """

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

    /// Removes the whitelist auto-archive rule table from an already-migrated
    /// install. Editing `lagoon-v1`'s body would be a silent no-op there (GRDB
    /// records migrations by identifier), so the removal needs its own
    /// migration — the same reason `indexReconciliation` exists. `IF EXISTS`
    /// keeps a fresh install, whose `lagoon-v1` no longer creates the table,
    /// on the same path.
    static let advisoryOnlyReconciliation = """
        DROP TABLE IF EXISTS auto_archive_rules;
    """

    /// Adds the advice table to an already-migrated install. `IF NOT EXISTS`
    /// keeps a fresh install — whose `lagoon-v1` body already creates it — on
    /// the same path, exactly as `indexReconciliation` does for indexes.
    static let adviceReconciliation = """
        CREATE TABLE IF NOT EXISTS advice (
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
        -- statement
        CREATE INDEX IF NOT EXISTS advice_queue_idx
            ON advice (account_id, decision, created_at DESC);
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
        // The body is sealed, so SQLite cannot match inside it. These two
        // functions put the decision back inside the query: `…_contains`
        // answers "does this sealed body contain the needle" for the search
        // route, and `…_seal` seals a whole column for the migration.
        //
        // Registered per connection — `prepareDatabase` runs for every
        // connection the pool hands out, including the one the migrator
        // borrows, which is why the migration can use `lagoon_cipher_seal`.
        configuration.prepareDatabase { db in
            db.add(function: BodyCipher.containsFunction)
            db.add(function: BodyCipher.sealFunction)
        }
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
        -- statement
        -- Read-only advice (constitution §3). One row per message, upserted as
        -- the classifier re-evaluates. Deliberately NOT part of `ai_actions`:
        -- a suggestion is not an action, and mixing them would put rows the
        -- user never acted on into the undo history.
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
        -- statement
        -- The decision queue: pending rows, newest first, per account.
        CREATE INDEX advice_queue_idx
            ON advice (account_id, decision, created_at DESC);
        -- statement
        -- Reminders the user set for themselves. A reminder points at a
        -- mail and survives a reboot — the notification is delivered from
        -- this row, not from the system's (forgettable) queue.
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
        -- statement
        CREATE INDEX reminders_pending_idx
            ON reminders (account_id, dismissed_at, due_at);
        -- statement
        -- One-shot notices the store raises for the user. A migration that
        -- had to drop what it could not encrypt writes one here, so the app
        -- can say "your drafts were deleted" instead of the user discovering
        -- an empty list and guessing.
        CREATE TABLE store_notices (
            id         TEXT PRIMARY KEY,
            detail     TEXT,
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f','now'))
        );
    """
}
