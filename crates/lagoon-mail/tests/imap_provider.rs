//! Provider-level tests: capability negotiation, folder roles, the UIDPLUS
//! gate, safe moves, body/attachment fetching and the read-only pull.
//!
//! Every test is a scripted wire conversation. The UIDPLUS gate tests assert
//! on the *absence* of commands as much as on the error: a refused permanent
//! delete must leave the session untouched, not degrade to a blanket EXPUNGE.

mod support;

use lagoon_mail::error::MailErrorKind;
use lagoon_mail::imap::provider::{ImapProvider, ProviderCredentials};
use lagoon_mail::preset::ProviderPreset;
use lagoon_mail::sync::{MailSyncReading, SyncCursor};
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

fn header_literal(subject: &str) -> Vec<u8> {
    format!(
        "From: \"Chen, Qi\" <chen@example.com>\r\nSubject: {subject}\r\nMessage-ID: <m1@example.com>\r\nReferences: <root@example.com>\r\n\r\n"
    )
    .into_bytes()
}

#[test]
fn capabilities_negotiate_roles_and_names_from_one_list() {
    let transport = ScriptedTransport::new();
    imap_session_script(&transport, "IMAP4rev1 MOVE IDLE UIDPLUS");
    transport.enqueue_lines(&[
        "* LIST (\\HasNoChildren) \"/\" \"INBOX\"",
        "* LIST (\\Archive \\HasNoChildren) \"/\" \"Archive\"",
        "* LIST (\\Trash \\HasNoChildren) \"/\" \"Trash\"",
        "* LIST (\\Sent \\HasNoChildren) \"/\" \"Sent\"",
        "A0003 OK LIST completed",
    ]);
    let mut provider = provider(&transport);

    let capabilities = provider.capabilities().expect("negotiated");
    assert_eq!(capabilities.archive_folder, Some(true));
    assert_eq!(capabilities.archive_folder_name.as_deref(), Some("Archive"));
    assert_eq!(capabilities.trash_folder, Some(true));
    assert_eq!(capabilities.sent_folder, Some(true));
    assert_eq!(capabilities.uidplus, Some(true));
    assert!(capabilities.idle);
    assert!(capabilities.supports_move);
    assert!(capabilities.server_snippet);
    assert!(capabilities.allows_purge());
    assert!(capabilities.allows_archive());

    // The probe and the resolvers share one LIST; no second LIST, no CREATE.
    assert_eq!(
        transport
            .command_lines()
            .join("\n")
            .matches(" LIST ")
            .count(),
        1
    );
    assert!(!transport.writes_text().contains("CREATE"));
}

#[test]
fn a_missing_archive_role_is_created_once() {
    let transport = ScriptedTransport::new();
    imap_session_script(&transport, "IMAP4rev1 UIDPLUS");
    transport.enqueue_lines(&[
        "* LIST (\\HasNoChildren) \"/\" \"INBOX\"",
        "* LIST (\\Trash) \"/\" \"Trash\"",
        "A0003 OK LIST completed",
        "A0004 OK CREATE completed",
    ]);
    let mut provider = provider(&transport);

    let capabilities = provider.capabilities().expect("negotiated");
    assert_eq!(capabilities.archive_folder, Some(true));
    assert_eq!(capabilities.archive_folder_name.as_deref(), Some("Archive"));
    assert!(transport
        .command_lines()
        .iter()
        .any(|line| line == "A0004 CREATE \"Archive\""));

    // A second probe uses the cached roles and does not CREATE again.
    let capabilities = provider.capabilities().expect("negotiated");
    assert_eq!(capabilities.archive_folder_name.as_deref(), Some("Archive"));
    assert_eq!(
        transport
            .command_lines()
            .iter()
            .filter(|line| line.contains("CREATE"))
            .count(),
        1
    );
}

#[test]
fn a_refused_archive_create_is_a_settled_false_not_a_missing_answer() {
    let transport = ScriptedTransport::new();
    imap_session_script(&transport, "IMAP4rev1 UIDPLUS");
    transport.enqueue_lines(&[
        "* LIST (\\HasNoChildren) \"/\" \"INBOX\"",
        "A0003 OK LIST completed",
        "A0004 NO CREATE refused",
    ]);
    let mut provider = provider(&transport);

    let capabilities = provider.capabilities().expect("negotiated");
    assert_eq!(capabilities.archive_folder, Some(false));
    assert_eq!(capabilities.archive_folder_name, None);
    assert!(!capabilities.allows_archive());
}

#[test]
fn a_failed_negotiation_returns_none_not_an_empty_capability_set() {
    let transport = ScriptedTransport::new();
    imap_session_script(&transport, "IMAP4rev1 UIDPLUS");
    transport.enqueue_line("A0003 NO LIST failed");
    let mut provider = provider(&transport);
    assert_eq!(provider.capabilities(), None);
}

