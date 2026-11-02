//! Cached body reads (`message_bodies`).
//!
//! Bodies are immutable once parsed, so a stored row is never stale: v3 reads
//! here first and only reaches the provider on a miss. R1 has no provider, so a
//! miss is answered `503 provider-not-configured` - which is also what v3
//! answers when its provider cannot be constructed, so the two agree on every
//! store R1 can serve.

use rusqlite::Connection;

use crate::uuid::Uuid;
use crate::wire::Attachment;

/// One cached body, still sealed.
#[derive(Debug, Clone)]
pub struct StoredBody {
    pub text_cipher: String,
    pub html_cipher: Option<String>,
    pub has_more: bool,
    pub attachments: Vec<Attachment>,
    pub to: Vec<String>,
    pub cc: Vec<String>,
}

const GET_SQL: &str = "
    SELECT body_cipher, body_html_cipher, has_more, attachments, to_addresses, cc_addresses
    FROM message_bodies
    WHERE account_id = ? AND remote_id = ?
";

/// v3 `BodyStore.get(accountId:remoteId:)`.
pub fn find(
    connection: &Connection,
    account_id: Uuid,
    remote_id: &str,
) -> rusqlite::Result<Option<StoredBody>> {
    let mut statement = connection.prepare(GET_SQL)?;
    let mut rows = statement.query(rusqlite::params![
        account_id.as_bytes().as_slice(),
        remote_id
    ])?;
    let Some(row) = rows.next()? else {
        return Ok(None);
    };
    let attachments: String = row.get(3)?;
    let to: String = row.get(4)?;
    let cc: String = row.get(5)?;
    Ok(Some(StoredBody {
        text_cipher: row.get(0)?,
        html_cipher: row.get(1)?,
        has_more: row.get::<_, i64>(2)? != 0,
        // v3 `Row.decodedJSON(_, as: [Attachment].self) ?? []`: an unparseable
        // value is an empty list, never an error - the attachment list is
        // metadata, and losing it must not take the body down.
        attachments: serde_json::from_str(&attachments).unwrap_or_default(),
        to: serde_json::from_str(&to).unwrap_or_default(),
        cc: serde_json::from_str(&cc).unwrap_or_default(),
    }))
}
