//! Command-layer tests for `ImapClient`: LOGIN/SASL, CAPABILITY caching,
//! LIST/SELECT, UID SEARCH/FETCH, STORE/MOVE/UID EXPUNGE and argument quoting.
//! All wire bytes are scripted.

mod support;

use base64::Engine as _;
use lagoon_mail::error::MailErrorKind;
use lagoon_mail::imap::client::{ImapClient, DEFAULT_HEADER_FIELDS};
use support::ScriptedTransport;

fn connected(transport: &ScriptedTransport) -> ImapClient {
    transport.enqueue_line("* OK ready");
    let mut client = ImapClient::new(Box::new(transport.handle()));
    client.connect("imap.example.test", 993).unwrap();
    client
}

#[test]
fn capability_is_parsed_uppercased_and_cached() {
    let transport = ScriptedTransport::new();
    transport.enqueue_line("* OK ready");
    transport.enqueue_line("* CAPABILITY imap4rev1 uidplus move idle");
    transport.enqueue_line("A0001 OK CAPABILITY completed");
    let mut client = connected(&transport);

    let capabilities = client.capability().unwrap();
    assert!(capabilities.contains("UIDPLUS"));
    assert!(capabilities.contains("MOVE"));
    assert!(capabilities.contains("IDLE"));
    assert!(capabilities.contains("IMAP4REV1"));

    // Cached: no second command.
    client.capability().unwrap();
    assert_eq!(transport.command_lines(), ["A0001 CAPABILITY"]);
}

#[test]
fn capability_without_an_untagged_line_is_not_cached() {
    let transport = ScriptedTransport::new();
    transport.enqueue_line("* OK ready");
    transport.enqueue_line("A0001 OK CAPABILITY completed");
    transport.enqueue_line("A0002 OK CAPABILITY completed");
    let mut client = connected(&transport);

    assert!(client.capability().unwrap().is_empty());
    assert!(client.capability().unwrap().is_empty());
    assert_eq!(
        transport.command_lines(),
        ["A0001 CAPABILITY", "A0002 CAPABILITY"]
    );
}

#[test]
fn login_uses_authenticate_plain_with_sasl_ir() {
    let transport = ScriptedTransport::new();
    transport.enqueue_line("* OK ready");
    transport.enqueue_line("A0001 OK AUTHENTICATE completed");
    let mut client = connected(&transport);

    client.login("user@example.com", "auth-code").unwrap();
    let command = &transport.command_lines()[0];
    let payload = command
        .strip_prefix("A0001 AUTHENTICATE PLAIN ")
        .expect("SASL-IR form");
    let decoded = base64::engine::general_purpose::STANDARD
        .decode(payload)
        .unwrap();
    assert_eq!(decoded, b"\0user@example.com\0auth-code");
    assert!(
        !command.contains("auth-code"),
        "raw secret on the wire: {command}"
    );
}

#[test]
fn login_falls_back_to_logout_free_login_after_sasl_rejection() {
    let transport = ScriptedTransport::new();
    transport.enqueue_line("* OK ready");
    transport.enqueue_line("A0001 NO AUTHENTICATE not supported");
    transport.enqueue_line("A0002 OK LOGIN completed");
    let mut client = connected(&transport);

    client.login("user@example.com", "auth-code").unwrap();
    let lines = transport.command_lines();
    assert_eq!(lines.len(), 2, "{lines:?}");
    assert!(
        lines[0].starts_with("A0001 AUTHENTICATE PLAIN "),
        "{lines:?}"
    );
    assert_eq!(lines[1], "A0002 LOGIN \"user@example.com\" \"auth-code\"");
}

#[test]
fn login_no_after_login_is_auth_failed() {
    let transport = ScriptedTransport::new();
    transport.enqueue_line("* OK ready");
    transport.enqueue_line("A0001 NO AUTHENTICATE not supported");
    transport.enqueue_line("A0002 NO bad credentials");
    let mut client = connected(&transport);
    let error = client.login("user@example.com", "auth-code").unwrap_err();
    assert_eq!(error.kind(), MailErrorKind::AuthFailed);
}