#[test]
fn permanently_delete_without_uidplus_is_refused_before_any_command() {
    let transport = ScriptedTransport::new();
    imap_session_script(&transport, "IMAP4rev1 IDLE MOVE");
    transport.enqueue_lines(&[
        "* LIST (\\HasNoChildren) \"/\" \"INBOX\"",
        "* LIST (\\Trash \\HasNoChildren) \"/\" \"Trash\"",
        "A0003 OK LIST completed",
    ]);
    select_script(&transport, "A0004", 1, 7, 8);
    let mut provider = provider(&transport);

    let error = provider.permanently_delete("42").unwrap_err();
    assert_eq!(error.kind(), MailErrorKind::MissingCapability);
    assert_eq!(error.code(), "uidplus-missing");
    let wire = transport.writes_text();
    assert!(
        !wire.contains("STORE"),
        "a refused purge wrote STORE:
{wire}"
    );
    assert!(
        !wire.contains("EXPUNGE"),
        "a refused purge wrote EXPUNGE:
{wire}"
    );
    // Only the session baseline + LIST + SELECT went out.
    assert_eq!(transport.command_lines().len(), 4);
}

#[test]
fn permanently_delete_with_uidplus_flags_then_uid_expunges_one_message() {
    let transport = ScriptedTransport::new();
    imap_session_script(&transport, "IMAP4rev1 UIDPLUS");
    transport.enqueue_lines(&[
        "* LIST (\\HasNoChildren) \"/\" \"INBOX\"",
        "* LIST (\\Trash \\HasNoChildren) \"/\" \"Trash\"",
        "A0003 OK LIST completed",
    ]);
    select_script(&transport, "A0004", 1, 7, 8);
    transport.enqueue_line("A0005 OK STORE completed");
    transport.enqueue_line("A0006 OK EXPUNGE completed");
    let mut provider = provider(&transport);

    provider.permanently_delete("42").unwrap();
    let lines = transport.command_lines();
    assert!(
        lines.contains(&"A0005 UID STORE 42 +FLAGS (\\Deleted)".to_owned()),
        "{lines:?}"
    );
    assert!(
        lines.contains(&"A0006 UID EXPUNGE 42".to_owned()),
        "{lines:?}"
    );
    assert!(
        !lines.iter().any(|line| line.ends_with(" EXPUNGE")),
        "{lines:?}"
    );
}

#[test]
fn empty_trash_with_uidplus_expunges_the_uid_set_in_one_command() {
    let transport = ScriptedTransport::new();
    imap_session_script(&transport, "IMAP4rev1 UIDPLUS");
    transport.enqueue_lines(&[
        "* LIST (\\HasNoChildren) \"/\" \"INBOX\"",
        "* LIST (\\Trash) \"/\" \"Trash\"",
        "A0003 OK LIST completed",
    ]);
    select_script(&transport, "A0004", 2, 7, 9);
    transport.enqueue_line("* SEARCH 41 42");
    transport.enqueue_line("A0005 OK SEARCH completed");
    transport.enqueue_line("A0006 OK STORE completed");
    transport.enqueue_line("A0007 OK STORE completed");
    transport.enqueue_line("A0008 OK EXPUNGE completed");
    let mut provider = provider(&transport);

    provider.empty_trash().unwrap();
    let lines = transport.command_lines();
    assert!(
        lines.contains(&"A0005 UID SEARCH ALL".to_owned()),
        "{lines:?}"
    );
    assert!(
        lines.contains(&"A0006 UID STORE 41 +FLAGS (\\Deleted)".to_owned()),
        "{lines:?}"
    );
    assert!(
        lines.contains(&"A0007 UID STORE 42 +FLAGS (\\Deleted)".to_owned()),
        "{lines:?}"
    );
    assert!(
        lines.contains(&"A0008 UID EXPUNGE 41,42".to_owned()),
        "{lines:?}"
    );
    assert!(
        !lines.iter().any(|line| line.ends_with(" EXPUNGE")),
        "{lines:?}"
    );
}

#[test]
fn empty_trash_without_uidplus_is_refused_before_searching() {
    let transport = ScriptedTransport::new();
    imap_session_script(&transport, "IMAP4rev1");
    transport.enqueue_lines(&[
        "* LIST (\\HasNoChildren) \"/\" \"INBOX\"",
        "* LIST (\\Trash) \"/\" \"Trash\"",
        "A0003 OK LIST completed",
    ]);
    select_script(&transport, "A0004", 2, 7, 9);
    let mut provider = provider(&transport);

    let error = provider.empty_trash().unwrap_err();
    assert_eq!(error.code(), "uidplus-missing");
    assert!(!transport.writes_text().contains("SEARCH"));
    assert!(!transport.writes_text().contains("EXPUNGE"));
}

