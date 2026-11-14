//! Synthetic store contents, reconstructed from the golden fixtures.
//!
//! The values are not restated here on purpose. A fixture carries the exact
//! response v3 produced for a known store, so the store is the inverse of that
//! response: if the seed is derived from the fixture and the server then answers
//! with the fixture, no field can be wrong without the test noticing. It also
//! keeps values that tooling may redact in one transcript out of the source.

use rusqlite::{params, Connection};
use serde_json::Value;

use lagoon_api::uuid::Uuid;

use super::fixtures::Fixtures;

/// One seeded header row.
#[derive(Debug, Clone)]
pub struct SeedMessage {
    pub id: String,
    pub remote_id: String,
    pub thread_id: String,
    pub from_address: String,
    pub from_name: Option<String>,
    pub subject: Option<String>,
    pub received_at: String,
    pub is_read: bool,
    pub is_archived: bool,
    pub is_deleted: bool,
    pub is_sent: bool,
    pub message_id_header: Option<String>,
    pub in_reply_to: Option<String>,
    pub references: Option<String>,
}

pub struct Seed {
    pub account_id: String,
    pub account_email: String,
    pub capabilities: Value,
    pub messages: Vec<SeedMessage>,
    pub pinned_remote_ids: Vec<String>,
}

impl Seed {
    pub fn from_fixtures(fixtures: &Fixtures) -> Self {
        let identity = fixtures.seed_block();
        let account_id = identity["accountId"]
            .as_str()
            .expect("seed.accountId")
            .to_owned();
        let account_email = identity["accountEmail"]
            .as_str()
            .expect("seed.accountEmail")
            .to_owned();

        let account_body = &fixtures.by_name("accounts.list")["response"]["body"];
        let capabilities = account_body[0]["capabilities"].clone();

        // Every list lens carries a disjoint slice of the same store; union them
        // by remoteId so the seeded store is the whole mailbox the fixtures
        // describe.
        let mut messages: Vec<SeedMessage> = Vec::new();
        for name in [
            "messages.list",
            "messages.list.archived",
            "messages.list.pinned",
            "messages.list.unread",
        ] {
            let body = &fixtures.by_name(name)["response"]["body"];
            let Some(items) = body["messages"].as_array() else {
                continue;
            };
            for message in items {
                let remote_id = message["remoteId"].as_str().expect("remoteId").to_owned();
                if messages.iter().any(|seeded| seeded.remote_id == remote_id) {
                    continue;
                }
                messages.push(message_from_fixture(message));
            }
        }

        let pinned_remote_ids = fixtures.by_name("messages.list.pinned")["response"]["body"]
            ["messages"]
            .as_array()
            .map(|items| {
                items
                    .iter()
                    .map(|message| message["remoteId"].as_str().expect("remoteId").to_owned())
                    .collect()
            })
            .unwrap_or_default();

        Self {
            account_id,
            account_email,
            capabilities,
            messages,
            pinned_remote_ids,
        }
    }

    pub fn account_uuid(&self) -> Uuid {
        Uuid::parse_strict(&self.account_id).expect("seed account id is a UUID")
    }

