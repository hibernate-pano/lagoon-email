//! The writable store: the write paths v3 needs, implemented against the same
//! schema and with the same parameterised-SQL rules the read side follows.
//!
//! R3.2 does not expose HTTP write routes yet - that is R3.3+ - so these
//! functions are the foundation: accounts, headers, sealed bodies, pins,
//! capabilities/sync state, the audit log and drafts.
//!
//! Every value is bound, never formatted into the SQL text. The one place a
//! table name appears in a format string is migration.rs's fixed child-table
//! list, where the names are constants in this crate.

use rusqlite::{Connection, OptionalExtension};
use serde_json::Value;

use crate::crypto::BodyKey;
use crate::uuid::Uuid;

#[derive(Debug)]
pub enum WriteError {
    Sqlite(rusqlite::Error),
    Cipher(crate::crypto::CipherError),
    /// A sealed column was written without a key.
    MissingBodyKey,
    /// A JSON payload handed to the store is not valid JSON.
    MalformedJson(String),
    /// An account id that does not exist.
    UnknownAccount,
}

impl std::fmt::Display for WriteError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            WriteError::Sqlite(error) => write!(formatter, "sqlite: {error}"),
            WriteError::Cipher(error) => write!(formatter, "cipher: {error}"),
            WriteError::MissingBodyKey => write!(formatter, "LAGOON_BODY_KEY is required"),
            WriteError::MalformedJson(error) => write!(formatter, "malformed json: {error}"),
            WriteError::UnknownAccount => write!(formatter, "unknown account"),
        }
    }
}

impl std::error::Error for WriteError {}

impl From<rusqlite::Error> for WriteError {
    fn from(error: rusqlite::Error) -> Self {
        WriteError::Sqlite(error)
    }
}

impl From<crate::crypto::CipherError> for WriteError {
    fn from(error: crate::crypto::CipherError) -> Self {
        WriteError::Cipher(error)
    }
}

pub struct NewAccount<'a> {
    /// The id the caller wants for a new row. On conflict the stored id wins,
    /// because it is the one every child row already points at.
    pub id: Uuid,
    pub provider: &'a str,
    pub oauth_user: &'a str,
    pub email: &'a str,
    pub credentials: Option<&'a [u8]>,
    pub capabilities: &'a str,
    pub sync_state: &'a str,
}

/// Insert or update the account keyed by (provider, oauth_user).
///
/// Returns the stored id: a re-authorisation of the same mailbox must not mint a
/// second account, and everything the user accumulated hangs off the first one.
pub fn upsert_account(
    connection: &Connection,
    account: &NewAccount<'_>,
) -> Result<Uuid, WriteError> {
    connection.execute(
        "INSERT INTO accounts (id, provider, oauth_user, email, credentials,
                               capabilities, sync_state)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
         ON CONFLICT(provider, oauth_user) DO UPDATE SET
             email = excluded.email,
             credentials = excluded.credentials,
             capabilities = excluded.capabilities,
             sync_state = excluded.sync_state,
             updated_at = strftime('%Y-%m-%d %H:%M:%f','now')",
        rusqlite::params![
            account.id.as_bytes().as_slice(),
            account.provider,
            account.oauth_user,
            account.email,
            account.credentials,
            account.capabilities,
            account.sync_state,
        ],
    )?;
    let stored: Vec<u8> = connection.query_row(
        "SELECT id FROM accounts WHERE provider = ?1 AND oauth_user = ?2",
        rusqlite::params![account.provider, account.oauth_user],
        |row| row.get(0),
    )?;
    Uuid::from_stored(&stored).ok_or(WriteError::UnknownAccount)
}

pub fn set_account_active(
    connection: &Connection,
    account_id: Uuid,
    active: bool,
) -> Result<usize, WriteError> {
    Ok(connection.execute(
        "UPDATE accounts SET is_active = ?1, updated_at = strftime('%Y-%m-%d %H:%M:%f','now')
         WHERE id = ?2",
        rusqlite::params![active, account_id.as_bytes().as_slice()],
    )?)
}