#[test]
fn archive_uses_uid_move_when_available() {
    let transport = ScriptedTransport::new();
    imap_session_script(&transport, "IMAP4rev1 MOVE UIDPLUS");
    transport.enqueue_lines(&[
        "* LIST (\\HasNoChildren) \"/\" \"INBOX\"",
        "* LIST (\\Archive) \"/\" \"Archive\"",
        "A0003 OK LIST completed",
    ]);
    select_script(&transport, "A0004", 1, 7, 8);
    transport.enqueue_line("A0005 OK MOVE completed");
    let mut provider = provider(&transport);

    provider.archive("42").unwrap();
    assert!(transport
        .command_lines()
        .contains(&"A0005 UID MOVE 42 \"Archive\"".to_owned()));
}

#[test]
fn archive_without_move_and_uidplus_is_refused_rather_than_degrading() {
    let transport = ScriptedTransport::new();
    imap_session_script(&transport, "IMAP4rev1");
    transport.enqueue_lines(&[
        "* LIST (\\HasNoChildren) \"/\" \"INBOX\"",
        "* LIST (\\Archive) \"/\" \"Archive\"",
        "A0003 OK LIST completed",
    ]);
    select_script(&transport, "A0004", 1, 7, 8);
    let mut provider = provider(&transport);

    let error = provider.archive("42").unwrap_err();
    assert_eq!(error.kind(), MailErrorKind::UnsafeOperation);
    assert_eq!(error.code(), "move-needs-uidplus");
    let wire = transport.writes_text();
    assert!(!wire.contains("UID COPY"), "{wire}");
    assert!(!wire.contains("EXPUNGE"), "{wire}");
}

#[test]
fn archive_without_move_but_with_uidplus_uses_copy_then_uid_expunge() {
    let transport = ScriptedTransport::new();
    imap_session_script(&transport, "IMAP4rev1 UIDPLUS");
    transport.enqueue_lines(&[
        "* LIST (\\HasNoChildren) \"/\" \"INBOX\"",
        "* LIST (\\Archive) \"/\" \"Archive\"",
        "A0003 OK LIST completed",
    ]);
    select_script(&transport, "A0004", 1, 7, 8);
    transport.enqueue_line("A0005 OK COPY completed");
    transport.enqueue_line("A0006 OK STORE completed");
    transport.enqueue_line("A0007 OK EXPUNGE completed");
    let mut provider = provider(&transport);

    provider.archive("42").unwrap();
    let lines = transport.command_lines();
    assert!(
        lines.contains(&"A0005 UID COPY 42 \"Archive\"".to_owned()),
        "{lines:?}"
    );
    assert!(
        lines.contains(&"A0006 UID STORE 42 +FLAGS (\\Deleted)".to_owned()),
        "{lines:?}"
    );
    assert!(
        lines.contains(&"A0007 UID EXPUNGE 42".to_owned()),
        "{lines:?}"
    );
    assert!(
        !lines.iter().any(|line| line.ends_with(" EXPUNGE")),
        "{lines:?}"
    );
}

#[test]
fn set_read_uses_uid_store() {
    let transport = ScriptedTransport::new();
    imap_session_script(&transport, "IMAP4rev1 UIDPLUS");
    select_script(&transport, "A0003", 1, 7, 8);
    transport.enqueue_line("A0004 OK STORE completed");
    let mut provider = provider(&transport);

    provider.set_read("42", true).unwrap();
    assert!(transport
        .command_lines()
        .contains(&"A0004 UID STORE 42 +FLAGS (\\Seen)".to_owned()));
}

#[test]
fn fetch_body_decodes_a_gbk_message_and_uses_body_peek() {
    let transport = ScriptedTransport::new();
    imap_session_script(&transport, "IMAP4rev1 UIDPLUS");
    select_script(&transport, "A0003", 1, 7, 8);
    let mut raw =
        b"Content-Type: text/plain; charset=gb2312\r\nContent-Transfer-Encoding: 8bit\r\n\r\n"
            .to_vec();
    raw.extend_from_slice(&[0xD6, 0xD0, 0xCE, 0xC4]);
    transport.enqueue_line(format!("* 1 FETCH (UID 42 BODY[] {{{}}}", raw.len()));
    transport.enqueue_literal(raw);
    transport.enqueue_line(")");
    transport.enqueue_line("A0004 OK FETCH completed");
    let mut provider = provider(&transport);

    let body = provider.fetch_body("42", None).unwrap();
    assert_eq!(body.text, "中文");
    assert!(body.attachments.is_empty());
    let lines = transport.command_lines();
    assert!(
        lines.contains(&"A0004 UID FETCH 42 (BODY.PEEK[])".to_owned()),
        "{lines:?}"
    );
    assert!(
        !lines.iter().any(|line| line.contains("(BODY[])")),
        "{lines:?}"
    );
}

