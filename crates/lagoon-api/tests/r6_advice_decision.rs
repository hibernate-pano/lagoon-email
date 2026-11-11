//! R6 · the advice decision出口 (plan §5.5).
//!
//! The rule these tests exist to hold: **a suggestion is not an action.** The
//! decision route records what the user chose; it changes no mail. And the two
//! can never contradict each other:
//!
//! * deciding twice is idempotent, and keeps the first timestamp;
//! * `pending` is not an input, so a caller cannot un-decide and hand the row
//!   back to the worker;
//! * archiving a mail by hand settles its pending suggestion, because acting on
//!   the mail *is* the accept - otherwise the same mail comes back tomorrow;
//! * a decision the user already made (dismissed) is never rewritten by a later
//!   mail action.

mod support;

use rusqlite::params;
use serde_json::Value;

use support::http;
use support::seed::Seed;
use support::server::TestServer;
use support::fixtures::Fixtures;

/// Insert a pending suggestion for a mail that already exists in the seed.
fn insert_advice(server: &TestServer, seed: &Seed, remote_id: &str, action: &str) -> i64 {
    let connection = support::server::open_read_write(&server.db_path);
    connection
        .execute(
            "INSERT INTO advice (account_id, remote_id, action, confidence, source, decision)
             VALUES (?, ?, ?, 'high', 'ai', 'pending')",
            params![seed.account_uuid().as_bytes().as_slice(), remote_id, action],
        )
        .expect("insert advice");
    connection.last_insert_rowid()
}

/// Insert a mail row (the seed's own messages have fixture-specific ids).
fn insert_mail(server: &TestServer, seed: &Seed, remote_id: &str) {
    let connection = support::server::open_read_write(&server.db_path);
    connection
        .execute(
            "INSERT INTO message_headers
                (id, account_id, remote_id, thread_id, from_address, subject, received_at,
                 is_read, is_archived, is_deleted, is_sent)
             VALUES (?, ?, ?, ?, 'friend@example.com', '你好', '2026-01-01 00:00:00.000',
                     0, 0, 0, 0)",
            params![
                row_uuid(remote_id).as_bytes().as_slice(),
                seed.account_uuid().as_bytes().as_slice(),
                remote_id,
                remote_id,
            ],
        )
        .expect("insert message");
}

fn row_uuid(remote_id: &str) -> lagoon_api::uuid::Uuid {
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};
    let mut hasher = DefaultHasher::new();
    remote_id.hash(&mut hasher);
    let value = hasher.finish();
    let hex = format!("{value:016x}");
    lagoon_api::uuid::Uuid::parse_strict(&format!(
        "{}-{}-4{}-8{}-{}",
        &hex[0..8],
        &hex[8..12],
        &hex[13..16],
        &hex[1..4],
        &hex[4..16]
    ))
    .expect("uuid")
}

/// Open the archive/trash gates for this account.
///
/// The seed's capabilities come from the `accounts.list` fixture, which records
/// what that account answered at capture time; whether it had an Archive folder
/// is not something these tests should depend on. The gate is the account's own
/// statement, so a test that needs to pass it says so here.
fn enable_write_capabilities(server: &TestServer, seed: &Seed) {
    let connection = support::server::open_read_write(&server.db_path);
    // The seed's credentials are 48 zero bytes no key opens, which is
    // deliberate: nothing in the contract tests may reach a mailbox. A write
    // test needs a provider, so it seals a throwaway credential with the same
    // test key the server was started with.
    let sealed = lagoon_api::token::ImapCredentials::new("fixture@example.invalid", "auth-code")
        .seal(&support::server::token_key())
        .expect("seal a throwaway credential");
    let capabilities = serde_json::json!({
        "archiveFolder": true,
        "idle": true,
        "move": true,
        "serverSnippet": true,
        "uidplus": true,
        "sentFolder": true,
        "trashFolder": true,
        "archiveFolderName": "Archive",
    })
    .to_string();
    connection
        .execute(
            "UPDATE accounts SET capabilities = ?, credentials = ? WHERE id = ?",
            params![
                capabilities,
                sealed,
                seed.account_uuid().as_bytes().as_slice()
            ],
        )
        .expect("open the write gates");
}