/// Deletes the account; the schema cascades to every child table.
pub fn delete_account(connection: &Connection, account_id: Uuid) -> Result<usize, WriteError> {
    Ok(connection.execute(
        "DELETE FROM accounts WHERE id = ?1",
        rusqlite::params![account_id.as_bytes().as_slice()],
    )?)
}

/// Replace the capabilities blob (a JSON object; see MailCapabilities).
pub fn update_capabilities(
    connection: &Connection,
    account_id: Uuid,
    capabilities: &str,
) -> Result<usize, WriteError> {
    ensure_object(capabilities)?;
    Ok(connection.execute(
        "UPDATE accounts SET capabilities = ?1, updated_at = strftime('%Y-%m-%d %H:%M:%f','now')
         WHERE id = ?2",
        rusqlite::params![capabilities, account_id.as_bytes().as_slice()],
    )?)
}

/// Set one folder-role bit inside the capabilities JSON, leaving the rest alone.
///
/// The role names are the wire names of MailCapabilities, because the client
/// reads the blob directly.
pub fn set_folder_role(
    connection: &Connection,
    account_id: Uuid,
    role: &str,
    value: Option<bool>,
) -> Result<(), WriteError> {
    let current: String = connection
        .query_row(
            "SELECT capabilities FROM accounts WHERE id = ?1",
            rusqlite::params![account_id.as_bytes().as_slice()],
            |row| row.get(0),
        )
        .optional()?
        .ok_or(WriteError::UnknownAccount)?;
    let mut parsed: Value = serde_json::from_str(&current)
        .map_err(|error| WriteError::MalformedJson(error.to_string()))?;
    let object = parsed
        .as_object_mut()
        .ok_or_else(|| WriteError::MalformedJson("capabilities is not an object".to_owned()))?;
    match value {
        Some(flag) => {
            object.insert(role.to_owned(), Value::Bool(flag));
        }
        None => {
            object.remove(role);
        }
    }
    let encoded = serde_json::to_string(&parsed)
        .map_err(|error| WriteError::MalformedJson(error.to_string()))?;
    update_capabilities(connection, account_id, &encoded)?;
    Ok(())
}

/// Replace the sync state and the health fields the account list reports.
pub fn update_sync_state(
    connection: &Connection,
    account_id: Uuid,
    sync_state: &str,
    status: &str,
    last_sync_at: Option<&str>,
    last_sync_error: Option<&str>,
) -> Result<usize, WriteError> {
    ensure_object(sync_state)?;
    Ok(connection.execute(
        "UPDATE accounts
            SET sync_state = ?1, sync_status = ?2, last_sync_at = ?3,
                last_sync_error = ?4,
                updated_at = strftime('%Y-%m-%d %H:%M:%f','now')
          WHERE id = ?5",
        rusqlite::params![
            sync_state,
            status,
            last_sync_at,
            last_sync_error,
            account_id.as_bytes().as_slice()
        ],
    )?)
}

pub struct NewHeader<'a> {
    pub id: Uuid,
    pub account_id: Uuid,
    pub remote_id: &'a str,
    pub thread_id: &'a str,
    pub from_address: &'a str,
    pub from_name: Option<&'a str>,
    pub subject: Option<&'a str>,
    /// Plain snippet; sealed here when a key is supplied.
    pub snippet: Option<&'a str>,
    pub received_at: &'a str,
    pub list_unsubscribe: bool,
    pub message_id_header: Option<&'a str>,
    pub in_reply_to: Option<&'a str>,
    pub references: Option<&'a str>,
    pub unsubscribe_links: &'a str,
    /// The server UID this row was read at (v4 addition). None for rows from
    /// builds without it; the body route then falls back to resolving by id.
    pub remote_uid: Option<i64>,
}