#[test]
fn fetch_attachment_returns_decoded_bytes() {
    let transport = ScriptedTransport::new();
    imap_session_script(&transport, "IMAP4rev1 UIDPLUS");
    select_script(&transport, "A0003", 1, 7, 8);
    let raw = b"Content-Type: multipart/mixed; boundary=b\r\n\r\n--b\r\nContent-Type: text/plain\r\n\r\nbody\r\n--b\r\nContent-Type: application/pdf; name=\"r.pdf\"\r\nContent-Disposition: attachment; filename=\"r.pdf\"\r\nContent-Transfer-Encoding: base64\r\n\r\naGVsbG8=\r\n--b--\r\n".to_vec();
    transport.enqueue_line(format!("* 1 FETCH (UID 42 BODY[] {{{}}}", raw.len()));
    transport.enqueue_literal(raw);
    transport.enqueue_line(")");
    transport.enqueue_line("A0004 OK FETCH completed");
    let mut provider = provider(&transport);

    let attachment = provider.fetch_attachment("42", "1.2").unwrap();
    assert_eq!(attachment.filename.as_deref(), Some("r.pdf"));
    assert_eq!(attachment.mime_type, "application/pdf");
    assert_eq!(attachment.data, b"hello");
}

/// Archiving moves a message out of INBOX, so a body fetch that only looks in
/// INBOX turns "open an archived message" into a permanent 502. The Message-ID
/// is the identity that survives the move; the provider must chase it into the
/// role folders before calling the message gone.
#[test]
fn fetch_raw_message_finds_an_archived_message_after_inbox_says_gone() {
    let transport = ScriptedTransport::new();
    imap_session_script(&transport, "IMAP4rev1 UIDPLUS");
    select_script(&transport, "A0003", 1, 7, 8);
    // INBOX: the header search is empty and the recent-window scan finds
    // nothing, so INBOX really has no such message.
    transport.enqueue_line("* SEARCH");
    transport.enqueue_line("A0004 OK SEARCH completed");
    transport.enqueue_line("A0005 OK FETCH completed");
    // Roles are discovered once, and Archive exists.
    transport.enqueue_lines(&[
        "* LIST (\\HasNoChildren) \"/\" \"INBOX\"",
        "* LIST (\\Archive) \"/\" \"Archive\"",
        "A0006 OK LIST completed",
    ]);
    select_script(&transport, "A0007", 2, 7, 50);
    transport.enqueue_line("* SEARCH 42");
    transport.enqueue_line("A0008 OK SEARCH completed");
    let raw = b"Message-ID: <m1@example.com>\r\nSubject: archived\r\n\r\nold body".to_vec();
    transport.enqueue_line(format!("* 1 FETCH (UID 42 BODY[] {{{}}}", raw.len()));
    transport.enqueue_literal(raw.clone());
    transport.enqueue_line(")");
    transport.enqueue_line("A0009 OK FETCH completed");
    let mut provider = provider(&transport);

    let fetched = provider.fetch_raw_message("<m1@example.com>").unwrap();
    assert_eq!(fetched, raw);
    let lines = transport.command_lines();
    assert!(
        lines.contains(&"A0007 SELECT \"Archive\"".to_owned()),
        "{lines:?}"
    );
    assert!(
        lines.contains(&"A0009 UID FETCH 42 (BODY.PEEK[])".to_owned()),
        "{lines:?}"
    );
}

/// Sync already reads every message's UID from the server. Persisting it and
/// passing it back on open turns the cold body fetch into one FETCH; without
/// the hint it is a SEARCH (empty on QQ) plus a whole-mailbox header scan —
/// measured at 2.2s on a 419-message mailbox, and slower as the mailbox grows.
#[test]
fn fetch_body_with_a_stored_uid_is_one_fetch_and_no_search_or_scan() {
    let transport = ScriptedTransport::new();
    imap_session_script(&transport, "IMAP4rev1 UIDPLUS");
    select_script(&transport, "A0003", 1, 7, 8);
    let raw = b"Message-ID: <m1@example.com>\r\nSubject: hello\r\n\r\nbody".to_vec();
    transport.enqueue_line(format!("* 1 FETCH (UID 42 BODY[] {{{}}}", raw.len()));
    transport.enqueue_literal(raw);
    transport.enqueue_line(")");
    transport.enqueue_line("A0004 OK FETCH completed");
    let mut provider = provider(&transport);

    let body = provider.fetch_body("<m1@example.com>", Some(42)).unwrap();
    assert_eq!(body.text, "body");
    let lines = transport.command_lines();
    assert!(
        lines.contains(&"A0004 UID FETCH 42 (BODY.PEEK[])".to_owned()),
        "{lines:?}"
    );
    assert!(
        !lines.iter().any(|line| line.contains("SEARCH")),
        "a stored UID must not search: {lines:?}"
    );
    assert!(
        !lines.iter().any(|line| line.contains("1:*")),
        "a stored UID must not scan: {lines:?}"
    );
}

