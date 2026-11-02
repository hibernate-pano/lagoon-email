//! R3.4b-2a: one-session inbox/archive/trash membership.
//!
//! Every test asserts `connect_count == 1`: the whole point of the API is that
//! the three membership sets cost one authenticated session, not one per folder.
//! All wire bytes are scripted; there is no socket and no network.

mod support;

use std::collections::BTreeSet;

use lagoon_mail::imap::provider::{ImapProvider, ProviderCredentials};
use lagoon_mail::preset::ProviderPreset;
use lagoon_mail::transport::Transport;
use support::{imap_session_script, select_script, ScriptedTransport};

fn provider(transport: &ScriptedTransport) -> ImapProvider {
    let handle = transport.handle();
    ImapProvider::new(
        ProviderPreset::qq(),
        ProviderCredentials::new("user@example.com", "auth-code"),
        Box::new(move || Box::new(handle.clone()) as Box<dyn Transport>),
    )
}

fn header_with_message_id(message_id: &str) -> Vec<u8> {
    format!("Message-ID: {message_id}\r\n\r\n").into_bytes()
}

fn header_without_message_id() -> Vec<u8> {
    b"Subject: no message id\r\n\r\n".to_vec()
}

fn enqueue_fetch(transport: &ScriptedTransport, sequence: usize, uid: i64, header: &[u8]) {
    transport.enqueue_line(format!(
        "* {sequence} FETCH (UID {uid} BODY[HEADER.FIELDS (MESSAGE-ID)] {{{}}}",
        header.len()
    ));
    transport.enqueue_literal(header.to_vec());
    transport.enqueue_line(")");
}

fn assert_one_connection(transport: &ScriptedTransport) {
    assert_eq!(
        transport.connect_count(),
        1,
        "membership must reuse one session; connects: {:?}",
        transport.connects()
    );
}

#[test]
fn all_three_folders_are_read_on_one_session_with_uid_and_remote_ids() {
    let transport = ScriptedTransport::new();
    imap_session_script(&transport, "IMAP4rev1"); // no MOVE, no UIDPLUS
    transport.enqueue_lines(&[
        "* LIST (\\HasNoChildren) \"/\" \"INBOX\"",
        // Name-heuristic archive role (no \Archive attribute).
        "* LIST (\\HasNoChildren) \"/\" \"归档\"",
        "* LIST (\\Trash) \"/\" \"Trash\"",
        "A0003 OK LIST completed",
    ]);
    select_script(&transport, "A0004", 2, 7, 12);
    transport.enqueue_line("* SEARCH 10 11");
    transport.enqueue_line("A0005 OK SEARCH completed");
    enqueue_fetch(
        &transport,
        1,
        10,
        &header_with_message_id("<inbox-10@example.com>"),
    );
    enqueue_fetch(&transport, 2, 11, &header_without_message_id());
    transport.enqueue_line("A0006 OK FETCH completed");

    select_script(&transport, "A0007", 0, 8, 9);
    transport.enqueue_line("* SEARCH");
    transport.enqueue_line("A0008 OK SEARCH completed");

    select_script(&transport, "A0009", 1, 9, 10);
    transport.enqueue_line("* SEARCH 42");
    transport.enqueue_line("A0010 OK SEARCH completed");
    enqueue_fetch(
        &transport,
        1,
        42,
        &header_with_message_id("<trash-42@example.com>"),
    );
    transport.enqueue_line("A0011 OK FETCH completed");

    let mut provider = provider(&transport);
    let membership = provider.remote_membership();

    assert_one_connection(&transport);
    assert!(membership.is_complete(), "{membership:?}");

    let inbox = membership.inbox.as_ref().unwrap();
    assert_eq!(inbox.uids, BTreeSet::from([10, 11]));
    assert_eq!(
        inbox.remote_ids,
        BTreeSet::from(["<inbox-10@example.com>".to_owned(), "uid:11".to_owned()])
    );
    assert_eq!(
        membership.inbox_remote_ids(),
        Some(vec![
            "<inbox-10@example.com>".to_owned(),
            "uid:11".to_owned()
        ])
    );

    assert_eq!(membership.archive.as_ref().unwrap().uids, BTreeSet::new());
    assert_eq!(
        membership.trash.as_ref().unwrap().uids,
        BTreeSet::from([42])
    );
    assert_eq!(
        membership.trashed_remote_ids(),
        Some(vec!["<trash-42@example.com>".to_owned()])
    );

    // Reading membership is read-only: no MOVE/UIDPLUS command may appear.
    let wire = transport.writes_text();
    assert!(!wire.contains("MOVE"), "{wire}");
    assert!(!wire.contains("EXPUNGE"), "{wire}");
    assert!(!wire.contains("STORE"), "{wire}");
    assert!(!wire.contains("UID COPY"), "{wire}");
}

