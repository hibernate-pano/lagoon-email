//! R3.3: the account lifecycle routes over the provider seam.
//!
//! Every branch runs against FakeProvider, so the whole status matrix is
//! covered without a mail server. The one real-crypto assertion is that the
//! stored credential blob is the bare AES-GCM format v3 reads (see token.rs for
//! the CryptoKit-produced vector).

mod support;

use std::sync::Arc;

use serde_json::{json, Value};

use lagoon_api::provider::fake::{FakeOutcome, FakeProviderFactory};
use lagoon_api::provider::{MailChangeSet, ProviderFactory, NoProviderFactory};
use lagoon_api::token::ImapCredentials;
use lagoon_api::uuid::Uuid;
use lagoon_api::wire::MailCapabilities;

use support::http;
use support::server::{open_read_write, token_key, TestServer};

fn uuid_bytes(raw: &str) -> Vec<u8> {
    Uuid::parse_strict(raw).expect("uuid").as_bytes().to_vec()
}

async fn post_json(
    client: &http::HttpClient,
    url: &str,
    headers: &[(String, String)],
    body: &Value,
) -> http::Observed {
    http::request_with_body(client, "POST", url, headers, body.to_string().as_bytes()).await
}

fn tri_state_capabilities() -> MailCapabilities {
    MailCapabilities {
        archive_folder: Some(true),
        idle: true,
        move_supported: false,
        server_snippet: false,
        uidplus: Some(true),
        sent_folder: Some(false),
        trash_folder: None,
        archive_folder_name: Some("Archive".to_owned()),
    }
}

