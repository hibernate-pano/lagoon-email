//! R3.5b: the three send paths - reply, compose, forward.
//!
//! What these pin, in order of how badly it hurts when it is wrong:
//! * a send is **not** silently duplicated: one requestId, one delivery;
//! * a replay answers the first result instead of sending again;
//! * a requestId another request still owns answers 409, not a second mail;
//! * an invalid recipient or attachment is refused BEFORE SMTP, never dropped
//!   on the way;
//! * the sent copy is stored locally, so "已发送" lists it without the server;
//! * forwarding carries the original as `message/rfc822`, not as quoted text.

mod support;

use std::sync::Arc;

use serde_json::{json, Value};

use lagoon_api::provider::fake::{FakeOutcome, FakeProviderFactory};
use lagoon_api::provider::{ProviderError, SentMail};
use lagoon_api::token::ImapCredentials;
use lagoon_api::uuid::Uuid;

use support::http;
use support::server::{open_read_write, token_key, TestServer};

const ACCOUNT_A: &str = "11111111-1111-4111-8111-111111111111";
const ACCOUNT_EMAIL: &str = "contract-fixture@example.invalid";
/// Seeded by the contract fixtures: alice's message "Contract fixture one".
const REMOTE: &str = "fixture-msg-1";
const REQUEST_ID: &str = "33333333-3333-4333-8333-333333333331";

fn uuid_bytes(raw: &str) -> Vec<u8> {
    Uuid::parse_strict(raw).expect("uuid").as_bytes().to_vec()
}

/// Re-seal account A's credentials with the test token key: without it the
/// route cannot build a send provider and answers 503 before any assertion
/// about the mail itself.
fn prepare_account(server: &TestServer) {
    let connection = open_read_write(&server.db_path);
    let sealed = ImapCredentials::new(ACCOUNT_EMAIL, "auth-code")
        .seal(&token_key())
        .expect("seal");
    connection
        .execute(
            "UPDATE accounts SET credentials = ? WHERE id = ?",
            rusqlite::params![sealed, uuid_bytes(ACCOUNT_A)],
        )
        .expect("prepare account");
}

async fn post(
    client: &http::HttpClient,
    server: &TestServer,
    path: &str,
    body: &Value,
) -> http::Observed {
    http::request_with_body(
        client,
        "POST",
        &format!("{}{path}", server.base_url),
        &server.auth_headers(),
        body.to_string().as_bytes(),
    )
    .await
}

fn sent_rows(server: &TestServer) -> i64 {
    let connection = open_read_write(&server.db_path);
    connection
        .query_row(
            "SELECT count(*) FROM message_headers WHERE account_id = ? AND is_sent = TRUE",
            rusqlite::params![uuid_bytes(ACCOUNT_A)],
            |row| row.get(0),
        )
        .expect("sent count")
}

fn sent_body_rows(server: &TestServer, remote_id: &str) -> i64 {
    let connection = open_read_write(&server.db_path);
    connection
        .query_row(
            "SELECT count(*) FROM message_bodies WHERE account_id = ? AND remote_id = ?",
            rusqlite::params![uuid_bytes(ACCOUNT_A), remote_id],
            |row| row.get(0),
        )
        .expect("body count")
}

#[tokio::test]
async fn compose_sends_the_message_and_stores_the_sent_copy() {
    let factory = Arc::new(FakeProviderFactory::new(FakeOutcome::succeeds()));
    factory.send_script(vec![Ok(SentMail {
        provider_message_id: Some("<sent-1@lagoon>".to_owned()),
    })]);
    let (server, _fixtures) =
        TestServer::spawn_with_provider("r3-send-compose", factory.clone()).await;
    prepare_account(&server);
    let client = http::client();

    let observed = post(
        &client,
        &server,
        &format!("/api/compose/send?accountId={ACCOUNT_A}"),
        &json!({
            "to": "bob@example.invalid",
            "subject": "Hi",
            "body": "Hello there",
            "requestId": REQUEST_ID,
        }),
    )
    .await;
    assert_eq!(observed.status, 200, "{:?}", observed.body);
    assert_eq!(observed.body["ok"], json!(true));
    assert_eq!(observed.body["providerMessageId"], json!("<sent-1@lagoon>"));

    let sent = factory.send_calls();
    assert_eq!(sent.len(), 1, "exactly one delivery");
    assert_eq!(sent[0].to, vec!["bob@example.invalid".to_owned()]);
    assert_eq!(sent[0].subject, "Hi");
    assert_eq!(sent[0].body, "Hello there");
    assert_eq!(sent[0].from_email, ACCOUNT_EMAIL);
    assert!(!sent[0].is_reply);

    // The sent copy is local: the "已发送" list is a lower bound that does not
    // need the server's Sent folder.
    assert_eq!(sent_rows(&server), 1);
    assert_eq!(
        sent_body_rows(&server, "<sent-1@lagoon>"),
        1,
        "the sent body is cached, so opening it never asks the server"
    );
}

