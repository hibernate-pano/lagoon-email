//! Read-only IMAP probe: what does opening one mail cost, with and without the
//! stored UID?
//!
//! The product resolves a Message-ID to a UID with `UID SEARCH HEADER
//! Message-ID "<id>"`. QQ answers that with an empty set for every spelling,
//! so the fallback scans every UID — measured at ~2.2s per open on a
//! 419-message mailbox. Sync already knows each message's UID, so the fix is to
//! persist it and fetch by UID directly. This probe proves both numbers on the
//! real mailbox.
//!
//! Read-only: LOGIN, SELECT, SEARCH, FETCH (BODY.PEEK).

use std::time::{Duration, Instant};

use lagoon_api::token::{ImapCredentials, TokenKey};
use lagoon_mail::imap::provider::{ImapProvider, ProviderCredentials};
use lagoon_mail::preset::ProviderPreset;
use lagoon_mail::sync::SyncCursor;
use lagoon_mail::transport::TlsTransport;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let db = args
        .iter()
        .position(|a| a == "--db")
        .and_then(|i| args.get(i + 1))
        .expect("--db required");
    let keys = args
        .iter()
        .position(|a| a == "--keys")
        .and_then(|i| args.get(i + 1))
        .expect("--keys required");

    let connection =
        rusqlite::Connection::open_with_flags(db, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
            .expect("open store");
    let (oauth_user, blob): (String, Vec<u8>) = connection
        .query_row(
            "SELECT oauth_user, credentials FROM accounts WHERE is_active = TRUE LIMIT 1",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("active account");
    let keys_raw = std::fs::read_to_string(keys).expect("keys file");
    let keys_json: serde_json::Value = serde_json::from_str(&keys_raw).expect("keys json");
    let token_key = TokenKey::from_base64(keys_json["tokenKey"].as_str().expect("tokenKey"))
        .expect("token key");
    let credentials = ImapCredentials::open(&token_key, &blob).expect("decrypt credentials");
    println!("account: {oauth_user}");

    let make_provider = || {
        ImapProvider::new(
            ProviderPreset::qq(),
            ProviderCredentials::new(&credentials.username, &credentials.auth_code),
            Box::new(|| Box::new(TlsTransport::new())),
        )
    };

    // One round's worth of headers: exactly what sync reads. This is the only
    // way to learn a (message-id, uid) pair without touching the store.
    let mut provider = make_provider();
    let started = Instant::now();
    let changes = provider
        .pull_changes(SyncCursor::default(), Duration::ZERO)
        .expect("pull headers");
    println!(
        "header pull: {:?} -> {} rows",
        started.elapsed(),
        changes.upserts.len()
    );

    // The per-round cost the sync loop also pays: membership walks every UID in
    // INBOX, Archive and Trash on the same session.
    let started = Instant::now();
    let membership = provider.remote_membership();
    println!(
        "membership: {:?} -> inbox {:?} archive {:?} trash {:?}",
        started.elapsed(),
        membership.inbox.as_ref().map(|folder| folder.uids.len()),
        membership.archive.as_ref().map(|folder| folder.uids.len()),
        membership.trash.as_ref().map(|folder| folder.uids.len()),
    );
    let sample = changes
        .upserts
        .iter()
        .find(|header| header.remote_id.starts_with('<'))
        .expect("one Message-ID-shaped row")
        .clone();
    provider.shutdown();
    println!("sample: {} uid {}", sample.remote_id, sample.uid);

    // Cold open, no hint: the pre-fix path (search + full scan).
    let mut provider = make_provider();
    let started = Instant::now();
    let slow = provider
        .fetch_body(&sample.remote_id, None)
        .expect("slow body");
    println!(
        "cold open, no hint: {:?} -> {} chars",
        started.elapsed(),
        slow.text.chars().count()
    );
    provider.shutdown();

    // Cold open, stored UID: what the route now passes.
    let mut provider = make_provider();
    let started = Instant::now();
    let fast = provider
        .fetch_body(&sample.remote_id, Some(sample.uid))
        .expect("fast body");
    println!(
        "cold open, stored uid: {:?} -> {} chars",
        started.elapsed(),
        fast.text.chars().count()
    );
    provider.shutdown();

    assert_eq!(slow.text, fast.text, "both paths must return the same mail");
    println!("same body: yes");
}