fn decision_of(server: &TestServer, id: i64) -> (String, Option<String>) {
    let connection = support::server::open_read_write(&server.db_path);
    connection
        .query_row(
            "SELECT decision, decided_at FROM advice WHERE id = ?",
            [id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("advice row")
}

async fn post_json(
    client: &http::HttpClient,
    url: &str,
    headers: &[(String, String)],
    body: &str,
) -> http::Observed {
    http::request_with_body(client, "POST", url, headers, body.as_bytes()).await
}

/* ------------------------------------------------------------ the decision ---- */

#[tokio::test]
async fn deciding_a_pending_advice_records_it_and_writes_no_mail() {
    let fixtures = Fixtures::load();
    let seed = Seed::from_fixtures(&fixtures);
    let server = TestServer::spawn_with_seed("r6-decide", &seed).await;
    let client = http::client();
    insert_mail(&server, &seed, "m-1");
    let id = insert_advice(&server, &seed, "m-1", "archive");

    let url = format!(
        "{}/api/advice/{}/decision?accountId={}",
        server.base_url, id, seed.account_id
    );
    let observed = post_json(&client, &url, &server.auth_headers(), r#"{"decision":"accepted"}"#).await;
    assert_eq!(observed.status, 200, "{:?}", observed.body);
    assert_eq!(observed.body["id"], id);
    assert_eq!(observed.body["decision"], "accepted");

    let (decision, decided_at) = decision_of(&server, id);
    assert_eq!(decision, "accepted");
    assert!(decided_at.is_some(), "the timestamp is the evidence it happened");

    // ★ A decision changes no mail. This is the constitution in one assertion.
    let connection = support::server::open_read_write(&server.db_path);
    let (archived, deleted): (i64, i64) = connection
        .query_row(
            "SELECT is_archived, is_deleted FROM message_headers WHERE remote_id = 'm-1'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("message row");
    assert_eq!(archived, 0, "the decision route must not archive");
    assert_eq!(deleted, 0);
}

#[tokio::test]
async fn deciding_twice_is_idempotent_and_keeps_the_first_timestamp() {
    let fixtures = Fixtures::load();
    let seed = Seed::from_fixtures(&fixtures);
    let server = TestServer::spawn_with_seed("r6-idempotent", &seed).await;
    let client = http::client();
    insert_mail(&server, &seed, "m-1");
    let id = insert_advice(&server, &seed, "m-1", "archive");
    let url = format!(
        "{}/api/advice/{}/decision?accountId={}",
        server.base_url, id, seed.account_id
    );

    let first = post_json(&client, &url, &server.auth_headers(), r#"{"decision":"accepted"}"#).await;
    assert_eq!(first.status, 200);
    let (_, first_at) = decision_of(&server, id);

    let second = post_json(&client, &url, &server.auth_headers(), r#"{"decision":"accepted"}"#).await;
    assert_eq!(second.status, 200, "a retry is not a conflict");
    let (decision, second_at) = decision_of(&server, id);
    assert_eq!(decision, "accepted");
    assert_eq!(first_at, second_at, "the first timestamp is the one that happened");
}

#[tokio::test]
async fn pending_is_not_a_legal_decision() {
    let fixtures = Fixtures::load();
    let seed = Seed::from_fixtures(&fixtures);
    let server = TestServer::spawn_with_seed("r6-pending", &seed).await;
    let client = http::client();
    insert_mail(&server, &seed, "m-1");
    let id = insert_advice(&server, &seed, "m-1", "archive");
    let url = format!(
        "{}/api/advice/{}/decision?accountId={}",
        server.base_url, id, seed.account_id
    );

    let observed = post_json(&client, &url, &server.auth_headers(), r#"{"decision":"pending"}"#).await;
    assert_eq!(observed.status, 400);
    assert_eq!(observed.body["error"], "invalid-decision");
    // Un-deciding would reopen the row for the worker to overwrite.
    assert_eq!(decision_of(&server, id).0, "pending", "nothing changed");
}

#[tokio::test]
async fn an_unknown_advice_id_is_a_404() {
    let fixtures = Fixtures::load();
    let seed = Seed::from_fixtures(&fixtures);
    let server = TestServer::spawn_with_seed("r6-unknown-advice", &seed).await;
    let client = http::client();

    let url = format!(
        "{}/api/advice/999999/decision?accountId={}",
        server.base_url, seed.account_id
    );
    let observed = post_json(&client, &url, &server.auth_headers(), r#"{"decision":"accepted"}"#).await;
    assert_eq!(observed.status, 404);
    assert_eq!(observed.body["error"], "unknown-advice");
}

#[tokio::test]
async fn a_bulk_decision_reports_each_row() {
    let fixtures = Fixtures::load();
    let seed = Seed::from_fixtures(&fixtures);
    let server = TestServer::spawn_with_seed("r6-bulk", &seed).await;
    let client = http::client();
    insert_mail(&server, &seed, "m-1");
    insert_mail(&server, &seed, "m-2");
    let first = insert_advice(&server, &seed, "m-1", "archive");
    let second = insert_advice(&server, &seed, "m-2", "delete");

    let url = format!(
        "{}/api/advice/decisions-bulk?accountId={}",
        server.base_url, seed.account_id
    );
    let body = format!(
        r#"{{"ids":[{first},{second},999999],"decision":"dismissed"}}"#
    );
    let observed = post_json(&client, &url, &server.auth_headers(), &body).await;
    assert_eq!(observed.status, 200, "{:?}", observed.body);
    // Partial success is a normal outcome: two landed, one did not exist.
    assert_eq!(observed.body["decided"], 2);
    let items = observed.body["items"].as_array().expect("items");
    assert_eq!(items.len(), 3);
    let unknown = items
        .iter()
        .find(|item| item["id"] == 999999)
        .expect("the unknown id is reported");
    assert_eq!(unknown["ok"], false);
    assert_eq!(unknown["errorCode"], "unknown-advice");

    assert_eq!(decision_of(&server, first).0, "dismissed");
    assert_eq!(decision_of(&server, second).0, "dismissed");
}

#[tokio::test]
async fn an_empty_or_oversized_bulk_is_refused_before_anything_is_written() {
    let fixtures = Fixtures::load();
    let seed = Seed::from_fixtures(&fixtures);
    let server = TestServer::spawn_with_seed("r6-bulk-limits", &seed).await;
    let client = http::client();
    let url = format!(
        "{}/api/advice/decisions-bulk?accountId={}",
        server.base_url, seed.account_id
    );

    let observed = post_json(&client, &url, &server.auth_headers(), r#"{"ids":[],"decision":"accepted"}"#).await;
    assert_eq!(observed.status, 400);
    assert_eq!(observed.body["error"], "empty-ids");

    let big: Vec<String> = (0..501).map(|index| index.to_string()).collect();
    let body = format!(r#"{{"ids":[{}],"decision":"accepted"}}"#, big.join(","));
    let observed = post_json(&client, &url, &server.auth_headers(), &body).await;
    assert_eq!(observed.status, 400);
    assert_eq!(observed.body["error"], "too-many-ids");
}

#[tokio::test]
async fn an_unknown_account_is_a_404_and_writes_nothing() {
    let fixtures = Fixtures::load();
    let seed = Seed::from_fixtures(&fixtures);
    let server = TestServer::spawn_with_seed("r6-account", &seed).await;
    let client = http::client();
    insert_mail(&server, &seed, "m-1");
    let id = insert_advice(&server, &seed, "m-1", "archive");

    let url = format!(
        "{}/api/advice/{}/decision?accountId=99999999-9999-4999-8999-999999999999",
        server.base_url, id
    );
    let observed = post_json(&client, &url, &server.auth_headers(), r#"{"decision":"accepted"}"#).await;
    assert_eq!(observed.status, 404);
    assert_eq!(observed.body["error"], "unknown-account");
    assert_eq!(decision_of(&server, id).0, "pending");
}

/* ------------------------------------------ acting on the mail is the accept ---- */

#[tokio::test]
async fn archiving_a_message_settles_its_pending_suggestion() {
    let fixtures = Fixtures::load();
    let seed = Seed::from_fixtures(&fixtures);
    // The seed's capabilities include an archive folder, so the gate opens.
    let factory = std::sync::Arc::new(lagoon_api::provider::fake::FakeProviderFactory::new(
        lagoon_api::provider::fake::FakeOutcome::succeeds(),
    ));
    factory.write_script(vec![lagoon_api::provider::fake::FakeWriteOutcome::Ok]);
    let server = TestServer::spawn_with_provider("r6-consume", factory)
        .await
        .0;
    let client = http::client();
    enable_write_capabilities(&server, &seed);
    let remote_id = "m-consume";
    insert_mail(&server, &seed, remote_id);
    let id = insert_advice(&server, &seed, remote_id, "archive");

    let url = format!(
        "{}/api/messages/{}/archive?accountId={}",
        server.base_url, remote_id, seed.account_id
    );
    let observed = post_json(&client, &url, &server.auth_headers(), "").await;
    assert!(
        observed.status == 200 || observed.status == 202,
        "archive answered {}: {:?}",
        observed.status,
        observed.body
    );

    // ★ Otherwise the same mail reappears in the queue tomorrow.
    assert_eq!(decision_of(&server, id).0, "accepted");
}

#[tokio::test]
async fn archiving_never_rewrites_a_decision_the_user_already_made() {
    let fixtures = Fixtures::load();
    let seed = Seed::from_fixtures(&fixtures);
    let factory = std::sync::Arc::new(lagoon_api::provider::fake::FakeProviderFactory::new(
        lagoon_api::provider::fake::FakeOutcome::succeeds(),
    ));
    factory.write_script(vec![lagoon_api::provider::fake::FakeWriteOutcome::Ok]);
    let server = TestServer::spawn_with_provider("r6-respect-decision", factory)
        .await
        .0;
    let client = http::client();
    enable_write_capabilities(&server, &seed);
    let remote_id = "m-dismissed";
    insert_mail(&server, &seed, remote_id);
    let id = insert_advice(&server, &seed, remote_id, "archive");
    {
        let connection = support::server::open_read_write(&server.db_path);
        connection
            .execute(
                "UPDATE advice SET decision = 'dismissed', decided_at = '2026-01-02 00:00:00.000' WHERE id = ?",
                [id],
            )
            .expect("pre-dismiss");
    }

    let url = format!(
        "{}/api/messages/{}/archive?accountId={}",
        server.base_url, remote_id, seed.account_id
    );
    let observed = post_json(&client, &url, &server.auth_headers(), "").await;
    assert!(
        observed.status == 200 || observed.status == 202,
        "archive answered {}",
        observed.status
    );

    let (decision, decided_at) = decision_of(&server, id);
    assert_eq!(decision, "dismissed", "a dismissal is not an accept");
    assert_eq!(
        decided_at.as_deref(),
        Some("2026-01-02 00:00:00.000"),
        "and its timestamp is untouched"
    );
}

#[tokio::test]
async fn marking_read_does_not_consume_a_suggestion() {
    let fixtures = Fixtures::load();
    let seed = Seed::from_fixtures(&fixtures);
    let factory = std::sync::Arc::new(lagoon_api::provider::fake::FakeProviderFactory::new(
        lagoon_api::provider::fake::FakeOutcome::succeeds(),
    ));
    factory.write_script(vec![lagoon_api::provider::fake::FakeWriteOutcome::Ok]);
    let server = TestServer::spawn_with_provider("r6-read-noop", factory)
        .await
        .0;
    let client = http::client();
    enable_write_capabilities(&server, &seed);
    let remote_id = "m-read";
    insert_mail(&server, &seed, remote_id);
    let id = insert_advice(&server, &seed, remote_id, "reply");

    let url = format!(
        "{}/api/messages/{}/read?accountId={}",
        server.base_url, remote_id, seed.account_id
    );
    let observed = post_json(&client, &url, &server.auth_headers(), "").await;
    assert!(observed.status == 204 || observed.status == 200, "{}", observed.status);

    // Reading a mail is not a triage decision; treating it as one would empty
    // the queue by opening it.
    assert_eq!(decision_of(&server, id).0, "pending");
}

#[tokio::test]
async fn the_advice_list_shows_the_decisions_it_recorded() {
    let fixtures = Fixtures::load();
    let seed = Seed::from_fixtures(&fixtures);
    let server = TestServer::spawn_with_seed("r6-list", &seed).await;
    let client = http::client();
    insert_mail(&server, &seed, "m-1");
    insert_mail(&server, &seed, "m-2");
    let first = insert_advice(&server, &seed, "m-1", "archive");
    let second = insert_advice(&server, &seed, "m-2", "delete");

    let url = format!(
        "{}/api/advice/decisions-bulk?accountId={}",
        server.base_url, seed.account_id
    );
    let body = format!(r#"{{"ids":[{first}],"decision":"accepted"}}"#);
    let observed = post_json(&client, &url, &server.auth_headers(), &body).await;
    assert_eq!(observed.status, 200);

    // Pending still lists only the undecided one.
    let url = format!(
        "{}/api/advice?accountId={}&decision=pending",
        server.base_url, seed.account_id
    );
    let observed = http::request(&client, "GET", &url, &server.auth_headers()).await;
    assert_eq!(observed.status, 200);
    let rows: Vec<i64> = observed.body["advice"]
        .as_array()
        .expect("advice")
        .iter()
        .map(|row| row["id"].as_i64().expect("id"))
        .collect();
    assert_eq!(rows, vec![second], "the decided row left the pending queue");

    // And `decision=any` still has both, so the history is intact.
    let url = format!(
        "{}/api/advice?accountId={}&decision=any",
        server.base_url, seed.account_id
    );
    let observed = http::request(&client, "GET", &url, &server.auth_headers()).await;
    assert_eq!(observed.body["advice"].as_array().expect("advice").len(), 2);
}

#[tokio::test]
async fn accepted_stats_reflects_only_real_accepts() {
    let fixtures = Fixtures::load();
    let seed = Seed::from_fixtures(&fixtures);
    let server = TestServer::spawn_with_seed("r6-stats", &seed).await;
    let client = http::client();
    insert_mail(&server, &seed, "m-1");
    insert_mail(&server, &seed, "m-2");
    let accepted = insert_advice(&server, &seed, "m-1", "archive");
    let dismissed = insert_advice(&server, &seed, "m-2", "archive");

    let url = format!(
        "{}/api/advice/decisions-bulk?accountId={}",
        server.base_url, seed.account_id
    );
    let body = format!(r#"{{"ids":[{accepted}],"decision":"accepted"}}"#);
    post_json(&client, &url, &server.auth_headers(), &body).await;
    let body = format!(r#"{{"ids":[{dismissed}],"decision":"dismissed"}}"#);
    post_json(&client, &url, &server.auth_headers(), &body).await;

    let url = format!(
        "{}/api/advice/accepted-stats?accountId={}",
        server.base_url, seed.account_id
    );
    let observed = http::request(&client, "GET", &url, &server.auth_headers()).await;
    assert_eq!(observed.status, 200);
    let stats: &Value = &observed.body["stats"];
    let total: i64 = stats
        .as_array()
        .expect("stats")
        .iter()
        .map(|row| row["count"].as_i64().unwrap_or(0))
        .sum();
    assert_eq!(total, 1, "one accept, one dismissal: {stats}");
}
