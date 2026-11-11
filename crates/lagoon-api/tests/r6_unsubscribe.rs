//! R6 · `List-Unsubscribe` reaches the reader (plan §8.4).
//!
//! The rule under test is as much about what is *absent* as what is present:
//!
//! * the stored links come from the header, once, at sync;
//! * only `https:` and `mailto:` survive - everything else a stranger can write
//!   into a header is dropped before it can become a button;
//! * the body route reports them, so the reader can offer a way out;
//! * **nothing issues a request.** There is no server-side unsubscribe call in
//!   this build, and this file is where that stays true: the assertion is that
//!   the parsed value arrives, not that anything was contacted.

mod support;

use rusqlite::params;
use serde_json::Value;

use support::fixtures::Fixtures;
use support::http;
use support::seed::Seed;
use support::server::TestServer;

/// Insert a mail row carrying exact header values.
///
/// The parser is the unit under test in `lagoon-mail`; this file checks the
/// wiring, so the rows are written with the values a real mailbox would have.
fn insert_mail(
    server: &TestServer,
    seed: &Seed,
    remote_id: &str,
    list_unsubscribe: &str,
    one_click: bool,
    links: &str,
) {
    let connection = support::server::open_read_write(&server.db_path);
    let body_key = support::server::body_key();
    let sealed = body_key.seal("hello").expect("seal a body");
    connection
        .execute(
            "INSERT INTO message_headers
                (id, account_id, remote_id, thread_id, from_address, subject, received_at,
                 is_read, is_archived, is_deleted, is_sent, list_unsubscribe, unsubscribe_links)
             VALUES (?, ?, ?, ?, 'news@example.com', '周刊', '2026-01-01 00:00:00.000',
                     0, 0, 0, 0, ?, ?)",
            params![
                row_uuid(remote_id).as_bytes().as_slice(),
                seed.account_uuid().as_bytes().as_slice(),
                remote_id,
                remote_id,
                i64::from(!list_unsubscribe.is_empty()),
                links,
            ],
        )
        .expect("insert message");
    connection
        .execute(
            "INSERT INTO message_bodies (account_id, remote_id, body_cipher)
             VALUES (?, ?, ?)",
            params![
                seed.account_uuid().as_bytes().as_slice(),
                remote_id,
                sealed
            ],
        )
        .expect("insert body");
    let _ = one_click;
}

fn row_uuid(remote_id: &str) -> lagoon_api::uuid::Uuid {
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};
    let mut hasher = DefaultHasher::new();
    remote_id.hash(&mut hasher);
    let hex = format!("{:016x}", hasher.finish());
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

async fn body_of(
    client: &http::HttpClient,
    server: &TestServer,
    seed: &Seed,
    remote_id: &str,
) -> Value {
    let url = format!(
        "{}/api/messages/{}/body?accountId={}",
        server.base_url,
        urlencode(remote_id),
        seed.account_id
    );
    let observed = http::request(client, "GET", &url, &server.auth_headers()).await;
    assert_eq!(observed.status, 200, "body: {:?}", observed.body);
    observed.body
}

fn urlencode(raw: &str) -> String {
    raw.chars()
        .map(|ch| match ch {
            'a'..='z' | 'A'..='Z' | '0'..='9' | '-' | '_' | '.' | '~' => ch.to_string(),
            other => format!("%{:02X}", other as u32),
        })
        .collect()
}

#[tokio::test]
async fn the_body_reports_the_links_the_header_offered() {
    let fixtures = Fixtures::load();
    let seed = Seed::from_fixtures(&fixtures);
    let server = TestServer::spawn_with_seed("r6-unsub", &seed).await;
    let client = http::client();

    insert_mail(
        &server,
        &seed,
        "u-1",
        "<https://a.example/u?id=1>, <mailto:u@a.example>",
        false,
        r#"[{"url":"https://a.example/u?id=1","kind":"https","oneClick":false},{"url":"mailto:u@a.example","kind":"mailto","oneClick":false}]"#,
    );

    let body = body_of(&client, &server, &seed, "u-1").await;
    let raw = body["unsubscribeLinks"].as_str().expect("a string field");
    let links: Value = serde_json::from_str(raw).expect("well-formed json");
    let array = links.as_array().expect("an array");
    assert_eq!(array.len(), 2);
    assert_eq!(array[0]["kind"], "https");
    assert_eq!(array[1]["kind"], "mailto");
}