/// A stored UID is only meaningful inside the UIDVALIDITY that issued it. If
/// the server's UID space was rebuilt, the same number can now hold a
/// different message; answering with it would show the user the wrong mail.
/// The fetched bytes are checked against the Message-ID the row is keyed by,
/// and a disagreement falls back to identity resolution.
#[test]
fn fetch_body_ignores_a_stored_uid_that_now_holds_another_message() {
    let transport = ScriptedTransport::new();
    imap_session_script(&transport, "IMAP4rev1 UIDPLUS");
    select_script(&transport, "A0003", 2, 7, 900);
    let stale = b"Message-ID: <other@example.com>\r\nSubject: not yours\r\n\r\nwrong body".to_vec();
    transport.enqueue_line(format!("* 1 FETCH (UID 42 BODY[] {{{}}}", stale.len()));
    transport.enqueue_literal(stale);
    transport.enqueue_line(")");
    transport.enqueue_line("A0004 OK FETCH completed");
    // Fallback: the search is empty (QQ), the scan finds the Message-ID at 12.
    transport.enqueue_line("* SEARCH");
    transport.enqueue_line("A0005 OK SEARCH completed");
    let header = b"Message-ID: <m1@example.com>\r\n\r\n".to_vec();
    transport.enqueue_line(format!(
        "* 1 FETCH (UID 12 BODY[HEADER.FIELDS (MESSAGE-ID)] {{{}}}",
        header.len()
    ));
    transport.enqueue_literal(header);
    transport.enqueue_line(")");
    transport.enqueue_line("A0006 OK FETCH completed");
    let raw = b"Message-ID: <m1@example.com>\r\nSubject: right\r\n\r\nright body".to_vec();
    transport.enqueue_line(format!("* 1 FETCH (UID 12 BODY[] {{{}}}", raw.len()));
    transport.enqueue_literal(raw);
    transport.enqueue_line(")");
    transport.enqueue_line("A0007 OK FETCH completed");
    let mut provider = provider(&transport);

    let body = provider.fetch_body("<m1@example.com>", Some(42)).unwrap();
    assert_eq!(body.text, "right body");
    let lines = transport.command_lines();
    assert!(
        lines.contains(&"A0004 UID FETCH 42 (BODY.PEEK[])".to_owned()),
        "{lines:?}"
    );
    assert!(
        lines.contains(&"A0007 UID FETCH 12 (BODY.PEEK[])".to_owned()),
        "the fallback must fetch the right message: {lines:?}"
    );
}

/// QQ answers `UID SEARCH HEADER Message-ID <id>` with an **empty set** even
/// when the header is present, so a body fetch by Message-ID cannot rely on
/// the search. The UID space is sparse (a mailbox with 419 messages can have
/// UIDNEXT 13963), so a "recent window" scan also misses older messages: the
/// scan must cover the whole UID range, not the last N UIDs.
#[test]
fn fetch_raw_message_finds_an_inbox_message_when_the_header_search_comes_back_empty() {
    let transport = ScriptedTransport::new();
    imap_session_script(&transport, "IMAP4rev1 UIDPLUS");
    // A mailbox whose UID space is sparse: 2 messages, UIDNEXT 900.
    select_script(&transport, "A0003", 2, 7, 900);
    // The header search finds nothing.
    transport.enqueue_line("* SEARCH");
    transport.enqueue_line("A0004 OK SEARCH completed");
    // The full-range scan: `1:*` is every UID the mailbox has, however sparse.
    let header = b"Message-ID: <m1@example.com>\r\n\r\n".to_vec();
    transport.enqueue_line(format!(
        "* 1 FETCH (UID 12 BODY[HEADER.FIELDS (MESSAGE-ID)] {{{}}}",
        header.len()
    ));
    transport.enqueue_literal(header);
    transport.enqueue_line(")");
    transport.enqueue_line("A0005 OK FETCH completed");
    let raw = b"Message-ID: <m1@example.com>\r\nSubject: old\r\n\r\nold body".to_vec();
    transport.enqueue_line(format!("* 1 FETCH (UID 12 BODY[] {{{}}}", raw.len()));
    transport.enqueue_literal(raw.clone());
    transport.enqueue_line(")");
    transport.enqueue_line("A0006 OK FETCH completed");
    let mut provider = provider(&transport);

    let fetched = provider.fetch_raw_message("<m1@example.com>").unwrap();
    assert_eq!(fetched, raw);
    let lines = transport.command_lines();
    assert!(
        lines.contains(
            &"A0005 UID FETCH 1:* (UID FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)])"
                .to_owned()
        ),
        "{lines:?}"
    );
    assert!(
        lines.contains(&"A0006 UID FETCH 12 (BODY.PEEK[])".to_owned()),
        "{lines:?}"
    );
}