#[tokio::test]
async fn a_reply_defaults_to_the_sender_and_keeps_the_thread() {
    let factory = Arc::new(FakeProviderFactory::new(FakeOutcome::succeeds()));
    let (server, _fixtures) =
        TestServer::spawn_with_provider("r3-send-reply", factory.clone()).await;
    prepare_account(&server);
    let client = http::client();

    let observed = post(
        &client,
        &server,
        &format!("/api/messages/{REMOTE}/send?accountId={ACCOUNT_A}"),
        &json!({ "body": "Sure, that works." }),
    )
    .await;
    assert_eq!(observed.status, 200, "{:?}", observed.body);

    let sent = factory.send_calls();
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0].to, vec!["alice.fixture@example.invalid".to_owned()]);
    assert_eq!(sent[0].subject, "Contract fixture one");
    assert!(sent[0].is_reply);
    assert_eq!(
        sent[0].in_reply_to.as_deref(),
        Some("<fixture-1@example.invalid>")
    );
    assert!(sent[0]
        .references
        .as_deref()
        .unwrap_or_default()
        .contains("<fixture-1@example.invalid>"));
}

#[tokio::test]
async fn a_reply_to_a_message_that_is_not_there_is_404() {
    let factory = Arc::new(FakeProviderFactory::new(FakeOutcome::succeeds()));
    let (server, _fixtures) =
        TestServer::spawn_with_provider("r3-send-unknown", factory.clone()).await;
    prepare_account(&server);
    let client = http::client();

    let observed = post(
        &client,
        &server,
        &format!("/api/messages/fixture-missing/send?accountId={ACCOUNT_A}"),
        &json!({ "body": "Hello" }),
    )
    .await;
    assert_eq!(observed.status, 404, "{:?}", observed.body);
    assert_eq!(observed.body["error"], json!("unknown-message"));
    assert!(factory.send_calls().is_empty());
}

#[tokio::test]
async fn the_same_request_id_sends_once_and_replays_the_first_result() {
    let factory = Arc::new(FakeProviderFactory::new(FakeOutcome::succeeds()));
    factory.send_script(vec![Ok(SentMail {
        provider_message_id: Some("<sent-once@lagoon>".to_owned()),
    })]);
    let (server, _fixtures) =
        TestServer::spawn_with_provider("r3-send-idempotent", factory.clone()).await;
    prepare_account(&server);
    let client = http::client();

    let path = format!("/api/compose/send?accountId={ACCOUNT_A}");
    let body = json!({
        "to": "bob@example.invalid",
        "subject": "Once",
        "body": "Only once",
        "requestId": REQUEST_ID,
    });

    let first = post(&client, &server, &path, &body).await;
    assert_eq!(first.status, 200, "{:?}", first.body);
    let second = post(&client, &server, &path, &body).await;
    assert_eq!(second.status, 200, "{:?}", second.body);
    assert_eq!(
        second.body["providerMessageId"],
        json!("<sent-once@lagoon>")
    );

    assert_eq!(
        factory.send_calls().len(),
        1,
        "a replayed requestId must not deliver a second mail"
    );
}

