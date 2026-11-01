//! The list, its filters, and the sidebar counts.
//!
//! Ported from `MessageStore` (`filterSQL`, `recent`, `count`, `unreadCount`,
//! `pinnedCount`, `sentCount`, `deletedCount`) with the SQL text kept as close
//! to the original as Rust string literals allow. The clause is built by
//! splicing **static fragments only**; every value is bound.

use rusqlite::types::Value;
use rusqlite::{Connection, Row};

use crate::db::{bool_column, timestamp_column, uuid_column};
use crate::timefmt::Timestamp;
use crate::uuid::Uuid;

use super::StoreError;

/// A 聚合规则 match arm: exact sender, or a case-insensitive subject contains.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StackMatch {
    Sender(String),
    Keyword(String),
}

/// Which list a read is asking for.
///
/// The axes are **mutually exclusive** exactly as v3 makes them: `pinned` is a
/// lens of its own (it ignores archived/deleted), `sent` and `deleted` each
/// ignore the archived axis, and only the ordinary inbox/archive view carries
/// `is_sent = FALSE`. Getting this wrong puts one row in two lists, which is
/// the bug class the v3 comments call out by name.
#[derive(Debug, Clone)]
pub struct MessageFilter {
    pub account_id: Uuid,
    pub sender: Option<String>,
    pub archived: bool,
    pub deleted: bool,
    pub sent: bool,
    pub pinned: bool,
    pub unread: bool,
    /// Lower time bound, not a row cap: v3's briefing window is "the last N
    /// days", and a fixed row count would drop mail on a busy week.
    pub received_after: Option<Timestamp>,
    pub stack: Option<StackMatch>,
}

impl MessageFilter {
    pub fn inbox(account_id: Uuid) -> Self {
        Self {
            account_id,
            sender: None,
            archived: false,
            deleted: false,
            sent: false,
            pinned: false,
            unread: false,
            received_after: None,
            stack: None,
        }
    }

    /// v3 `MessageStore.filterSQL` - the WHERE clause plus its bound values.
    ///
    /// The arguments are appended in the original order: account id first, then
    /// the stack arm, then the sender. Callers that add a `LIMIT` append after.
    pub fn where_clause(&self) -> (String, Vec<Value>) {
        let mut arguments: Vec<Value> = vec![Value::Blob(self.account_id.as_bytes().to_vec())];
        let mut clause = String::from("WHERE h.account_id = ?");

        if self.pinned {
            // 置顶 is a lens of its own: a pin means "I deliberately kept this",
            // and filing the message elsewhere does not un-keep it.
            clause.push_str(PINNED_WHERE_CLAUSE);
        } else {
            clause.push_str(" AND h.is_deleted = ");
            clause.push_str(if self.deleted { "TRUE" } else { "FALSE" });
            if self.sent {
                // Sent ignores the archived axis: an archived reply I sent still
                // belongs to 已发送.
                clause.push_str(" AND h.is_sent = TRUE");
            } else if self.deleted {
                // The Trash likewise ignores the archived axis, so a message that
                // was archived and then deleted is still reachable from exactly
                // one list.
            } else {
                clause.push_str(" AND h.is_archived = ");
                clause.push_str(if self.archived { "TRUE" } else { "FALSE" });
                clause.push_str(" AND h.is_sent = FALSE");
            }
        }

        if self.unread {
            clause.push_str(" AND h.is_read = FALSE");
        }

        match &self.stack {
            Some(StackMatch::Sender(address)) => {
                clause.push_str(" AND h.from_address = ?");
                arguments.push(Value::Text(address.clone()));
            }
            Some(StackMatch::Keyword(value)) => {
                clause.push_str(" AND h.subject LIKE ? ESCAPE '\\'");
                arguments.push(Value::Text(like_pattern(value)));
            }
            None => {}
        }

        if let Some(sender) = &self.sender {
            clause.push_str(" AND h.from_address = ?");
            arguments.push(Value::Text(sender.clone()));
        }

        // v3 filterSQL appends the lower time bound last; the binding has to be
        // in the column's stored shape for the TEXT comparison to be a date
        // comparison.
        if let Some(received_after) = self.received_after {
            clause.push_str(" AND h.received_at >= ?");
            arguments.push(Value::Text(crate::timefmt::to_stored(received_after)));
        }

        (clause, arguments)
    }
}

