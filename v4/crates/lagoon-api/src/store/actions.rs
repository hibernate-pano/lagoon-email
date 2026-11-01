//! Audit-log reads (v3 AIActionStore).

use std::collections::{BTreeMap, HashSet};

use rusqlite::Connection;

use crate::db::{optional_timestamp_column, timestamp_column, uuid_column};
use crate::timefmt::{self, Timestamp};
use crate::uuid::Uuid;

#[derive(Debug, Clone)]
pub struct AIActionRow {
    pub id: i64,
    pub account_id: Uuid,
    pub kind: String,
    pub payload: BTreeMap<String, String>,
    pub created_at: Timestamp,
    pub expires_at: Option<Timestamp>,
}

#[derive(Debug, Clone)]
pub struct Page {
    pub actions: Vec<AIActionRow>,
    pub total_count: i64,
    pub has_more: bool,
}

/// A keyset cursor: v3's ActionListCursor.
#[derive(Debug, Clone)]
pub struct Cursor {
    pub created_at: String,
    pub id: i64,
}

const COLUMNS: &str = "id, account_id, kind, payload, created_at, expires_at";

/// Filters every audit query in v3 applies: an action that was later undone is
/// not history, a Sent-folder harvest is not something Lagoon did, and a send
/// that is still claimed or that failed never happened.
const VISIBLE_ACTIONS: &str = "
      NOT EXISTS (
          SELECT 1 FROM ai_actions u
          WHERE u.account_id = ai_actions.account_id
            AND u.kind = 'undo'
            AND json_extract(u.payload, '$.undoOf') = ai_actions.id
      )
      AND NOT (kind = 'send' AND json_extract(payload, '$.sentFolder') IS NOT NULL)
      AND (
          kind <> 'send'
          OR json_extract(payload, '$.status') IS NULL
          OR json_extract(payload, '$.status') = 'sent'
      )";

fn page_sql() -> String {
    format!(
        "SELECT {COLUMNS} FROM ai_actions
         WHERE account_id = ? AND created_at >= ?
           AND (created_at, id) < (?, ?)
           AND {VISIBLE_ACTIONS}
         ORDER BY created_at DESC, id DESC
         LIMIT ?"
    )
}

fn count_sql() -> String {
    format!(
        "SELECT COUNT(*) FROM ai_actions
         WHERE account_id = ? AND created_at >= ?
           AND {VISIBLE_ACTIONS}"
    )
}

/// Bound values for "no lower bound" / "no upper bound". v3 uses
/// Date.distantPast, Date.distantFuture and Int64.max, whose stored spellings
/// are below and above every real row.
const LOWER_BOUND: &str = "0001-01-01 00:00:00.000";
const UPPER_BOUND: &str = "4001-01-01 00:00:00.000";

/// v3 AIActionStore.page: one page plus the counts the client needs to page on.
pub fn page(
    connection: &Connection,
    account_id: Uuid,
    since: Option<Timestamp>,
    before: Option<&Cursor>,
    limit: i64,
) -> rusqlite::Result<Page> {
    let lower = since
        .map(timefmt::to_stored)
        .unwrap_or_else(|| LOWER_BOUND.to_owned());
    let upper_created = before
        .map(|cursor| cursor.created_at.clone())
        .unwrap_or_else(|| UPPER_BOUND.to_owned());
    let upper_id = before.map(|cursor| cursor.id).unwrap_or(i64::MAX);
    let limit = limit.max(1);

    let mut statement = connection.prepare(&page_sql())?;
    let mut rows = statement.query(rusqlite::params![
        account_id.as_bytes().as_slice(),
        lower,
        upper_created,
        upper_id,
        limit + 1
    ])?;
    let mut actions = Vec::new();
    while let Some(row) = rows.next()? {
        actions.push(decode(row)?);
    }
    let has_more = actions.len() as i64 > limit;
    actions.truncate(usize::try_from(limit).unwrap_or(usize::MAX));

    let mut count_statement = connection.prepare(&count_sql())?;
    let total_count: i64 = count_statement.query_row(
        rusqlite::params![account_id.as_bytes().as_slice(), lower],
        |row| row.get(0),
    )?;

    Ok(Page {
        actions,
        total_count,
        has_more,
    })
}

/// v3 AIActionStore.cursor: the keyset of an existing action, or None.
pub fn cursor(connection: &Connection, id: i64, account_id: Uuid) -> rusqlite::Result<Option<Cursor>> {
    let mut statement =
        connection.prepare("SELECT created_at FROM ai_actions WHERE id = ? AND account_id = ?")?;
    let mut rows = statement.query(rusqlite::params![id, account_id.as_bytes().as_slice()])?;
    match rows.next()? {
        Some(row) => Ok(Some(Cursor {
            created_at: row.get(0)?,
            id,
        })),
        None => Ok(None),
    }
}