/// Fill `remote_uid` for live INBOX rows from the membership walk.
///
/// Rows stored before the column existed have NULL here, and every body open
/// for them pays a full-mailbox scan. The walk the sync round already ran
/// fetched every Message-ID, so this is a pure local write. Rows that already
/// carry a value are only rewritten when the UID actually moved: INBOX
/// membership is the fresher truth.
pub fn fill_remote_uids(
    connection: &Connection,
    account_id: Uuid,
    uids: &[(String, i64)],
) -> Result<(), WriteError> {
    // A row with a UID only needs rewriting when the UID moved, and a message
    // that moved back into INBOX arrives as a new UID in the pull anyway and is
    // upserted there. So: nothing NULL, nothing to do — the steady-state round
    // pays no writes.
    let missing: i64 = connection.query_row(
        "SELECT COUNT(*) FROM message_headers
         WHERE account_id = ? AND is_archived = FALSE AND is_deleted = FALSE
           AND remote_uid IS NULL",
        [account_id.as_bytes().as_slice()],
        |row| row.get(0),
    )?;
    if missing == 0 {
        return Ok(());
    }
    let mut statement = connection.prepare(
        "UPDATE message_headers
         SET remote_uid = ?1
         WHERE account_id = ?2 AND remote_id = ?3
           AND is_archived = FALSE AND is_deleted = FALSE
           AND (remote_uid IS NULL OR remote_uid != ?1)",
    )?;
    for (remote_id, uid) in uids {
        statement.execute(rusqlite::params![
            uid,
            account_id.as_bytes().as_slice(),
            remote_id
        ])?;
    }
    Ok(())
}

/// Insert or update one header, keyed by (account_id, remote_id).
pub fn upsert_header(
    connection: &Connection,
    header: &NewHeader<'_>,
    body_key: Option<&BodyKey>,
) -> Result<i64, WriteError> {
    let snippet = match (header.snippet, body_key) {
        (None, _) => None,
        (Some(text), Some(key)) => Some(key.seal(text)?),
        (Some(_), None) => return Err(WriteError::MissingBodyKey),
    };
    connection.execute(
        "INSERT INTO message_headers
             (id, account_id, remote_id, thread_id, from_address, from_name, subject,
              snippet_cipher, received_at, list_unsubscribe, message_id_header,
              in_reply_to, references_header, unsubscribe_links, remote_uid)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)
         ON CONFLICT(account_id, remote_id) DO UPDATE SET
             thread_id = excluded.thread_id,
             from_address = excluded.from_address,
             from_name = excluded.from_name,
             subject = excluded.subject,
             snippet_cipher = excluded.snippet_cipher,
             received_at = excluded.received_at,
             list_unsubscribe = excluded.list_unsubscribe,
             message_id_header = excluded.message_id_header,
             in_reply_to = excluded.in_reply_to,
             references_header = excluded.references_header,
             unsubscribe_links = excluded.unsubscribe_links,
             remote_uid = excluded.remote_uid",
        rusqlite::params![
            header.id.as_bytes().as_slice(),
            header.account_id.as_bytes().as_slice(),
            header.remote_id,
            header.thread_id,
            header.from_address,
            header.from_name,
            header.subject,
            snippet,
            header.received_at,
            header.list_unsubscribe,
            header.message_id_header,
            header.in_reply_to,
            header.references,
            header.unsubscribe_links,
            header.remote_uid,
        ],
    )?;
    Ok(connection.last_insert_rowid())
}

pub struct NewBody<'a> {
    pub account_id: Uuid,
    pub remote_id: &'a str,
    pub text: &'a str,
    pub html: Option<&'a str>,
    pub has_more: bool,
    pub attachments: &'a str,
    pub to_addresses: &'a str,
    pub cc_addresses: &'a str,
}

/// Store one body, sealed as a single envelope per column (v3 BodyCipher).
pub fn save_body(
    connection: &Connection,
    body: &NewBody<'_>,
    body_key: &BodyKey,
) -> Result<(), WriteError> {
    let sealed_text = body_key.seal(body.text)?;
    let sealed_html = match body.html {
        Some(html) => Some(body_key.seal(html)?),
        None => None,
    };
    ensure_array(body.attachments)?;
    ensure_array(body.to_addresses)?;
    ensure_array(body.cc_addresses)?;
    connection.execute(
        "INSERT INTO message_bodies
             (account_id, remote_id, body_cipher, body_html_cipher, has_more,
              attachments, to_addresses, cc_addresses)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
         ON CONFLICT(account_id, remote_id) DO UPDATE SET
             body_cipher = excluded.body_cipher,
             body_html_cipher = excluded.body_html_cipher,
             has_more = excluded.has_more,
             attachments = excluded.attachments,
             to_addresses = excluded.to_addresses,
             cc_addresses = excluded.cc_addresses,
             fetched_at = strftime('%Y-%m-%d %H:%M:%f','now')",
        rusqlite::params![
            body.account_id.as_bytes().as_slice(),
            body.remote_id,
            sealed_text,
            sealed_html,
            body.has_more,
            body.attachments,
            body.to_addresses,
            body.cc_addresses,
        ],
    )?;
    Ok(())
}