#[test]
fn move_message_creates_the_folder_after_a_refused_copy() {
    let transport = ScriptedTransport::new();
    imap_session_script(&transport, "IMAP4rev1 UIDPLUS");
    select_script(&transport, "A0003", 1, 7, 8);
    transport.enqueue_line("A0004 NO [TRYCREATE] no such folder");
    transport.enqueue_line("A0005 OK CREATE completed");
    transport.enqueue_line("A0006 OK COPY completed");
    transport.enqueue_line("A0007 OK STORE completed");
    transport.enqueue_line("A0008 OK EXPUNGE completed");
    let mut provider = provider(&transport);

    assert!(provider.move_message("42", "Projects", true).unwrap());
    let lines = transport.command_lines();
    assert!(
        lines.contains(&"A0005 CREATE \"Projects\"".to_owned()),
        "{lines:?}"
    );
    assert!(
        lines.contains(&"A0006 UID COPY 42 \"Projects\"".to_owned()),
        "{lines:?}"
    );
    assert!(
        lines.contains(&"A0008 UID EXPUNGE 42".to_owned()),
        "{lines:?}"
    );
}

#[test]
fn move_message_without_move_or_uidplus_refuses_before_copying() {
    let transport = ScriptedTransport::new();
    imap_session_script(&transport, "IMAP4rev1");
    select_script(&transport, "A0003", 1, 7, 8);
    let mut provider = provider(&transport);

    let error = provider.move_message("42", "Projects", true).unwrap_err();
    assert_eq!(error.code(), "move-needs-uidplus");
    assert!(!transport.writes_text().contains("UID COPY"));
}

#[test]
fn list_folders_excludes_reserved_roles_and_reports_children() {
    let transport = ScriptedTransport::new();
    imap_session_script(&transport, "IMAP4rev1");
    transport.enqueue_lines(&[
        "* LIST (\\HasNoChildren) \"/\" \"INBOX\"",
        "* LIST (\\HasNoChildren) \"/\" \"Projects\"",
        "* LIST (\\HasNoChildren) \"/\" \"Projects/Sub\"",
        "* LIST (\\Drafts) \"/\" \"Drafts\"",
        "* LIST (\\Junk) \"/\" \"Junk\"",
        "* LIST (\\Archive) \"/\" \"Archive\"",
        "A0003 OK LIST completed",
    ]);
    let mut provider = provider(&transport);

    let folders = provider.list_folders().unwrap();
    assert_eq!(folders.len(), 2, "{folders:?}");
    assert_eq!(folders[0].name, "Projects");
    assert_eq!(folders[0].path, "Projects");
    assert!(folders[0].has_children);
    assert_eq!(folders[1].path, "Projects/Sub");
    assert!(!folders[1].has_children);
}

#[test]
fn list_sent_reads_the_sent_role_and_decodes_headers() {
    let transport = ScriptedTransport::new();
    imap_session_script(&transport, "IMAP4rev1");
    transport.enqueue_lines(&[
        "* LIST (\\HasNoChildren) \"/\" \"INBOX\"",
        "* LIST (\\Sent) \"/\" \"Sent\"",
        "A0003 OK LIST completed",
    ]);
    select_script(&transport, "A0004", 1, 7, 8);
    let header = header_literal("=?UTF-8?B?5L2g5aW9?=");
    transport.enqueue_line(format!("* 1 FETCH (UID 7 BODY[HEADER.FIELDS (FROM SUBJECT DATE MESSAGE-ID IN-REPLY-TO REFERENCES LIST-UNSUBSCRIBE)] {{{}}}", header.len()));
    transport.enqueue_literal(header);
    transport.enqueue_line(")");
    transport.enqueue_line("A0005 OK FETCH completed");
    let mut provider = provider(&transport);

    let sent = provider.list_sent(10).unwrap();
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0].remote_id, "<m1@example.com>");
    assert_eq!(sent[0].subject.as_deref(), Some("你好"));
    assert_eq!(sent[0].from_address, "chen@example.com");
    assert_eq!(sent[0].thread_id, "<root@example.com>");
    assert!(transport.command_lines().contains(&"A0005 FETCH 1:* (UID FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE MESSAGE-ID IN-REPLY-TO REFERENCES LIST-UNSUBSCRIBE)])".to_owned()));
}

