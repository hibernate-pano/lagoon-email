//! The attachment download route.
//!
//! The contract has always promised `GET /api/messages/{remoteId}/attachments/
//! {attachmentId}`; the router had no such route, so a mail with a PDF showed
//! a file chip the user could not open. These tests pin the answer matrix:
//!
//! * 200 with the original bytes, the original MIME type and a filename;
//! * 404 `attachment-not-found` when the message is there and the part is not;
//! * 410 `message-gone` when the message itself is gone;
//! * 413 `attachment-too-large` when the bytes are over the cap;
//! * 404 `unknown-account` before any provider work;
//! * 503 `provider-not-configured` when the account has no readable
//!   credentials.

mod support;

use std::sync::Arc;

use base64::Engine as _;
use serde_json::json;

use lagoon_api::provider::fake::{FakeOutcome, FakeProviderFactory};
use lagoon_api::provider::{MailAttachment, ProviderError};
use lagoon_api::token::ImapCredentials;
use lagoon_api::uuid::Uuid;

use support::http;
use support::server::{open_read_write, token_key, TestServer};

const ACCOUNT_A: &str = "11111111-1111-4111-8111-111111111111";
const UNKNOWN_ACCOUNT: &str = "99999999-9999-4999-8999-999999999999";
const REMOTE: &str = "fixture-msg-1";

fn uuid_bytes(raw: &str) -> Vec<u8> {
    Uuid::parse_strict(raw).expect("uuid").as_bytes().to_vec()
}

/// Re-seal account A's credentials with the test token key, so a body provider
/// can actually be built.
fn prepare_account(server: &TestServer) {
    let connection = open_read_write(&server.db_path);
    let sealed = ImapCredentials::new("contract-fixture@example.invalid", "auth-code")
        .seal(&token_key())
        .expect("seal");
    connection
        .execute(
            "UPDATE accounts SET credentials = ? WHERE id = ?",
            rusqlite::params![sealed, uuid_bytes(ACCOUNT_A)],
        )
        .expect("prepare account");
}

async fn get(client: &http::HttpClient, server: &TestServer, path: &str) -> http::Observed {
    http::request(
        client,
        "GET",
        &format!("{}{path}", server.base_url),
        &server.auth_headers(),
    )
    .await
}

fn attachment_path(attachment_id: &str) -> String {
    format!("/api/messages/{REMOTE}/attachments/{attachment_id}?accountId={ACCOUNT_A}")
}

#[tokio::test]
async fn an_attachment_is_answered_with_its_bytes_type_and_filename() {
    let factory = Arc::new(FakeProviderFactory::new(FakeOutcome::succeeds()));
    factory.attachment_script(vec![Ok(Some(MailAttachment {
        filename: Some("会议纪要.pdf".to_owned()),
        mime_type: "application/pdf".to_owned(),
        data: b"%PDF-1.4 body".to_vec(),
    }))]);
    let (server, _fixtures) =
        TestServer::spawn_with_provider("r5-attachments-ok", factory.clone()).await;
    prepare_account(&server);
    let client = http::client();

    let observed = get(&client, &server, &attachment_path("1.3")).await;
    assert_eq!(observed.status, 200, "{:?}", observed.body);
    assert_eq!(observed.content_type, "application/pdf");
    assert_eq!(
        observed.body,
        json!(String::from_utf8_lossy(b"%PDF-1.4 body").into_owned())
    );
}

#[tokio::test]
async fn a_part_that_is_not_in_the_message_answers_404_attachment_not_found() {
    let factory = Arc::new(FakeProviderFactory::new(FakeOutcome::succeeds()));
    factory.attachment_script(vec![Ok(None)]);
    let (server, _fixtures) =
        TestServer::spawn_with_provider("r5-attachments-missing", factory.clone()).await;
    prepare_account(&server);
    let client = http::client();

    let observed = get(&client, &server, &attachment_path("9.9")).await;
    assert_eq!(observed.status, 404, "{:?}", observed.body);
    assert_eq!(observed.body["error"], json!("attachment-not-found"));
}