pub fn set_pinned(
    connection: &Connection,
    account_id: Uuid,
    remote_id: &str,
    pinned: bool,
) -> Result<usize, WriteError> {
    if pinned {
        Ok(connection.execute(
            "INSERT OR IGNORE INTO message_pins (account_id, remote_id) VALUES (?1, ?2)",
            rusqlite::params![account_id.as_bytes().as_slice(), remote_id],
        )?)
    } else {
        Ok(connection.execute(
            "DELETE FROM message_pins WHERE account_id = ?1 AND remote_id = ?2",
            rusqlite::params![account_id.as_bytes().as_slice(), remote_id],
        )?)
    }
}

/// Append one audit row (the ai_actions log the undo surface reads).
pub fn record_action(
    connection: &Connection,
    account_id: Uuid,
    kind: &str,
    payload: &str,
) -> Result<i64, WriteError> {
    ensure_object(payload)?;
    connection.execute(
        "INSERT INTO ai_actions (account_id, kind, payload) VALUES (?1, ?2, ?3)",
        rusqlite::params![account_id.as_bytes().as_slice(), kind, payload],
    )?;
    Ok(connection.last_insert_rowid())
}

/// Record the undo of an earlier action: one row, no mutation of the original.
pub fn record_undo(
    connection: &Connection,
    account_id: Uuid,
    undo_of: i64,
    payload: &str,
) -> Result<i64, WriteError> {
    ensure_object(payload)?;
    // undoOf is a STRING, not an integer: is_undone compares
    // json_extract(payload, '$.undoOf') = ? with the id bound as text, and
    // SQLite will not cross-compare INTEGER with TEXT (v3 stores the same
    // shape because its payload dict is [String: String]).
    connection.execute(
        "INSERT INTO ai_actions (account_id, kind, payload) VALUES (?1, 'undo', ?2)",
        rusqlite::params![
            account_id.as_bytes().as_slice(),
            format!("{{\"undoOf\":\"{undo_of}\",\"detail\":{payload}}}")
        ],
    )?;
    Ok(connection.last_insert_rowid())
}

/// Store the reply variants for one mail, sealed as one JSON array envelope.
pub fn save_draft(
    connection: &Connection,
    account_id: Uuid,
    remote_id: &str,
    variants: &[String],
    chosen_variant: Option<i64>,
    body_key: &BodyKey,
) -> Result<i64, WriteError> {
    let json = serde_json::to_string(variants)
        .map_err(|error| WriteError::MalformedJson(error.to_string()))?;
    let sealed = body_key.seal(&json)?;
    // draft_replies is append-only: the table has no (account_id, remote_id)
    // uniqueness, because regenerating a draft creates another row and the
    // history is what lets the UI offer the earlier variants.
    connection.execute(
        "INSERT INTO draft_replies (account_id, remote_id, variants, chosen_variant)
         VALUES (?1, ?2, ?3, ?4)",
        rusqlite::params![
            account_id.as_bytes().as_slice(),
            remote_id,
            sealed,
            chosen_variant
        ],
    )?;
    Ok(connection.last_insert_rowid())
}

fn ensure_object(raw: &str) -> Result<(), WriteError> {
    match serde_json::from_str::<Value>(raw) {
        Ok(Value::Object(_)) => Ok(()),
        _ => Err(WriteError::MalformedJson(raw.to_owned())),
    }
}

fn ensure_array(raw: &str) -> Result<(), WriteError> {
    match serde_json::from_str::<Value>(raw) {
        Ok(Value::Array(_)) => Ok(()),
        _ => Err(WriteError::MalformedJson(raw.to_owned())),
    }
}