#[test]
fn a_missing_archive_role_is_none_while_inbox_and_trash_are_known() {
    let transport = ScriptedTransport::new();
    imap_session_script(&transport, "IMAP4rev1");
    transport.enqueue_lines(&[
        "* LIST (\\HasNoChildren) \"/\" \"INBOX\"",
        "* LIST (\\Trash) \"/\" \"Trash\"",
        "A0003 OK LIST completed",
    ]);
    select_script(&transport, "A0004", 0, 7, 8);
    transport.enqueue_line("* SEARCH");
    transport.enqueue_line("A0005 OK SEARCH completed");
    select_script(&transport, "A0006", 0, 8, 9);
    transport.enqueue_line("* SEARCH");
    transport.enqueue_line("A0007 OK SEARCH completed");

    let mut provider = provider(&transport);
    let membership = provider.remote_membership();

    assert_one_connection(&transport);
    assert!(membership.inbox.is_some());
    assert_eq!(membership.archive, None);
    assert!(membership.trash.is_some());
    assert!(!membership.is_complete());
    assert_eq!(membership.archived_remote_ids(), None);
    // No SELECT for an archive folder may be attempted.
    assert!(!transport.writes_text().contains("SELECT \"Archive\""));
}

#[test]
fn an_oversized_folder_is_none_not_a_truncated_set() {
    let transport = ScriptedTransport::new();
    imap_session_script(&transport, "IMAP4rev1");
    transport.enqueue_lines(&[
        "* LIST (\\HasNoChildren) \"/\" \"INBOX\"",
        "* LIST (\\Archive) \"/\" \"Archive\"",
        "* LIST (\\Trash) \"/\" \"Trash\"",
        "A0003 OK LIST completed",
    ]);
    // EXISTS alone is over budget: do not even issue SEARCH ALL.
    select_script(&transport, "A0004", 5001, 7, 5002);
    select_script(&transport, "A0005", 0, 8, 9);
    transport.enqueue_line("* SEARCH");
    transport.enqueue_line("A0006 OK SEARCH completed");
    select_script(&transport, "A0007", 0, 9, 10);
    transport.enqueue_line("* SEARCH");
    transport.enqueue_line("A0008 OK SEARCH completed");

    let mut provider = provider(&transport);
    let membership = provider.remote_membership();

    assert_one_connection(&transport);
    assert_eq!(membership.inbox, None);
    assert!(membership.archive.is_some());
    assert!(membership.trash.is_some());
    let searches = transport
        .command_lines()
        .iter()
        .filter(|line| line.contains("UID SEARCH ALL"))
        .count();
    assert_eq!(
        searches,
        2,
        "only archive and trash may be walked: {:?}",
        transport.command_lines()
    );
}