#[tokio::test]
async fn a_request_id_another_request_still_owns_answers_409() {
    let factory = Arc::new(FakeProviderFactory::new(FakeOutcome::succeeds()));
    let (server, _fixtures) =
        TestServer::spawn_with_provider("r3-send-inflight", factory.clone()).await;
    prepare_account(&server);
    // A pending row is what an in-flight send looks like in the store.
    let connection = open_read_write(&server.db_path);
    connection
        .execute(
            "INSERT INTO ai_actions (account_id, kind, payload) VALUES (?1, 'send', ?2)",
            rusqlite::params![
                uuid_bytes(ACCOUNT_A),
                json!({"requestId": REQUEST_ID, "status": "pending"}).to_string()
            ],
        )
        .expect("pending send");
    drop(connection);

    let client = http::client();
    let observed = post(
        &client,
        &server,
        &format!("/api/compose/send?accountId={ACCOUNT_A}"),
        &json!({
            "to": "bob@example.invalid",
            "subject": "Twice",
            "body": "Twice",
            "requestId": REQUEST_ID,
        }),
    )
    .await;
    assert_eq!(observed.status, 409, "{:?}", observed.body);
    assert_eq!(observed.body["error"], json!("send-in-flight"));
    assert!(factory.send_calls().is_empty());
}

#[tokio::test]
async fn an_invalid_recipient_is_refused_before_smtp() {
    let factory = Arc::new(FakeProviderFactory::new(FakeOutcome::succeeds()));
    let (server, _fixtures) =
        TestServer::spawn_with_provider("r3-send-bad-recipient", factory.clone()).await;
    prepare_account(&server);
    let client = http::client();

    let observed = post(
        &client,
        &server,
        &format!("/api/compose/send?accountId={ACCOUNT_A}"),
        &json!({ "to": "not an address", "subject": "Hi", "body": "Hello" }),
    )
    .await;
    assert_eq!(observed.status, 400, "{:?}", observed.body);
    assert_eq!(observed.body["error"], json!("malformed-recipient"));
    assert!(factory.send_calls().is_empty());
}

#[tokio::test]
async fn an_unreadable_attachment_is_refused_before_smtp() {
    let factory = Arc::new(FakeProviderFactory::new(FakeOutcome::succeeds()));
    let (server, _fixtures) =
        TestServer::spawn_with_provider("r3-send-bad-attachment", factory.clone()).await;
    prepare_account(&server);
    let client = http::client();

    let observed = post(
        &client,
        &server,
        &format!("/api/compose/send?accountId={ACCOUNT_A}"),
        &json!({
            "to": "bob@example.invalid",
            "subject": "Hi",
            "body": "Hello",
            "attachments": [{
                "filename": "note.txt",
                "mimeType": "text/plain",
                "dataBase64": "not base64!!",
            }],
        }),
    )
    .await;
    assert_eq!(observed.status, 400, "{:?}", observed.body);
    assert_eq!(observed.body["error"], json!("malformed-attachment"));
    assert!(factory.send_calls().is_empty());
}

#[tokio::test]
async fn a_malformed_request_id_is_refused_before_smtp() {
    let factory = Arc::new(FakeProviderFactory::new(FakeOutcome::succeeds()));
    let (server, _fixtures) =
        TestServer::spawn_with_provider("r3-send-bad-request-id", factory.clone()).await;
    prepare_account(&server);
    let client = http::client();

    let observed = post(
        &client,
        &server,
        &format!("/api/compose/send?accountId={ACCOUNT_A}"),
        &json!({
            "to": "bob@example.invalid",
            "subject": "Hi",
            "body": "Hello",
            "requestId": "not-a-uuid",
        }),
    )
    .await;
    assert_eq!(observed.status, 400, "{:?}", observed.body);
    assert_eq!(observed.body["error"], json!("malformed-request-id"));
    assert!(factory.send_calls().is_empty());
}