/// Replace the sealed credential blob (v3 AccountStore.updateCredentials).
pub fn update_credentials(
    connection: &Connection,
    account_id: Uuid,
    credentials: &[u8],
) -> Result<usize, WriteError> {
    Ok(connection.execute(
        "UPDATE accounts SET credentials = ?1, updated_at = strftime('%Y-%m-%d %H:%M:%f','now')
         WHERE id = ?2",
        rusqlite::params![credentials, account_id.as_bytes().as_slice()],
    )?)
}

/// v3 AccountStore.updateHealth: lastSyncAt is COALESCEd, lastError replaced.
pub fn update_health(
    connection: &Connection,
    account_id: Uuid,
    status: &str,
    last_sync_at: Option<&str>,
    last_error: Option<&str>,
) -> Result<usize, WriteError> {
    Ok(connection.execute(
        "UPDATE accounts
            SET sync_status = ?1,
                last_sync_at = COALESCE(?2, last_sync_at),
                last_sync_error = ?3,
                updated_at = strftime('%Y-%m-%d %H:%M:%f','now')
          WHERE id = ?4",
        rusqlite::params![
            status,
            last_sync_at,
            last_error,
            account_id.as_bytes().as_slice()
        ],
    )?)
}

/// v3 AccountStore.setActive: exactly one account is active at a time.
pub fn set_active(connection: &Connection, account_id: Uuid) -> Result<(), WriteError> {
    let transaction = connection.unchecked_transaction()?;
    connection.execute(
        "UPDATE accounts SET is_active = FALSE WHERE is_active = TRUE",
        [],
    )?;
    connection.execute(
        "UPDATE accounts
            SET is_active = TRUE, updated_at = strftime('%Y-%m-%d %H:%M:%f','now')
          WHERE id = ?1",
        rusqlite::params![account_id.as_bytes().as_slice()],
    )?;
    transaction.commit()?;
    Ok(())
}

/// v3 AccountStore.reconcileActive: repair a zero-selected state after a delete.
pub fn reconcile_active(connection: &Connection) -> Result<(), WriteError> {
    let transaction = connection.unchecked_transaction()?;
    let active: i64 = connection.query_row(
        "SELECT COUNT(*) FROM accounts WHERE is_active = TRUE",
        [],
        |row| row.get(0),
    )?;
    if active == 0 {
        let newest: Option<Vec<u8>> = connection
            .query_row(
                "SELECT id FROM accounts ORDER BY updated_at DESC, id LIMIT 1",
                [],
                |row| row.get(0),
            )
            .optional()?;
        if let Some(bytes) = newest {
            connection.execute(
                "UPDATE accounts SET is_active = TRUE WHERE id = ?1",
                rusqlite::params![bytes],
            )?;
        }
    }
    transaction.commit()?;
    Ok(())
}

/// The sealed credential blob, for the sync engine's provider factory.
pub fn credentials(
    connection: &Connection,
    account_id: Uuid,
) -> Result<Option<Vec<u8>>, WriteError> {
    let mut statement =
        connection.prepare("SELECT credentials FROM accounts WHERE id = ? LIMIT 1")?;
    let mut rows = statement.query([account_id.as_bytes().as_slice()])?;
    match rows.next()? {
        Some(row) => Ok(row.get(0)?),
        None => Ok(None),
    }
}

/// v3 MessageStore.deleteLiveRows: wipe only live inbox rows on a UID reset.
///
/// The archive and trash are not wiped: a UIDVALIDITY change invalidates the
/// server's UID space, not the mail. The app never reads those folders back, so
/// deleting them locally would be an unrecoverable deletion.
pub fn delete_live_rows(connection: &Connection, account_id: Uuid) -> Result<usize, WriteError> {
    Ok(connection.execute(
        "DELETE FROM message_headers
         WHERE account_id = ?
           AND is_archived = FALSE AND is_deleted = FALSE AND is_sent = FALSE",
        rusqlite::params![account_id.as_bytes().as_slice()],
    )?)
}

