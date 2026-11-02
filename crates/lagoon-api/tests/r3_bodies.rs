//! R3: the body route must fetch a body it does not have.
//!
//! The regression this pins: `write::save_body` had zero callers and
//! `lagoon-mail::fetch_body` was only reached from lagoon-mail's own tests, so
//! the store only ever contained headers. A real mailbox showed the symptom
//! exactly: 413 headers, 0 bodies - opening any message answered 503.

mod support;

use std::sync::Arc;

use serde_json::json;

use lagoon_api::provider::fake::{FakeOutcome, FakeProviderFactory};
use lagoon_api::provider::{MailBody, ProviderError};
use lagoon_api::token::ImapCredentials;
use lagoon_api::uuid::Uuid;

use support::http;
use support::server::{open_read_write, token_key, TestServer};

const ACCOUNT_A: &str = "11111111-1111-4111-8111-111111111111";
const UNKNOWN_ACCOUNT: &str = "99999999-9999-4999-8999-999999999999";
/// Seeded with a header and no body (the `body.provider-unconfigured` fixture).
const REMOTE: &str = "fixture-msg-1";

fn uuid_bytes(raw: &str) -> Vec<u8> {
    Uuid::parse_strict(raw).expect("uuid").as_bytes().to_vec()
}

/// Re-seal account A's credentials with the test token key, so a body provider
/// can actually be built. Without this the blob is unreadable and the route
/// answers 503 before any provider call.
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

fn stored_body_count(server: &TestServer) -> i64 {
    let connection = open_read_write(&server.db_path);
    connection
        .query_row(
            "SELECT count(*) FROM message_bodies WHERE account_id = ? AND remote_id = ?",
            rusqlite::params![uuid_bytes(ACCOUNT_A), REMOTE],
            |row| row.get(0),
        )
        .expect("body count")
}

fn fetched_body() -> MailBody {
    MailBody {
        text: "hello body".to_owned(),
        html: None,
        has_more: false,
        attachments: Vec::new(),
        to: Vec::new(),
        cc: Vec::new(),
    }
}

#[tokio::test]
async fn a_body_the_store_does_not_have_is_fetched_cached_and_answered() {
    let factory = Arc::new(FakeProviderFactory::new(FakeOutcome::succeeds()));
    factory.body_script(vec![Ok(fetched_body())]);
    let (server, _fixtures) =
        TestServer::spawn_with_provider("r3-bodies-fetch", factory.clone()).await;
    prepare_account(&server);
    let client = http::client();

    assert_eq!(stored_body_count(&server), 0);

    let observed = get(
        &client,
        &server,
        &format!("/api/messages/{REMOTE}/body?accountId={ACCOUNT_A}"),
    )
    .await;
    assert_eq!(observed.status, 200, "{:?}", observed.body);
    assert_eq!(observed.body["text"], json!("hello body"));
    assert_eq!(factory.body_calls(), 1);

    // The body is really stored, so the next open is a cache hit: the provider
    // script must not be touched again.
    assert_eq!(stored_body_count(&server), 1);
    let observed = get(
        &client,
        &server,
        &format!("/api/messages/{REMOTE}/body?accountId={ACCOUNT_A}"),
    )
    .await;
    assert_eq!(observed.status, 200, "{:?}", observed.body);
    assert_eq!(observed.body["text"], json!("hello body"));
    assert_eq!(factory.body_calls(), 1, "a cached body must not re-fetch");
}

#[tokio::test]
async fn a_body_fetch_failure_answers_502_and_caches_nothing() {
    let factory = Arc::new(FakeProviderFactory::new(FakeOutcome::succeeds()));
    factory.body_script(vec![Err(ProviderError::Unreachable("boom".to_owned()))]);
    let (server, _fixtures) =
        TestServer::spawn_with_provider("r3-bodies-unreachable", factory.clone()).await;
    prepare_account(&server);
    let client = http::client();

    let observed = get(
        &client,
        &server,
        &format!("/api/messages/{REMOTE}/body?accountId={ACCOUNT_A}"),
    )
    .await;
    assert_eq!(observed.status, 502, "{:?}", observed.body);
    assert_eq!(observed.body["error"], json!("provider-unreachable"));
    assert_eq!(stored_body_count(&server), 0);
}

/// The contract has always promised 410 `message-gone` for a body that no
/// longer exists; before this test the route folded every non-auth failure
/// into 502 `provider-unreachable`, misreporting a deleted message as an
/// outage.
#[tokio::test]
async fn a_gone_message_answers_410_message_gone_and_caches_nothing() {
    let factory = Arc::new(FakeProviderFactory::new(FakeOutcome::succeeds()));
    factory.body_script(vec![Err(ProviderError::MessageGone)]);
    let (server, _fixtures) =
        TestServer::spawn_with_provider("r3-bodies-gone", factory.clone()).await;
    prepare_account(&server);
    let client = http::client();

    let observed = get(
        &client,
        &server,
        &format!("/api/messages/{REMOTE}/body?accountId={ACCOUNT_A}"),
    )
    .await;
    assert_eq!(observed.status, 410, "{:?}", observed.body);
    assert_eq!(observed.body["error"], json!("message-gone"));
    assert_eq!(stored_body_count(&server), 0);
}

#[tokio::test]
async fn an_account_without_readable_credentials_answers_503() {
    let factory = Arc::new(FakeProviderFactory::new(FakeOutcome::succeeds()));
    factory.body_script(vec![Ok(fetched_body())]);
    let (server, _fixtures) =
        TestServer::spawn_with_provider("r3-bodies-unconfigured", factory.clone()).await;
    // Deliberately NOT calling prepare_account: the seeded blob is unreadable.
    let client = http::client();

    let observed = get(
        &client,
        &server,
        &format!("/api/messages/{REMOTE}/body?accountId={ACCOUNT_A}"),
    )
    .await;
    assert_eq!(observed.status, 503, "{:?}", observed.body);
    assert_eq!(observed.body["error"], json!("provider-not-configured"));
    assert_eq!(factory.body_calls(), 0, "no provider, no fetch");
}

#[tokio::test]
async fn an_unknown_account_answers_404_before_any_fetch() {
    let factory = Arc::new(FakeProviderFactory::new(FakeOutcome::succeeds()));
    factory.body_script(vec![Ok(fetched_body())]);
    let (server, _fixtures) =
        TestServer::spawn_with_provider("r3-bodies-unknown", factory.clone()).await;
    prepare_account(&server);
    let client = http::client();

    let observed = get(
        &client,
        &server,
        &format!("/api/messages/{REMOTE}/body?accountId={UNKNOWN_ACCOUNT}"),
    )
    .await;
    assert_eq!(observed.status, 404, "{:?}", observed.body);
    assert_eq!(observed.body["error"], json!("unknown-account"));
    assert_eq!(factory.body_calls(), 0);
}