/// v3 AIActionStore.repliedRemoteIds - the "already replied" signal the
/// briefing classifier matches on.
pub fn replied_remote_ids(
    connection: &Connection,
    account_id: Uuid,
) -> rusqlite::Result<HashSet<String>> {
    let mut statement = connection.prepare(
        "SELECT DISTINCT json_extract(payload, '$.remoteId') AS rid
         FROM ai_actions
         WHERE account_id = ? AND kind = 'send'
           AND json_extract(payload, '$.remoteId') IS NOT NULL
           AND (json_extract(payload, '$.status') IS NULL
                OR json_extract(payload, '$.status') = 'sent')",
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

/// Per-message overrides, newest wins - v3 AIActionStore.overridesByMessage.
pub fn overrides_by_message(
    connection: &Connection,
    account_id: Uuid,
) -> rusqlite::Result<Vec<(String, String)>> {
    let mut statement = connection.prepare(
        "WITH ranked AS (
             SELECT o.remote_id AS remote_id, o.to_group AS to_group,
                 row_number() OVER (PARTITION BY o.remote_id ORDER BY o.created_at DESC, o.rowid DESC) AS rn
             FROM ai_overrides o
             WHERE o.account_id = ? AND o.scope = 'message'
         )
         SELECT remote_id, to_group FROM ranked WHERE rn = 1",
    )?;
    let mut rows = statement.query([account_id.as_bytes().as_slice()])?;
    let mut pairs = Vec::new();
    while let Some(row) = rows.next()? {
        pairs.push((row.get(0)?, row.get(1)?));
    }
    Ok(pairs)
}

/// Per-sender overrides, newest wins - v3 AIActionStore.overridesBySender.
///
/// The scope predicate is load-bearing: a message-scoped override must not reach
/// this map, or it would re-file the sender's whole mailbox.
pub fn overrides_by_sender(
    connection: &Connection,
    account_id: Uuid,
) -> rusqlite::Result<Vec<(String, String)>> {
    let mut statement = connection.prepare(
        "WITH ranked AS (
             SELECT o.to_group AS to_group, o.from_address AS from_address,
                 row_number() OVER (PARTITION BY o.from_address ORDER BY o.created_at DESC, o.rowid DESC) AS rn
             FROM ai_overrides o
             WHERE o.account_id = ? AND o.scope = 'sender' AND o.from_address IS NOT NULL
         )
         SELECT from_address, to_group FROM ranked WHERE rn = 1",
    )?;
    let mut rows = statement.query([account_id.as_bytes().as_slice()])?;
    let mut pairs = Vec::new();
    while let Some(row) = rows.next()? {
        pairs.push((row.get(0)?, row.get(1)?));
    }
    Ok(pairs)
}

/// (kind, created_at) for the time-saved report - v3 AIActionStore.timeSavedEvents.
pub fn time_saved_events(
    connection: &Connection,
    account_id: Uuid,
    since: Timestamp,
) -> rusqlite::Result<Vec<(String, Timestamp)>> {
    let mut statement = connection.prepare(
        "SELECT a.kind, a.created_at
         FROM ai_actions a
         WHERE a.account_id = ? AND a.created_at >= ?
           AND NOT (a.kind = 'send' AND json_extract(a.payload, '$.sentFolder') IS NOT NULL)
           AND (a.kind <> 'send'
                OR json_extract(a.payload, '$.status') IS NULL
                OR json_extract(a.payload, '$.status') = 'sent')
           AND NOT EXISTS (
               SELECT 1 FROM ai_actions u
               WHERE u.account_id = a.account_id AND u.kind = 'undo'
                 AND json_extract(u.payload, '$.undoOf') = CAST(a.id AS TEXT)
           )",
    )?;
    let mut rows = statement.query(rusqlite::params![
        account_id.as_bytes().as_slice(),
        timefmt::to_stored(since)
    ])?;
    let mut events = Vec::new();
    while let Some(row) = rows.next()? {
        events.push((row.get(0)?, timestamp_column(row, 1)?));
    }
    Ok(events)
}

fn decode(row: &rusqlite::Row<'_>) -> rusqlite::Result<AIActionRow> {
    let payload: String = row.get(3)?;
    Ok(AIActionRow {
        id: row.get(0)?,
        account_id: uuid_column(row, 1)?,
        // v3 reads an unrecognised kind as archive rather than dropping the row.
        kind: row.get::<_, String>(2).unwrap_or_else(|_| "archive".to_owned()),
        payload: decode_payload(&payload),
        created_at: timestamp_column(row, 4)?,
        expires_at: optional_timestamp_column(row, 5)?,
    })
}

/// v3 AIActionStore.decodePayload: the audit payload is a JSON object of
/// scalars; string values pass through, numbers become their decimal spelling
/// (Foundation bridges them through NSNumber), and everything else is dropped.
pub fn decode_payload(text: &str) -> BTreeMap<String, String> {
    let mut payload = BTreeMap::new();
    let Ok(serde_json::Value::Object(object)) = serde_json::from_str::<serde_json::Value>(text) else {
        return payload;
    };
    for (key, value) in object {
        match value {
            serde_json::Value::String(text) => {
                payload.insert(key, text);
            }
            serde_json::Value::Number(number) => {
                payload.insert(key, number.to_string());
            }
            serde_json::Value::Bool(flag) => {
                payload.insert(key, if flag { "1".to_owned() } else { "0".to_owned() });
            }
            _ => {}
        }
    }
    payload
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn payload_scalars_become_strings() {
        let payload = decode_payload(
            "{\"remoteId\":\"42\",\"count\":3,\"flag\":true,\"nested\":{\"a\":1},\"nil\":null}",
        );
        assert_eq!(payload.get("remoteId").map(String::as_str), Some("42"));
        assert_eq!(payload.get("count").map(String::as_str), Some("3"));
        assert_eq!(payload.get("flag").map(String::as_str), Some("1"));
        assert!(payload.get("nested").is_none());
        assert!(payload.get("nil").is_none());
    }

    #[test]
    fn an_unparseable_payload_is_empty_not_an_error() {
        assert!(decode_payload("not json").is_empty());
        assert!(decode_payload("[]").is_empty());
    }
}