/// A message that no longer exists is not a missing part: the contract
/// promises 410 for it, and the reader treats the two differently.
#[tokio::test]
async fn a_gone_message_answers_410_message_gone() {
    let factory = Arc::new(FakeProviderFactory::new(FakeOutcome::succeeds()));
    factory.attachment_script(vec![Err(ProviderError::MessageGone)]);
    let (server, _fixtures) =
        TestServer::spawn_with_provider("r5-attachments-gone", factory.clone()).await;
    prepare_account(&server);
    let client = http::client();

    let observed = get(&client, &server, &attachment_path("1.3")).await;
    assert_eq!(observed.status, 410, "{:?}", observed.body);
    assert_eq!(observed.body["error"], json!("message-gone"));
}

#[tokio::test]
async fn an_attachment_over_the_cap_answers_413_attachment_too_large() {
    let factory = Arc::new(FakeProviderFactory::new(FakeOutcome::succeeds()));
    factory.attachment_script(vec![Err(ProviderError::TooLarge(
        "attachment-too-large".to_owned(),
    ))]);
    let (server, _fixtures) =
        TestServer::spawn_with_provider("r5-attachments-large", factory.clone()).await;
    prepare_account(&server);
    let client = http::client();

    let observed = get(&client, &server, &attachment_path("1.3")).await;
    assert_eq!(observed.status, 413, "{:?}", observed.body);
    assert_eq!(observed.body["error"], json!("attachment-too-large"));
}

#[tokio::test]
async fn an_unknown_account_answers_404_before_any_fetch() {
    let factory = Arc::new(FakeProviderFactory::new(FakeOutcome::succeeds()));
    factory.attachment_script(vec![Ok(Some(MailAttachment {
        filename: None,
        mime_type: "application/pdf".to_owned(),
        data: b"x".to_vec(),
    }))]);
    let (server, _fixtures) =
        TestServer::spawn_with_provider("r5-attachments-unknown-account", factory.clone()).await;
    prepare_account(&server);
    let client = http::client();

    let observed = get(
        &client,
        &server,
        &format!("/api/messages/{REMOTE}/attachments/1.3?accountId={UNKNOWN_ACCOUNT}"),
    )
    .await;
    assert_eq!(observed.status, 404, "{:?}", observed.body);
    assert_eq!(observed.body["error"], json!("unknown-account"));
    assert!(
        factory.attachment_calls().is_empty(),
        "no provider work before the account gate"
    );
}

#[tokio::test]
async fn an_account_without_readable_credentials_answers_503() {
    let factory = Arc::new(FakeProviderFactory::new(FakeOutcome::succeeds()));
    factory.attachment_script(vec![Ok(Some(MailAttachment {
        filename: None,
        mime_type: "application/pdf".to_owned(),
        data: b"x".to_vec(),
    }))]);
    let (server, _fixtures) =
        TestServer::spawn_with_provider("r5-attachments-unconfigured", factory.clone()).await;
    // Deliberately NOT calling prepare_account: the seeded blob is unreadable.
    let client = http::client();

    let observed = get(&client, &server, &attachment_path("1.3")).await;
    assert_eq!(observed.status, 503, "{:?}", observed.body);
    assert_eq!(observed.body["error"], json!("provider-not-configured"));
    assert!(
        factory.attachment_calls().is_empty(),
        "no provider, no fetch"
    );
}