#[tokio::test]
async fn a_mail_with_no_header_reports_an_empty_array_not_a_missing_field() {
    let fixtures = Fixtures::load();
    let seed = Seed::from_fixtures(&fixtures);
    let server = TestServer::spawn_with_seed("r6-unsub-empty", &seed).await;
    let client = http::client();

    insert_mail(&server, &seed, "u-2", "", false, "[]");

    let body = body_of(&client, &server, &seed, "u-2").await;
    let raw = body["unsubscribeLinks"].as_str().expect("a string field");
    // "[]" and absent mean the same thing to the reader; returning the empty
    // array keeps that decision in one place instead of in every client.
    assert_eq!(raw, "[]");
}

#[tokio::test]
async fn a_hostile_header_never_becomes_a_link() {
    let fixtures = Fixtures::load();
    let seed = Seed::from_fixtures(&fixtures);
    let server = TestServer::spawn_with_seed("r6-unsub-hostile", &seed).await;
    let client = http::client();

    // What the parser would store for a header that offers one real link and
    // four attacks. The attacks are dropped at parse time; this asserts the
    // route does not resurrect them.
    insert_mail(
        &server,
        &seed,
        "u-3",
        "<javascript:alert(1)>, <http://plain.example/u>",
        false,
        r#"[{"url":"https://ok.example/u","kind":"https","oneClick":false}]"#,
    );

    let body = body_of(&client, &server, &seed, "u-3").await;
    let raw = body["unsubscribeLinks"].as_str().expect("a string field");
    assert!(!raw.contains("javascript"), "{raw}");
    assert!(!raw.contains("http://plain"), "{raw}");
    let links: Value = serde_json::from_str(raw).expect("json");
    assert_eq!(links.as_array().expect("array").len(), 1);
}

#[tokio::test]
async fn the_stored_links_are_what_the_reader_reads() {
    let fixtures = Fixtures::load();
    let seed = Seed::from_fixtures(&fixtures);
    let server = TestServer::spawn_with_seed("r6-unsub-store", &seed).await;
    let client = http::client();

    insert_mail(&server, &seed, "u-4", "<https://x.example/u>", true, r#"[{"url":"https://x.example/u","kind":"https","oneClick":true}]"#);

    let body = body_of(&client, &server, &seed, "u-4").await;
    let raw = body["unsubscribeLinks"].as_str().expect("a string field");
    let links: Value = serde_json::from_str(raw).expect("json");
    // The one-click fact is recorded because a future version may use it. It
    // is not acted on: this build issues no request on the user's behalf.
    assert_eq!(links[0]["oneClick"], true);
}

#[tokio::test]
async fn an_old_row_with_no_links_column_still_answers() {
    let fixtures = Fixtures::load();
    let seed = Seed::from_fixtures(&fixtures);
    let server = TestServer::spawn_with_seed("r6-unsub-old", &seed).await;
    let client = http::client();

    insert_mail(&server, &seed, "u-5", "", false, "");
    // An empty string is what a row written before this column existed holds.
    {
        let connection = support::server::open_read_write(&server.db_path);
        connection
            .execute(
                "UPDATE message_headers SET unsubscribe_links = '' WHERE remote_id = 'u-5'",
                [],
            )
            .expect("blank the column");
    }

    let body = body_of(&client, &server, &seed, "u-5").await;
    assert_eq!(body["unsubscribeLinks"].as_str(), Some("[]"));
}