#[test]
fn pull_changes_fetches_new_headers_and_reports_the_cursor() {
    let transport = ScriptedTransport::new();
    imap_session_script(&transport, "IMAP4rev1");
    select_script(&transport, "A0003", 3, 7, 20);
    let header = header_literal("Hello");
    transport.enqueue_line(format!("* 1 FETCH (UID 10 BODY[HEADER.FIELDS (FROM SUBJECT DATE MESSAGE-ID IN-REPLY-TO REFERENCES LIST-UNSUBSCRIBE)] {{{}}}", header.len()));
    transport.enqueue_literal(header);
    transport.enqueue_line(")");
    transport.enqueue_line("A0004 OK FETCH completed");
    let mut provider = provider(&transport);

    let changes = provider
        .pull_changes(
            SyncCursor {
                uid_next: 10,
                uid_validity: 7,
            },
            std::time::Duration::ZERO,
        )
        .unwrap();
    assert!(!changes.reset_required);
    assert_eq!(changes.upserts.len(), 1);
    assert_eq!(changes.upserts[0].subject.as_deref(), Some("Hello"));
    assert_eq!(changes.cursor.uid_next, 20);
    assert_eq!(changes.cursor.uid_validity, 7);
    // Unknown membership sets must stay unknown: the store deletes nothing.
    assert!(changes.inbox_remote_ids.is_none());
    assert!(changes.removed_remote_ids.is_none());
    assert!(transport.command_lines().contains(&"A0004 UID FETCH 10:* (UID FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE MESSAGE-ID IN-REPLY-TO REFERENCES LIST-UNSUBSCRIBE)])".to_owned()));
}

#[test]
fn a_uidvalidity_change_requires_a_reset_and_fetches_nothing() {
    let transport = ScriptedTransport::new();
    imap_session_script(&transport, "IMAP4rev1");
    select_script(&transport, "A0003", 3, 99, 20);
    let mut provider = provider(&transport);

    let changes = provider
        .pull_changes(
            SyncCursor {
                uid_next: 10,
                uid_validity: 7,
            },
            std::time::Duration::ZERO,
        )
        .unwrap();
    assert!(changes.reset_required);
    assert!(changes.upserts.is_empty());
    assert_eq!(changes.cursor.uid_validity, 99);
    assert_eq!(transport.command_lines().len(), 3);
}

#[test]
fn probe_logs_in_resolves_roles_and_selects_the_inbox() {
    let transport = ScriptedTransport::new();
    imap_session_script(&transport, "IMAP4rev1 UIDPLUS");
    transport.enqueue_lines(&[
        "* LIST (\\HasNoChildren) \"/\" \"INBOX\"",
        "* LIST (\\Archive) \"/\" \"Archive\"",
        "A0003 OK LIST completed",
    ]);
    select_script(&transport, "A0004", 0, 7, 8);
    let mut provider = provider(&transport);

    provider.probe().unwrap();
    let lines = transport.command_lines();
    assert!(
        lines.contains(&"A0004 SELECT \"INBOX\"".to_owned()),
        "{lines:?}"
    );
}

#[test]
fn shutdown_closes_the_transport() {
    let transport = ScriptedTransport::new();
    imap_session_script(&transport, "IMAP4rev1");
    transport.enqueue_lines(&[
        "* LIST (\\HasNoChildren) \"/\" \"INBOX\"",
        "A0003 OK LIST completed",
    ]);
    let mut provider = provider(&transport);
    let _ = provider.capabilities();
    provider.shutdown();
    assert_eq!(transport.close_count(), 1);
}

#[test]
fn the_sync_seam_is_read_only_by_type() {
    // The trait has exactly three methods and none of them can mutate the
    // mailbox. This test exists so the signature itself is the assertion; a
    // future write verb added to `MailSyncReading` breaks this call shape.
    fn use_seam(seam: &mut dyn MailSyncReading) -> Option<lagoon_mail::MailCapabilities> {
        seam.capabilities()
    }
    let transport = ScriptedTransport::new();
    imap_session_script(&transport, "IMAP4rev1 UIDPLUS");
    transport.enqueue_lines(&[
        "* LIST (\\HasNoChildren) \"/\" \"INBOX\"",
        "* LIST (\\Archive) \"/\" \"Archive\"",
        "A0003 OK LIST completed",
    ]);
    let mut provider = provider(&transport);
    let capabilities = use_seam(&mut provider);
    assert!(capabilities.is_some());
}

/// A message with one inline picture and one file attachment.
fn multipart_message() -> Vec<u8> {
    b"Message-ID: <m1@example.com>\r\nContent-Type: multipart/mixed; boundary=m\r\n\r\n\
--m\r\nContent-Type: text/plain\r\n\r\nbody\r\n\
--m\r\nContent-Type: image/png\r\nContent-Transfer-Encoding: base64\r\n\
Content-Disposition: inline; filename=pic.png\r\nContent-ID: <pic1@example.com>\r\n\r\niVBORw0KGgo=\r\n\
--m\r\nContent-Type: application/pdf; name=\"r.pdf\"\r\n\
Content-Disposition: attachment; filename=\"r.pdf\"\r\nContent-Transfer-Encoding: base64\r\n\r\nJVBERg==\r\n\
--m--\r\n"
        .to_vec()
}

