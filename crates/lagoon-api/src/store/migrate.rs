//! The migration engine.
//!
//! v3's authority is Sources/LagoonKit/LagoonDatabase.swift: eleven
//! registerMigration blocks. The DDL text lives in migrations.rs, generated from
//! that file; this module owns the parts that are not SQL text: the GRDB
//! bookkeeping table, one transaction per migration, and the three data steps
//! (account-id repair, body sealing, draft sealing).
//!
//! The bookkeeping has to be GRDB's, not ours: GRDB records progress in
//! grdb_migrations(identifier), and v3 decides "already migrated" by reading
//! that table. A store this crate creates must therefore look, to v3, exactly
//! like a store v3 created itself.

use rusqlite::types::Value;
use rusqlite::Connection;

use crate::crypto::{BodyKey, CipherError};
use crate::migrations;
use crate::uuid::Uuid;

#[derive(Debug)]
pub enum MigrationError {
    Sqlite(rusqlite::Error),
    Cipher(CipherError),
    /// A data step needed the body key and the caller did not supply one.
    MissingBodyKey,
}

/// Why a store could not be prepared for the server.
#[derive(Debug)]
pub enum PrepareError {
    Io(std::io::Error),
    /// The writable open failed (permissions, a directory in the way, ...).
    Open(String),
    Migration(MigrationError),
}

impl std::fmt::Display for PrepareError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PrepareError::Io(error) => write!(formatter, "io: {error}"),
            PrepareError::Open(message) => write!(formatter, "open: {message}"),
            PrepareError::Migration(error) => write!(formatter, "{error}"),
        }
    }
}

impl std::error::Error for PrepareError {}

impl From<MigrationError> for PrepareError {
    fn from(error: MigrationError) -> Self {
        PrepareError::Migration(error)
    }
}

impl std::fmt::Display for MigrationError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            MigrationError::Sqlite(error) => write!(formatter, "sqlite: {error}"),
            MigrationError::Cipher(error) => write!(formatter, "cipher: {error}"),
            MigrationError::MissingBodyKey => write!(formatter, "LAGOON_BODY_KEY is required"),
        }
    }
}

impl std::error::Error for MigrationError {}

impl From<rusqlite::Error> for MigrationError {
    fn from(error: rusqlite::Error) -> Self {
        MigrationError::Sqlite(error)
    }
}

impl From<CipherError> for MigrationError {
    fn from(error: CipherError) -> Self {
        MigrationError::Cipher(error)
    }
}

#[derive(Debug, Default)]
pub struct MigrationReport {
    pub applied: Vec<&'static str>,
    pub already_present: usize,
}

impl MigrationReport {
    pub fn is_noop(&self) -> bool {
        self.applied.is_empty()
    }
}

/// Creates the GRDB bookkeeping table if it is missing.
///
/// The statement is GRDB's own: v3 reads the table by name and column, and a
/// store created here has to be indistinguishable from one it created.
pub fn ensure_bookkeeping(connection: &Connection) -> Result<(), MigrationError> {
    connection.execute_batch(
        "CREATE TABLE IF NOT EXISTS grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)",
    )?;
    Ok(())
}

/// Applies every migration v3 knows about, in registration order.
pub fn migrate(
    connection: &Connection,
    body_key: Option<&BodyKey>,
) -> Result<MigrationReport, MigrationError> {
    connection.execute_batch("PRAGMA foreign_keys = ON")?;
    ensure_bookkeeping(connection)?;
    let mut report = MigrationReport::default();
    for migration in migrations::MIGRATIONS {
        let recorded: bool = connection.query_row(
            "SELECT EXISTS (SELECT 1 FROM grdb_migrations WHERE identifier = ?1)",
            [migration.identifier],
            |row| row.get(0),
        )?;
        if recorded {
            report.already_present += 1;
            continue;
        }
        // One transaction per migration, like DatabaseMigrator: either the DDL,
        // the data rewrite and the identifier row all land, or none of them do.
        // IMMEDIATE because a data step reads before it rewrites (see
        // `repair_account_ids`); a deferred snapshot that goes stale under a
        // concurrent writer is refused with SQLITE_BUSY_SNAPSHOT, which no busy
        // timeout retries.
        let transaction = rusqlite::Transaction::new_unchecked(
            connection,
            rusqlite::TransactionBehavior::Immediate,
        )?;
        migrations::apply(connection, migration, body_key)?;
        connection.execute(
            "INSERT INTO grdb_migrations (identifier) VALUES (?1)",
            [migration.identifier],
        )?;
        transaction.commit()?;
        report.applied.push(migration.identifier);
    }
    Ok(report)
}