    /// Insert the seed rows. The caller owns the connection (read-write), which
    /// is the only place in this crate's world where a write happens - and it
    /// is a throwaway temp store, never a real one.
    pub fn apply(&self, connection: &Connection) -> rusqlite::Result<()> {
        let account_uuid = self.account_uuid();
        let created_at = "2025-01-01 00:00:00.000";
        connection.execute(
            "INSERT INTO accounts (
                 id, provider, oauth_user, email, credentials, sync_state, capabilities,
                 is_active, sync_status, created_at, updated_at
             ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            params![
                account_uuid.as_bytes().as_slice(),
                "qq",
                self.account_email,
                self.account_email,
                // 48 zero bytes: a well-formed AES-GCM container no key opens, so
                // nothing in this process can ever build a provider from it.
                vec![0u8; 48],
                "{}",
                serde_json::to_string(&self.capabilities).expect("capabilities json"),
                1i64,
                "ok",
                created_at,
                created_at,
            ],
        )?;

        let mut statement = connection.prepare(
            "INSERT INTO message_headers (
                 id, account_id, remote_id, thread_id, from_address, from_name, subject,
                 snippet_cipher, received_at, is_read, is_archived, is_deleted, is_sent,
                 message_id_header, in_reply_to, references_header, fetched_at
             ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        )?;
        for message in &self.messages {
            let id = Uuid::parse_strict(&message.id).expect("message id is a UUID");
            statement.execute(params![
                id.as_bytes().as_slice(),
                account_uuid.as_bytes().as_slice(),
                message.remote_id,
                message.thread_id,
                message.from_address,
                message.from_name,
                message.subject,
                message.received_at,
                message.is_read as i64,
                message.is_archived as i64,
                message.is_deleted as i64,
                message.is_sent as i64,
                message.message_id_header,
                message.in_reply_to,
                message.references,
                created_at,
            ])?;
        }

        let mut pin = connection.prepare(
            "INSERT INTO message_pins (account_id, remote_id, created_at) VALUES (?, ?, ?)",
        )?;
        for remote_id in &self.pinned_remote_ids {
            pin.execute(params![
                account_uuid.as_bytes().as_slice(),
                remote_id,
                created_at
            ])?;
        }
        Ok(())
    }
}

fn message_from_fixture(message: &Value) -> SeedMessage {
    SeedMessage {
        id: message["id"].as_str().expect("id").to_owned(),
        remote_id: message["remoteId"].as_str().expect("remoteId").to_owned(),
        thread_id: message["threadId"].as_str().expect("threadId").to_owned(),
        from_address: message["fromAddress"]
            .as_str()
            .expect("fromAddress")
            .to_owned(),
        from_name: message["fromName"].as_str().map(str::to_owned),
        subject: message["subject"].as_str().map(str::to_owned),
        received_at: iso_to_stored(message["receivedAt"].as_str().expect("receivedAt")),
        is_read: message["isRead"].as_bool().expect("isRead"),
        is_archived: message["isArchived"].as_bool().expect("isArchived"),
        is_deleted: message["isDeleted"].as_bool().unwrap_or(false),
        is_sent: message["isSent"].as_bool().unwrap_or(false),
        message_id_header: message["messageIdHeader"].as_str().map(str::to_owned),
        in_reply_to: message["inReplyTo"].as_str().map(str::to_owned),
        references: message["references"].as_str().map(str::to_owned),
    }
}

/// ISO-8601 (which the wire carries) to the store's "yyyy-MM-dd HH:mm:ss.SSS".
fn iso_to_stored(wire: &str) -> String {
    let without_suffix = wire.trim_end_matches('Z');
    let (date, clock) = without_suffix.split_once('T').expect("wire date");
    let clock = if clock.contains('.') {
        let (whole, fraction) = clock.split_once('.').expect("fraction");
        let mut fraction = fraction.to_owned();
        while fraction.len() < 3 {
            fraction.push('0');
        }
        fraction.truncate(3);
        format!("{whole}.{fraction}")
    } else {
        format!("{clock}.000")
    };
    format!("{date} {clock}")
}

/// Seed a store with the contract harness' own seed script.
///
/// Why shell out instead of inserting rows from Rust: the fixtures' data
/// (including the sealed body and the sealed draft) is defined in one place, the
/// harness, and was captured against exactly that seed with an ephemeral body
/// key. A second copy here would be a row-for-row clone that nothing keeps in
/// step - and the fixtures are the oracle precisely because the seed is shared.
///
/// Returns Err with a human message when python3 or the harness is missing, so
/// the caller can skip loudly instead of failing for the wrong reason.
pub fn seed_via_harness(
    db_path: &std::path::Path,
    body_key_base64: &str,
    keep_account_ids: &[String],
) -> Result<(), String> {
    let harness = harness_path();
    seed_via_harness_at(&harness, db_path, body_key_base64, keep_account_ids)
}

