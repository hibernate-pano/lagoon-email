//! Reminders (v3 ReminderStore.pending / all).

use rusqlite::Connection;

use crate::db::{optional_timestamp_column, timestamp_column, uuid_column};
use crate::timefmt::Timestamp;
use crate::uuid::Uuid;

#[derive(Debug, Clone)]
pub struct ReminderRow {
    pub id: i64,
    pub account_id: Uuid,
    pub remote_id: String,
    pub subject: Option<String>,
    pub due_at: Timestamp,
    pub note: Option<String>,
    pub created_at: Timestamp,
    pub dismissed_at: Option<Timestamp>,
}

const COLUMNS: &str = "r.id, r.account_id, r.remote_id, r.due_at, r.note,
                       r.created_at, r.dismissed_at, m.subject";

/// Still-active reminders, due first (v3 ReminderStore.pending).
pub fn pending(connection: &Connection, account_id: Uuid) -> rusqlite::Result<Vec<ReminderRow>> {
    let sql = format!(
        "SELECT {COLUMNS}
         FROM reminders r
         JOIN message_headers m
           ON m.account_id = r.account_id AND m.remote_id = r.remote_id
         WHERE r.account_id = ? AND r.dismissed_at IS NULL
           AND m.is_deleted = FALSE
         ORDER BY r.due_at ASC
         LIMIT ?"
    );
    let mut statement = connection.prepare(&sql)?;
    let mut rows = statement.query(rusqlite::params![account_id.as_bytes().as_slice(), 200])?;
    collect(&mut rows)
}

/// Every reminder, active ones first (v3 ReminderStore.all).
pub fn all(connection: &Connection, account_id: Uuid) -> rusqlite::Result<Vec<ReminderRow>> {
    let sql = format!(
        "SELECT {COLUMNS}
         FROM reminders r
         JOIN message_headers m
           ON m.account_id = r.account_id AND m.remote_id = r.remote_id
         WHERE r.account_id = ? AND m.is_deleted = FALSE
         ORDER BY r.dismissed_at IS NOT NULL, r.due_at ASC
         LIMIT ?"
    );
    let mut statement = connection.prepare(&sql)?;
    let mut rows = statement.query(rusqlite::params![account_id.as_bytes().as_slice(), 500])?;
    collect(&mut rows)
}

fn collect(rows: &mut rusqlite::Rows<'_>) -> rusqlite::Result<Vec<ReminderRow>> {
    let mut reminders = Vec::new();
    while let Some(row) = rows.next()? {
        reminders.push(ReminderRow {
            id: row.get(0)?,
            account_id: uuid_column(row, 1)?,
            remote_id: row.get(2)?,
            subject: row.get(7)?,
            // v3's decoder throws on an unparseable due_at or created_at (the
            // route then answers 500), and reads dismissed_at leniently.
            due_at: timestamp_column(row, 3)?,
            note: row.get(4)?,
            created_at: timestamp_column(row, 5)?,
            dismissed_at: optional_timestamp_column(row, 6)?,
        });
    }
    Ok(reminders)
}
