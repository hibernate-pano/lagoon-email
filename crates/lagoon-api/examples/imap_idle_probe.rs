//! Read-only IMAP IDLE probe: where exactly does the session die?
//!
//! `pull_changes` selects INBOX, waits on IDLE, then re-selects before
//! fetching. On the real mailbox a full-budget round failed as "unreachable"
//! after exactly IDLE_BUDGET, so this probe separates the steps: connect,
//! LOGIN, SELECT, IDLE, re-SELECT. Read-only: LOGIN, SELECT, IDLE.
//!
//!     cargo run -p lagoon-api --example imap_idle_probe -- \
//!       --db <store> --keys <keys.json> --idle 60

use std::time::{Duration, Instant};

use lagoon_api::token::{ImapCredentials, TokenKey};
use lagoon_mail::imap::client::ImapClient;
use lagoon_mail::preset::ProviderPreset;
use lagoon_mail::transport::TlsTransport;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let value = |name: &str| -> String {
        args.iter()
            .position(|a| a == name)
            .and_then(|i| args.get(i + 1))
            .unwrap_or_else(|| panic!("{name} required"))
            .clone()
    };
    let db = value("--db");
    let keys = value("--keys");
    let idle_secs: u64 = value("--idle").parse().expect("--idle seconds");

    let connection =
        rusqlite::Connection::open_with_flags(&db, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
            .expect("open store");
    let (oauth_user, blob): (String, Vec<u8>) = connection
        .query_row(
            "SELECT oauth_user, credentials FROM accounts WHERE is_active = TRUE LIMIT 1",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("active account");
    let keys_raw = std::fs::read_to_string(&keys).expect("keys file");
    let keys_json: serde_json::Value = serde_json::from_str(&keys_raw).expect("keys json");
    let token_key = TokenKey::from_base64(keys_json["tokenKey"].as_str().expect("tokenKey"))
        .expect("token key");
    let credentials = ImapCredentials::open(&token_key, &blob).expect("decrypt credentials");
    println!("account: {oauth_user}");

    let preset = ProviderPreset::qq();
    let (host, port) = preset.imap_endpoint();
    let mut client = ImapClient::new(Box::new(TlsTransport::new()));

    let started = Instant::now();
    match client.connect(host, port) {
        Ok(()) => println!("connect: ok {:?}", started.elapsed()),
        Err(error) => {
            println!("connect: err {:?}: {error}", started.elapsed());
            return;
        }
    }
    let started = Instant::now();
    match client.login(&credentials.username, &credentials.auth_code) {
        Ok(()) => println!("login: ok {:?}", started.elapsed()),
        Err(error) => {
            println!(
                "login: err {:?} kind={:?}: {error}",
                started.elapsed(),
                error.kind()
            );
            return;
        }
    }
    match client.capability() {
        Ok(capabilities) => println!("idle advertised: {}", capabilities.contains("IDLE")),
        Err(error) => println!("capability err: {error}"),
    }
    let started = Instant::now();
    match client.select("INBOX") {
        Ok(state) => println!(
            "select: ok {:?} exists={} uidNext={}",
            started.elapsed(),
            state.exists,
            state.uid_next
        ),
        Err(error) => {
            println!(
                "select: err {:?} kind={:?}: {error}",
                started.elapsed(),
                error.kind()
            );
            return;
        }
    }

    let started = Instant::now();
    match client.idle(Duration::from_secs(idle_secs)) {
        Ok(events) => println!(
            "idle {idle_secs}s: ok {:?} events={}",
            started.elapsed(),
            events.len()
        ),
        Err(error) => println!(
            "idle {idle_secs}s: err {:?} kind={:?}: {error}",
            started.elapsed(),
            error.kind()
        ),
    }

    let started = Instant::now();
    match client.select("INBOX") {
        Ok(state) => println!(
            "reselect: ok {:?} exists={} uidNext={}",
            started.elapsed(),
            state.exists,
            state.uid_next
        ),
        Err(error) => println!(
            "reselect: err {:?} kind={:?}: {error}",
            started.elapsed(),
            error.kind()
        ),
    }
    client.logout();
}