#[tokio::test]
async fn a_missing_recipient_is_a_malformed_compose() {
    let factory = Arc::new(FakeProviderFactory::new(FakeOutcome::succeeds()));
    let (server, _fixtures) =
        TestServer::spawn_with_provider("r3-send-malformed", factory.clone()).await;
    prepare_account(&server);
    let client = http::client();

    let observed = post(
        &client,
        &server,
        &format!("/api/compose/send?accountId={ACCOUNT_A}"),
        &json!({ "subject": "Hi", "body": "Hello" }),
    )
    .await;
    assert_eq!(observed.status, 400, "{:?}", observed.body);
    assert_eq!(observed.body["error"], json!("malformed-compose"));
    assert!(factory.send_calls().is_empty());
}

#[tokio::test]
async fn a_rejected_authorization_code_is_401_and_a_transport_failure_is_502() {
    let factory = Arc::new(FakeProviderFactory::new(FakeOutcome::succeeds()));
    factory.send_script(vec![
        Err(ProviderError::AuthFailed),
        Err(ProviderError::Unreachable("smtp-timeout".to_owned())),
    ]);
    let (server, _fixtures) =
        TestServer::spawn_with_provider("r3-send-errors", factory.clone()).await;
    prepare_account(&server);
    let client = http::client();

    let path = format!("/api/compose/send?accountId={ACCOUNT_A}");
    let first = post(
        &client,
        &server,
        &path,
        &json!({ "to": "bob@example.invalid", "subject": "Hi", "body": "Hello" }),
    )
    .await;
    assert_eq!(first.status, 401, "{:?}", first.body);
    assert_eq!(first.body["error"], json!("smtp-auth-failed"));

    let second = post(
        &client,
        &server,
        &path,
        &json!({ "to": "bob@example.invalid", "subject": "Hi", "body": "Hello" }),
    )
    .await;
    assert_eq!(second.status, 502, "{:?}", second.body);
    assert_eq!(second.body["error"], json!("smtp-send-failed"));
}

#[tokio::test]
async fn forward_carries_the_original_as_a_message_rfc822_part() {
    let factory = Arc::new(FakeProviderFactory::new(FakeOutcome::succeeds()));
    factory.raw_script(vec![Ok(
        b"From: alice@example.invalid\r\n\r\noriginal".to_vec()
    )]);
    let (server, _fixtures) =
        TestServer::spawn_with_provider("r3-send-forward", factory.clone()).await;
    prepare_account(&server);
    let client = http::client();

    let observed = post(
        &client,
        &server,
        &format!("/api/messages/{REMOTE}/forward?accountId={ACCOUNT_A}"),
        &json!({ "to": ["bob@example.invalid"], "body": "FYI" }),
    )
    .await;
    assert_eq!(observed.status, 200, "{:?}", observed.body);

    let sent = factory.send_calls();
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0].to, vec!["bob@example.invalid".to_owned()]);
    assert_eq!(sent[0].subject, "Fwd: Contract fixture one");
    assert_eq!(sent[0].body, "FYI");
    assert_eq!(sent[0].attachments.len(), 1);
    assert_eq!(sent[0].attachments[0].mime_type, "message/rfc822");
    assert!(sent[0].attachments[0].inline);
    assert_eq!(
        sent[0].attachments[0].data,
        b"From: alice@example.invalid\r\n\r\noriginal".to_vec()
    );
}

#[tokio::test]
async fn forward_without_the_original_answers_502_forward_original_unavailable() {
    let factory = Arc::new(FakeProviderFactory::new(FakeOutcome::succeeds()));
    factory.raw_script(vec![Err(ProviderError::Protocol("no-original".to_owned()))]);
    let (server, _fixtures) =
        TestServer::spawn_with_provider("r3-send-forward-missing", factory.clone()).await;
    prepare_account(&server);
    let client = http::client();

    let observed = post(
        &client,
        &server,
        &format!("/api/messages/{REMOTE}/forward?accountId={ACCOUNT_A}"),
        &json!({ "to": ["bob@example.invalid"], "body": "FYI" }),
    )
    .await;
    assert_eq!(observed.status, 502, "{:?}", observed.body);
    assert_eq!(
        observed.body["error"],
        json!("forward-original-unavailable")
    );
    assert!(factory.send_calls().is_empty());
}