#[tokio::test]
async fn connect_creates_the_account_and_seals_its_credentials() {
    let factory = Arc::new(FakeProviderFactory::new(FakeOutcome::with_capabilities(
        tri_state_capabilities(),
    )));
    // The connect route now starts the account's sync loop, and its first
    // round runs while the response is in flight: script a benign round so
    // the assertions on stored state are not racing a failing pull.
    factory.pull_rounds(vec![Ok(MailChangeSet::default())]);
    let (server, _fixtures) = TestServer::spawn_with_provider("r3-connect", factory.clone()).await;
    let client = http::client();
    let auth = server.auth_headers();

    let observed = post_json(
        &client,
        &format!("{}/api/accounts/imap", server.base_url),
        &auth,
        &json!({
            "provider": "qq",
            "email": "  connect@example.invalid \n",
            "authCode": "  auth-code-123 \n",
        }),
    )
    .await;
    assert_eq!(observed.status, 201, "{:?}", observed.body);
    assert_eq!(observed.body["email"], json!("connect@example.invalid"));
    assert_eq!(observed.body["provider"], json!("qq"));
    assert_eq!(observed.body["isActive"], json!(true));
    assert_eq!(observed.body["unreadCount"], json!(0));
    assert_eq!(observed.body["syncHealth"]["status"], json!("ok"));
    // Tri-state capabilities: archiveFolder true, sentFolder false,
    // trashFolder unknown (an absent key, not false).
    assert_eq!(observed.body["capabilities"]["archiveFolder"], json!(true));
    assert_eq!(observed.body["capabilities"]["sentFolder"], json!(false));
    assert!(observed.body["capabilities"].get("trashFolder").is_none());
    assert_eq!(observed.body["capabilities"]["idle"], json!(true));

    // The probe saw the *submitted* credentials, trimmed. The connect route
    // also starts the sync loop, whose round builds its own provider from the
    // stored credentials - so at least two makes, all the same identity.
    let calls = factory.calls().all();
    assert!(calls.len() >= 1);
    assert!(calls.iter().all(|call| {
        call.username == "connect@example.invalid" && call.auth_code == "auth-code-123"
    }));

    // Stored blob is bare AES-GCM (no lgb1:), and it opens with the token key.
    let connection = open_read_write(&server.db_path);
    let (blob, capabilities, sync_state): (Vec<u8>, String, String) = connection
        .query_row(
            "SELECT credentials, capabilities, sync_state FROM accounts WHERE email = ?1",
            ["connect@example.invalid"],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .expect("account row");
    assert!(blob.len() > 28);
    assert_ne!(&blob[..4], b"lgb1");
    let credentials = ImapCredentials::open(&token_key(), &blob).expect("open blob");
    assert_eq!(credentials.username, "connect@example.invalid");
    assert_eq!(credentials.auth_code, "auth-code-123");
    // capabilities JSON keeps the three-state representation.
    let stored: Value = serde_json::from_str(&capabilities).expect("capabilities json");
    assert_eq!(stored["archiveFolder"], json!(true));
    assert_eq!(stored["sentFolder"], json!(false));
    assert!(stored.get("trashFolder").is_none());
    // sync_state recorded the resolved archive folder.
    let sync: Value = serde_json::from_str(&sync_state).expect("sync state");
    assert_eq!(sync["archiveFolder"], json!("Archive"));
}

#[tokio::test]
async fn the_status_matrix_matches_v3() {
    let factory = Arc::new(FakeProviderFactory::new(FakeOutcome::AuthFails));
    let (server, _fixtures) = TestServer::spawn_with_provider("r3-matrix", factory).await;
    let client = http::client();
    let auth = server.auth_headers();
    let url = format!("{}/api/accounts/imap", server.base_url);

    // An empty body decodes as nothing, so v3 reports missing-field (measured
    // against the sidecar, 2026-10-29); missing-body is for a stream failure.
    let empty = http::request_with_body(&client, "POST", &url, &auth, b"").await;
    assert_eq!(empty.status, 400);
    assert_eq!(empty.body, json!({"error": "missing-field"}));

    let bad_json = http::request_with_body(&client, "POST", &url, &auth, b"{not json").await;
    assert_eq!(bad_json.status, 400);
    assert_eq!(bad_json.body, json!({"error": "missing-field"}));

    for body in [
        json!({"provider": "qq", "email": "x@example.invalid"}),
        json!({"provider": "qq", "email": "", "authCode": "c"}),
        json!({"provider": "qq", "email": "x@example.invalid", "authCode": "   "}),
        json!({"provider": "gmail", "email": "x@example.invalid", "authCode": "c"}),
    ] {
        let observed = post_json(&client, &url, &auth, &body).await;
        assert_eq!(observed.status, 400, "{body}: {:?}", observed.body);
        assert_eq!(observed.body, json!({"error": "missing-field"}));
    }

    let unauthorized = post_json(
        &client,
        &url,
        &auth,
        &json!({"provider": "qq", "email": "x@example.invalid", "authCode": "c"}),
    )
    .await;
    assert_eq!(unauthorized.status, 401);
    assert_eq!(unauthorized.body, json!({"error": "imap-auth-failed"}));
}

#[tokio::test]
async fn unreachable_and_missing_provider_are_distinct() {
    let factory = Arc::new(FakeProviderFactory::new(FakeOutcome::Unreachable(
        "dns".to_owned(),
    )));
    let (server, _fixtures) = TestServer::spawn_with_provider("r3-unreachable", factory).await;
    let client = http::client();
    let auth = server.auth_headers();
    let observed = post_json(
        &client,
        &format!("{}/api/accounts/imap", server.base_url),
        &auth,
        &json!({"provider": "qq", "email": "u@example.invalid", "authCode": "c"}),
    )
    .await;
    assert_eq!(observed.status, 502);
    assert_eq!(observed.body, json!({"error": "imap-unreachable"}));

    // No provider at all is 503, not 502: the server is not telling the user
    // their mailbox is down.
    let (bare, _fixtures) = TestServer::spawn_with_provider(
        "r3-no-provider",
        Arc::new(NoProviderFactory) as Arc<dyn ProviderFactory>,
    )
    .await;
    let observed = post_json(
        &client,
        &format!("{}/api/accounts/imap", bare.base_url),
        &auth,
        &json!({"provider": "qq", "email": "u@example.invalid", "authCode": "c"}),
    )
    .await;
    assert_eq!(observed.status, 503);
    assert_eq!(observed.body, json!({"error": "provider-not-configured"}));
}

#[tokio::test]
async fn healthy_account_conflicts_and_reauthentication_replaces() {
    let factory = Arc::new(FakeProviderFactory::new(FakeOutcome::with_capabilities(
        tri_state_capabilities(),
    )));
    // The connect route starts this account's sync loop; keep the background
    // rounds benign so the health assertions below are deterministic.
    factory.pull_rounds(vec![Ok(MailChangeSet::default())]);
    let (server, _fixtures) = TestServer::spawn_with_provider("r3-reattach", factory.clone()).await;
    let client = http::client();
    let auth = server.auth_headers();
    let url = format!("{}/api/accounts/imap", server.base_url);
    let account = "aaaaaaaa-1111-4111-8111-111111111111";

    // A healthy row answers 409 before the probe is even built.
    {
        let connection = open_read_write(&server.db_path);
        connection
            .execute(
                "INSERT INTO accounts (id, provider, oauth_user, email, sync_status, capabilities)
                 VALUES (?, 'qq', 'health@example.invalid', 'health@example.invalid', 'ok', '{}')",
                rusqlite::params![uuid_bytes(account)],
            )
            .expect("healthy account");
    }
    let conflict = post_json(
        &client,
        &url,
        &auth,
        &json!({"provider": "qq", "email": "health@example.invalid", "authCode": "ignored"}),
    )
    .await;
    assert_eq!(conflict.status, 409);
    assert_eq!(conflict.body, json!({"error": "account-exists"}));
    assert!(factory.calls().all().is_empty(), "no probe for a healthy account");

    // A parked row is re-authenticated in place: same id, new code, health ok.
    {
        let connection = open_read_write(&server.db_path);
        connection
            .execute(
                "UPDATE accounts SET sync_status = 'needsReconnect', last_sync_error = 'expired'",
                [],
            )
            .expect("park account");
    }
    let reauth = post_json(
        &client,
        &url,
        &auth,
        &json!({"provider": "qq", "email": "health@example.invalid", "authCode": "fresh-code"}),
    )
    .await;
    assert_eq!(reauth.status, 201, "{:?}", reauth.body);
    assert_eq!(reauth.body["id"], json!(account));
    assert_eq!(reauth.body["syncHealth"]["status"], json!("ok"));
    assert!(reauth.body["syncHealth"].get("lastError").is_none());
    let connection = open_read_write(&server.db_path);
    let (blob, status): (Vec<u8>, String) = connection
        .query_row(
            "SELECT credentials, sync_status FROM accounts WHERE id = ?1",
            rusqlite::params![uuid_bytes(account)],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("row");
    assert_eq!(status, "ok");
    assert_eq!(
        ImapCredentials::open(&token_key(), &blob).expect("open").auth_code,
        "fresh-code"
    );
}

#[tokio::test]
async fn a_failed_reauthentication_leaves_the_row_untouched() {
    let factory = Arc::new(FakeProviderFactory::new(FakeOutcome::AuthFails));
    let (server, _fixtures) = TestServer::spawn_with_provider("r3-touch", factory).await;
    let client = http::client();
    let auth = server.auth_headers();
    let account = "bbbbbbbb-2222-4222-8222-222222222222";
    let original = token_key();
    let original_blob = ImapCredentials::new("parked@example.invalid", "old-code")
        .seal(&original)
        .expect("seal");
    {
        let connection = open_read_write(&server.db_path);
        connection
            .execute(
                "INSERT INTO accounts (id, provider, oauth_user, email, credentials, sync_status)
                 VALUES (?, 'qq', 'parked@example.invalid', 'parked@example.invalid', ?, 'needsReconnect')",
                rusqlite::params![uuid_bytes(account), original_blob],
            )
            .expect("parked account");
    }
    let observed = post_json(
        &client,
        &format!("{}/api/accounts/imap", server.base_url),
        &auth,
        &json!({"provider": "qq", "email": "parked@example.invalid", "authCode": "rejected"}),
    )
    .await;
    assert_eq!(observed.status, 401);
    let connection = open_read_write(&server.db_path);
    let (blob, status): (Vec<u8>, String) = connection
        .query_row(
            "SELECT credentials, sync_status FROM accounts WHERE id = ?1",
            rusqlite::params![uuid_bytes(account)],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("row");
    assert_eq!(blob, original_blob, "credentials must not move on a failed probe");
    assert_eq!(status, "needsReconnect");
}

#[tokio::test]
async fn activate_switches_and_delete_cascades() {
    let (server, _fixtures) = TestServer::spawn("r3-lifecycle").await;
    let client = http::client();
    let auth = server.auth_headers();
    let first = "aaaaaaaa-1111-4111-8111-111111111111";
    let second = "bbbbbbbb-2222-4222-8222-222222222222";
    {
        let connection = open_read_write(&server.db_path);
        for (id, email, active) in [(first, "one@example.invalid", 1), (second, "two@example.invalid", 0)] {
            connection
                .execute(
                    "INSERT INTO accounts (id, provider, oauth_user, email, is_active)
                     VALUES (?, 'qq', ?, ?, ?)",
                    rusqlite::params![uuid_bytes(id), email, email, active],
                )
                .expect("account");
        }
        connection
            .execute(
                "INSERT INTO message_headers (id, account_id, remote_id, thread_id, from_address, received_at)
                 VALUES (?, ?, 'msg-1', 'thread-1', 'a@b', '2025-01-01 00:00:00.000')",
                rusqlite::params![uuid_bytes("33333333-3333-4333-8333-333333333333"), uuid_bytes(second)],
            )
            .expect("header");
        connection
            .execute(
                "INSERT INTO message_bodies (account_id, remote_id, body_cipher) VALUES (?, 'msg-1', 'x')",
                rusqlite::params![uuid_bytes(second)],
            )
            .expect("body");
    }

    let activated = http::request(
        &client,
        "POST",
        &format!("{}/api/accounts/{second}/activate", server.base_url),
        &auth,
    )
    .await;
    assert_eq!(activated.status, 204);
    assert_eq!(activated.body_kind, "empty");
    let connection = open_read_write(&server.db_path);
    let active: Vec<String> = connection
        .prepare("SELECT email FROM accounts WHERE is_active = TRUE")
        .expect("prepare")
        .query_map([], |row| row.get(0))
        .expect("query")
        .map(|row| row.expect("row"))
        .collect();
    assert_eq!(active, vec!["two@example.invalid".to_owned()]);

    let unknown = http::request(
        &client,
        "POST",
        &format!("{}/api/accounts/99999999-9999-4999-8999-999999999999/activate", server.base_url),
        &auth,
    )
    .await;
    assert_eq!(unknown.status, 404);
    assert_eq!(unknown.body, json!({"error": "unknown-account"}));

    let malformed = http::request(
        &client,
        "POST",
        &format!("{}/api/accounts/not-a-uuid/activate", server.base_url),
        &auth,
    )
    .await;
    assert_eq!(malformed.status, 404, "v3 says unknown-account for a bad uuid");
    assert_eq!(malformed.body, json!({"error": "unknown-account"}));

    // Delete the active account: cascade removes its header and body, and
    // reconcileActive promotes the remaining account.
    let deleted = http::request(
        &client,
        "DELETE",
        &format!("{}/api/accounts/{second}", server.base_url),
        &auth,
    )
    .await;
    assert_eq!(deleted.status, 204);
    let connection = open_read_write(&server.db_path);
    // The seed store already carries account A; deleting `second` leaves two.
    let remaining: i64 = connection
        .query_row("SELECT COUNT(*) FROM accounts", [], |row| row.get(0))
        .expect("count");
    assert_eq!(remaining, 2);
    for table in ["message_headers", "message_bodies"] {
        let count: i64 = connection
            .query_row(
                &format!("SELECT COUNT(*) FROM {table} WHERE account_id = ?1"),
                rusqlite::params![uuid_bytes(second)],
                |row| row.get(0),
            )
            .expect("count");
        assert_eq!(count, 0, "{table} should cascade");
    }
    let active: Vec<String> = connection
        .prepare("SELECT email FROM accounts WHERE is_active = TRUE")
        .expect("prepare")
        .query_map([], |row| row.get(0))
        .expect("query")
        .map(|row| row.expect("row"))
        .collect();
    assert_eq!(active, vec!["one@example.invalid".to_owned()]);

    let missing = http::request(
        &client,
        "DELETE",
        &format!("{}/api/accounts/{second}", server.base_url),
        &auth,
    )
    .await;
    assert_eq!(missing.status, 404);
    assert_eq!(missing.body, json!({"error": "unknown-account"}));
}
