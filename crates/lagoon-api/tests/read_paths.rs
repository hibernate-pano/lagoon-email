//! Read paths the fixtures cannot cover: a cached body, a decrypted snippet,
//! the stack filters, and the properties that only exist on this side of the
//! wire (read-only handles, Host normalisation).
//!
//! The fixture replay proves the shapes v3 answers on a store with no cached
//! bodies. These tests build the rows that make the cache and the filters
//! matter, including one body and one snippet sealed by CryptoKit rather than
//! by this crate.

mod support;

use serde_json::{json, Value};

use lagoon_api::db::Db;
use lagoon_api::uuid::Uuid;

use support::fixtures::Fixtures;
use support::http;
use support::schema;
use support::seed::Seed;
use support::server::{open_read_write, TestServer, TEST_API_TOKEN};

/// Sealed by CryptoKit for the spike (v4/spike/cipher-interop). With the test
/// key below it opens to SWIFT_BODY_PLAINTEXT, so a stored row carrying it is
/// exactly what a v3 store holds.
const SWIFT_BODY_ENVELOPE: &str =
    "lgb1:LcH/xenkpJ44fimid/VyxqwwgOEm4wv8f5/7vMOkie7hqmxlSt88+qX1Xw==";
const SWIFT_BODY_PLAINTEXT: &str = "hello lagoon v4";

/// The spike's CJK vector: a preview would be sealed the same way.
const SWIFT_SNIPPET_ENVELOPE: &str = "lgb1:dKrEO5zqBGoWq5IG8Iqz7OlIBH5zFRK3CKZoYHucsQsEjaTyk+miq8X/wGv9FM0IP8IwmPWgZLv1w9E0Ro1imbMjIZvhIX/qdM8LN9WRHhJOld8Q";
const SWIFT_SNIPPET_PLAINTEXT: &str = "你好，Lagoon —— 中文正文 🚀 with ascii tail";

const UNKNOWN_ACCOUNT: &str = "99999999-9999-4999-8999-999999999999";

fn uuid_bytes(raw: &str) -> Vec<u8> {
    Uuid::parse_strict(raw).expect("uuid").as_bytes().to_vec()
}

fn find_message<'a>(fixtures: &'a Fixtures, remote_id: &str) -> &'a Value {
    for name in ["messages.list", "messages.list.archived"] {
        if let Some(items) = fixtures.by_name(name)["response"]["body"]["messages"].as_array() {
            if let Some(found) = items.iter().find(|item| item["remoteId"] == remote_id) {
                return found;
            }
        }
    }
    panic!("fixture message {remote_id} is missing");
}

async fn get(client: &http::HttpClient, url: &str, headers: &[(String, String)]) -> http::Observed {
    http::request(client, "GET", url, headers).await
}