/// v3 MessageStore.reconcileInbox: move rows the provider placed elsewhere,
/// and delete only the ones it confirmed gone.
pub fn reconcile_inbox(
    connection: &Connection,
    account_id: Uuid,
    keeping: &[String],
    archived: &[String],
    trashed: &[String],
    removed: &[String],
) -> Result<(), WriteError> {
    let local: Vec<String> = {
        let mut statement = connection.prepare(
            "SELECT remote_id FROM message_headers
             WHERE account_id = ? AND is_archived = FALSE AND is_deleted = FALSE AND is_sent = FALSE",
        )?;
        let rows = statement.query_map([account_id.as_bytes().as_slice()], |row| row.get(0))?;
        let mut ids = Vec::new();
        for row in rows {
            ids.push(row?);
        }
        ids
    };
    let keeping: std::collections::HashSet<&str> = keeping.iter().map(String::as_str).collect();
    let archived: std::collections::HashSet<&str> = archived.iter().map(String::as_str).collect();
    let trashed: std::collections::HashSet<&str> = trashed.iter().map(String::as_str).collect();
    let removed: std::collections::HashSet<&str> = removed.iter().map(String::as_str).collect();
    for remote_id in local {
        if keeping.contains(remote_id.as_str()) {
            continue;
        }
        if archived.contains(remote_id.as_str()) {
            connection.execute(
                "UPDATE message_headers SET is_archived = TRUE WHERE account_id = ? AND remote_id = ?",
                rusqlite::params![account_id.as_bytes().as_slice(), remote_id],
            )?;
        } else if trashed.contains(remote_id.as_str()) {
            connection.execute(
                "UPDATE message_headers SET is_deleted = TRUE WHERE account_id = ? AND remote_id = ?",
                rusqlite::params![account_id.as_bytes().as_slice(), remote_id],
            )?;
        } else if removed.contains(remote_id.as_str()) {
            connection.execute(
                "DELETE FROM message_headers WHERE account_id = ? AND remote_id = ?",
                rusqlite::params![account_id.as_bytes().as_slice(), remote_id],
            )?;
        }
        // Otherwise: whereabouts unknown. The row stays; a message that merely
        // left the inbox is not evidence that it was deleted.
    }
    Ok(())
}

/// The remote ids of live inbox rows (v3 filterSQL's live lens). The engine
/// uses it to derive deletions from provider membership.
pub fn live_remote_ids(
    connection: &Connection,
    account_id: Uuid,
) -> Result<Vec<String>, WriteError> {
    let mut statement = connection.prepare(
        "SELECT remote_id FROM message_headers
         WHERE account_id = ? AND is_archived = FALSE AND is_deleted = FALSE AND is_sent = FALSE",
    )?;
    let rows = statement.query_map([account_id.as_bytes().as_slice()], |row| row.get(0))?;
    let mut ids = Vec::new();
    for row in rows {
        ids.push(row?);
    }
    Ok(ids)
}

// ---------------------------------------------------------------- actions ---
// R3.5a: the action routes read and write ai_actions directly. The predicates
// mirror v3's AIActionStore.pageSQL: undone rows disappear from the history,
// a send that was claimed but never completed never appears, and the keyset
// cursor is the (created_at, id) pair - an offset would shift under inserts.

/// One audit row as the action routes see it.
#[derive(Debug, Clone)]
pub struct ActionRecord {
    pub id: i64,
    pub kind: String,
    pub payload: String,
    pub created_at: String,
    pub expires_at: Option<String>,
}

/// The (created_at, id) keyset cursor for one action row.
#[derive(Debug, Clone)]
pub struct ActionCursor {
    pub created_at: String,
    pub id: i64,
}

/// One page of the undo history. `total_count` is the count with the same
/// predicate but no cursor, so "还有 N 条" is about the same list.
pub struct ActionPage {
    pub actions: Vec<ActionRecord>,
    pub total_count: i64,
    pub has_more: bool,
}

const PAGE_PREDICATE: &str = "AND NOT EXISTS (\
         SELECT 1 FROM ai_actions u \
         WHERE u.account_id = ai_actions.account_id AND u.kind = 'undo' \
           AND json_extract(u.payload, '$.undoOf') = ai_actions.id) \
       AND NOT (kind = 'send' AND json_extract(payload, '$.sentFolder') IS NOT NULL)";

