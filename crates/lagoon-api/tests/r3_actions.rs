//! R3.5a: the write paths over HTTP, against the FakeProviderFactory.
//!
//! The seeded fixture accounts carry unreadable credentials, so the setup
//! re-seals account A's blob with the test token key: without that, every
//! action route answers 503 provider-not-configured and nothing below the
//! gate can be exercised. Capabilities are rewritten per test to place the
//! gate exactly where the assertions need it.

mod support;

use rusqlite::OptionalExtension;
use std::sync::Arc;

use serde_json::{json, Value};

use lagoon_api::provider::fake::{FakeOutcome, FakeProviderFactory, FakeWriteOutcome};
use lagoon_api::provider::ProviderFactory;
use lagoon_api::token::ImapCredentials;

use support::http;
use support::server::{open_read_write, token_key, TestServer};

const ACCOUNT_A: &str = "11111111-1111-4111-8111-111111111111";
const REMOTE: &str = "fixture-msg-1";

fn all_caps_allowed() -> Value {
    json!({
        "archiveFolder": true, "idle": true, "move": true,
        "sentFolder": true, "serverSnippet": true, "trashFolder": true,
        "uidplus": true, "archiveFolderName": "Archive",
    })
}

fn all_caps_false() -> Value {
    json!({
        "archiveFolder": false, "idle": false, "move": false,
        "sentFolder": false, "serverSnippet": false, "trashFolder": false,
        "uidplus": false,
    })
}

/// Give account A readable credentials and the capability JSON the test wants.
fn prepare_account(server: &TestServer, capabilities: &Value) {
    let connection = open_read_write(&server.db_path);
    let sealed = ImapCredentials::new("contract-fixture@example.invalid", "auth-code")
        .seal(&token_key())
        .expect("seal");
    connection
        .execute(
            "UPDATE accounts SET credentials = ?, capabilities = ? WHERE id = ?",
            rusqlite::params![
                sealed,
                capabilities.to_string(),
                uuid_bytes(ACCOUNT_A)
            ],
        )
        .expect("prepare account");
}

fn uuid_bytes(raw: &str) -> Vec<u8> {
    use lagoon_api::uuid::Uuid;
    Uuid::parse_strict(raw).expect("uuid").as_bytes().to_vec()
}

async fn post(
    client: &http::HttpClient,
    server: &TestServer,
    path: &str,
    body: Option<&Value>,
) -> http::Observed {
    let headers = server.auth_headers();
    match body {
        Some(body) => {
            http::request_with_body(client, "POST", &format!("{}{path}", server.base_url), &headers, body.to_string().as_bytes()).await
        }
        None => http::request(client, "POST", &format!("{}{path}", server.base_url), &headers).await,
    }
}

fn flag(server: &TestServer, column: &str, remote_id: &str) -> Option<bool> {
    let connection = open_read_write(&server.db_path);
    if column == "is_pinned" {
        // Pinned lives in message_pins, not a header flag (v3 setPinnedSync).
        let found = connection
            .prepare(
                "SELECT 1 FROM message_pins WHERE account_id = ? AND remote_id = ? LIMIT 1",
            )
            .expect("prepare pins")
            .query_row(rusqlite::params![uuid_bytes(ACCOUNT_A), remote_id], |_| Ok(()))
            .optional()
            .expect("pins");
        return Some(found.is_some());
    }
    let sql = format!("SELECT {column} FROM message_headers WHERE account_id = ? AND remote_id = ?");
    let mut statement = connection.prepare(&sql).expect("prepare");
    statement
        .query_row(
            rusqlite::params![uuid_bytes(ACCOUNT_A), remote_id],
            |row| row.get::<_, Option<bool>>(0),
        )
        .expect("flag")
}

#[tokio::test]
async fn the_gate_answers_409_before_any_provider_call() {
    let factory = Arc::new(FakeProviderFactory::new(FakeOutcome::succeeds()));
    let (server, _fixtures) = TestServer::spawn_with_provider("r3-actions-gate", factory.clone()).await;
    prepare_account(&server, &all_caps_false());
    let client = http::client();

    let observed = post(&client, &server, &format!("/api/messages/{REMOTE}/archive?accountId={ACCOUNT_A}"), None).await;
    assert_eq!(observed.status, 409, "{:?}", observed.body);
    assert_eq!(observed.body["error"], json!("archive-unavailable"));
    // The gate runs before the provider is even built: no write calls.
    assert!(factory.write_calls().all().is_empty());

    let observed = post(&client, &server, &format!("/api/messages/{REMOTE}/purge?accountId={ACCOUNT_A}"), None).await;
    assert_eq!(observed.status, 409, "{:?}", observed.body);
    assert_eq!(observed.body["error"], json!("uidplus-missing"));

    let observed = post(&client, &server, &format!("/api/trash/empty?accountId={ACCOUNT_A}"), None).await;
    assert_eq!(observed.status, 409, "{:?}", observed.body);

    // Unknown account: 404 before anything else.
    let other = "99999999-9999-4999-8999-999999999999";
    let observed = post(&client, &server, &format!("/api/messages/{REMOTE}/archive?accountId={other}"), None).await;
    assert_eq!(observed.status, 404, "{:?}", observed.body);
    assert_eq!(observed.body["error"], json!("unknown-account"));
}