#[test]
fn select_parses_exists_uidvalidity_and_uidnext() {
    let transport = ScriptedTransport::new();
    transport.enqueue_line("* OK ready");
    transport.enqueue_line("* 12 EXISTS");
    transport.enqueue_line("* OK [UIDVALIDITY 99] valid");
    transport.enqueue_line("* OK [UIDNEXT 100] next");
    transport.enqueue_line("A0001 OK [READ-WRITE] SELECT completed");
    let mut client = connected(&transport);

    let selected = client.select("INBOX").unwrap();
    assert_eq!(selected.mailbox, "INBOX");
    assert_eq!(selected.exists, 12);
    assert_eq!(selected.uid_validity, 99);
    assert_eq!(selected.uid_next, 100);
    assert_eq!(transport.command_lines(), ["A0001 SELECT \"INBOX\""]);
}

#[test]
fn list_parses_attributes_unicode_names_and_nested_paths() {
    let transport = ScriptedTransport::new();
    transport.enqueue_line("* OK ready");
    transport.enqueue_line("* LIST (\\HasNoChildren) \"/\" \"INBOX\"");
    transport.enqueue_line("* LIST (\\Archive \\HasNoChildren) \"/\" \"QQ/归档\"");
    transport.enqueue_line("A0001 OK LIST completed");
    let mut client = connected(&transport);

    let mailboxes = client.list_mailboxes().unwrap();
    assert_eq!(mailboxes.len(), 2);
    assert_eq!(mailboxes[0].name, "INBOX");
    assert!(mailboxes[0].attributes[0].eq_ignore_ascii_case("\\HasNoChildren"));
    assert_eq!(mailboxes[1].name, "QQ/归档");
    assert_eq!(mailboxes[1].attributes, ["\\Archive", "\\HasNoChildren"]);
    assert_eq!(transport.command_lines(), ["A0001 LIST \"\" \"*\""]);
}

fn header_fetch_script(transport: &ScriptedTransport, tag: &str) {
    let header = b"From: Alice <alice@example.com>\r\nSubject: =?GBK?B?u+HS6bzN0qo=?=\r\nMessage-ID: <m1@example.com>\r\n\r\n";
    transport.enqueue_line(format!(
        "* 1 FETCH (UID 7 FLAGS (\\Seen) INTERNALDATE \"11-Sep-2026 10:00:00 +0800\" BODY[HEADER.FIELDS (FROM SUBJECT)] {{{}}}",
        header.len()
    ));
    transport.enqueue_literal(header.to_vec());
    transport.enqueue_line(")");
    transport.enqueue_line(format!("{tag} OK FETCH completed"));
}

#[test]
fn fetch_headers_parses_flags_date_and_unfolded_raw_values() {
    let transport = ScriptedTransport::new();
    transport.enqueue_line("* OK ready");
    header_fetch_script(&transport, "A0001");
    let mut client = connected(&transport);

    let headers = client
        .fetch_headers_from_uid(7, &DEFAULT_HEADER_FIELDS)
        .unwrap();
    assert_eq!(headers.len(), 1);
    let header = &headers[0];
    assert_eq!(header.uid, 7);
    assert_eq!(header.flags, ["\\Seen"]);
    assert_eq!(header.internal_date, Some(1_789_092_000));
    // Values stay RFC 2047-encoded; decoding is the provider's job.
    assert_eq!(
        header.raw_headers.get("subject").unwrap(),
        "=?GBK?B?u+HS6bzN0qo=?="
    );
    assert_eq!(
        header.raw_headers.get("message-id").unwrap(),
        "<m1@example.com>"
    );
    let command = &transport.command_lines()[0];
    assert!(command.starts_with("A0001 UID FETCH 7:* "), "{command}");
    // LIST-UNSUBSCRIBE-POST (RFC 8058) joined the set in R6: the one-click
    // fact has to be fetched to be recorded. An assertion on the exact field
    // list is what caught this, which is why it is written as an equality of
    // the whole parenthesised set rather than a `contains` per field.
    assert!(
        command.contains(
            "BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE MESSAGE-ID IN-REPLY-TO REFERENCES \
             LIST-UNSUBSCRIBE LIST-UNSUBSCRIBE-POST)]"
        ),
        "{command}"
    );
}

