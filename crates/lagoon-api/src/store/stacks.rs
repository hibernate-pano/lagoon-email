//! Stack rules (v3 StackStore.list / messageCount).

use rusqlite::Connection;

use crate::db::{timestamp_column, uuid_column};
use crate::timefmt::Timestamp;
use crate::uuid::Uuid;

use super::messages::{count, MessageFilter, StackMatch};
use super::StoreError;

#[derive(Debug, Clone)]
pub struct StackRuleRow {
    pub id: Uuid,
    pub account_id: Uuid,
    pub name: String,
    pub kind: String,
    pub value: String,
    pub created_at: Timestamp,
}

const COLUMNS: &str = "id, account_id, name, kind, value, created_at";

/// v3 StackStore.list: rules in creation order.
///
/// v3's row decoder reads an unrecognised kind as sender rather than throwing,
/// and the filter path uses the same decoder, so a rule with an unknown kind
/// behaves as a sender rule on both routes. That normalisation happens once,
/// here.
pub fn list(connection: &Connection, account_id: Uuid) -> Result<Vec<StackRuleRow>, StoreError> {
    let sql =
        format!("SELECT {COLUMNS} FROM stack_rules WHERE account_id = ? ORDER BY created_at ASC");
    let mut statement = connection.prepare(&sql)?;
    let mut rows = statement.query([account_id.as_bytes().as_slice()])?;
    let mut rules = Vec::new();
    while let Some(row) = rows.next()? {
        rules.push(decode(row)?);
    }
    Ok(rules)
}

/// v3 StackStore.messageCount: the same filterSQL clause the list uses.
pub fn message_count(connection: &Connection, rule: &StackRuleRow) -> rusqlite::Result<i64> {
    let stack = if rule.kind == "keyword" {
        StackMatch::Keyword(rule.value.clone())
    } else {
        StackMatch::Sender(rule.value.clone())
    };
    let filter = MessageFilter {
        stack: Some(stack),
        ..MessageFilter::inbox(rule.account_id)
    };
    count(connection, &filter)
}

/// The kind normalisation the list route and the filter share.
pub fn normalised_kind(raw: &str) -> &'static str {
    if raw == "keyword" {
        "keyword"
    } else {
        "sender"
    }
}

fn decode(row: &rusqlite::Row<'_>) -> Result<StackRuleRow, StoreError> {
    Ok(StackRuleRow {
        id: uuid_column(row, 0)?,
        account_id: uuid_column(row, 1)?,
        name: row.get(2)?,
        kind: normalised_kind(&row.get::<_, String>(3)?).to_owned(),
        value: row.get(4)?,
        created_at: timestamp_column(row, 5)?,
    })
}