#[test]
fn a_uid_set_over_the_custom_budget_is_none() {
    let transport = ScriptedTransport::new();
    imap_session_script(&transport, "IMAP4rev1");
    transport.enqueue_lines(&[
        "* LIST (\\HasNoChildren) \"/\" \"INBOX\"",
        "* LIST (\\Archive) \"/\" \"Archive\"",
        "* LIST (\\Trash) \"/\" \"Trash\"",
        "A0003 OK LIST completed",
    ]);
    select_script(&transport, "A0004", 1, 7, 8);
    transport.enqueue_line("* SEARCH 1 2 3");
    transport.enqueue_line("A0005 OK SEARCH completed");
    select_script(&transport, "A0006", 0, 8, 9);
    transport.enqueue_line("* SEARCH");
    transport.enqueue_line("A0007 OK SEARCH completed");
    select_script(&transport, "A0008", 0, 9, 10);
    transport.enqueue_line("* SEARCH");
    transport.enqueue_line("A0009 OK SEARCH completed");

    let mut provider = provider(&transport);
    let membership = provider.remote_membership_with_budget(2);

    assert_one_connection(&transport);
    assert_eq!(membership.inbox, None);
    assert!(membership.archive.is_some());
    assert!(membership.trash.is_some());
    // No header walk for a set that is already over budget.
    assert!(!transport.writes_text().contains("HEADER.FIELDS"));
}

#[test]
fn a_forbidden_folder_is_none_and_the_other_folders_still_complete() {
    let transport = ScriptedTransport::new();
    imap_session_script(&transport, "IMAP4rev1");
    transport.enqueue_lines(&[
        "* LIST (\\HasNoChildren) \"/\" \"INBOX\"",
        "* LIST (\\Archive) \"/\" \"Archive\"",
        "* LIST (\\Trash) \"/\" \"Trash\"",
        "A0003 OK LIST completed",
    ]);
    select_script(&transport, "A0004", 0, 7, 8);
    transport.enqueue_line("* SEARCH");
    transport.enqueue_line("A0005 OK SEARCH completed");
    transport.enqueue_line("A0006 NO [NOPERM] no permission");
    select_script(&transport, "A0007", 0, 9, 10);
    transport.enqueue_line("* SEARCH");
    transport.enqueue_line("A0008 OK SEARCH completed");

    let mut provider = provider(&transport);
    let membership = provider.remote_membership();

    assert_one_connection(&transport);
    assert!(membership.inbox.is_some());
    assert_eq!(membership.archive, None);
    assert!(membership.trash.is_some());
}

#[test]
fn a_select_timeout_marks_remaining_folders_unknown_without_panicking() {
    let transport = ScriptedTransport::new();
    imap_session_script(&transport, "IMAP4rev1");
    transport.enqueue_lines(&[
        "* LIST (\\HasNoChildren) \"/\" \"INBOX\"",
        "* LIST (\\Archive) \"/\" \"Archive\"",
        "* LIST (\\Trash) \"/\" \"Trash\"",
        "A0003 OK LIST completed",
    ]);
    select_script(&transport, "A0004", 0, 7, 8);
    transport.enqueue_line("* SEARCH");
    transport.enqueue_line("A0005 OK SEARCH completed");
    // SELECT Archive stalls: the scripted transport reports a read timeout.
    transport.enqueue_timeout();

    let mut provider = provider(&transport);
    let membership = provider.remote_membership();

    assert_one_connection(&transport);
    assert!(membership.inbox.is_some());
    assert_eq!(membership.archive, None);
    assert_eq!(membership.trash, None);
    // The dead session was closed rather than left half-open.
    assert_eq!(transport.close_count(), 1);
}

#[test]
fn a_roles_less_listing_failure_yields_all_unknown_without_reconnecting() {
    let transport = ScriptedTransport::new();
    imap_session_script(&transport, "IMAP4rev1");
    transport.enqueue_line("A0003 NO LIST failed");

    let mut provider = provider(&transport);
    let membership = provider.remote_membership();

    assert_one_connection(&transport);
    assert_eq!(membership, Default::default());
    assert!(!transport.writes_text().contains("SELECT"));
}