/// The route must not fetch a part whose id is not a part path: the id comes
/// from the URL, and a value that can close the bracket can also inject an
/// IMAP command.
#[tokio::test]
async fn a_malformed_attachment_id_is_refused_before_any_fetch() {
    let factory = Arc::new(FakeProviderFactory::new(FakeOutcome::succeeds()));
    factory.attachment_script(vec![Ok(Some(MailAttachment {
        filename: None,
        mime_type: "application/pdf".to_owned(),
        data: b"x".to_vec(),
    }))]);
    let (server, _fixtures) =
        TestServer::spawn_with_provider("r5-attachments-bad-id", factory.clone()).await;
    prepare_account(&server);
    let client = http::client();

    // Percent-encoded `1.2]`: the router decodes it, and the route must refuse
    // it before it reaches an IMAP command.
    let observed = get(&client, &server, &attachment_path("1.2%5D")).await;
    assert_eq!(observed.status, 400, "{:?}", observed.body);
    assert_eq!(observed.body["error"], json!("malformed-attachmentId"));
    assert!(
        factory.attachment_calls().is_empty(),
        "a malformed id never reaches the provider"
    );
}

// ------------------------------------------------------------ inline images --

use lagoon_api::provider::MailInlineImage;

#[tokio::test]
async fn inline_images_come_back_base64_under_lowercased_content_ids() {
    let factory = Arc::new(FakeProviderFactory::new(FakeOutcome::succeeds()));
    factory.inline_images_script(vec![Ok(vec![MailInlineImage {
        // The sender wrote `<Pic1@Example.com>`; the reader looks up
        // `cid:pic1@example.com` and must find it.
        content_id: "Pic1@Example.com".to_owned(),
        mime_type: "image/png".to_owned(),
        data: b"\x89PNG\r\n\x1a\n".to_vec(),
    }])]);
    let (server, _fixtures) =
        TestServer::spawn_with_provider("r5-inline-images", factory.clone()).await;
    prepare_account(&server);
    let client = http::client();

    let observed = get(
        &client,
        &server,
        &format!("/api/messages/{REMOTE}/inline-images?accountId={ACCOUNT_A}"),
    )
    .await;
    assert_eq!(observed.status, 200, "{:?}", observed.body);
    assert_eq!(
        observed.body["images"]["pic1@example.com"],
        json!(base64::engine::general_purpose::STANDARD.encode(b"\x89PNG\r\n\x1a\n"))
    );
}

#[tokio::test]
async fn inline_images_of_a_gone_message_answer_410() {
    let factory = Arc::new(FakeProviderFactory::new(FakeOutcome::succeeds()));
    factory.inline_images_script(vec![Err(ProviderError::MessageGone)]);
    let (server, _fixtures) =
        TestServer::spawn_with_provider("r5-inline-images-gone", factory.clone()).await;
    prepare_account(&server);
    let client = http::client();

    let observed = get(
        &client,
        &server,
        &format!("/api/messages/{REMOTE}/inline-images?accountId={ACCOUNT_A}"),
    )
    .await;
    assert_eq!(observed.status, 410, "{:?}", observed.body);
    assert_eq!(observed.body["error"], json!("message-gone"));
}

#[tokio::test]
async fn inline_images_are_capped_at_forty_pictures() {
    let factory = Arc::new(FakeProviderFactory::new(FakeOutcome::succeeds()));
    let images: Vec<MailInlineImage> = (0..50)
        .map(|index| MailInlineImage {
            content_id: format!("pic{index}@example.com"),
            mime_type: "image/png".to_owned(),
            data: b"\x89PNG".to_vec(),
        })
        .collect();
    factory.inline_images_script(vec![Ok(images)]);
    let (server, _fixtures) =
        TestServer::spawn_with_provider("r5-inline-images-cap", factory.clone()).await;
    prepare_account(&server);
    let client = http::client();

    let observed = get(
        &client,
        &server,
        &format!("/api/messages/{REMOTE}/inline-images?accountId={ACCOUNT_A}"),
    )
    .await;
    assert_eq!(observed.status, 200, "{:?}", observed.body);
    let images = observed.body["images"].as_object().expect("an object");
    assert_eq!(images.len(), 40);
}
