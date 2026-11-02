//! Writes a fake account into a store created by this crate.
//!
//! Why this exists: the acceptance proof for the account lifecycle asks that
//! v3.2.0 open a store this crate created and use the account it finds. The
//! credentials must therefore be sealed exactly the way v3 seals them (bare
//! AES-GCM under LAGOON_TOKEN_KEY), or v3 would park the account as
//! "credentials unreadable" instead of attempting IMAP.
//!
//!     LAGOON_BODY_KEY=<base64> LAGOON_TOKEN_KEY=<base64> \
//!         cargo run --example fake_account -- --db /tmp/x.sqlite
//!
//! It writes one fixed fake account and never talks to a mail server.

use std::process::ExitCode;

use lagoon_api::crypto::BodyKey;
use lagoon_api::db;
use lagoon_api::store::migrate::migrate;
use lagoon_api::store::write::{self, NewAccount, NewHeader};
use lagoon_api::token::{ImapCredentials, TokenKey};
use lagoon_api::uuid::Uuid;

fn main() -> ExitCode {
    let mut path: Option<String> = None;
    let mut arguments = std::env::args().skip(1);
    while let Some(argument) = arguments.next() {
        if argument == "--db" {
            path = arguments.next();
        }
    }
    let Some(path) = path else {
        eprintln!(
            "usage: LAGOON_BODY_KEY=<base64> LAGOON_TOKEN_KEY=<base64> fake_account --db PATH"
        );
        return ExitCode::FAILURE;
    };
    let Ok(body_key) = BodyKey::from_base64(&std::env::var("LAGOON_BODY_KEY").unwrap_or_default())
    else {
        eprintln!("LAGOON_BODY_KEY must be the base64 of the 32-byte body key");
        return ExitCode::FAILURE;
    };
    let Ok(token_key) =
        TokenKey::from_base64(&std::env::var("LAGOON_TOKEN_KEY").unwrap_or_default())
    else {
        eprintln!("LAGOON_TOKEN_KEY must be the base64 of the 32-byte credential key");
        return ExitCode::FAILURE;
    };
    match seed(&path, &body_key, &token_key) {
        Ok(account_id) => {
            println!("{account_id}");
            ExitCode::SUCCESS
        }
        Err(message) => {
            eprintln!("{message}");
            ExitCode::FAILURE
        }
    }
}

fn seed(path: &str, body_key: &BodyKey, token_key: &TokenKey) -> Result<String, String> {
    let connection = db::open_writable(path).map_err(|error| error.to_string())?;
    migrate(&connection, Some(body_key)).map_err(|error| error.to_string())?;

    let email = "fake-r3-account@example.invalid";
    let sealed = ImapCredentials::new(email, "fake-auth-code")
        .seal(token_key)
        .map_err(|error| error.to_string())?;
    let account_id = Uuid::new_v4();
    let stored = write::upsert_account(
        &connection,
        &NewAccount {
            id: account_id,
            provider: "qq",
            oauth_user: email,
            email,
            credentials: Some(&sealed),
            capabilities: r#"{"archiveFolder":false,"idle":false,"move":false,"serverSnippet":false,"uidplus":false,"sentFolder":false}"#,
            sync_state: "{}",
        },
    )
    .map_err(|error| error.to_string())?;
    // Active, so the v3 sidecar actually attempts a sync when it opens this
    // store: the point of the exercise is that v3 treats the account as real.
    write::set_account_active(&connection, stored, true).map_err(|error| error.to_string())?;

    write::upsert_header(
        &connection,
        &NewHeader {
            id: Uuid::new_v4(),
            account_id: stored,
            remote_id: "r3-fake-1",
            thread_id: "r3-fake-thread-1",
            from_address: "sender@example.invalid",
            from_name: Some("R3 Fake Sender"),
            subject: Some("Store created by lagoon-api"),
            snippet: Some("written through the writable store"),
            received_at: "2025-03-01 09:00:00.000",
            list_unsubscribe: false,
            message_id_header: Some("<r3-fake-1@example.invalid>"),
            in_reply_to: None,
            references: None,
            unsubscribe_links: "[]",
        },
        Some(body_key),
    )
    .map_err(|error| error.to_string())?;

    Ok(stored.to_wire_string())
}