/// The production adapter's own contract: SMTP carries the message, and the
/// **same bytes** are appended to the account's Sent folder.
///
/// This is the composition the fake cannot check: two protocols, two sessions,
/// one message. If the append carried different bytes, the recipient's copy
/// and the sender's Sent folder would disagree - and the Sent folder is what
/// the user checks after a send.
#[tokio::test]
async fn the_production_adapter_sends_by_smtp_and_appends_the_same_bytes_to_sent() {
    use base64::Engine as _;
    use lagoon_api::provider::lagoon_mail::LagoonMailFactory;
    use lagoon_api::provider::{OutgoingMail, ProviderFactory};
    use lagoon_mail::transport::Transport;
    use support::scripted_transport::ScriptedTransport;

    let transport = ScriptedTransport::new();
    // The SMTP session.
    transport.enqueue_lines(&[
        "220 smtp.example.test ESMTP",
        "250-smtp.example.test",
        "250 AUTH PLAIN",
        "235 2.7.0 accepted",
        "250 2.1.0 sender ok",
        "250 2.1.5 recipient ok",
        "354 go ahead",
        "250 2.0.0 queued",
        "221 2.0.0 bye",
    ]);
    // The IMAP session that appends it to Sent.
    transport.enqueue_lines(&[
        "* OK [CAPABILITY IMAP4rev1] ready",
        "A0001 OK AUTHENTICATE completed",
        "* CAPABILITY IMAP4rev1",
        "A0002 OK CAPABILITY completed",
        "* LIST (\\HasNoChildren) \"/\" \"INBOX\"",
        "* LIST (\\Sent \\HasNoChildren) \"/\" \"Sent Messages\"",
        "A0003 OK LIST completed",
        "+ Ready for literal data",
        "A0004 OK APPEND completed",
    ]);

    let handle = transport.handle();
    let make: Arc<dyn Fn() -> Box<dyn Transport> + Send + Sync> =
        Arc::new(move || Box::new(handle.clone()));
    let provider = LagoonMailFactory::with_transport(make)
        .make_send(&ImapCredentials::new("me@example.invalid", "auth-code"))
        .expect("send provider");

    let sent = provider
        .send(OutgoingMail {
            from_email: "me@example.invalid".to_owned(),
            to: vec!["bob@example.invalid".to_owned()],
            subject: "Hi".to_owned(),
            body: "Hello there".to_owned(),
            ..OutgoingMail::default()
        })
        .await
        .expect("sent");
    let message_id = sent.provider_message_id.expect("message id");
    assert!(message_id.starts_with('<'), "{message_id}");
    assert!(message_id.ends_with("@lagoon>"), "{message_id}");

    let writes = transport.writes_text();
    assert!(
        writes.contains("MAIL FROM:<me@example.invalid>"),
        "{writes}"
    );
    assert!(writes.contains("RCPT TO:<bob@example.invalid>"), "{writes}");
    assert!(
        writes.contains("APPEND \"Sent Messages\""),
        "the sent copy must land in the Sent folder: {writes}"
    );
    // Both payloads carry the same body. The builder base64-encodes it.
    let body = base64::engine::general_purpose::STANDARD.encode("Hello there");
    assert_eq!(
        writes.matches(&body).count(),
        2,
        "SMTP and the Sent copy must carry the same message: {writes}"
    );
}