/// Create the store when it is missing, then bring it to this build's chain.
///
/// A first launch has no store at all - not even the directory. v3 created and
/// migrated its store at startup, and refusing to start because "the store
/// does not exist" would make a fresh install unusable. A file that exists
/// but is not a Lagoon store is never written to: `Ok(None)` sends the caller
/// to its strict schema probe, which refuses a foreign database with a clear
/// message instead of half-migrating it.
///
/// `Ok(Some(report))` means this call did look at (and possibly migrated) a
/// real store.
pub fn prepare(
    path: &std::path::Path,
    body_key: Option<&BodyKey>,
) -> Result<Option<MigrationReport>, PrepareError> {
    let fresh = !path.exists();
    if fresh {
        if let Some(parent) = path.parent() {
            if !parent.as_os_str().is_empty() {
                std::fs::create_dir_all(parent).map_err(PrepareError::Io)?;
            }
        }
    } else if !crate::db::looks_like_a_lagoon_store(path) {
        // Somebody else's SQLite file: not ours to touch.
        return Ok(None);
    }
    let connection =
        crate::db::open_writable(path).map_err(|error| PrepareError::Open(error.to_string()))?;
    let report = migrate(&connection, body_key)?;
    Ok(Some(report))
}

/// The child tables that carry an account_id, with whether they also carry the
/// (account_id, remote_id) uniqueness a text-to-binary rewrite can collide with.
///
/// This list must stay complete: a table that is missing here keeps its old
/// text account_id, so its rows stop matching the account after the rewrite
/// (and ON DELETE CASCADE stops firing). `reminders` was the case that got
/// away — it has had account_id since lagoon-v1, so it exists when v5b runs.
/// Tables added after v5b (message_summaries, lagoon-v12) do not exist yet at
/// that point and must not be listed.
const CHILD_TABLES: [(&str, bool); 9] = [
    ("message_headers", true),
    ("message_bodies", false),
    ("advice", true),
    ("ai_actions", false),
    ("draft_replies", false),
    ("message_pins", false),
    ("stack_rules", false),
    ("ai_overrides", false),
    ("reminders", true),
];

/// lagoon-v5b: move account ids stored as text onto the 16-byte form.
///
/// The defect: one install held the same UUID twice, as text in accounts.id and
/// as bytes in every child row. SQLite compares text and blob as different
/// values, so the parent was unreachable, ON DELETE CASCADE never fired, and
/// foreign_key_check reported hundreds of violations.
///
/// Both sides move onto the binary form because that is what every query binds.
/// A row that would collide with an existing (account_id, remote_id) pair is
/// left alone and counted, which is v3's rule too: the repair never deletes.
pub fn repair_account_ids(connection: &Connection) -> Result<(), MigrationError> {
    connection.execute_batch("PRAGMA defer_foreign_keys = ON")?;
    let mut statement = connection.prepare("SELECT id FROM accounts")?;
    let rows = statement.query_map([], |row| row.get::<_, Value>(0))?;
    let mut accounts: Vec<Value> = Vec::new();
    for row in rows {
        accounts.push(row?);
    }
    drop(statement);

    for value in accounts {
        let Value::Text(text) = value else { continue };
        let Some(uuid) = Uuid::parse_strict(&text) else {
            continue;
        };
        let bytes = uuid.as_bytes().to_vec();
        let mut collision = false;
        for (table, unique) in CHILD_TABLES {
            if !unique {
                continue;
            }
            let sql = format!(
                "SELECT COUNT(*) FROM {table}
                 WHERE remote_id IN (SELECT remote_id FROM {table} WHERE account_id = ?1)
                   AND account_id = ?2"
            );
            let count: i64 =
                connection.query_row(&sql, rusqlite::params![bytes, text], |row| row.get(0))?;
            if count > 0 {
                collision = true;
                break;
            }
        }
        if collision {
            continue;
        }
        for (table, _) in CHILD_TABLES {
            connection.execute(
                &format!("UPDATE {table} SET account_id = ?1 WHERE account_id = ?2"),
                rusqlite::params![bytes, text],
            )?;
        }
        connection.execute(
            "UPDATE accounts SET id = ?1 WHERE id = ?2",
            rusqlite::params![bytes, text],
        )?;
    }
    connection.execute_batch("PRAGMA defer_foreign_keys = OFF")?;
    Ok(())
}