#[tokio::test]
async fn serves_a_body_sealed_by_swift() {
    let (server, fixtures) = TestServer::spawn("body").await;
    let seed = Seed::from_fixtures(&fixtures);
    let seeded = &seed.messages[0];
    let remote_id = seeded.remote_id.clone();

    {
        let connection = open_read_write(&server.db_path);
        connection
            .execute(
                "INSERT INTO message_bodies (
                     account_id, remote_id, body_cipher, body_html_cipher, has_more,
                     attachments, to_addresses, cc_addresses
                 ) VALUES (?, ?, ?, NULL, 0, ?, ?, ?)",
                rusqlite::params![
                    uuid_bytes(&seed.account_id),
                    remote_id,
                    SWIFT_BODY_ENVELOPE,
                    json!([{
                        "id": "1.2",
                        "filename": "report.pdf",
                        "mimeType": "application/pdf",
                        "size": 1234,
                        "disposition": "attachment"
                    }])
                    .to_string(),
                    json!(["me@example.invalid"]).to_string(),
                    "[]",
                ],
            )
            .expect("insert a cached body");
    }

    let client = http::client();
    let url = format!(
        "{}/api/messages/{remote_id}/body?accountId={}",
        server.base_url, seed.account_id
    );
    let observed = get(&client, &url, &server.auth_headers()).await;

    assert_eq!(observed.status, 200, "{:?}", observed.body);
    assert_eq!(observed.content_type, "application/json; charset=utf-8");
    let fixture = find_message(&fixtures, &remote_id);
    assert_eq!(observed.body["remoteId"], json!(remote_id));
    assert_eq!(observed.body["text"], json!(SWIFT_BODY_PLAINTEXT));
    assert_eq!(observed.body["subject"], fixture["subject"]);
    assert_eq!(observed.body["fromAddress"], fixture["fromAddress"]);
    assert_eq!(observed.body["fromName"], fixture["fromName"]);
    // The stored header carries the instant, and the wire form must be ISO-8601
    // with second precision - the same string the fixture records.
    assert_eq!(observed.body["receivedAt"], fixture["receivedAt"]);
    assert_eq!(observed.body["to"], json!(["me@example.invalid"]));
    assert_eq!(observed.body["cc"], json!([]));
    assert_eq!(observed.body["hasMore"], json!(false));
    assert_eq!(observed.body["attachments"][0]["mimeType"], json!("application/pdf"));
    assert_eq!(observed.body["attachments"][0]["size"], json!(1234));
    // v3 passes toAddress nil on this path, and a nil optional is an absent key.
    assert!(
        observed.body.get("toAddress").is_none(),
        "toAddress must be absent, not null"
    );
    assert!(observed.body.get("html").is_none(), "no HTML was stored");
}

#[tokio::test]
async fn decrypts_a_swift_sealed_snippet_into_the_list() {
    let (server, fixtures) = TestServer::spawn("snippet").await;
    let seed = Seed::from_fixtures(&fixtures);
    let sealed_remote = seed.messages[0].remote_id.clone();

    {
        let connection = open_read_write(&server.db_path);
        connection
            .execute(
                "UPDATE message_headers SET snippet_cipher = ? WHERE remote_id = ?",
                rusqlite::params![SWIFT_SNIPPET_ENVELOPE, sealed_remote],
            )
            .expect("seal one preview");
    }

    let client = http::client();
    let url = format!("{}/api/messages?accountId={}", server.base_url, seed.account_id);
    let observed = get(&client, &url, &server.auth_headers()).await;
    assert_eq!(observed.status, 200);

    let messages = observed.body["messages"].as_array().expect("messages");
    let sealed = messages
        .iter()
        .find(|message| message["remoteId"] == json!(sealed_remote))
        .expect("sealed message in the list");
    assert_eq!(sealed["snippet"], json!(SWIFT_SNIPPET_PLAINTEXT));

    for message in messages {
        if message["remoteId"] != json!(sealed_remote) {
            assert!(
                message.get("snippet").is_none(),
                "an empty preview must be an absent key, not null"
            );
        }
    }
}

#[tokio::test]
async fn body_route_status_codes_match_the_contract() {
    let (server, fixtures) = TestServer::spawn("body-status").await;
    let seed = Seed::from_fixtures(&fixtures);
    let client = http::client();
    let auth = server.auth_headers();
    let remote = seed.messages[0].remote_id.clone();

    let malformed = get(
        &client,
        &format!("{}/api/messages/{remote}/body?accountId=not-a-uuid", server.base_url),
        &auth,
    )
    .await;
    assert_eq!(malformed.status, 400);
    assert_eq!(malformed.body, json!({"error": "malformed-accountId"}));

    let unknown = get(
        &client,
        &format!("{}/api/messages/{remote}/body?accountId={UNKNOWN_ACCOUNT}", server.base_url),
        &auth,
    )
    .await;
    assert_eq!(unknown.status, 404);
    assert_eq!(unknown.body, json!({"error": "unknown-account"}));

    let cache_miss = get(
        &client,
        &format!("{}/api/messages/{remote}/body?accountId={}", server.base_url, seed.account_id),
        &auth,
    )
    .await;
    assert_eq!(cache_miss.status, 503);
    assert_eq!(cache_miss.body, json!({"error": "provider-not-configured"}));

    let no_header = get(
        &client,
        &format!(
            "{}/api/messages/never-synced/body?accountId={}",
            server.base_url, seed.account_id
        ),
        &auth,
    )
    .await;
    assert_eq!(no_header.status, 503, "a store miss is the provider path");
}

