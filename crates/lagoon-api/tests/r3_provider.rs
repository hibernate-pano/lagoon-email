//! R3.4b-1: the lagoon-mail adapter and its HTTP wiring.
//!
//! Every case is a scripted IMAP conversation (lagoon-mail's ScriptedTransport
//! shape); no socket, DNS or TLS is touched.

mod support;

use std::sync::Arc;

use lagoon_api::provider::lagoon_mail::LagoonMailFactory;
use lagoon_api::provider::{MailProvider, ProviderError, ProviderFactory};
use lagoon_api::sync::SyncCursor;
use lagoon_api::token::ImapCredentials;
use lagoon_mail::transport::Transport;

use support::http;
use support::scripted_transport::{
    imap_session_script, select_script, FailureKind, ScriptedTransport,
};
use support::server::TestServer;

fn transport_factory(
    transport: &ScriptedTransport,
) -> Arc<dyn Fn() -> Box<dyn Transport> + Send + Sync> {
    let handle = transport.handle();
    Arc::new(move || Box::new(handle.clone()) as Box<dyn Transport>)
}

fn provider(transport: &ScriptedTransport) -> Arc<dyn MailProvider> {
    LagoonMailFactory::with_transport(transport_factory(transport))
        .make(&ImapCredentials::new("user@example.invalid", "auth-code"))
        .expect("provider")
}

fn header_literal(subject: &str) -> Vec<u8> {
    format!(
        "From: \"Chen, Qi\" <chen@example.com>\r\nSubject: {subject}\r\nMessage-ID: <m1@example.com>\r\nReferences: <root@example.com>\r\n\r\n"
    )
    .into_bytes()
}

#[tokio::test]
async fn probe_negotiates_capabilities_through_the_adapter() {
    let transport = ScriptedTransport::new();
    imap_session_script(&transport, "IMAP4rev1 MOVE IDLE UIDPLUS");
    transport.enqueue_lines(&[
        "* LIST (\\HasNoChildren) \"/\" \"INBOX\"",
        "* LIST (\\Archive \\HasNoChildren) \"/\" \"Archive\"",
        "* LIST (\\Trash \\HasNoChildren) \"/\" \"Trash\"",
        "* LIST (\\Sent \\HasNoChildren) \"/\" \"Sent\"",
        "A0003 OK LIST completed",
    ]);
    select_script(&transport, "A0004", 0, 7, 1);
    let observed = provider(&transport).probe().await.expect("probe");
    let capabilities = observed.capabilities.expect("negotiated");
    assert_eq!(capabilities.archive_folder, Some(true));
    assert_eq!(capabilities.trash_folder, Some(true));
    assert_eq!(capabilities.sent_folder, Some(true));
    assert_eq!(capabilities.uidplus, Some(true));
    assert!(capabilities.idle);
    assert!(capabilities.move_supported);
}

#[tokio::test]
async fn probe_maps_auth_failure_and_unreachable() {
    let auth = ScriptedTransport::new();
    auth.enqueue_line("* OK ready");
    auth.enqueue_line("A0001 NO [AUTHENTICATIONFAILED] invalid credentials");
    match provider(&auth).probe().await {
        Err(ProviderError::AuthFailed) => {}
        other => panic!("expected AuthFailed, got {other:?}"),
    }

    let down = ScriptedTransport::new();
    down.fail_next_read(FailureKind::Io);
    match provider(&down).probe().await {
        Err(ProviderError::Unreachable(_)) => {}
        other => panic!("expected Unreachable, got {other:?}"),
    }
}

