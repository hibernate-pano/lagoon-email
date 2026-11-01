//! Framing tests for `ImapConnection`: tags, literals, tagged verdicts,
//! continuation handling, APPEND and IDLE. All wire bytes are scripted; there
//! is no socket anywhere in this file.

mod support;

use lagoon_mail::error::MailErrorKind;
use lagoon_mail::imap::connection::ImapConnection;
use lagoon_mail::imap::parser::{ImapStatus, ResponseKind};
use lagoon_mail::transport::Transport;
use support::ScriptedTransport;

fn connect(transport: &ScriptedTransport) -> ImapConnection {
    let mut connection = ImapConnection::new(Box::new(transport.handle()));
    connection
        .connect("imap.example.test", 993)
        .expect("greeting accepted");
    connection
}

#[test]
fn connect_consumes_the_greeting_and_sends_nothing() {
    let transport = ScriptedTransport::new();
    transport.enqueue_line("* OK ready");
    let mut connection = ImapConnection::new(Box::new(transport.handle()));
    connection.connect("imap.example.test", 993).unwrap();
    assert!(connection.is_connected());
    assert!(transport.writes().is_empty());
    assert_eq!(
        transport.connects(),
        [("imap.example.test".to_owned(), 993)]
    );
}

#[test]
fn unexpected_greeting_is_a_protocol_error() {
    let transport = ScriptedTransport::new();
    transport.enqueue_line("* BYE go away");
    let mut connection = ImapConnection::new(Box::new(transport.handle()));
    let error = connection.connect("imap.example.test", 993).unwrap_err();
    assert_eq!(error.code(), "unexpected-greeting");
    assert_eq!(error.kind(), MailErrorKind::Protocol);
    assert!(!connection.is_connected());
}

#[test]
fn execute_mints_a_tag_and_collects_untagged_responses() {
    let transport = ScriptedTransport::new();
    transport.enqueue_line("* OK ready");
    transport.enqueue_line("* CAPABILITY IMAP4rev1 UIDPLUS MOVE");
    transport.enqueue_line("A0001 OK CAPABILITY completed");
    let mut connection = connect(&transport);

    let responses = connection.execute("CAPABILITY").unwrap();
    assert_eq!(transport.writes_text(), "A0001 CAPABILITY\r\n");
    assert_eq!(responses.len(), 2);
    assert_eq!(
        responses[0].atoms,
        ["*", "CAPABILITY", "IMAP4rev1", "UIDPLUS", "MOVE"]
    );
    assert_eq!(
        responses[1].kind,
        ResponseKind::Tagged {
            tag: "A0001".into(),
            status: ImapStatus::Ok
        }
    );
}

#[test]
fn literal_framing_merges_the_literal_and_its_tail_into_one_response() {
    let transport = ScriptedTransport::new();
    transport.enqueue_line("* OK ready");
    transport.enqueue_line("* 1 FETCH (UID 7 BODY[TEXT] {5}");
    transport.enqueue_literal(b"hello");
    transport.enqueue_line(")");
    transport.enqueue_line("A0001 OK FETCH completed");
    let mut connection = connect(&transport);

    let responses = connection.execute("UID FETCH 7 (BODY.PEEK[TEXT])").unwrap();
    assert_eq!(responses.len(), 2);
    assert_eq!(responses[0].literal.as_deref(), Some(b"hello".as_slice()));
    assert!(
        responses[0].raw.ends_with("})"),
        "raw was {:?}",
        responses[0].raw
    );
}

#[test]
fn oversized_literal_is_refused_before_allocating_the_body() {
    let transport = ScriptedTransport::new();
    transport.enqueue_line("* OK ready");
    transport.enqueue_line("* 1 FETCH (BODY[] {41943041}");
    transport.enqueue_line("* 1 FETCH (BODY[] {41943041}");
    let mut connection = connect(&transport);
    let error = connection.execute("UID FETCH 1 (BODY.PEEK[])").unwrap_err();
    assert_eq!(error.code(), "literal-too-large");
    assert_eq!(error.kind(), MailErrorKind::TooLarge);
}

#[test]
fn authentication_failed_tagged_no_is_typed_auth_failed() {
    let transport = ScriptedTransport::new();
    transport.enqueue_line("* OK ready");
    transport.enqueue_line("A0001 NO [AUTHENTICATIONFAILED] credentials rejected");
    let mut connection = connect(&transport);
    let error = connection.execute("LOGIN \"u\" \"p\"").unwrap_err();
    assert_eq!(error.kind(), MailErrorKind::AuthFailed);
}