#[tokio::test]
async fn stack_rules_narrow_the_list() {
    let (server, fixtures) = TestServer::spawn("stack").await;
    let seed = Seed::from_fixtures(&fixtures);
    let account_id = seed.account_id.clone();
    let rule_id = "33333333-3333-4333-8333-333333333333";

    {
        let connection = open_read_write(&server.db_path);
        connection
            .execute(
                "INSERT INTO stack_rules (id, account_id, name, kind, value) VALUES (?, ?, ?, ?, ?)",
                rusqlite::params![
                    uuid_bytes(rule_id),
                    uuid_bytes(&account_id),
                    "fixtures",
                    "keyword",
                    "fixture",
                ],
            )
            .expect("insert a stack rule");
    }

    let client = http::client();
    let auth = server.auth_headers();

    let filtered = get(
        &client,
        &format!(
            "{}/api/messages?accountId={account_id}&stackId={rule_id}",
            server.base_url
        ),
        &auth,
    )
    .await;
    assert_eq!(filtered.status, 200);
    let subject_count = seed
        .messages
        .iter()
        .filter(|message| {
            !message.is_archived
                && message
                    .subject
                    .as_deref()
                    .is_some_and(|subject| subject.to_lowercase().contains("fixture"))
        })
        .count();
    assert_eq!(filtered.body["totalCount"], json!(subject_count));
    assert_eq!(
        filtered.body["messages"].as_array().expect("messages").len(),
        subject_count
    );

    let unknown = get(
        &client,
        &format!(
            "{}/api/messages?accountId={account_id}&stackId=44444444-4444-4444-8444-444444444444",
            server.base_url
        ),
        &auth,
    )
    .await;
    assert_eq!(unknown.status, 404);
    assert_eq!(unknown.body, json!({"error": "unknown-stack"}));

    // A malformed stackId is ignored, not rejected: v3 wraps the lookup in
    // "if let raw = ..., let ruleId = UUID(uuidString: raw)".
    let ignored = get(
        &client,
        &format!(
            "{}/api/messages?accountId={account_id}&stackId=not-a-uuid",
            server.base_url
        ),
        &auth,
    )
    .await;
    assert_eq!(ignored.status, 200);
    assert_eq!(
        ignored.body["totalCount"],
        filtered.body["totalCount"],
        "ignoring the malformed id must leave the unfiltered inbox"
    );
}

#[tokio::test]
async fn an_unimplemented_provider_makes_the_directory_fail_like_v3() {
    let (server, fixtures) = TestServer::spawn("provider").await;
    let seed = Seed::from_fixtures(&fixtures);

    {
        let connection = open_read_write(&server.db_path);
        // 'gmail' is allowed by the table's CHECK but MailProviderKind has no
        // such case, so v3's decoder throws and the route answers 500.
        connection
            .execute(
                "INSERT INTO accounts (id, provider, oauth_user, email, is_active, sync_status)
                 VALUES (?, 'gmail', 'other@example.invalid', 'other@example.invalid', 0, 'ok')",
                rusqlite::params![uuid_bytes("55555555-5555-4555-8555-555555555555")],
            )
            .expect("insert an unimplemented provider row");
    }

    let client = http::client();
    let accounts = get(
        &client,
        &format!("{}/api/accounts", server.base_url),
        &server.auth_headers(),
    )
    .await;
    assert_eq!(accounts.status, 500);
    assert_eq!(accounts.body, json!({"error": "internal-error"}));
    assert!(!seed.account_id.is_empty());
}

