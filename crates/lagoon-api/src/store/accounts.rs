//! `GET /api/accounts` reads.

use rusqlite::{Connection, Row};

use crate::db::{bool_column, optional_timestamp_column, uuid_column};
use crate::timefmt::Timestamp;
use crate::uuid::Uuid;
use crate::wire::MailCapabilities;

use super::StoreError;

/// One `accounts` row, in the shape the directory route needs.
///
/// `credentials` and `sync_state` are deliberately **not** selected: the route
/// never exposes them, and reading a sealed credential blob a read-only process
/// cannot open is a liability with no upside.
#[derive(Debug, Clone)]
pub struct StoredAccount {
    pub id: Uuid,
    pub provider: String,
    pub email: String,
    pub is_active: bool,
    pub sync_status: String,
    pub last_sync_at: Option<Timestamp>,
    pub last_sync_error: Option<String>,
    pub capabilities: MailCapabilities,
}

const ALL_SQL: &str = "
    SELECT id, provider, email, is_active, sync_status, last_sync_at, last_sync_error, capabilities
    FROM accounts
    ORDER BY email
";

const BY_ID_SQL: &str = "
    SELECT id, provider, email, is_active, sync_status, last_sync_at, last_sync_error, capabilities
    FROM accounts
    WHERE id = ?
    LIMIT 1
";

/// v3 `AccountStore.all(db)` - the directory's list.
pub fn all(connection: &Connection) -> Result<Vec<StoredAccount>, StoreError> {
    let mut statement = connection.prepare(ALL_SQL)?;
    let mut rows = statement.query([])?;
    let mut accounts = Vec::new();
    while let Some(row) = rows.next()? {
        accounts.push(decode(row)?);
    }
    Ok(accounts)
}

/// v3 `AccountStore.find(byId:)` - the existence check every account-scoped
/// read route performs.
pub fn find(connection: &Connection, id: Uuid) -> Result<Option<StoredAccount>, StoreError> {
    let mut statement = connection.prepare(BY_ID_SQL)?;
    let mut rows = statement.query([id.as_bytes().as_slice()])?;
    match rows.next()? {
        Some(row) => Ok(Some(decode(row)?)),
        None => Ok(None),
    }
}

/// v3 `AccountStore.find(byOAuthUser:provider:)` - the connect route's identity check.
pub fn find_by_oauth_user(
    connection: &Connection,
    provider: &str,
    oauth_user: &str,
) -> Result<Option<StoredAccount>, StoreError> {
    let mut statement = connection.prepare(
        "SELECT id, provider, email, is_active, sync_status, last_sync_at, last_sync_error, capabilities
         FROM accounts WHERE provider = ? AND oauth_user = ? LIMIT 1",
    )?;
    let mut rows = statement.query(rusqlite::params![provider, oauth_user])?;
    match rows.next()? {
        Some(row) => Ok(Some(decode(row)?)),
        None => Ok(None),
    }
}

/// The raw sync_state JSON, for the routes that merge one field into it.
pub fn sync_state_json(connection: &Connection, id: Uuid) -> Result<Option<String>, StoreError> {
    let mut statement = connection.prepare("SELECT sync_state FROM accounts WHERE id = ? LIMIT 1")?;
    let mut rows = statement.query([id.as_bytes().as_slice()])?;
    match rows.next()? {
        Some(row) => Ok(row.get(0)?),
        None => Ok(None),
    }
}

/// Whether the row exists. Same answer as `find(..).is_some()` without decoding.
pub fn exists(connection: &Connection, id: Uuid) -> Result<bool, StoreError> {
    let mut statement =
        connection.prepare("SELECT EXISTS(SELECT 1 FROM accounts WHERE id = ?)")?;
    let present: i64 = statement.query_row([id.as_bytes().as_slice()], |row| row.get(0))?;
    Ok(present != 0)
}

fn decode(row: &Row<'_>) -> Result<StoredAccount, StoreError> {
    let provider: String = row.get(1)?;
    // `MailProviderKind` has exactly one case (`qq`), so any other value makes
    // v3's decoder throw and the whole list answer 500 `internal-error`. The
    // table's CHECK also allows 'gmail' for a provider that is not implemented.
    if provider != "qq" {
        return Err(StoreError::UnknownProvider(provider));
    }
    let capabilities: Option<String> = row.get(7)?;
    Ok(StoredAccount {
        id: uuid_column(row, 0)?,
        provider,
        email: row.get(2)?,
        is_active: bool_column(row, 3)?,
        sync_status: row.get(4)?,
        last_sync_at: optional_timestamp_column(row, 5)?,
        last_sync_error: row.get(6)?,
        // v3 `AccountStore.decode`: an absent or unparseable value is
        // `MailCapabilities.unknown`, never an error.
        capabilities: capabilities
            .as_deref()
            .and_then(|raw| serde_json::from_str::<MailCapabilities>(raw).ok())
            .unwrap_or_else(MailCapabilities::unknown),
    })
}