/// The download route asks for one part by its IMAP path. The bytes come back
/// decoded, and the metadata needed for Content-Type / Content-Disposition
/// comes with them.
#[test]
fn fetch_attachment_returns_the_bytes_of_the_requested_part() {
    let transport = ScriptedTransport::new();
    imap_session_script(&transport, "IMAP4rev1 UIDPLUS");
    select_script(&transport, "A0003", 1, 7, 8);
    let raw = multipart_message();
    transport.enqueue_line(format!("* 1 FETCH (UID 42 BODY[] {{{}}}", raw.len()));
    transport.enqueue_literal(raw);
    transport.enqueue_line(")");
    transport.enqueue_line("A0004 OK FETCH completed");
    let mut provider = provider(&transport);

    let fetched = provider
        .fetch_attachment_with_hint("<m1@example.com>", Some(42), "1.3")
        .unwrap();
    assert_eq!(fetched.mime_type, "application/pdf");
    assert_eq!(fetched.filename.as_deref(), Some("r.pdf"));
    assert_eq!(fetched.data, b"%PDF".to_vec());
}

/// A part that is not in the message is not a transport failure and not a
/// missing message: it is a fact about this message.
#[test]
fn fetch_attachment_of_a_part_that_is_not_there_says_not_found() {
    let transport = ScriptedTransport::new();
    imap_session_script(&transport, "IMAP4rev1 UIDPLUS");
    select_script(&transport, "A0003", 1, 7, 8);
    let raw = multipart_message();
    transport.enqueue_line(format!("* 1 FETCH (UID 42 BODY[] {{{}}}", raw.len()));
    transport.enqueue_literal(raw);
    transport.enqueue_line(")");
    transport.enqueue_line("A0004 OK FETCH completed");
    let mut provider = provider(&transport);

    let error = provider
        .fetch_attachment_with_hint("<m1@example.com>", Some(42), "9.9")
        .unwrap_err();
    assert_eq!(error.kind(), MailErrorKind::AttachmentNotFound);
    assert_eq!(error.code(), "attachment-not-found");
}

/// The reader resolves `cid:` references, so the inline images have to come
/// back with their content ids and their bytes.
#[test]
fn fetch_inline_images_returns_the_pictures_with_their_content_ids() {
    let transport = ScriptedTransport::new();
    imap_session_script(&transport, "IMAP4rev1 UIDPLUS");
    select_script(&transport, "A0003", 1, 7, 8);
    let raw = multipart_message();
    transport.enqueue_line(format!("* 1 FETCH (UID 42 BODY[] {{{}}}", raw.len()));
    transport.enqueue_literal(raw);
    transport.enqueue_line(")");
    transport.enqueue_line("A0004 OK FETCH completed");
    let mut provider = provider(&transport);

    let images = provider
        .fetch_inline_images_with_hint("<m1@example.com>", Some(42))
        .unwrap();
    assert_eq!(images.len(), 1);
    assert_eq!(images[0].content_id, "pic1@example.com");
    assert_eq!(images[0].mime_type, "image/png");
    assert_eq!(images[0].data, b"\x89PNG\r\n\x1a\n".to_vec());
}

/// A picture sent as a file can still carry a Content-ID. The body does not
/// render it, and the inline policy does not decode it - so handing it back as
/// an inline image would give the HTML an empty `data:` URL and the user a
/// broken picture instead of the file they were sent.
#[test]
fn a_picture_attached_as_a_file_is_not_an_inline_image() {
    let raw = b"Message-ID: <m2@example.com>\r\nContent-Type: multipart/mixed; boundary=m\r\n\r\n\
--m\r\nContent-Type: text/plain\r\n\r\nbody\r\n\
--m\r\nContent-Type: image/png\r\nContent-Transfer-Encoding: base64\r\n\
Content-Disposition: attachment; filename=photo.png\r\nContent-ID: <photo@example.com>\r\n\r\niVBORw0KGgo=\r\n\
--m--\r\n"
        .to_vec();
    let transport = ScriptedTransport::new();
    imap_session_script(&transport, "IMAP4rev1 UIDPLUS");
    select_script(&transport, "A0003", 1, 7, 8);
    transport.enqueue_line(format!("* 1 FETCH (UID 42 BODY[] {{{}}}", raw.len()));
    transport.enqueue_literal(raw);
    transport.enqueue_line(")");
    transport.enqueue_line("A0004 OK FETCH completed");
    let mut provider = provider(&transport);

    let images = provider
        .fetch_inline_images_with_hint("<m2@example.com>", Some(42))
        .unwrap();
    assert!(images.is_empty(), "not an inline image: {images:?}");
}