/// Run one of the harness' PRE_HOOKS by name.
///
/// The hooks live in python (harness.py) because they are part of the seed
/// contract: a fixture that needs its account restored to healthy must be
/// restored the way the capture restored it, or the replay is not the same
/// request. Only the hook NAME crosses the boundary.
pub fn run_pre_hook(db_path: &std::path::Path, hook: &str) -> Result<(), String> {
    let harness = harness_path();
    if !harness.is_file() {
        return Err(format!("missing {}", harness.display()));
    }
    let output = std::process::Command::new("python3")
        .arg(harness)
        .arg("pre")
        .arg("--hook")
        .arg(hook)
        .arg("--db")
        .arg(db_path)
        .output()
        .map_err(|error| format!("cannot run python3: {error}"))?;
    if !output.status.success() {
        return Err(format!(
            "pre hook {hook} failed ({}): {}{}",
            output.status,
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    Ok(())
}

fn harness_path() -> std::path::PathBuf {
    std::env::var("LAGOON_CONTRACT_HARNESS")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| {
            std::path::PathBuf::from(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../../tests/contract/harness.py"
            ))
        })
}

fn seed_via_harness_at(
    harness: &std::path::Path,
    db_path: &std::path::Path,
    body_key_base64: &str,
    keep_account_ids: &[String],
) -> Result<(), String> {
    if !harness.is_file() {
        return Err(format!(
            "missing {} - run: bash scripts/capture-contract.sh",
            harness.display()
        ));
    }
    let output = std::process::Command::new("python3")
        .arg(harness)
        .arg("seed")
        .arg("--db")
        .arg(db_path)
        .arg("--body-key")
        .arg(body_key_base64)
        .output()
        .map_err(|error| format!("cannot run python3: {error}"))?;
    if !output.status.success() {
        return Err(format!(
            "harness seed failed ({}): {}{}",
            output.status,
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    // The harness may be ahead of the fixtures file (it seeds accounts a newer
    // fixture set will use). The fixtures being replayed are the oracle for
    // *this* run, so keep exactly the accounts their seed block names.
    if !keep_account_ids.is_empty() {
        let connection = rusqlite::Connection::open(db_path)
            .map_err(|error| format!("cannot reopen seeded store: {error}"))?;
        connection
            .execute_batch("PRAGMA foreign_keys = ON;")
            .map_err(|error| format!("foreign keys: {error}"))?;
        let placeholders = vec!["?"; keep_account_ids.len()].join(",");
        let bytes: Vec<Vec<u8>> = keep_account_ids
            .iter()
            .map(|raw| {
                support_uuid_parse(raw)
                    .unwrap_or_else(|| panic!("bad account id in fixtures seed block: {raw}"))
            })
            .collect();
        let sql = format!("DELETE FROM accounts WHERE id NOT IN ({placeholders})");
        connection
            .execute(&sql, rusqlite::params_from_iter(bytes.iter()))
            .map_err(|error| format!("cannot prune extra seeded accounts: {error}"))?;
    }
    Ok(())
}

/// Small helper so the test support does not depend on a public uuid parser.
pub(crate) fn support_uuid_parse(raw: &str) -> Option<Vec<u8>> {
    let bytes = raw.as_bytes();
    if bytes.len() != 36 {
        return None;
    }
    let mut out = Vec::with_capacity(16);
    for (index, chunk) in raw.split('-').enumerate() {
        if chunk.len() != [8, 4, 4, 4, 12][index] || !chunk.chars().all(|c| c.is_ascii_hexdigit()) {
            return None;
        }
        for pair in chunk.as_bytes().chunks(2) {
            let value = (hex_value(pair[0])? << 4) | hex_value(pair[1])?;
            out.push(value);
        }
    }
    Some(out)
}

fn hex_value(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

/// base64 of the test-vector body key, the form the harness expects.
pub fn test_body_key_base64() -> String {
    use base64::Engine as _;
    base64::engine::general_purpose::STANDARD.encode(super::server::TEST_KEY_SEED)
}