/// lagoon-v6: seal every body that is still plaintext.
///
/// Fail-closed when there is no key, exactly like v3: the body cache is
/// regenerable, so it is deleted rather than kept in the clear, and the snippet
/// column is cleared (the header row is the mail and must survive).
pub fn seal_legacy_bodies(
    connection: &Connection,
    body_key: Option<&BodyKey>,
) -> Result<(), MigrationError> {
    let Some(key) = body_key else {
        connection.execute_batch("DELETE FROM message_bodies")?;
        connection.execute_batch(
            "UPDATE message_headers SET snippet_cipher = '' WHERE snippet_cipher IS NOT NULL",
        )?;
        return Ok(());
    };

    let mut statement = connection.prepare(
        "SELECT account_id, remote_id, body_cipher, body_html_cipher
         FROM message_bodies
         WHERE body_cipher NOT LIKE 'lgb1:%'
            OR (body_html_cipher IS NOT NULL AND body_html_cipher NOT LIKE 'lgb1:%')",
    )?;
    let rows = statement.query_map([], |row| {
        Ok((
            row.get::<_, Vec<u8>>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
            row.get::<_, Option<String>>(3)?,
        ))
    })?;
    let mut pending = Vec::new();
    for row in rows {
        pending.push(row?);
    }
    drop(statement);

    for (account_id, remote_id, body, html) in pending {
        let sealed_body = if body.starts_with("lgb1:") {
            body
        } else {
            key.seal(&body)?
        };
        let sealed_html = match html {
            Some(html) if html.starts_with("lgb1:") => Some(html),
            Some(html) => Some(key.seal(&html)?),
            None => None,
        };
        connection.execute(
            "UPDATE message_bodies SET body_cipher = ?1, body_html_cipher = ?2
             WHERE account_id = ?3 AND remote_id = ?4",
            rusqlite::params![sealed_body, sealed_html, account_id, remote_id],
        )?;
    }

    let mut statement = connection.prepare(
        "SELECT account_id, remote_id, snippet_cipher FROM message_headers
         WHERE snippet_cipher IS NOT NULL AND snippet_cipher != ''
           AND snippet_cipher NOT LIKE 'lgb1:%'",
    )?;
    let rows = statement.query_map([], |row| {
        Ok((
            row.get::<_, Vec<u8>>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
        ))
    })?;
    let mut pending = Vec::new();
    for row in rows {
        pending.push(row?);
    }
    drop(statement);

    for (account_id, remote_id, snippet) in pending {
        connection.execute(
            "UPDATE message_headers SET snippet_cipher = ?1
             WHERE account_id = ?2 AND remote_id = ?3",
            rusqlite::params![key.seal(&snippet)?, account_id, remote_id],
        )?;
    }
    Ok(())
}