#[test]
fn the_service_handle_is_read_only_and_refuses_a_foreign_store() {
    let temp = support::TempDir::new("read-only");
    let store = temp.join("lagoon.sqlite");
    {
        let connection = open_read_write(&store);
        schema::create(&connection).expect("schema");
    }

    let db = Db::open_read_only(&store).expect("open read-only");
    let write = db.with_connection(|connection| connection.execute("DELETE FROM accounts", []));
    assert!(write.is_err(), "a write through the service handle must fail");

    let missing = Db::open_read_only(temp.join("absent.sqlite"));
    assert!(missing.is_err(), "a missing store is refused, never created");

    let foreign = temp.join("not-a-lagoon-store.sqlite");
    std::fs::write(&foreign, b"this is not sqlite").expect("write junk");
    assert!(Db::open_read_only(&foreign).is_err());

    let older = temp.join("older.sqlite");
    {
        let connection = open_read_write(&older);
        connection
            .execute_batch(
                "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
                 CREATE TABLE accounts (id BLOB PRIMARY KEY, provider TEXT, email TEXT);",
            )
            .expect("half a schema");
    }
    assert!(
        Db::open_read_only(&older).is_err(),
        "a store missing the columns R1 reads is refused, not served empty"
    );
}

#[tokio::test]
async fn host_guard_and_auth_gate_match_v3() {
    let (server, _fixtures) = TestServer::spawn("guard").await;
    let client = http::client();
    let auth = server.auth_headers();
    let port = server.base_url.rsplit(':').next().expect("port");

    let health = get(&client, &format!("{}/healthz", server.base_url), &[]).await;
    assert_eq!(health.status, 200);
    assert_eq!(health.content_type, "text/plain; charset=utf-8");
    assert_eq!(health.body, json!("ok"));

    // Exact-match gating: a spelling the router may still normalise is gated.
    let doubled = get(&client, &format!("{server_base}//healthz", server_base = server.base_url), &[]).await;
    assert_eq!(doubled.status, 401, "//healthz must not be ungated");

    for host in ["localhost:1234", "[::1]:9999"] {
        let mut headers = auth.clone();
        headers.push(("Host".to_owned(), host.to_owned()));
        let accounts = get(&client, &format!("{}/api/accounts", server.base_url), &headers).await;
        assert_eq!(accounts.status, 200, "host {host} should be allowed");
    }

    let mut evil = auth.clone();
    evil.push(("Host".to_owned(), "evil.example".to_owned()));
    let forbidden = get(&client, &format!("{}/api/accounts", server.base_url), &evil).await;
    assert_eq!(forbidden.status, 403);
    assert_eq!(forbidden.body, json!({"error": "forbidden-host"}));

    // A bad token is the same 401 as no token (v3 hashes both sides).
    let mut wrong = vec![("Authorization".to_owned(), "Bearer nope".to_owned())];
    wrong.push(("Host".to_owned(), format!("127.0.0.1:{port}")));
    let unauthorized = get(&client, &format!("{}/api/accounts", server.base_url), &wrong).await;
    assert_eq!(unauthorized.status, 401);
    assert_eq!(unauthorized.body, json!({"error": "api-unauthorized"}));
    assert!(!TEST_API_TOKEN.is_empty());
}

#[tokio::test]
async fn a_server_without_a_token_refuses_every_gated_path() {
    // The shell always hands the backend a token, so "no token" is a
    // misconfiguration, not a mode. Fail closed: a missing token must never
    // mean "no auth required".
    let fixtures = Fixtures::load();
    let seed = Seed::from_fixtures(&fixtures);
    let server = TestServer::spawn_with("no-token", &seed, None).await;
    let client = http::client();

    let accounts = get(&client, &format!("{}/api/accounts", server.base_url), &[]).await;
    assert_eq!(accounts.status, 401, "a server with no token must fail closed");
    assert_eq!(accounts.body, json!({"error": "api-unauthorized"}));
}