pub fn message_exists(
    connection: &Connection,
    account_id: Uuid,
    remote_id: &str,
) -> Result<bool, WriteError> {
    let found = connection
        .prepare("SELECT 1 FROM message_headers WHERE account_id = ? AND remote_id = ? LIMIT 1")?
        .query_row(
            rusqlite::params![account_id.as_bytes().as_slice(), remote_id],
            |_| Ok(()),
        )
        .optional()?;
    Ok(found.is_some())
}

pub fn set_archived(
    connection: &Connection,
    account_id: Uuid,
    remote_id: &str,
    archived: bool,
) -> Result<(), WriteError> {
    connection.execute(
        "UPDATE message_headers SET is_archived = ? WHERE account_id = ? AND remote_id = ?",
        rusqlite::params![archived, account_id.as_bytes().as_slice(), remote_id],
    )?;
    Ok(())
}

pub fn set_deleted(
    connection: &Connection,
    account_id: Uuid,
    remote_id: &str,
    deleted: bool,
) -> Result<(), WriteError> {
    connection.execute(
        "UPDATE message_headers SET is_deleted = ? WHERE account_id = ? AND remote_id = ?",
        rusqlite::params![deleted, account_id.as_bytes().as_slice(), remote_id],
    )?;
    Ok(())
}

/// Flip is_read and return the value it replaced. None means the row does not
/// exist - the read route skips the audit for it, exactly like v3's
/// setReadSync returning nil.
pub fn set_read_flag(
    connection: &Connection,
    account_id: Uuid,
    remote_id: &str,
    is_read: bool,
) -> Result<Option<bool>, WriteError> {
    let previous = connection
        .prepare(
            "SELECT is_read FROM message_headers WHERE account_id = ? AND remote_id = ? LIMIT 1",
        )?
        .query_row(
            rusqlite::params![account_id.as_bytes().as_slice(), remote_id],
            |row| row.get::<_, Option<bool>>(0),
        )
        .optional()?;
    // NULL is_read does not occur in the schema (NOT NULL DEFAULT FALSE); the
    // double Option is just rusqlite's shape for the row value.
    let previous = previous.flatten();
    connection.execute(
        "UPDATE message_headers SET is_read = ? WHERE account_id = ? AND remote_id = ?",
        rusqlite::params![is_read, account_id.as_bytes().as_slice(), remote_id],
    )?;
    Ok(previous)
}

/// Purge deletes the row outright; the FK cascade takes the body and advice
/// with it (foreign_keys are ON for connections this module opens).
pub fn delete_message_row(
    connection: &Connection,
    account_id: Uuid,
    remote_id: &str,
) -> Result<usize, WriteError> {
    let changed = connection.execute(
        "DELETE FROM message_headers WHERE account_id = ? AND remote_id = ?",
        rusqlite::params![account_id.as_bytes().as_slice(), remote_id],
    )?;
    Ok(changed)
}

/// How many trashed rows the account holds: trash/empty reports this as
/// `purged` after the remote EXPUNGE succeeds.
pub fn trashed_count(connection: &Connection, account_id: Uuid) -> Result<i64, WriteError> {
    connection
        .prepare("SELECT COUNT(*) FROM message_headers WHERE account_id = ? AND is_deleted = TRUE")?
        .query_row([account_id.as_bytes().as_slice()], |row| row.get(0))
        .map_err(WriteError::Sqlite)
}

/// Remove every trashed row for the account after a successful remote
/// EXPUNGE; returns how many local rows went away.
pub fn delete_trashed_rows(connection: &Connection, account_id: Uuid) -> Result<usize, WriteError> {
    let changed = connection.execute(
        "DELETE FROM message_headers WHERE account_id = ? AND is_deleted = TRUE",
        [account_id.as_bytes().as_slice()],
    )?;
    Ok(changed)
}