#[test]
fn fetch_newest_headers_uses_sequence_numbers_and_clamps_to_one() {
    let transport = ScriptedTransport::new();
    transport.enqueue_line("* OK ready");
    header_fetch_script(&transport, "A0001");
    let mut client = connected(&transport);

    let headers = client
        .fetch_newest_headers(500, 12, &DEFAULT_HEADER_FIELDS)
        .unwrap();
    assert_eq!(headers.len(), 1);
    assert!(transport.command_lines()[0].starts_with("A0001 FETCH 1:* "));

    transport.enqueue_line("* OK ready");
    assert!(client
        .fetch_newest_headers(10, 0, &DEFAULT_HEADER_FIELDS)
        .unwrap()
        .is_empty());
    assert_eq!(transport.command_lines().len(), 1);
}

#[test]
fn fetch_flags_parses_uid_flag_rows() {
    let transport = ScriptedTransport::new();
    transport.enqueue_line("* OK ready");
    transport.enqueue_line("* 1 FETCH (UID 41 FLAGS (\\Seen \\Flagged))");
    transport.enqueue_line("* 2 FETCH (UID 42 FLAGS ())");
    transport.enqueue_line("A0001 OK FETCH completed");
    let mut client = connected(&transport);

    let rows = client.fetch_flags(41, 42).unwrap();
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0].uid, 41);
    assert_eq!(rows[0].flags, ["\\Seen", "\\Flagged"]);
    assert!(rows[1].flags.is_empty());
    assert_eq!(
        transport.command_lines(),
        ["A0001 UID FETCH 41:42 (UID FLAGS)"]
    );
}

#[test]
fn search_by_message_id_returns_the_highest_uid_and_all_uids_are_a_set() {
    let transport = ScriptedTransport::new();
    transport.enqueue_line("* OK ready");
    transport.enqueue_line("* SEARCH 41 43 42");
    transport.enqueue_line("A0001 OK SEARCH completed");
    transport.enqueue_line("* SEARCH 7 9");
    transport.enqueue_line("A0002 OK SEARCH completed");
    let mut client = connected(&transport);

    assert_eq!(
        client.search_uid_by_message_id("<m1@example.com>").unwrap(),
        Some(43)
    );
    assert_eq!(
        transport.command_lines()[0],
        "A0001 UID SEARCH HEADER Message-ID \"<m1@example.com>\""
    );
    let uids = client.all_uids().unwrap();
    assert_eq!(uids.into_iter().collect::<Vec<_>>(), [7, 9]);
    assert_eq!(transport.command_lines()[1], "A0002 UID SEARCH ALL");
}

#[test]
fn store_uses_add_and_remove_flag_forms() {
    let transport = ScriptedTransport::new();
    transport.enqueue_line("* OK ready");
    transport.enqueue_line("A0001 OK STORE completed");
    transport.enqueue_line("A0002 OK STORE completed");
    let mut client = connected(&transport);

    client.store(42, &["\\Seen"], &["\\Deleted"]).unwrap();
    assert_eq!(
        transport.command_lines(),
        [
            "A0001 UID STORE 42 +FLAGS (\\Seen)",
            "A0002 UID STORE 42 -FLAGS (\\Deleted)"
        ]
    );
}

#[test]
fn move_requires_the_move_capability_and_sends_nothing_without_it() {
    let transport = ScriptedTransport::new();
    transport.enqueue_line("* OK ready");
    transport.enqueue_line("* CAPABILITY IMAP4rev1 UIDPLUS");
    transport.enqueue_line("A0001 OK CAPABILITY completed");
    let mut client = connected(&transport);

    let error = client.move_to(42, "Archive").unwrap_err();
    assert_eq!(error.kind(), MailErrorKind::MissingCapability);
    assert_eq!(error.code(), "move-missing");
    assert!(!transport.writes_text().contains("UID MOVE"));
}

