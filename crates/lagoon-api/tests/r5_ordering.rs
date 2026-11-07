//! R3.5: the list order must be total, not just "roughly by date".
//!
//! `received_at` is IMAP INTERNALDATE — whole seconds. A real inbox has runs of
//! mail that share one value, so `ORDER BY received_at DESC LIMIT ?` leaves the
//! boundary rows free to come back in a different order on the next poll. The
//! list polls every 30 seconds and the "load more" button re-runs the same
//! query with a bigger limit, so an unstable order shows up as a mail that
//! appears twice while scrolling, or one that disappears from the list.
//!
//! These tests pin the tiebreaker (`id`) that makes the order total.

mod support;

use lagoon_api::db;
use lagoon_api::store::messages::{export_index, recent, MessageFilter};
use lagoon_api::store::migrate::migrate;
use lagoon_api::store::write::{self, NewAccount, NewHeader};
use lagoon_api::uuid::Uuid;
use support::TempDir;

fn account_id() -> Uuid {
    Uuid::parse_strict("11111111-1111-4111-8111-111111111111").expect("uuid")
}

fn new_account() -> NewAccount<'static> {
    NewAccount {
        id: account_id(),
        provider: "qq",
        oauth_user: "order@example.invalid",
        email: "order@example.invalid",
        credentials: Some(b"credential"),
        capabilities: r#"{"archiveFolder":false,"idle":false,"move":false,"serverSnippet":false,"uidplus":false,"sentFolder":false}"#,
        sync_state: "{}",
    }
}

/// Six mails that all arrived in the same second.
const TIE: &str = "2025-03-01 09:00:00.000";

/// The id is the tiebreaker, so each row gets a distinct, ordered one.
fn message_id(index: u8) -> Uuid {
    Uuid::parse_strict(&format!("22222222-2222-4222-8222-2222222222{index:02x}")).expect("uuid")
}

fn header<'a>(index: u8, remote_id: &'a str) -> NewHeader<'a> {
    NewHeader {
        id: message_id(index),
        account_id: account_id(),
        remote_id,
        thread_id: "thread",
        from_address: "sender@example.invalid",
        from_name: Some("Sender"),
        subject: Some("Subject"),
        snippet: None,
        received_at: TIE,
        list_unsubscribe: false,
        message_id_header: None,
        in_reply_to: None,
        references: None,
        unsubscribe_links: "[]",
        remote_uid: None,
    }
}

fn seeded() -> (TempDir, rusqlite::Connection) {
    let temp = TempDir::new("r5-ordering");
    let connection = db::open_writable(temp.join("store.sqlite")).expect("open");
    migrate(&connection, None).expect("migrate");
    write::upsert_account(&connection, &new_account()).expect("account");
    let remote_ids: Vec<String> = (1..=6).map(|index| format!("msg-{index}")).collect();
    for (offset, remote_id) in remote_ids.iter().enumerate() {
        let index = offset as u8 + 1;
        write::upsert_header(&connection, &header(index, remote_id), None).expect("header");
    }
    (temp, connection)
}

#[test]
fn the_newest_page_is_the_same_on_every_call() {
    let (_temp, connection) = seeded();
    let filter = MessageFilter::inbox(account_id());
    let first = recent(&connection, &filter, 3).expect("first page");
    let second = recent(&connection, &filter, 3).expect("second page");
    let first_ids: Vec<String> = first.iter().map(|row| row.remote_id.clone()).collect();
    let second_ids: Vec<String> = second.iter().map(|row| row.remote_id.clone()).collect();
    assert_eq!(
        first_ids, second_ids,
        "a tie must not reshuffle between polls"
    );
    assert_eq!(
        first_ids,
        vec!["msg-6", "msg-5", "msg-4"],
        "within one second the newer id comes first"
    );
}

#[test]
fn growing_the_window_only_appends_older_rows() {
    // This is what "加载更多" does: same query, bigger limit. Nothing that was
    // on page one may move or vanish, or the reader sees the list reorder
    // under their cursor.
    let (_temp, connection) = seeded();
    let filter = MessageFilter::inbox(account_id());
    let small = recent(&connection, &filter, 3).expect("small");
    let large = recent(&connection, &filter, 6).expect("large");
    let small_ids: Vec<String> = small.iter().map(|row| row.remote_id.clone()).collect();
    let large_ids: Vec<String> = large.iter().map(|row| row.remote_id.clone()).collect();
    assert_eq!(
        &large_ids[..3],
        &small_ids[..],
        "the first page must not move"
    );
    assert_eq!(
        large_ids,
        vec!["msg-6", "msg-5", "msg-4", "msg-3", "msg-2", "msg-1"]
    );
}

#[test]
fn the_export_is_ordered_the_same_way_twice() {
    // A backup that reorders between runs is not diffable.
    let (_temp, connection) = seeded();
    let first: Vec<String> = export_index(&connection, account_id())
        .expect("export")
        .into_iter()
        .map(|row| row.remote_id)
        .collect();
    let second: Vec<String> = export_index(&connection, account_id())
        .expect("export")
        .into_iter()
        .map(|row| row.remote_id)
        .collect();
    assert_eq!(first, second);
    assert_eq!(
        first,
        vec!["msg-1", "msg-2", "msg-3", "msg-4", "msg-5", "msg-6"],
        "oldest first, ties broken by id ascending"
    );
}
