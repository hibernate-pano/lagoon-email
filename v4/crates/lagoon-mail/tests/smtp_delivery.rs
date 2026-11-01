//! SMTP delivery tests. Each session is a scripted reply sequence; no socket,
//! no TLS, no credentials that are real.

mod support;

use base64::Engine as _;
use lagoon_mail::error::MailErrorKind;
use lagoon_mail::mime::builder::OutboundMessage;
use lagoon_mail::smtp::SmtpClient;
use support::ScriptedTransport;

fn outbound() -> OutboundMessage {
    OutboundMessage {
        from_email: "me@example.com".to_owned(),
        from_name: Some("Me".to_owned()),
        to: "alice@example.com".to_owned(),
        cc: Vec::new(),
        bcc: Vec::new(),
        subject: "Hello".to_owned(),
        body: "Plain text body".to_owned(),
        in_reply_to: None,
        references: None,
        is_reply: true,
        attachments: Vec::new(),
    }
}

fn client(transport: &ScriptedTransport) -> SmtpClient {
    SmtpClient::new(Box::new(transport.handle()))
}

fn session_ok(transport: &ScriptedTransport) {
    transport.enqueue_lines(&[
        "220 smtp.example.test ESMTP",
        "250-smtp.example.test",
        "250-AUTH PLAIN",
        "250 OK",
        "235 2.7.0 accepted",
        "250 2.1.0 sender ok",
        "250 2.1.5 recipient ok",
        "354 go ahead",
        "250 2.0.0 queued",
        "221 2.0.0 bye",
    ]);
}

#[test]
fn happy_path_sends_the_expected_command_sequence() {
    let transport = ScriptedTransport::new();
    session_ok(&transport);
    let mut smtp = client(&transport);

    let message_id = smtp
        .send(
            &outbound(),
            "smtp.example.test",
            465,
            "user@example.com",
            "auth-code",
        )
        .unwrap();
    assert!(message_id.starts_with('<'), "{message_id}");
    assert!(message_id.ends_with("@lagoon>"), "{message_id}");

    let writes = transport.writes();
    assert_eq!(String::from_utf8_lossy(&writes[0]), "EHLO lagoon.local\r\n");
    let auth = String::from_utf8_lossy(&writes[1]).to_string();
    let payload = auth
        .trim_end()
        .strip_prefix("AUTH PLAIN ")
        .expect("AUTH PLAIN");
    assert_eq!(
        base64::engine::general_purpose::STANDARD
            .decode(payload)
            .unwrap(),
        b"\0user@example.com\0auth-code"
    );
    assert_eq!(
        String::from_utf8_lossy(&writes[2]),
        "MAIL FROM:<me@example.com>\r\n"
    );
    assert_eq!(
        String::from_utf8_lossy(&writes[3]),
        "RCPT TO:<alice@example.com>\r\n"
    );
    assert_eq!(String::from_utf8_lossy(&writes[4]), "DATA\r\n");
    let data = String::from_utf8_lossy(&writes[5]).to_string();
    assert!(data.contains("Subject: Re: Hello\r\n"), "{data}");
    assert!(data.ends_with("\r\n.\r\n"), "{data}");
    assert_eq!(transport.connect_count(), 1);
    assert!(transport.close_count() >= 1);
}

#[test]
fn new_message_keeps_subject_and_omits_thread_headers() {
    let transport = ScriptedTransport::new();
    session_ok(&transport);
    let mut message = outbound();
    message.is_reply = false;
    message.in_reply_to = Some("<ignored@example.com>".to_owned());
    message.references = Some("<ignored@example.com>".to_owned());
    let mut smtp = client(&transport);

    smtp.send(
        &message,
        "smtp.example.test",
        465,
        "user@example.com",
        "code",
    )
    .unwrap();
    let data = String::from_utf8_lossy(&transport.writes()[5]).to_string();
    assert!(data.contains("Subject: Hello\r\n"), "{data}");
    assert!(!data.contains("Subject: Re:"), "{data}");
    assert!(!data.contains("In-Reply-To:"), "{data}");
    assert!(!data.contains("References:"), "{data}");
}

#[test]
fn reply_carries_thread_headers() {
    let transport = ScriptedTransport::new();
    session_ok(&transport);
    let mut message = outbound();
    message.in_reply_to = Some("<a@example.com>".to_owned());
    message.references = Some("<root@example.com> <a@example.com>".to_owned());
    let mut smtp = client(&transport);

    smtp.send(
        &message,
        "smtp.example.test",
        465,
        "user@example.com",
        "code",
    )
    .unwrap();
    let data = String::from_utf8_lossy(&transport.writes()[5]).to_string();
    assert!(data.contains("In-Reply-To: <a@example.com>\r\n"), "{data}");
    assert!(
        data.contains("References: <root@example.com> <a@example.com>\r\n"),
        "{data}"
    );
}