#[tokio::test]
async fn pull_changes_maps_cursor_and_upserts() {
    let transport = ScriptedTransport::new();
    imap_session_script(&transport, "IMAP4rev1");
    select_script(&transport, "A0003", 3, 7, 20);
    let header = header_literal("Hello");
    transport.enqueue_line(format!(
        "* 1 FETCH (UID 10 BODY[HEADER.FIELDS (FROM SUBJECT DATE MESSAGE-ID IN-REPLY-TO REFERENCES LIST-UNSUBSCRIBE)] {{{}}}",
        header.len()
    ));
    transport.enqueue_literal(header);
    transport.enqueue_line(")");
    transport.enqueue_line("A0004 OK FETCH completed");

    let changes = provider(&transport)
        .pull_changes(&SyncCursor {
            uid_validity: Some(7),
            last_uid: Some(9),
        })
        .await
        .expect("pull");
    assert!(!changes.reset_required);
    assert_eq!(changes.upserts.len(), 1);
    assert_eq!(changes.upserts[0].subject.as_deref(), Some("Hello"));
    assert_eq!(changes.cursor.uid_validity, Some(7));
    assert_eq!(
        changes.cursor.last_uid,
        Some(19),
        "uid_next 20 -> last uid 19"
    );
    // This half deliberately leaves membership unknown.
    assert!(changes.inbox_remote_ids.is_none());
    assert!(changes.archived_remote_ids.is_none());
    assert!(changes.trashed_remote_ids.is_none());
}

#[tokio::test]
async fn pull_changes_maps_reset_required() {
    let transport = ScriptedTransport::new();
    imap_session_script(&transport, "IMAP4rev1");
    select_script(&transport, "A0003", 3, 99, 20);
    let changes = provider(&transport)
        .pull_changes(&SyncCursor {
            uid_validity: Some(7),
            last_uid: Some(9),
        })
        .await
        .expect("pull");
    assert!(changes.reset_required);
    assert!(changes.upserts.is_empty());
    assert_eq!(changes.cursor.uid_validity, Some(99));
}

fn connect_body(email: &str) -> serde_json::Value {
    serde_json::json!({"provider": "qq", "email": email, "authCode": "auth-code"})
}

async fn post_connect(server: &TestServer, body: &serde_json::Value) -> http::Observed {
    let client = http::client();
    http::request_with_body(
        &client,
        "POST",
        &format!("{}/api/accounts/imap", server.base_url),
        &server.auth_headers(),
        body.to_string().as_bytes(),
    )
    .await
}

#[tokio::test]
async fn http_connect_returns_201_on_success_and_401_on_auth_failure() {
    let success = ScriptedTransport::new();
    imap_session_script(&success, "IMAP4rev1 UIDPLUS");
    success.enqueue_lines(&[
        "* LIST (\\HasNoChildren) \"/\" \"INBOX\"",
        "* LIST (\\Archive) \"/\" \"Archive\"",
        "A0003 OK LIST completed",
    ]);
    select_script(&success, "A0004", 0, 7, 1);
    let factory = Arc::new(LagoonMailFactory::with_transport(transport_factory(
        &success,
    )));
    let (server, _fixtures) = TestServer::spawn_with_provider("r3b-201", factory).await;
    let observed = post_connect(&server, &connect_body("ok@example.invalid")).await;
    assert_eq!(observed.status, 201, "{:?}", observed.body);
    assert_eq!(
        observed.body["email"],
        serde_json::json!("ok@example.invalid")
    );

    let denied = ScriptedTransport::new();
    denied.enqueue_line("* OK ready");
    denied.enqueue_line("A0001 NO [AUTHENTICATIONFAILED] invalid credentials");
    let factory = Arc::new(LagoonMailFactory::with_transport(transport_factory(
        &denied,
    )));
    let (server, _fixtures) = TestServer::spawn_with_provider("r3b-401", factory).await;
    let observed = post_connect(&server, &connect_body("denied@example.invalid")).await;
    assert_eq!(observed.status, 401, "{:?}", observed.body);
    assert_eq!(
        observed.body,
        serde_json::json!({"error": "imap-auth-failed"})
    );
}

#[tokio::test]
async fn http_connect_returns_502_when_unreachable() {
    let down = ScriptedTransport::new();
    down.fail_next_read(FailureKind::Io);
    let factory = Arc::new(LagoonMailFactory::with_transport(transport_factory(&down)));
    let (server, _fixtures) = TestServer::spawn_with_provider("r3b-502", factory).await;
    let observed = post_connect(&server, &connect_body("down@example.invalid")).await;
    assert_eq!(observed.status, 502, "{:?}", observed.body);
    assert_eq!(
        observed.body,
        serde_json::json!({"error": "imap-unreachable"})
    );
}

