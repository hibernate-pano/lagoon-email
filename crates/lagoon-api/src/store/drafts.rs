//! Draft replies (v3 AIActionStore.list + DraftCipher.open).

use rusqlite::Connection;

use crate::crypto::{BodyKey, CipherError};
use crate::db::{timestamp_column, uuid_column};
use crate::timefmt::Timestamp;
use crate::uuid::Uuid;

#[derive(Debug, Clone)]
pub struct DraftRow {
    pub id: i64,
    pub account_id: Uuid,
    pub remote_id: String,
    pub variants: Vec<String>,
    pub chosen_variant: Option<i64>,
    pub created_at: Timestamp,
}

/// One unreadable draft must not cost the user the readable ones, and must not
/// be hidden either: v3 refuses the whole list with draft-unreadable rather
/// than showing two drafts when the truth is three, one of them broken.
#[derive(Debug)]
pub enum DraftError {
    Sqlite(rusqlite::Error),
    Unreadable(CipherError),
    Malformed,
}

impl std::fmt::Display for DraftError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            DraftError::Sqlite(error) => write!(formatter, "sqlite: {error}"),
            DraftError::Unreadable(error) => write!(formatter, "draft cannot be opened: {error}"),
            DraftError::Malformed => {
                formatter.write_str("draft payload is not an array of strings")
            }
        }
    }
}

impl From<rusqlite::Error> for DraftError {
    fn from(error: rusqlite::Error) -> Self {
        DraftError::Sqlite(error)
    }
}

/// v3 AIActionStore.list(accountId:remoteId:) - newest first, no limit.
///
/// DraftCipher seals the whole array as one lgb1: envelope with the body key,
/// which is why this needs the key rather than a plain column read.
pub fn list(
    connection: &Connection,
    body_key: &BodyKey,
    account_id: Uuid,
    remote_id: &str,
) -> Result<Vec<DraftRow>, DraftError> {
    let mut statement = connection.prepare(
        "SELECT id, account_id, remote_id, variants, chosen_variant, created_at
         FROM draft_replies
         WHERE account_id = ? AND remote_id = ?
         ORDER BY created_at DESC",
    )?;
    let mut rows = statement.query(rusqlite::params![
        account_id.as_bytes().as_slice(),
        remote_id
    ])?;
    let mut drafts = Vec::new();
    while let Some(row) = rows.next()? {
        let sealed: String = row.get(3)?;
        let json = body_key.open(&sealed).map_err(DraftError::Unreadable)?;
        let variants: Vec<String> =
            serde_json::from_str(&json).map_err(|_| DraftError::Malformed)?;
        drafts.push(DraftRow {
            id: row.get(0)?,
            account_id: uuid_column(row, 1)?,
            remote_id: row.get(2)?,
            variants,
            chosen_variant: row.get(4)?,
            created_at: timestamp_column(row, 5)?,
        });
    }
    Ok(drafts)
}

/// Store a new set of reply variants and answer its row id.
///
/// The whole array is sealed as one envelope, the same way
/// [`list`] opens it: a draft is the model's words about a private mail, and
/// a half-sealed draft is a draft nobody can read.
pub fn insert(
    connection: &Connection,
    body_key: &BodyKey,
    account_id: Uuid,
    remote_id: &str,
    variants: &[String],
) -> Result<i64, DraftError> {
    let json = serde_json::to_string(variants).map_err(|_| DraftError::Malformed)?;
    let sealed = body_key.seal(&json).map_err(DraftError::Unreadable)?;
    connection.execute(
        "INSERT INTO draft_replies (account_id, remote_id, variants)
         VALUES (?1, ?2, ?3)",
        rusqlite::params![account_id.as_bytes().as_slice(), remote_id, sealed],
    )?;
    Ok(connection.last_insert_rowid())
}
