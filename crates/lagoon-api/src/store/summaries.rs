//! The cached AI summary of one message (`message_summaries`).
//!
//! A summary is derived from the body, so it is sealed with the body key like
//! the body and the drafts are: what the model said about a private mail
//! stays private at rest.
//!
//! The cache is not an optimisation, it is the budget: without it every open
//! of a mail would be a paid model call. One summary per message, computed
//! once.

use rusqlite::Connection;

use crate::crypto::{BodyKey, CipherError};
use crate::db::timestamp_column;
use crate::timefmt::Timestamp;
use crate::uuid::Uuid;

/// One stored summary, opened.
#[derive(Debug, Clone)]
pub struct SummaryRow {
    pub summary: String,
    pub action_items: Vec<String>,
    pub model: Option<String>,
    pub created_at: Timestamp,
}

/// Why a summary could not be read or written.
#[derive(Debug)]
pub enum SummaryError {
    Sqlite(rusqlite::Error),
    /// The sealed payload will not open: the key changed, or the row is
    /// damaged.
    Unreadable(CipherError),
    /// The sealed payload opened but is not the shape we wrote.
    Malformed,
    /// The payload could not be sealed.
    Unsealable(CipherError),
}

impl std::fmt::Display for SummaryError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SummaryError::Sqlite(error) => write!(formatter, "sqlite: {error}"),
            SummaryError::Unreadable(error) => {
                write!(formatter, "summary cannot be opened: {error}")
            }
            SummaryError::Malformed => formatter.write_str("summary payload is malformed"),
            SummaryError::Unsealable(error) => {
                write!(formatter, "summary cannot be sealed: {error}")
            }
        }
    }
}

impl From<rusqlite::Error> for SummaryError {
    fn from(error: rusqlite::Error) -> Self {
        SummaryError::Sqlite(error)
    }
}

/// The payload shape inside the envelope.
#[derive(Debug, serde::Serialize, serde::Deserialize)]
struct Payload {
    summary: String,
    #[serde(default)]
    action_items: Vec<String>,
}

/// The summary of one message, if it has been computed.
pub fn find(
    connection: &Connection,
    body_key: &BodyKey,
    account_id: Uuid,
    remote_id: &str,
) -> Result<Option<SummaryRow>, SummaryError> {
    let mut statement = connection.prepare(
        "SELECT payload, model, created_at
         FROM message_summaries
         WHERE account_id = ? AND remote_id = ?",
    )?;
    let mut rows = statement.query(rusqlite::params![
        account_id.as_bytes().as_slice(),
        remote_id
    ])?;
    let Some(row) = rows.next()? else {
        return Ok(None);
    };
    let sealed: String = row.get(0)?;
    let json = body_key.open(&sealed).map_err(SummaryError::Unreadable)?;
    let payload: Payload = serde_json::from_str(&json).map_err(|_| SummaryError::Malformed)?;
    Ok(Some(SummaryRow {
        summary: payload.summary,
        action_items: payload.action_items,
        model: row.get(1)?,
        created_at: timestamp_column(row, 2)?,
    }))
}

/// Store a summary, replacing any earlier one for the same message.
pub fn save(
    connection: &Connection,
    body_key: &BodyKey,
    account_id: Uuid,
    remote_id: &str,
    summary: &str,
    action_items: &[String],
    model: &str,
) -> Result<(), SummaryError> {
    let payload = serde_json::to_string(&Payload {
        summary: summary.to_owned(),
        action_items: action_items.to_vec(),
    })
    .map_err(|_| SummaryError::Malformed)?;
    let sealed = body_key.seal(&payload).map_err(SummaryError::Unsealable)?;
    connection.execute(
        "INSERT INTO message_summaries (account_id, remote_id, payload, model)
         VALUES (?1, ?2, ?3, ?4)
         ON CONFLICT (account_id, remote_id)
         DO UPDATE SET payload = excluded.payload, model = excluded.model",
        rusqlite::params![account_id.as_bytes().as_slice(), remote_id, sealed, model],
    )?;
    Ok(())
}
