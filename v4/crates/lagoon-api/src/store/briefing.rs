//! The briefing feed's two queries (v3 BriefingRoutes.snapshot) and its signals.

use std::collections::HashSet;

use rusqlite::Connection;

use crate::timefmt::Timestamp;
use crate::uuid::Uuid;

use super::messages::{decode_message_row, MessageFilter, StoredMessage};

/// v3 BriefingRoutes.maxItems / maxBacklogItems / windowDays.
pub const WINDOW_DAYS: i64 = 30;
pub const MAX_ITEMS: i64 = 500;
pub const MAX_BACKLOG_ITEMS: i64 = 50;

pub struct BriefingSnapshot {
    pub messages: Vec<StoredMessage>,
    pub window_total: i64,
    pub backlog: Vec<StoredMessage>,
    pub backlog_total: i64,
}

impl BriefingSnapshot {
    /// Mail inside the window that the row cap withheld.
    pub fn omitted(&self) -> i64 {
        (self.window_total - self.messages.len() as i64).max(0)
    }
}

const MESSAGE_ROWS: &str = "
    SELECT h.id, h.account_id, h.remote_id, h.thread_id, h.from_address,
           NULLIF(h.from_name, '') AS from_name,
           NULLIF(h.subject, '') AS subject,
           NULLIF(h.snippet_cipher, '') AS snippet_cipher,
           h.received_at, h.is_read, h.is_archived, h.is_deleted, h.is_sent,
           h.message_id_header, h.in_reply_to, h.references_header,
           (message_pins.account_id IS NOT NULL) AS is_pinned
    FROM message_headers h
    LEFT JOIN message_pins
           ON message_pins.account_id = h.account_id
          AND message_pins.remote_id = h.remote_id
";

/// The feed's window rows plus the unresolved backlog - v3 BriefingRoutes.snapshot.
///
/// The window is a *lower time bound*, not a row count, because "the last 30
/// days" is what the user means by recent; the backlog reaches past it for mail
/// that is still unread, because a mail does not stop needing a reply by
/// getting old.
pub fn snapshot(
    connection: &Connection,
    account_id: Uuid,
    window_start: Timestamp,
    limit: i64,
) -> rusqlite::Result<BriefingSnapshot> {
    let window_filter = MessageFilter {
        received_after: Some(window_start),
        ..MessageFilter::inbox(account_id)
    };
    let (window_clause, window_arguments) = window_filter.where_clause();

    let backlog_filter = MessageFilter {
        unread: true,
        ..MessageFilter::inbox(account_id)
    };
    let (backlog_axes, backlog_arguments) = backlog_filter.where_clause();
    let backlog_clause = format!("{backlog_axes}\nAND h.received_at < ?");

    let window_rows_sql = format!(
        "{MESSAGE_ROWS} {window_clause} ORDER BY h.received_at DESC LIMIT ?"
    );
    let window_count_sql = format!("SELECT COUNT(*) FROM message_headers h {window_clause}");
    let backlog_rows_sql = format!(
        "{MESSAGE_ROWS} {backlog_clause} ORDER BY h.received_at ASC LIMIT ?"
    );
    let backlog_count_sql = format!("SELECT COUNT(*) FROM message_headers h {backlog_clause}");

    // Two different statements share one WHERE clause, so the LIMIT value is
    // pushed onto a copy: the count must see exactly the clause's arguments.
    let mut window_rows_arguments = window_arguments.clone();
    window_rows_arguments.push(rusqlite::types::Value::Integer(limit.max(1)));

    let mut backlog_count_arguments = backlog_arguments.clone();
    backlog_count_arguments
        .push(rusqlite::types::Value::Text(crate::timefmt::to_stored(window_start)));

    let mut backlog_rows_arguments = backlog_count_arguments.clone();
    backlog_rows_arguments.push(rusqlite::types::Value::Integer(MAX_BACKLOG_ITEMS));

    let messages = query_messages(connection, &window_rows_sql, &window_rows_arguments)?;
    let window_total: i64 = connection.query_row(
        &window_count_sql,
        rusqlite::params_from_iter(window_arguments.iter()),
        |row| row.get(0),
    )?;
    let backlog = query_messages(connection, &backlog_rows_sql, &backlog_rows_arguments)?;
    let backlog_total: i64 = connection.query_row(
        &backlog_count_sql,
        rusqlite::params_from_iter(backlog_count_arguments.iter()),
        |row| row.get(0),
    )?;

    Ok(BriefingSnapshot {
        messages,
        window_total,
        backlog,
        backlog_total,
    })
}

fn query_messages(
    connection: &Connection,
    sql: &str,
    arguments: &[rusqlite::types::Value],
) -> rusqlite::Result<Vec<StoredMessage>> {
    let mut statement = connection.prepare(sql)?;
    let mut rows = statement.query(rusqlite::params_from_iter(arguments.iter()))?;
    let mut messages = Vec::new();
    while let Some(row) = rows.next()? {
        messages.push(decode_message_row(row)?);
    }
    Ok(messages)
}

/// v3 MessageStore.pinnedIds: every pinned remote id for the account.
pub fn pinned_ids(connection: &Connection, account_id: Uuid) -> rusqlite::Result<HashSet<String>> {
    let mut statement =
        connection.prepare("SELECT remote_id FROM message_pins WHERE account_id = ?")?;
    let mut rows = statement.query([account_id.as_bytes().as_slice()])?;
    let mut ids = HashSet::new();
    while let Some(row) = rows.next()? {
        if let Some(remote_id) = row.get::<_, Option<String>>(0)? {
            ids.insert(remote_id);
        }
    }
    Ok(ids)
}

/// v3 MessageStore.listUnsubscribeIds: rows whose metadata carried a
/// List-Unsubscribe header. Deliberately spans every axis - an archived
/// newsletter still teaches the classifier what subscription mail looks like.
pub fn list_unsubscribe_ids(
    connection: &Connection,
    account_id: Uuid,
) -> rusqlite::Result<HashSet<String>> {
    let mut statement = connection.prepare(
        "SELECT remote_id FROM message_headers
         WHERE account_id = ? AND list_unsubscribe = TRUE",
    )?;
    let mut rows = statement.query([account_id.as_bytes().as_slice()])?;
    let mut ids = HashSet::new();
    while let Some(row) = rows.next()? {
        if let Some(remote_id) = row.get::<_, Option<String>>(0)? {
            ids.insert(remote_id);
        }
    }
    Ok(ids)
}