#[tokio::test]
async fn http_connect_returns_503_when_no_provider_is_configured() {
    let (server, _fixtures) = TestServer::spawn("r3b-503").await;
    let observed = post_connect(&server, &connect_body("none@example.invalid")).await;
    assert_eq!(observed.status, 503, "{:?}", observed.body);
    assert_eq!(
        observed.body,
        serde_json::json!({"error": "provider-not-configured"})
    );
}

#[tokio::test]
async fn pull_changes_fills_membership_on_the_same_session() {
    let transport = ScriptedTransport::new();
    imap_session_script(&transport, "IMAP4rev1");
    select_script(&transport, "A0003", 3, 7, 20);
    let header = header_literal("Hello");
    transport.enqueue_line(format!(
        "* 1 FETCH (UID 10 BODY[HEADER.FIELDS (FROM SUBJECT DATE MESSAGE-ID IN-REPLY-TO REFERENCES LIST-UNSUBSCRIBE)] {{{}}}",
        header.len()
    ));
    transport.enqueue_literal(header.clone());
    transport.enqueue_line(")");
    transport.enqueue_line("A0004 OK FETCH completed");
    transport.enqueue_lines(&[
        "* LIST (\\HasNoChildren) \"/\" \"INBOX\"",
        "* LIST (\\Archive \\HasNoChildren) \"/\" \"Archive\"",
        "* LIST (\\Trash \\HasNoChildren) \"/\" \"Trash\"",
        "A0005 OK LIST completed",
    ]);
    select_script(&transport, "A0006", 1, 7, 20);
    transport.enqueue_line("* SEARCH 10");
    transport.enqueue_line("A0007 OK SEARCH completed");
    transport.enqueue_line(format!(
        "* 1 FETCH (UID 10 BODY[HEADER.FIELDS (FROM SUBJECT DATE MESSAGE-ID IN-REPLY-TO REFERENCES LIST-UNSUBSCRIBE)] {{{}}}",
        header.len()
    ));
    transport.enqueue_literal(header);
    transport.enqueue_line(")");
    transport.enqueue_line("A0008 OK FETCH completed");
    select_script(&transport, "A0009", 0, 8, 1);
    select_script(&transport, "A0010", 0, 9, 1);

    let changes = provider(&transport)
        .pull_changes(&SyncCursor {
            uid_validity: Some(7),
            last_uid: Some(9),
        })
        .await
        .expect("pull");
    assert_eq!(
        changes.inbox_remote_ids,
        Some(vec!["<m1@example.com>".to_owned()])
    );
    // The scripted session ends after INBOX, so the other two folders are
    // reported unknown; what this test proves is (a) INBOX membership came
    // from remote_membership on the pull session and (b) one login.
    assert!(
        changes.archived_remote_ids.is_none() || changes.archived_remote_ids == Some(Vec::new())
    );
    assert!(changes.trashed_remote_ids.is_none() || changes.trashed_remote_ids == Some(Vec::new()));
    assert_eq!(transport.connect_count(), 1, "one login per round");
}

#[tokio::test]
async fn a_reset_round_skips_membership_and_keeps_one_connection() {
    let transport = ScriptedTransport::new();
    imap_session_script(&transport, "IMAP4rev1");
    select_script(&transport, "A0003", 3, 99, 20);
    let changes = provider(&transport)
        .pull_changes(&SyncCursor {
            uid_validity: Some(7),
            last_uid: Some(9),
        })
        .await
        .expect("pull");
    assert!(changes.reset_required);
    assert!(changes.inbox_remote_ids.is_none());
    assert!(changes.archived_remote_ids.is_none());
    assert!(changes.trashed_remote_ids.is_none());
    assert_eq!(
        transport.connect_count(),
        1,
        "reset round opens no extra session"
    );
}