#[tokio::test]
async fn archive_runs_remote_then_flips_the_flag_and_audits() {
    let factory = Arc::new(FakeProviderFactory::new(FakeOutcome::succeeds()));
    factory.write_script(vec![FakeWriteOutcome::Ok]);
    let (server, _fixtures) = TestServer::spawn_with_provider("r3-actions-archive", factory.clone()).await;
    prepare_account(&server, &all_caps_allowed());
    let client = http::client();

    assert_eq!(flag(&server, "is_archived", REMOTE), Some(false));
    let observed = post(&client, &server, &format!("/api/messages/{REMOTE}/archive?accountId={ACCOUNT_A}"), None).await;
    assert_eq!(observed.status, 200, "{:?}", observed.body);
    assert_eq!(observed.body["ok"], json!(true));
    assert_eq!(observed.body["remote"], json!(true));
    let action_id = observed.body["actionId"].as_i64().expect("actionId");
    assert!(action_id > 0);
    assert_eq!(flag(&server, "is_archived", REMOTE), Some(true));

    // The audit row: kind archive, remoteWrite true, the returned id.
    let calls = factory.write_calls().all();
    assert_eq!(calls, vec![("archive".to_owned(), REMOTE.to_owned())]);
    let connection = open_read_write(&server.db_path);
    let (kind, payload): (String, String) = connection
        .query_row(
            "SELECT kind, payload FROM ai_actions WHERE id = ?",
            [action_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("audit row");
    assert_eq!(kind, "archive");
    let payload: Value = serde_json::from_str(&payload).expect("payload");
    assert_eq!(payload["remoteId"], json!(REMOTE));
    assert_eq!(payload["remoteWrite"], json!("true"));
}

#[tokio::test]
async fn mark_read_flips_locally_and_treats_the_remote_as_best_effort() {
    let factory = Arc::new(FakeProviderFactory::new(FakeOutcome::succeeds()));
    // The remote STORE fails: the route must still answer, and the local flag
    // must stay flipped (v3 markRead.remoteFailed).
    factory.write_script(vec![FakeWriteOutcome::Unreachable("store failed".to_owned())]);
    let (server, _fixtures) = TestServer::spawn_with_provider("r3-actions-read", factory.clone()).await;
    prepare_account(&server, &all_caps_allowed());
    let client = http::client();

    // record=false: a 204 with no audit row, despite the remote failure.
    let observed = post(&client, &server, &format!("/api/messages/{REMOTE}/read?accountId={ACCOUNT_A}"), None).await;
    assert_eq!(observed.status, 204, "{:?}", observed.body);
    assert_eq!(flag(&server, "is_read", REMOTE), Some(true));
    assert!(factory.write_calls().all().len() == 1);

    // record=true flips back (isRead=false) and records the previous value.
    factory.write_script(vec![FakeWriteOutcome::Ok]);
    let observed = post(
        &client,
        &server,
        &format!("/api/messages/{REMOTE}/read?accountId={ACCOUNT_A}&isRead=false&record=true"),
        None,
    )
    .await;
    assert_eq!(observed.status, 200, "{:?}", observed.body);
    assert_eq!(flag(&server, "is_read", REMOTE), Some(false));
    let connection = open_read_write(&server.db_path);
    let payload: String = connection
        .query_row(
            "SELECT payload FROM ai_actions WHERE kind = 'markRead' ORDER BY id DESC LIMIT 1",
            [],
            |row| row.get(0),
        )
        .expect("audit row");
    let payload: Value = serde_json::from_str(&payload).expect("payload");
    // The undo needs the value this action replaced, not a hardcoded false.
    assert_eq!(payload["previousIsRead"], json!("true"));
}

#[tokio::test]
async fn pin_undo_flips_back_and_the_second_undo_is_already_undone() {
    let factory = Arc::new(FakeProviderFactory::new(FakeOutcome::succeeds()));
    let (server, _fixtures) = TestServer::spawn_with_provider("r3-actions-undo", factory).await;
    prepare_account(&server, &all_caps_allowed());
    let client = http::client();

    let observed = post(&client, &server, &format!("/api/messages/{REMOTE}/pin?accountId={ACCOUNT_A}&pinned=true"), None).await;
    assert_eq!(observed.status, 200, "{:?}", observed.body);
    let action_id = observed.body["actionId"].as_i64().expect("actionId");
    assert_eq!(flag(&server, "is_pinned", REMOTE), Some(true));

    // Undo: 200, local flag back.
    let observed = post(&client, &server, &format!("/api/actions/{action_id}/undo?accountId={ACCOUNT_A}"), None).await;
    assert_eq!(observed.status, 200, "{:?}", observed.body);
    assert_eq!(observed.body["undone"], json!(action_id));
    assert_eq!(flag(&server, "is_pinned", REMOTE), Some(false));

    // Single-use: the second attempt is 409 already-undone.
    let observed = post(&client, &server, &format!("/api/actions/{action_id}/undo?accountId={ACCOUNT_A}"), None).await;
    assert_eq!(observed.status, 409, "{:?}", observed.body);
    assert_eq!(observed.body["error"], json!("already-undone"));

    // The history hides undone rows (v3 pageSQL NOT EXISTS undo).
    let observed = http::request(
        &client,
        "GET",
        &format!("{}/api/actions?accountId={ACCOUNT_A}", server.base_url),
        &server.auth_headers(),
    )
    .await;
    let actions = observed.body["actions"].as_array().expect("actions");
    assert!(actions.iter().all(|action| action["kind"] != json!("pin")));
}

#[tokio::test]
async fn undo_of_a_purge_is_not_undoable_and_an_expired_one_is_410() {
    let factory = Arc::new(FakeProviderFactory::new(FakeOutcome::succeeds()));
    let (server, _fixtures) = TestServer::spawn_with_provider("r3-actions-purge", factory).await;
    prepare_account(&server, &all_caps_allowed());
    let client = http::client();
    let connection = open_read_write(&server.db_path);

    // A purge action, hand-written: the purge route itself does not audit.
    connection
        .execute(
            "INSERT INTO ai_actions (account_id, kind, payload) VALUES (?, 'purge', ?)",
            rusqlite::params![uuid_bytes(ACCOUNT_A), json!({"remoteId": REMOTE}).to_string()],
        )
        .expect("insert purge action");
    let purge_id: i64 = connection
        .query_row("SELECT id FROM ai_actions WHERE kind = 'purge'", [], |row| row.get(0))
        .expect("purge id");

    let observed = post(&client, &server, &format!("/api/actions/{purge_id}/undo?accountId={ACCOUNT_A}"), None).await;
    assert_eq!(observed.status, 400, "{:?}", observed.body);
    assert_eq!(observed.body["error"], json!("not-undoable"));

    // An expired action: expires_at in the past.
    connection
        .execute(
            "INSERT INTO ai_actions (account_id, kind, payload, expires_at)
             VALUES (?, 'archive', ?, '2020-01-01 00:00:00.000')",
            rusqlite::params![uuid_bytes(ACCOUNT_A), json!({"remoteId": REMOTE}).to_string()],
        )
        .expect("insert expired action");
    let expired_id: i64 = connection
        .query_row(
            "SELECT id FROM ai_actions WHERE kind = 'archive' AND expires_at < '2026-01-01'",
            [],
            |row| row.get(0),
        )
        .expect("expired id");

    let observed = post(&client, &server, &format!("/api/actions/{expired_id}/undo?accountId={ACCOUNT_A}"), None).await;
    assert_eq!(observed.status, 410, "{:?}", observed.body);
    assert_eq!(observed.body["error"], json!("action-expired"));
}

#[tokio::test]
async fn bulk_archive_reports_per_item_results() {
    let factory = Arc::new(FakeProviderFactory::new(FakeOutcome::succeeds()));
    factory.write_script(vec![
        FakeWriteOutcome::Ok,
        FakeWriteOutcome::Unreachable("move failed".to_owned()),
    ]);
    let (server, _fixtures) = TestServer::spawn_with_provider("r3-actions-bulk", factory.clone()).await;
    prepare_account(&server, &all_caps_allowed());
    let client = http::client();

    let observed = post(
        &client,
        &server,
        &format!("/api/archive-bulk?accountId={ACCOUNT_A}"),
        Some(&json!({ "remoteIds": ["fixture-msg-1", "fixture-msg-3"] })),
    )
    .await;
    assert_eq!(observed.status, 200, "{:?}", observed.body);
    let items = observed.body["items"].as_array().expect("items");
    assert_eq!(items.len(), 2);
    assert_eq!(items[0]["ok"], json!(true));
    assert_eq!(items[0]["remoteId"], json!("fixture-msg-1"));
    assert_eq!(items[1]["ok"], json!(false));
    assert_eq!(flag(&server, "is_archived", "fixture-msg-1"), Some(true));
    assert_eq!(flag(&server, "is_archived", "fixture-msg-3"), Some(false));

    // Contract shapes: empty body and empty list are distinct 400s.
    let observed = post(&client, &server, &format!("/api/archive-bulk?accountId={ACCOUNT_A}"), None).await;
    assert_eq!(observed.status, 400);
    assert_eq!(observed.body["error"], json!("missing-body"));
    let observed = post(
        &client,
        &server,
        &format!("/api/archive-bulk?accountId={ACCOUNT_A}"),
        Some(&json!({ "remoteIds": [] })),
    )
    .await;
    assert_eq!(observed.status, 400);
    assert_eq!(observed.body["error"], json!("empty-remoteIds"));
}
