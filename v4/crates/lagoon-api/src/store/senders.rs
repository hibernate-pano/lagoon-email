//! Sender ranking (v3 MessageStore.senderRanking).

use rusqlite::Connection;

use crate::timefmt;
use crate::timefmt::Timestamp;

use super::messages::like_pattern;

#[derive(Debug, Clone)]
pub struct SenderRow {
    pub address: String,
    pub display_name: Option<String>,
    pub total_count: i64,
    pub unread_count: i64,
    pub latest_at: Timestamp,
}

/// Senders ranked by how much mail they have written.
///
/// Deleted mail is excluded (a sender whose mail was thrown away is not still
/// writing), archived mail is included (that is where finished mail lives), and
/// sent mail is excluded (otherwise the user ranks as their own top sender).
pub fn ranking(
    connection: &Connection,
    account_id: crate::uuid::Uuid,
    limit: i64,
    query: Option<&str>,
) -> rusqlite::Result<Vec<SenderRow>> {
    let mut sql = String::from(
        "SELECT from_address AS address,
                MAX(NULLIF(from_name, '')) AS display_name,
                COUNT(*) AS total,
                SUM(CASE WHEN is_read = FALSE THEN 1 ELSE 0 END) AS unread,
                MAX(received_at) AS latest_at
         FROM message_headers
         WHERE account_id = ? AND is_deleted = FALSE AND is_sent = FALSE",
    );
    let mut arguments: Vec<rusqlite::types::Value> =
        vec![rusqlite::types::Value::Blob(account_id.as_bytes().to_vec())];
    if let Some(query) = query {
        sql.push_str(" AND (from_address LIKE ? ESCAPE '\\' OR IFNULL(from_name, '') LIKE ? ESCAPE '\\')");
        let pattern = like_pattern(query);
        arguments.push(rusqlite::types::Value::Text(pattern.clone()));
        arguments.push(rusqlite::types::Value::Text(pattern));
    }
    sql.push_str(" GROUP BY from_address ORDER BY total DESC, latest_at DESC LIMIT ?");
    arguments.push(rusqlite::types::Value::Integer(limit.max(1)));

    let mut statement = connection.prepare(&sql)?;
    let mut rows = statement.query(rusqlite::params_from_iter(arguments.iter()))?;
    let mut senders = Vec::new();
    while let Some(row) = rows.next()? {
        let latest_at: Option<String> = row.get(4)?;
        senders.push(SenderRow {
            address: row.get(0)?,
            // v3 optionalText: NULL and the empty string are both "no name".
            display_name: row.get::<_, Option<String>>(1)?.filter(|name| !name.is_empty()),
            total_count: row.get(2)?,
            unread_count: row.get::<_, Option<i64>>(3)?.unwrap_or(0),
            // v3 falls back to the epoch so one unparseable row ranks last
            // instead of taking the panel down.
            latest_at: timefmt::parse(latest_at.as_deref())
                .unwrap_or_else(|| Timestamp::from_millis(0)),
        });
    }
    Ok(senders)
}