/// The send writer and the audit readers must agree on the seam between them.
///
/// Two failures this pins, both silent: a status the readers do not know (the
/// row exists, no history query returns it) and a `remoteId` holding the new
/// Message-ID instead of the message being answered (the "already replied"
/// signal can never match an inbox row). Neither causes an error anywhere.
#[tokio::test]
async fn a_reply_is_history_against_the_message_it_answers() {
    let factory = Arc::new(FakeProviderFactory::new(FakeOutcome::succeeds()));
    factory.send_script(vec![Ok(SentMail {
        provider_message_id: Some("<audit-reply@lagoon>".to_owned()),
    })]);
    let (server, _fixtures) =
        TestServer::spawn_with_provider("r3-send-audit", factory.clone()).await;
    prepare_account(&server);
    let client = http::client();

    let observed = post(
        &client,
        &server,
        &format!("/api/messages/{REMOTE}/send?accountId={ACCOUNT_A}"),
        &json!({ "body": "answering", "requestId": REQUEST_ID }),
    )
    .await;
    assert_eq!(observed.status, 200, "{:?}", observed.body);

    // The row the writer produced: the status the readers test, and the
    // message it answers.
    let connection = open_read_write(&server.db_path);
    let (status, remote_id): (Option<String>, Option<String>) = connection
        .query_row(
            "SELECT json_extract(payload, '$.status'), json_extract(payload, '$.remoteId')
             FROM ai_actions WHERE account_id = ? AND kind = 'send' LIMIT 1",
            rusqlite::params![uuid_bytes(ACCOUNT_A)],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("audit row");
    assert_eq!(
        status.as_deref(),
        Some("sent"),
        "the one status every history reader treats as delivered"
    );
    assert_eq!(
        remote_id.as_deref(),
        Some(REMOTE),
        "the audit names the message it answers, not the outgoing Message-ID"
    );

    // Reader 1: the audit log.
    let actions = http::request(
        &client,
        "GET",
        &format!("{}/api/actions?accountId={ACCOUNT_A}", server.base_url),
        &server.auth_headers(),
    )
    .await;
    assert_eq!(actions.status, 200, "{:?}", actions.body);
    let shown = actions.body["actions"]
        .as_array()
        .expect("actions array")
        .iter()
        .any(|row| row["kind"] == json!("send"));
    assert!(
        shown,
        "a delivered send is history, so /api/actions must list it: {}",
        actions.body
    );

    // Reader 2: the briefing's "already replied" signal.
    let account = Uuid::parse_strict(ACCOUNT_A).expect("uuid");
    let replied =
        lagoon_api::store::actions::replied_remote_ids(&connection, account).expect("replied ids");
    assert!(
        replied.contains(REMOTE),
        "the briefing cannot mark the mail as replied; it has {replied:?}"
    );

    // Reader 3: the time-saved report counts a send as an action.
    let since = lagoon_api::timefmt::Timestamp::from_millis(0);
    let events = lagoon_api::store::actions::time_saved_events(&connection, account, since)
        .expect("time saved");
    assert!(
        events.iter().any(|(kind, _)| kind == "send"),
        "a delivered send must count toward time saved: {events:?}"
    );
}

/// A claim left behind by a crash must not wedge that requestId forever.
///
/// The web client deliberately reuses the same requestId after an `inflight`
/// outcome, so a permanent 409 means the user can never send that mail again.
#[tokio::test]
async fn an_expired_claim_is_taken_over_so_the_mail_can_be_sent() {
    let factory = Arc::new(FakeProviderFactory::new(FakeOutcome::succeeds()));
    factory.send_script(vec![Ok(SentMail {
        provider_message_id: Some("<reclaimed@lagoon>".to_owned()),
    })]);
    let (server, _fixtures) =
        TestServer::spawn_with_provider("r3-send-lease", factory.clone()).await;
    prepare_account(&server);

    // What a kill between the claim and the SMTP answer leaves behind: a
    // pending row whose claim is older than the lease.
    let stale = lagoon_api::timefmt::now().millis() - 60 * 60 * 1000;
    let connection = open_read_write(&server.db_path);
    connection
        .execute(
            "INSERT INTO ai_actions (account_id, kind, payload) VALUES (?1, 'send', ?2)",
            rusqlite::params![
                uuid_bytes(ACCOUNT_A),
                json!({"requestId": REQUEST_ID, "status": "pending", "claimedAt": stale})
                    .to_string()
            ],
        )
        .expect("stale claim");
    drop(connection);

    let client = http::client();
    let observed = post(
        &client,
        &server,
        &format!("/api/compose/send?accountId={ACCOUNT_A}"),
        &json!({
            "to": "bob@example.invalid",
            "subject": "After the crash",
            "body": "again",
            "requestId": REQUEST_ID,
        }),
    )
    .await;
    assert_eq!(
        observed.status, 200,
        "an expired claim must not block the retry: {:?}",
        observed.body
    );
    assert_eq!(factory.send_calls().len(), 1, "the retry is the delivery");
}