#[test]
fn plain_tagged_no_is_a_protocol_error_and_bad_is_too() {
    let transport = ScriptedTransport::new();
    transport.enqueue_line("* OK ready");
    transport.enqueue_line("A0001 NO no such mailbox");
    transport.enqueue_line("A0002 BAD bad command");
    let mut connection = connect(&transport);
    assert_eq!(
        connection.execute("SELECT \"nope\"").unwrap_err().code(),
        "tagged-NO"
    );
    assert_eq!(connection.execute("WAT").unwrap_err().code(), "tagged-BAD");
}

#[test]
fn unknown_tags_are_kept_but_do_not_complete_the_command() {
    let transport = ScriptedTransport::new();
    transport.enqueue_line("* OK ready");
    transport.enqueue_line("* 2 EXISTS");
    transport.enqueue_line("A9999 OK unrelated");
    transport.enqueue_line("A0001 OK done");
    let mut connection = connect(&transport);
    let responses = connection.execute("NOOP").unwrap();
    assert_eq!(responses.len(), 3);
    assert_eq!(
        responses.last().unwrap().kind,
        ResponseKind::Tagged {
            tag: "A0001".into(),
            status: ImapStatus::Ok
        }
    );
}

#[test]
fn continuation_gets_a_bare_crlf_so_the_server_does_not_stall() {
    let transport = ScriptedTransport::new();
    transport.enqueue_line("* OK ready");
    transport.enqueue_line("+ continue");
    transport.enqueue_line("A0001 OK done");
    let mut connection = connect(&transport);
    connection.execute("NOOP").unwrap();
    assert_eq!(
        transport.writes(),
        vec![b"A0001 NOOP\r\n".to_vec(), b"\r\n".to_vec()]
    );
}

#[test]
fn idle_returns_after_one_mailbox_event_and_sends_done() {
    let transport = ScriptedTransport::new();
    transport.enqueue_line("* OK ready");
    transport.enqueue_line("+ idling");
    transport.enqueue_line("* 2 EXISTS");
    transport.enqueue_line("A0001 OK IDLE completed");
    let mut connection = connect(&transport);

    let events = connection.idle(std::time::Duration::from_secs(5)).unwrap();
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].atoms, ["*", "2", "EXISTS"]);
    assert_eq!(transport.command_lines(), ["A0001 IDLE", "DONE"]);
}

#[test]
fn idle_timeout_is_the_normal_exit_and_still_sends_done() {
    let transport = ScriptedTransport::new();
    transport.enqueue_line("* OK ready");
    transport.enqueue_line("+ idling");
    transport.enqueue_timeout();
    transport.enqueue_line("A0001 OK IDLE completed");
    let mut connection = connect(&transport);

    let events = connection
        .idle(std::time::Duration::from_millis(50))
        .unwrap();
    assert!(events.is_empty());
    assert_eq!(transport.command_lines(), ["A0001 IDLE", "DONE"]);
}

#[test]
fn idle_refused_by_a_tagged_completion_is_a_protocol_error() {
    let transport = ScriptedTransport::new();
    transport.enqueue_line("* OK ready");
    transport.enqueue_line("A0001 NO IDLE not supported");
    let mut connection = connect(&transport);
    let error = connection
        .idle(std::time::Duration::from_millis(50))
        .unwrap_err();
    assert_eq!(error.code(), "idle-refused");
}

#[test]
fn append_waits_for_the_continuation_then_writes_the_exact_literal() {
    let transport = ScriptedTransport::new();
    transport.enqueue_line("* OK ready");
    transport.enqueue_line("+ ready for literal");
    transport.enqueue_line("A0001 OK APPEND completed");
    let mut connection = connect(&transport);

    connection.append("\"Sent\"", b"hello").unwrap();
    let writes = transport.writes();
    assert_eq!(
        writes[0],
        b"A0001 APPEND \"Sent\" (\\Seen) {5}\r\n".to_vec()
    );
    assert_eq!(writes[1], b"hello".to_vec());
    assert_eq!(writes[2], b"\r\n".to_vec());
}

#[test]
fn a_dead_socket_maps_to_unreachable_not_protocol() {
    let transport = ScriptedTransport::new();
    transport.enqueue_line("* OK ready");
    let mut connection = connect(&transport);
    transport.fail_next_read(support::FailureKind::Io);
    let error = connection.execute("NOOP").unwrap_err();
    assert_eq!(error.kind(), MailErrorKind::Unreachable);
}

#[test]
fn transport_update_path_is_exercised_by_the_fake() {
    // Guards the fake itself: reads must honour the timeout setter and the
    // literal reader must return exact bytes.
    let mut transport = ScriptedTransport::new();
    transport.enqueue_literal(b"abc");
    transport
        .set_read_timeout(std::time::Duration::from_millis(1))
        .unwrap();
    assert_eq!(transport.read_exact(3).unwrap(), b"abc");
    assert_eq!(
        transport.read_exact(3),
        Err(lagoon_mail::error::TransportError::Closed)
    );
}