/// lagoon-v9: seal every draft that is still plaintext JSON.
///
/// Same fail-closed rule as the body cache: drafts are regenerable, so without a
/// key they are deleted rather than kept readable.
pub fn seal_legacy_drafts(
    connection: &Connection,
    body_key: Option<&BodyKey>,
) -> Result<(), MigrationError> {
    let Some(key) = body_key else {
        connection.execute_batch("DELETE FROM draft_replies")?;
        return Ok(());
    };

    let mut statement = connection
        .prepare("SELECT id, variants FROM draft_replies WHERE variants NOT LIKE 'lgb1:%'")?;
    let rows = statement.query_map([], |row| {
        Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?))
    })?;
    let mut pending = Vec::new();
    for row in rows {
        pending.push(row?);
    }
    drop(statement);

    for (id, variants) in pending {
        // The column holds one JSON array; sealing the whole array keeps its
        // length and order unreadable, which is the point (v3 DraftCipher).
        let payload: Vec<String> = serde_json::from_str(&variants)
            .map_err(|_| MigrationError::Sqlite(rusqlite::Error::InvalidQuery))?;
        let json = serde_json::to_string(&payload)
            .map_err(|_| MigrationError::Sqlite(rusqlite::Error::InvalidQuery))?;
        connection.execute(
            "UPDATE draft_replies SET variants = ?1 WHERE id = ?2",
            rusqlite::params![key.seal(&json)?, id],
        )?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_key() -> BodyKey {
        use base64::Engine as _;
        let encoded =
            base64::engine::general_purpose::STANDARD.encode(b"0123456789abcdef0123456789abcdef");
        BodyKey::from_base64(&encoded).expect("test key")
    }

    fn open() -> Connection {
        let connection = Connection::open_in_memory().expect("in-memory database");
        connection
            .execute_batch("PRAGMA foreign_keys = ON")
            .expect("pragmas");
        connection
    }

    #[test]
    fn every_table_with_an_account_id_is_repaired() {
        // lagoon-v5b rewrites every child row's account_id from text to bytes.
        // A table it does not know about keeps the text form, so its rows stop
        // matching the account (and ON DELETE CASCADE stops firing) — the exact
        // defect v5b exists to remove, left half-done. `reminders` was missing.
        let connection = open();
        let key = test_key();
        migrate(&connection, Some(&key)).expect("migrate");

        // Tables this build creates after lagoon-v5b runs: they do not exist
        // when it is applied, so they cannot be in CHILD_TABLES.
        let created_after_v5b = ["message_summaries"];

        let tables: Vec<String> = {
            let mut statement = connection
                .prepare("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
                .expect("prepare");
            statement
                .query_map([], |row| row.get(0))
                .expect("query")
                .collect::<rusqlite::Result<Vec<String>>>()
                .expect("rows")
        };

        let repaired: Vec<&str> = CHILD_TABLES.iter().map(|(table, _)| *table).collect();
        for table in tables {
            if table == "accounts" || created_after_v5b.contains(&table.as_str()) {
                continue;
            }
            let has_account_id: bool = {
                let mut statement = connection
                    .prepare(&format!("PRAGMA table_info({table})"))
                    .expect("pragma");
                let columns: Vec<String> = statement
                    .query_map([], |row| row.get(1))
                    .expect("query")
                    .collect::<rusqlite::Result<Vec<String>>>()
                    .expect("rows");
                columns.iter().any(|column| column == "account_id")
            };
            if has_account_id {
                assert!(
                    repaired.contains(&table.as_str()),
                    "`{table}` carries an account_id but is not in CHILD_TABLES: \
                     lagoon-v5b would leave it pointing at the old text id"
                );
            }
        }
    }

    #[test]
    fn repair_moves_a_reminder_off_the_legacy_text_account_id() {
        // The behaviour behind the guard above, on the table that was missing.
        // A v3 install could hold the same UUID twice: as text in accounts.id
        // and (correctly) as bytes in every child row. The repair rewrites both
        // sides onto the bytes; if it skips reminders, store::reminders::pending
        // (which binds the bytes) can never find the row again.
        let connection = open();
        let key = test_key();
        migrate(&connection, Some(&key)).expect("migrate");
        let text_id = "11111111-1111-4111-8111-111111111111";
        let bytes = Uuid::parse_strict(text_id)
            .expect("uuid")
            .as_bytes()
            .to_vec();
        connection
            .execute(
                "INSERT INTO accounts (id, email, provider, oauth_user, is_active)
                 VALUES (?1, 'user@example.com', 'qq', 'user@example.com', TRUE)",
                [text_id],
            )
            .expect("text-shaped account");
        connection
            .execute(
                "INSERT INTO message_headers
                   (id, account_id, remote_id, thread_id, from_address, received_at)
                 VALUES (?1, ?2, 'm1', 'm1', 'sender@example.com', '2026-01-01 00:00:00.000')",
                rusqlite::params![vec![1u8; 16], text_id],
            )
            .expect("header under the text id");
        connection
            .execute(
                "INSERT INTO reminders (account_id, remote_id, due_at)
                 VALUES (?1, 'm1', '2026-01-02 00:00:00.000')",
                [text_id],
            )
            .expect("reminder under the text id");

        // The repair is a migration data step: it relies on running inside one
        // transaction so its deferred foreign-key checks are evaluated at
        // commit, after both sides have moved. Calling it in autocommit mode
        // checks after each statement and fails half-way.
        let transaction = rusqlite::Transaction::new_unchecked(
            &connection,
            rusqlite::TransactionBehavior::Immediate,
        )
        .expect("begin");
        repair_account_ids(&connection).expect("repair");
        transaction.commit().expect("commit");

        let account_id: Vec<u8> = connection
            .query_row("SELECT id FROM accounts", [], |row| row.get(0))
            .expect("account id");
        assert_eq!(account_id, bytes, "the account id must become the bytes");
        let reminder_account_id: Vec<u8> = connection
            .query_row("SELECT account_id FROM reminders", [], |row| row.get(0))
            .expect("reminder account id");
        assert_eq!(
            reminder_account_id, bytes,
            "the reminder must follow the account onto the bytes, or it is orphaned"
        );
        let violations: i64 = connection
            .query_row("SELECT COUNT(*) FROM pragma_foreign_key_check", [], |row| {
                row.get(0)
            })
            .expect("foreign_key_check");
        assert_eq!(
            violations, 0,
            "the repair must not leave the store inconsistent"
        );
    }

    #[test]
    fn every_known_migration_is_recorded_once() {
        let connection = open();
        let key = test_key();
        let report = migrate(&connection, Some(&key)).expect("migrate");
        // Eleven v3 migrations plus v4's additive lagoon-v11 and lagoon-v12.
        assert_eq!(report.applied.len(), 13);
        let recorded: i64 = connection
            .query_row("SELECT COUNT(*) FROM grdb_migrations", [], |row| row.get(0))
            .expect("count");
        assert_eq!(recorded, 13);
        // Every table v3 creates is there.
        for table in [
            "accounts",
            "message_headers",
            "message_bodies",
            "message_pins",
            "advice",
            "stack_rules",
            "reminders",
            "store_notices",
            "draft_replies",
            "ai_actions",
            "ai_overrides",
            "usage_log",
            "message_summaries",
        ] {
            let exists: i64 = connection
                .query_row(
                    "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1",
                    [table],
                    |row| row.get(0),
                )
                .expect("table probe");
            assert_eq!(exists, 1, "missing table {table}");
        }
    }

    #[test]
    fn migrating_twice_is_a_noop() {
        let connection = open();
        let key = test_key();
        migrate(&connection, Some(&key)).expect("first migrate");
        let second = migrate(&connection, Some(&key)).expect("second migrate");
        assert!(second.is_noop());
        assert_eq!(second.already_present, 13);
    }

    #[test]
    fn seal_bodies_rewrites_plaintext_and_is_idempotent() {
        let connection = open();
        let key = test_key();
        migrate(&connection, Some(&key)).expect("migrate");
        connection
            .execute_batch(
                "INSERT INTO accounts (id, provider, oauth_user, email)
                 VALUES (x'11111111111141118111111111111111', 'qq', 'u', 'a@b');
                 INSERT INTO message_headers
                     (id, account_id, remote_id, thread_id, from_address, received_at, snippet_cipher)
                 VALUES (x'22222222222242228222222222222222',
                         x'11111111111141118111111111111111', 'r1', 't1', 'a@b',
                         '2025-01-01 00:00:00.000', 'plain snippet');
                 INSERT INTO message_bodies (account_id, remote_id, body_cipher)
                 VALUES (x'11111111111141118111111111111111', 'r1', 'plain body');",
            )
            .expect("legacy rows");
        seal_legacy_bodies(&connection, Some(&key)).expect("seal");
        let body: String = connection
            .query_row("SELECT body_cipher FROM message_bodies", [], |row| {
                row.get(0)
            })
            .expect("body");
        assert!(body.starts_with("lgb1:"));
        assert_eq!(key.open(&body).expect("open"), "plain body");
        let snippet: String = connection
            .query_row("SELECT snippet_cipher FROM message_headers", [], |row| {
                row.get(0)
            })
            .expect("snippet");
        assert_eq!(key.open(&snippet).expect("open"), "plain snippet");
        // Running it again changes nothing.
        seal_legacy_bodies(&connection, Some(&key)).expect("second seal");
        let again: String = connection
            .query_row("SELECT body_cipher FROM message_bodies", [], |row| {
                row.get(0)
            })
            .expect("body");
        assert_eq!(again, body);
    }
}