/// v3 `MessageStore.filterSQL`'s named constant: EXISTS rather than a join,
/// because the same predicate has to serve `recent()` (which joins the pin
/// table) and `count()` (which does not).
const PINNED_WHERE_CLAUSE: &str = " AND h.is_sent = FALSE AND EXISTS (SELECT 1 FROM message_pins p WHERE p.account_id = h.account_id AND p.remote_id = h.remote_id)";

/// v3 `MessageStore.likePattern(containing:)`: escape LIKE metacharacters so a
/// keyword like `100%` matches literally, then wrap in `%…%`.
pub fn like_pattern(containing: &str) -> String {
    let mut pattern = String::with_capacity(containing.len() + 2);
    pattern.push('%');
    for character in containing.chars() {
        match character {
            '\\' => pattern.push_str("\\\\"),
            '%' => pattern.push_str("\\%"),
            '_' => pattern.push_str("\\_"),
            other => pattern.push(other),
        }
    }
    pattern.push('%');
    pattern
}

/// One `message_headers` row as the list/briefing routes see it.
#[derive(Debug, Clone)]
pub struct StoredMessage {
    pub id: Uuid,
    pub account_id: Uuid,
    pub remote_id: String,
    pub thread_id: String,
    pub from_address: String,
    pub from_name: Option<String>,
    pub subject: Option<String>,
    /// Still sealed. Opening it belongs to the wire mapping, not to SQL.
    pub snippet_cipher: Option<String>,
    pub received_at: Timestamp,
    pub is_read: bool,
    pub is_archived: bool,
    pub is_deleted: bool,
    pub is_sent: bool,
    pub is_pinned: bool,
    pub message_id_header: Option<String>,
    pub in_reply_to: Option<String>,
    pub references: Option<String>,
}

const SELECT_COLUMNS: &str = "
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
          AND message_pins.remote_id = h.remote_id"
;

/// v3 `MessageStore.recent(forAccount:limit:...)`.
pub fn recent(
    connection: &Connection,
    filter: &MessageFilter,
    limit: i64,
) -> rusqlite::Result<Vec<StoredMessage>> {
    let (where_clause, mut arguments) = filter.where_clause();
    arguments.push(Value::Integer(limit.max(1)));
    let sql = format!("{SELECT_COLUMNS}\n{where_clause}\nORDER BY h.received_at DESC\nLIMIT ?");
    let mut statement = connection.prepare(&sql)?;
    let mut rows = statement.query(rusqlite::params_from_iter(arguments.iter()))?;
    let mut messages = Vec::new();
    while let Some(row) = rows.next()? {
        messages.push(decode_message_row(row)?);
    }
    Ok(messages)
}

/// v3 `MessageStore.count` - the same WHERE clause minus LIMIT.
pub fn count(connection: &Connection, filter: &MessageFilter) -> rusqlite::Result<i64> {
    let (where_clause, arguments) = filter.where_clause();
    let sql = format!("SELECT COUNT(*) AS count FROM message_headers h\n{where_clause}");
    let mut statement = connection.prepare(&sql)?;
    statement.query_row(rusqlite::params_from_iter(arguments.iter()), |row| row.get(0))
}

/// v3 `MessageStore.unreadCount` - the inbox clause plus `is_read = FALSE`.
pub fn unread_count(connection: &Connection, account_id: Uuid) -> rusqlite::Result<i64> {
    let (where_clause, arguments) = MessageFilter::inbox(account_id).where_clause();
    let sql = format!(
        "SELECT COUNT(*) AS count FROM message_headers h\n{where_clause}\n  AND h.is_read = FALSE"
    );
    let mut statement = connection.prepare(&sql)?;
    statement.query_row(rusqlite::params_from_iter(arguments.iter()), |row| row.get(0))
}