#[test]
fn one_rcpt_per_envelope_recipient_including_cc_and_bcc() {
    let transport = ScriptedTransport::new();
    transport.enqueue_lines(&[
        "220 ready",
        "250 OK",
        "235 accepted",
        "250 sender ok",
        "250 to1",
        "250 to2",
        "250 cc1",
        "250 bcc1",
        "354 go",
        "250 queued",
        "221 bye",
    ]);
    let mut message = outbound();
    message.to = "alice@example.com, bob@example.com".to_owned();
    message.cc = vec!["carol@example.com".to_owned()];
    message.bcc = vec!["dave@example.com".to_owned()];
    let mut smtp = client(&transport);

    smtp.send(
        &message,
        "smtp.example.test",
        465,
        "user@example.com",
        "code",
    )
    .unwrap();
    let rcpts: Vec<String> = transport
        .command_lines()
        .into_iter()
        .filter(|line| line.contains("RCPT TO:"))
        .collect();
    assert_eq!(
        rcpts,
        [
            "RCPT TO:<alice@example.com>",
            "RCPT TO:<bob@example.com>",
            "RCPT TO:<carol@example.com>",
            "RCPT TO:<dave@example.com>"
        ]
    );
    let data = String::from_utf8_lossy(&transport.writes()[8]).to_string();
    assert!(!data.to_ascii_lowercase().contains("bcc:"), "{data}");
}

#[test]
fn rejected_auth_is_terminal_and_does_not_name_the_mailbox() {
    let transport = ScriptedTransport::new();
    transport.enqueue_lines(&[
        "220 ready",
        "250 OK",
        "535 5.7.8 <user@example.com> bad auth code",
    ]);
    let mut smtp = client(&transport);
    let error = smtp
        .send(
            &outbound(),
            "smtp.example.test",
            465,
            "user@example.com",
            "code",
        )
        .unwrap_err();
    assert_eq!(error.kind(), MailErrorKind::AuthFailed);
    let rendered = format!("{error}");
    assert!(!rendered.contains("user@example.com"), "{rendered}");
    assert!(!rendered.contains("bad auth"), "{rendered}");
    assert_eq!(transport.connect_count(), 1);
    assert!(!transport.writes_text().contains("MAIL FROM"));
}

#[test]
fn a_4xx_auth_reply_is_retried_once() {
    let transport = ScriptedTransport::new();
    transport.enqueue_lines(&["220 ready", "250 OK", "454 4.7.0 try later"]);
    session_ok(&transport);
    let mut smtp = client(&transport);
    smtp.send(
        &outbound(),
        "smtp.example.test",
        465,
        "user@example.com",
        "code",
    )
    .unwrap();
    assert_eq!(transport.connect_count(), 2);
}

#[test]
fn a_4xx_before_data_is_retried_once() {
    let transport = ScriptedTransport::new();
    transport.enqueue_lines(&["220 ready", "421 4.3.2 service unavailable"]);
    session_ok(&transport);
    let mut smtp = client(&transport);
    smtp.send(
        &outbound(),
        "smtp.example.test",
        465,
        "user@example.com",
        "code",
    )
    .unwrap();
    assert_eq!(transport.connect_count(), 2);
}

#[test]
fn a_5xx_after_data_is_terminal_and_never_retried() {
    let transport = ScriptedTransport::new();
    transport.enqueue_lines(&[
        "220 ready",
        "250 OK",
        "235 accepted",
        "250 sender ok",
        "250 rcpt ok",
        "354 go",
        "554 5.0.0 rejected after payload",
    ]);
    let mut smtp = client(&transport);
    let error = smtp
        .send(
            &outbound(),
            "smtp.example.test",
            465,
            "user@example.com",
            "code",
        )
        .unwrap_err();
    assert_eq!(error.kind(), MailErrorKind::Protocol);
    assert_eq!(error.status(), Some(554));
    assert_eq!(transport.connect_count(), 1);
    // Exactly one payload reached the wire: a retry would duplicate the mail.
    let payload_writes = transport
        .writes()
        .iter()
        .filter(|chunk| String::from_utf8_lossy(chunk).contains("Subject:"))
        .count();
    assert_eq!(payload_writes, 1);
}

#[test]
fn a_rejected_recipient_does_not_stop_delivery_to_the_others() {
    let transport = ScriptedTransport::new();
    transport.enqueue_lines(&[
        "220 ready",
        "250 OK",
        "235 accepted",
        "250 sender ok",
        "550 5.1.1 <missing@example.com> no such user",
        "250 rcpt ok",
        "354 go",
        "250 queued",
        "221 bye",
    ]);
    let mut message = outbound();
    message.to = "missing@example.com, bob@example.com".to_owned();
    let mut smtp = client(&transport);
    smtp.send(
        &message,
        "smtp.example.test",
        465,
        "user@example.com",
        "code",
    )
    .unwrap();
    assert!(transport
        .writes_text()
        .contains("RCPT TO:<bob@example.com>"));
}