pub fn find_action(
    connection: &Connection,
    account_id: Uuid,
    id: i64,
) -> Result<Option<ActionRecord>, WriteError> {
    connection
        .prepare(
            "SELECT id, kind, payload, created_at, expires_at FROM ai_actions
             WHERE id = ? AND account_id = ? LIMIT 1",
        )?
        .query_row(
            rusqlite::params![id, account_id.as_bytes().as_slice()],
            decode_action,
        )
        .optional()
        .map_err(WriteError::Sqlite)
}

pub fn is_undone(connection: &Connection, account_id: Uuid, id: i64) -> Result<bool, WriteError> {
    let row = connection
        .prepare(
            "SELECT 1 FROM ai_actions WHERE account_id = ? AND kind = 'undo'
             AND json_extract(payload, '$.undoOf') = ? LIMIT 1",
        )?
        .query_row(
            rusqlite::params![account_id.as_bytes().as_slice(), id.to_string()],
            |_| Ok(()),
        )
        .optional()?;
    Ok(row.is_some())
}

/// Retract the undo claim row when the inverse write failed, so a failed undo
/// does not leave the action reading as done (v3 releaseClaim).
pub fn delete_action_row(connection: &Connection, id: i64) -> Result<usize, WriteError> {
    let changed = connection.execute("DELETE FROM ai_actions WHERE id = ?", [id])?;
    Ok(changed)
}

/// The (created_at, id) cursor of one action, for the `before` page param.
pub fn action_cursor(
    connection: &Connection,
    account_id: Uuid,
    id: i64,
) -> Result<Option<ActionCursor>, WriteError> {
    connection
        .prepare("SELECT created_at, id FROM ai_actions WHERE id = ? AND account_id = ? LIMIT 1")?
        .query_row(
            rusqlite::params![id, account_id.as_bytes().as_slice()],
            |row| {
                Ok(ActionCursor {
                    created_at: row.get(0)?,
                    id: row.get(1)?,
                })
            },
        )
        .optional()
        .map_err(WriteError::Sqlite)
}

/// One history page. `since` is a stored-format timestamp (`None` = the epoch
/// sentinel); `before` is the keyset cursor (`None` = newest first page).
pub fn actions_page(
    connection: &Connection,
    account_id: Uuid,
    since: Option<&str>,
    before: Option<&ActionCursor>,
    limit: i64,
) -> Result<ActionPage, WriteError> {
    let lower = since.unwrap_or("0001-01-01 00:00:00.000");
    let (upper_created, upper_id) = match before {
        Some(cursor) => (cursor.created_at.as_str(), cursor.id),
        None => ("4001-01-01 00:00:00.000", i64::MAX),
    };
    let sql = format!(
        "SELECT id, kind, payload, created_at, expires_at FROM ai_actions
         WHERE account_id = ? AND created_at >= ?
           AND (created_at, id) < (?, ?)
           {}
         ORDER BY created_at DESC, id DESC
         LIMIT ?",
        PAGE_PREDICATE
    );
    let mut statement = connection.prepare(&sql)?;
    let rows = statement.query_map(
        rusqlite::params![
            account_id.as_bytes().as_slice(),
            lower,
            upper_created,
            upper_id,
            limit + 1
        ],
        decode_action,
    )?;
    let mut actions = Vec::new();
    for row in rows {
        actions.push(row?);
    }
    let has_more = actions.len() as i64 > limit;
    actions.truncate(limit as usize);
    let total_count = connection
        .prepare(&format!(
            "SELECT COUNT(*) FROM ai_actions
             WHERE account_id = ? AND created_at >= ? AND {}",
            PAGE_PREDICATE
        ))?
        .query_row(
            rusqlite::params![account_id.as_bytes().as_slice(), lower],
            |row| row.get(0),
        )
        .map_err(WriteError::Sqlite)?;
    Ok(ActionPage {
        actions,
        total_count,
        has_more,
    })
}

fn decode_action(row: &rusqlite::Row<'_>) -> rusqlite::Result<ActionRecord> {
    Ok(ActionRecord {
        id: row.get(0)?,
        kind: row.get(1)?,
        payload: row.get(2)?,
        created_at: row.get(3)?,
        expires_at: row.get(4)?,
    })
}