/// The six sidebar tallies, read together.
#[derive(Debug, Clone, Copy)]
pub struct FolderTallies {
    pub live: i64,
    pub unread: i64,
    pub archived: i64,
    pub pinned: i64,
    pub deleted: i64,
    pub sent: i64,
}

/// v3 `MessageStore.pinnedCount`: counts the pin table joined back to headers,
/// excluding sent mail - `pinnedCount` is deliberately *not* a `filterSQL` lens.
pub fn pinned_count(connection: &Connection, account_id: Uuid) -> rusqlite::Result<i64> {
    let mut statement = connection.prepare(
        "SELECT COUNT(*) AS count FROM message_pins p\n         JOIN message_headers h\n           ON h.account_id = p.account_id AND h.remote_id = p.remote_id\n         WHERE p.account_id = ? AND h.is_sent = FALSE",
    )?;
    statement.query_row([account_id.as_bytes().as_slice()], |row| row.get(0))
}

/// v3 `MessageStore.sentCount` - `count(sent: true)`.
pub fn sent_count(connection: &Connection, account_id: Uuid) -> rusqlite::Result<i64> {
    let filter = MessageFilter {
        sent: true,
        ..MessageFilter::inbox(account_id)
    };
    count(connection, &filter)
}

/// v3 `MessageStore.deletedCount` - `count(deleted: true)`.
pub fn deleted_count(connection: &Connection, account_id: Uuid) -> rusqlite::Result<i64> {
    let filter = MessageFilter {
        deleted: true,
        ..MessageFilter::inbox(account_id)
    };
    count(connection, &filter)
}

/// The 档案柜 tally - `count(archived: true)`.
pub fn archived_count(connection: &Connection, account_id: Uuid) -> rusqlite::Result<i64> {
    let filter = MessageFilter {
        archived: true,
        ..MessageFilter::inbox(account_id)
    };
    count(connection, &filter)
}

/// The inbox tally - `count(archived: false)`, the same query the All Messages
/// list runs, so the badge and the list cannot disagree.
pub fn live_count(connection: &Connection, account_id: Uuid) -> rusqlite::Result<i64> {
    count(connection, &MessageFilter::inbox(account_id))
}

const FIND_SQL: &str = "
    SELECT id, account_id, remote_id, thread_id, from_address,
           NULLIF(from_name, '') AS from_name,
           NULLIF(subject, '') AS subject,
           NULLIF(snippet_cipher, '') AS snippet_cipher,
           received_at, is_read, is_archived, is_deleted, is_sent,
           message_id_header, in_reply_to, references_header
    FROM message_headers
    WHERE account_id = ? AND remote_id = ?
    LIMIT 1
";

/// v3 `MessageStore.find(remoteId:accountId:)` - one header by provider id.
///
/// No pin join, so `is_pinned` is false; v3's decoder defaults it the same way.
pub fn find(
    connection: &Connection,
    account_id: Uuid,
    remote_id: &str,
) -> rusqlite::Result<Option<StoredMessage>> {
    let mut statement = connection.prepare(FIND_SQL)?;
    let mut rows = statement.query(rusqlite::params![account_id.as_bytes().as_slice(), remote_id])?;
    match rows.next()? {
        Some(row) => {
            let mut message = decode_find_row(row)?;
            message.is_pinned = false;
            Ok(Some(message))
        }
        None => Ok(None),
    }
}

/// v3 `StackStore.listStackRule` reduced to what the list filter needs.
pub fn find_stack_rule(
    connection: &Connection,
    id: Uuid,
    account_id: Uuid,
) -> Result<Option<StackMatch>, StoreError> {
    let mut statement = connection.prepare(
        "SELECT kind, value FROM stack_rules WHERE id = ? AND account_id = ? LIMIT 1",
    )?;
    let mut rows = statement.query(rusqlite::params![id.as_bytes().as_slice(), account_id.as_bytes().as_slice()])?;
    let Some(row) = rows.next()? else {
        return Ok(None);
    };
    let kind: String = row.get(0)?;
    let value: String = row.get(1)?;
    match kind.as_str() {
        "sender" => Ok(Some(StackMatch::Sender(value))),
        "keyword" => Ok(Some(StackMatch::Keyword(value))),
        other => Err(StoreError::BadStackKind(other.to_owned())),
    }
}