#[test]
fn rebuffed_every_recipient_is_a_failure_and_data_is_not_sent() {
    let transport = ScriptedTransport::new();
    transport.enqueue_lines(&[
        "220 ready",
        "250 OK",
        "235 accepted",
        "250 sender ok",
        "550 5.1.1 no such user",
        "551 5.1.1 no such user either",
    ]);
    let mut message = outbound();
    message.to = "missing@example.com, also-missing@example.com".to_owned();
    let mut smtp = client(&transport);
    let error = smtp
        .send(
            &message,
            "smtp.example.test",
            465,
            "user@example.com",
            "code",
        )
        .unwrap_err();
    assert_eq!(error.kind(), MailErrorKind::Protocol);
    assert_eq!(error.status(), Some(551));
    assert!(!transport.writes_text().contains("DATA"));
}

#[test]
fn a_4xx_recipient_reply_aborts_the_session_and_retries() {
    let transport = ScriptedTransport::new();
    transport.enqueue_lines(&[
        "220 ready",
        "250 OK",
        "235 accepted",
        "250 sender ok",
        "451 4.2.0 come back later",
    ]);
    session_ok(&transport);
    let mut smtp = client(&transport);
    smtp.send(
        &outbound(),
        "smtp.example.test",
        465,
        "user@example.com",
        "code",
    )
    .unwrap();
    assert_eq!(transport.connect_count(), 2);
}

#[test]
fn no_envelope_recipient_is_a_refused_delivery_not_a_silent_noop() {
    let transport = ScriptedTransport::new();
    transport.enqueue_lines(&["220 ready", "250 OK", "235 accepted", "250 sender ok"]);
    let mut message = outbound();
    message.to = String::new();
    let mut smtp = client(&transport);
    let error = smtp
        .send(
            &message,
            "smtp.example.test",
            465,
            "user@example.com",
            "code",
        )
        .unwrap_err();
    assert_eq!(error.code(), "smtp-no-recipient");
    assert!(!transport.writes_text().contains("RCPT"));
    assert!(!transport.writes_text().contains("DATA"));
}

#[test]
fn crlf_in_a_recipient_is_refused_before_rcpt_is_written() {
    let transport = ScriptedTransport::new();
    transport.enqueue_lines(&["220 ready", "250 OK", "235 accepted", "250 sender ok"]);
    let mut message = outbound();
    // No space after the colon, so this survives address-list parsing and
    // reaches the envelope validator (the previous form was dropped before
    // that, producing "no recipient").
    message.to = "alice@example.com\rBcc:victim@evil.example".to_owned();
    let mut smtp = client(&transport);
    let error = smtp
        .send(
            &message,
            "smtp.example.test",
            465,
            "user@example.com",
            "code",
        )
        .unwrap_err();
    assert_eq!(error.code(), "smtp-invalid-address");
    assert!(!transport.writes_text().contains("RCPT"));
    assert!(!transport.writes_text().contains("victim@evil.example"));
}

#[test]
fn dot_stuffing_applies_to_raw_payloads() {
    let transport = ScriptedTransport::new();
    transport.enqueue_lines(&[
        "220 ready",
        "250 OK",
        "235 accepted",
        "250 sender ok",
        "250 rcpt ok",
        "354 go",
        "250 queued",
        "221 bye",
    ]);
    let raw = b"Subject: x\r\n\r\n.line1\r\n..line2\r\n";
    let mut smtp = client(&transport);
    smtp.send_raw(
        raw,
        &outbound(),
        "smtp.example.test",
        465,
        "user@example.com",
        "code",
    )
    .unwrap();
    let payload = transport
        .writes()
        .into_iter()
        .find(|chunk| String::from_utf8_lossy(chunk).contains("Subject: x"))
        .unwrap();
    assert_eq!(
        payload,
        b"Subject: x\r\n\r\n..line1\r\n...line2\r\n.\r\n".to_vec()
    );
}

#[test]
fn a_server_that_hangs_up_after_accepting_the_data_does_not_fail_the_send() {
    let transport = ScriptedTransport::new();
    transport.enqueue_lines(&[
        "220 ready",
        "250 OK",
        "235 accepted",
        "250 sender ok",
        "250 rcpt ok",
        "354 go",
        "250 queued",
        // No 221: the fake hangs up, exactly like the v3 incident.
    ]);
    let mut smtp = client(&transport);
    smtp.send(
        &outbound(),
        "smtp.example.test",
        465,
        "user@example.com",
        "code",
    )
    .unwrap();
}

#[test]
fn server_prose_never_reaches_the_error() {
    let transport = ScriptedTransport::new();
    transport.enqueue_lines(&[
        "220 ready",
        "250 OK",
        "235 accepted",
        "250 sender ok",
        "250 rcpt ok",
        "354 go",
        "550 5.1.1 <unknown@example.com> user unknown; contact postmaster@example.com",
    ]);
    let mut smtp = client(&transport);
    let error = smtp
        .send(
            &outbound(),
            "smtp.example.test",
            465,
            "user@example.com",
            "code",
        )
        .unwrap_err();
    let rendered = format!("{error}");
    // Not a single byte of the server's explanation may ride along: no
    // address, no prose. Only the stable code and the numeric status.
    assert!(!rendered.contains('@'), "{rendered}");
    assert!(!rendered.contains("user unknown"), "{rendered}");
    assert!(!rendered.contains("postmaster"), "{rendered}");
    assert_eq!(error.status(), Some(550));
}