#[test]
fn move_uses_uid_move_when_capability_is_present() {
    let transport = ScriptedTransport::new();
    transport.enqueue_line("* OK ready");
    transport.enqueue_line("* CAPABILITY IMAP4rev1 MOVE");
    transport.enqueue_line("A0001 OK CAPABILITY completed");
    transport.enqueue_line("A0002 OK MOVE completed");
    let mut client = connected(&transport);

    client.move_to(42, "QQ/Archive").unwrap();
    assert_eq!(
        transport.command_lines().last().unwrap(),
        "A0002 UID MOVE 42 \"QQ/Archive\""
    );
}

#[test]
fn uid_expunge_is_the_only_expunge_wire_form() {
    let transport = ScriptedTransport::new();
    transport.enqueue_line("* OK ready");
    transport.enqueue_line("A0001 OK EXPUNGE completed");
    transport.enqueue_line("A0002 OK EXPUNGE completed");
    let mut client = connected(&transport);

    client.uid_expunge(42).unwrap();
    client.uid_expunge_many(&[43, 44]).unwrap();
    assert_eq!(
        transport.command_lines(),
        ["A0001 UID EXPUNGE 42", "A0002 UID EXPUNGE 43,44"]
    );
    for line in transport.command_lines() {
        assert!(!line.ends_with(" EXPUNGE"), "plain EXPUNGE issued: {line}");
    }
}

#[test]
fn fetch_full_body_returns_the_literal_or_message_gone() {
    let transport = ScriptedTransport::new();
    transport.enqueue_line("* OK ready");
    transport.enqueue_line("* 1 FETCH (UID 42 BODY[] {5}");
    transport.enqueue_literal(b"hello");
    transport.enqueue_line(")");
    transport.enqueue_line("A0001 OK FETCH completed");
    transport.enqueue_line("A0002 OK FETCH completed");
    let mut client = connected(&transport);

    assert_eq!(client.fetch_full_body(42).unwrap(), b"hello");
    assert_eq!(
        client.fetch_full_body(43).unwrap_err().kind(),
        MailErrorKind::MessageGone
    );
}

#[test]
fn fetch_part_validates_the_part_path_before_building_a_command() {
    let transport = ScriptedTransport::new();
    transport.enqueue_line("* OK ready");
    let mut client = connected(&transport);
    for bad in ["", "1.2]", "1.2 BODY[]", "-1", "a.b"] {
        let error = client.fetch_part(42, bad).unwrap_err();
        assert_eq!(error.code(), "bad-part-path", "{bad}");
    }
    assert!(transport.writes().is_empty());
}

#[test]
fn fetch_part_returns_the_literal_for_one_mime_part() {
    let transport = ScriptedTransport::new();
    transport.enqueue_line("* OK ready");
    transport.enqueue_line("* 1 FETCH (UID 42 BODY[1.2] {5}");
    transport.enqueue_literal(b"hello");
    transport.enqueue_line(")");
    transport.enqueue_line("A0001 OK FETCH completed");
    let mut client = connected(&transport);

    assert_eq!(client.fetch_part(42, "1.2").unwrap(), b"hello");
    assert_eq!(
        transport.command_lines(),
        ["A0001 UID FETCH 42 (BODY.PEEK[1.2])"]
    );
}

#[test]
fn quoted_refuses_control_characters_and_escapes_quotes() {
    assert_eq!(
        ImapClient::quoted("INBOX\r\nA0002 DELETE INBOX"),
        Err(lagoon_mail::MailError::protocol("control-char-in-argument"))
    );
    assert_eq!(
        ImapClient::quoted("Sent \"Box\"").unwrap(),
        "\"Sent \\\"Box\\\"\""
    );
}