/// Decode one row in the pin-joined column order (recent, briefing snapshot).
pub(crate) fn decode_message_row(row: &Row<'_>) -> rusqlite::Result<StoredMessage> {
    Ok(StoredMessage {
        id: uuid_column(row, 0)?,
        account_id: uuid_column(row, 1)?,
        remote_id: row.get(2)?,
        thread_id: row.get(3)?,
        from_address: row.get(4)?,
        from_name: row.get(5)?,
        subject: row.get(6)?,
        snippet_cipher: row.get(7)?,
        received_at: timestamp_column(row, 8)?,
        is_read: bool_column(row, 9)?,
        is_archived: bool_column(row, 10)?,
        is_deleted: bool_column(row, 11)?,
        is_sent: bool_column(row, 12)?,
        is_pinned: bool_column(row, 16)?,
        message_id_header: row.get(13)?,
        in_reply_to: row.get(14)?,
        references: row.get(15)?,
    })
}

/// Decode one row in the column order without the pin join (find, search, export).
pub(crate) fn decode_find_row(row: &Row<'_>) -> rusqlite::Result<StoredMessage> {
    Ok(StoredMessage {
        id: uuid_column(row, 0)?,
        account_id: uuid_column(row, 1)?,
        remote_id: row.get(2)?,
        thread_id: row.get(3)?,
        from_address: row.get(4)?,
        from_name: row.get(5)?,
        subject: row.get(6)?,
        snippet_cipher: row.get(7)?,
        received_at: timestamp_column(row, 8)?,
        is_read: bool_column(row, 9)?,
        is_archived: bool_column(row, 10)?,
        is_deleted: bool_column(row, 11)?,
        is_sent: bool_column(row, 12)?,
        is_pinned: false,
        message_id_header: row.get(13)?,
        in_reply_to: row.get(14)?,
        references: row.get(15)?,
    })
}

/// v3 BackupRoutes.index: every header, oldest first, no limit.
pub fn export_index(
    connection: &Connection,
    account_id: Uuid,
) -> rusqlite::Result<Vec<StoredMessage>> {
    let mut statement = connection.prepare(
        "SELECT id, account_id, remote_id, thread_id, from_address,
                NULLIF(from_name, '') AS from_name,
                NULLIF(subject, '') AS subject,
                NULLIF(snippet_cipher, '') AS snippet_cipher,
                received_at, is_read, is_archived, is_deleted, is_sent,
                message_id_header, in_reply_to, references_header
         FROM message_headers
         WHERE account_id = ?
         ORDER BY received_at ASC",
    )?;
    let mut rows = statement.query([account_id.as_bytes().as_slice()])?;
    let mut messages = Vec::new();
    while let Some(row) = rows.next()? {
        messages.push(decode_find_row(row)?);
    }
    Ok(messages)
}

/// v3 BackupRoutes.folderCounts: the two counts the export index reports.
pub fn deleted_and_sent_counts(
    connection: &Connection,
    account_id: Uuid,
) -> rusqlite::Result<(i64, i64)> {
    let mut statement = connection.prepare(
        "SELECT SUM(CASE WHEN is_deleted THEN 1 ELSE 0 END) AS deleted,
                SUM(CASE WHEN is_sent THEN 1 ELSE 0 END) AS sent
         FROM message_headers
         WHERE account_id = ?",
    )?;
    let mut rows = statement.query([account_id.as_bytes().as_slice()])?;
    let Some(row) = rows.next()? else {
        return Ok((0, 0));
    };
    Ok((
        row.get::<_, Option<i64>>(0)?.unwrap_or(0),
        row.get::<_, Option<i64>>(1)?.unwrap_or(0),
    ))
}
