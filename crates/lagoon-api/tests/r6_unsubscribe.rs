//! R6 · `List-Unsubscribe` reaches the reader (plan §8.4).
//!
//! The rule under test is as much about what is *absent* as what is present:
//!
//! * the stored links come from the header, once, at sync;
//! * only `https:` and `mailto:` survive - everything else a stranger can write
//!   into a header is dropped before it can become a button;
//! * the body route reports them, so the reader can offer a way out;
//! * **only an RFC 8058 one-click target is ever contacted**, and only through
//!   the guards in `lagoon_api::unsubscribe`; a page link, a private address or
//!   a mailto is refused with the contract's 422 code instead of a request.
//!
//! The route tests inject a scripted firer (`Firer`), so this file can prove
//! what would be sent without a socket and without unsubscribing anyone.

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
            params![seed.account_uuid().as_bytes().as_slice(), remote_id, sealed],
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

    insert_mail(
        &server,
        &seed,
        "u-4",
        "<https://x.example/u>",
        true,
        r#"[{"url":"https://x.example/u","kind":"https","oneClick":true}]"#,
    );

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

/* ------------------------------------------------- one-click execution ---- */

/// A firer that records what it was asked to do and answers from a script.
struct ScriptedFirer {
    reply: lagoon_api::unsubscribe::Reply,
    seen: std::sync::Mutex<Vec<String>>,
}

impl ScriptedFirer {
    fn new(reply: lagoon_api::unsubscribe::Reply) -> std::sync::Arc<Self> {
        std::sync::Arc::new(Self {
            reply,
            seen: std::sync::Mutex::new(Vec::new()),
        })
    }

    fn seen(&self) -> Vec<String> {
        self.seen.lock().expect("seen lock").clone()
    }
}

impl lagoon_api::unsubscribe::Firer for ScriptedFirer {
    fn fire(&self, target: &lagoon_api::unsubscribe::Target) -> lagoon_api::unsubscribe::Reply {
        self.seen
            .lock()
            .expect("seen lock")
            .push(target.url.clone());
        self.reply.clone()
    }
}

fn one_click_links(url: &str) -> String {
    format!(r#"[{{"url":"{url}","kind":"https","oneClick":true}}]"#)
}

async fn post(
    client: &http::HttpClient,
    server: &TestServer,
    path: &str,
    body: Option<&serde_json::Value>,
) -> http::Observed {
    let url = format!("{}{}", server.base_url, path);
    let mut headers = server.auth_headers();
    headers.push(("content-type".to_owned(), "application/json".to_owned()));
    match body {
        Some(value) => {
            http::request_with_body(client, "POST", &url, &headers, value.to_string().as_bytes())
                .await
        }
        None => http::request_with_body(client, "POST", &url, &headers, &[]).await,
    }
}

#[tokio::test]
async fn a_one_click_target_is_fired_once_and_the_mail_is_settled() {
    let firer = ScriptedFirer::new(lagoon_api::unsubscribe::Reply::Unsubscribed {
        status: 200,
        publisher: "a.example".to_owned(),
    });
    let (server, fixtures) =
        TestServer::spawn_with_unsubscribe_firer("unsub-run", firer.clone()).await;
    let seed = Seed::from_fixtures(&fixtures);
    let client = http::client();
    insert_mail(
        &server,
        &seed,
        "u-run",
        "<https://a.example/u?id=1>",
        true,
        &one_click_links("https://a.example/u?id=1"),
    );
    {
        let connection = support::server::open_read_write(&server.db_path);
        connection
            .execute(
                "INSERT INTO advice (account_id, remote_id, action, category, confidence, rationale, source, decision)
                 VALUES (?, 'u-run', 'unsubscribe', 'newsletter', 'high', '发布方支持一键退订', 'heuristic', 'pending')",
                params![seed.account_uuid().as_bytes().as_slice()],
            )
            .expect("advice row");
    }

    let observed = post(
        &client,
        &server,
        &format!(
            "/api/messages/u-run/unsubscribe?accountId={}",
            seed.account_id
        ),
        None,
    )
    .await;

    assert_eq!(observed.status, 200, "{:?}", observed.body);
    assert_eq!(observed.body["unsubscribed"], true);
    assert_eq!(observed.body["publisher"], "a.example");
    assert!(observed.body["actionId"].as_i64().unwrap_or(0) > 0);
    assert_eq!(firer.seen(), vec!["https://a.example/u?id=1".to_owned()]);

    let connection = support::server::open_read_write(&server.db_path);
    let (archived, read): (i64, i64) = connection
        .query_row(
            "SELECT is_archived, is_read FROM message_headers WHERE remote_id = 'u-run'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("mail row");
    assert_eq!(
        (archived, read),
        (1, 1),
        "unsubscribed mail leaves the inbox"
    );
    let decision: String = connection
        .query_row(
            "SELECT decision FROM advice WHERE remote_id = 'u-run'",
            [],
            |row| row.get(0),
        )
        .expect("advice row");
    assert_eq!(decision, "accepted");
    // Two rows: the irreversible fact and the undoable side effect.
    let kinds: Vec<String> = {
        let mut statement = connection
            .prepare("SELECT kind FROM ai_actions ORDER BY id")
            .expect("statement");
        statement
            .query_map([], |row| row.get(0))
            .expect("rows")
            .map(|row| row.expect("kind"))
            .collect()
    };
    assert_eq!(kinds, ["archive", "unsubscribe"]);
}

#[tokio::test]
async fn a_page_only_target_is_refused_without_contacting_anyone() {
    let firer = ScriptedFirer::new(lagoon_api::unsubscribe::Reply::Failed {
        reason: "must-not-fire".to_owned(),
    });
    let (server, fixtures) =
        TestServer::spawn_with_unsubscribe_firer("unsub-page", firer.clone()).await;
    let seed = Seed::from_fixtures(&fixtures);
    let client = http::client();
    insert_mail(
        &server,
        &seed,
        "u-page",
        "<https://a.example/prefs>",
        false,
        r#"[{"url":"https://a.example/prefs","kind":"https","oneClick":false}]"#,
    );

    let observed = post(
        &client,
        &server,
        &format!(
            "/api/messages/u-page/unsubscribe?accountId={}",
            seed.account_id
        ),
        None,
    )
    .await;

    assert_eq!(observed.status, 422, "{:?}", observed.body);
    assert_eq!(observed.body["error"], "unsubscribe-page-required");
    assert!(
        firer.seen().is_empty(),
        "a page link is not a machine request"
    );
}

#[tokio::test]
async fn a_private_address_is_refused_by_the_guard() {
    let firer = ScriptedFirer::new(lagoon_api::unsubscribe::Reply::Failed {
        reason: "must-not-fire".to_owned(),
    });
    let (server, fixtures) =
        TestServer::spawn_with_unsubscribe_firer("unsub-private", firer.clone()).await;
    let seed = Seed::from_fixtures(&fixtures);
    let client = http::client();
    insert_mail(
        &server,
        &seed,
        "u-private",
        "<https://127.0.0.1/unsub>",
        true,
        &one_click_links("https://127.0.0.1/unsub"),
    );

    let observed = post(
        &client,
        &server,
        &format!(
            "/api/messages/u-private/unsubscribe?accountId={}",
            seed.account_id
        ),
        None,
    )
    .await;

    assert_eq!(observed.status, 422, "{:?}", observed.body);
    assert_eq!(observed.body["error"], "unsubscribe-manual-required");
    assert!(firer.seen().is_empty());
}

#[tokio::test]
async fn a_failed_request_leaves_the_mail_in_the_inbox() {
    let firer = ScriptedFirer::new(lagoon_api::unsubscribe::Reply::Failed {
        reason: "http-405".to_owned(),
    });
    let (server, fixtures) =
        TestServer::spawn_with_unsubscribe_firer("unsub-fail", firer.clone()).await;
    let seed = Seed::from_fixtures(&fixtures);
    let client = http::client();
    insert_mail(
        &server,
        &seed,
        "u-fail",
        "<https://a.example/u>",
        true,
        &one_click_links("https://a.example/u"),
    );

    let observed = post(
        &client,
        &server,
        &format!(
            "/api/messages/u-fail/unsubscribe?accountId={}",
            seed.account_id
        ),
        None,
    )
    .await;

    assert_eq!(observed.status, 502, "{:?}", observed.body);
    assert_eq!(observed.body["error"], "unsubscribe-failed");
    let archived: i64 = support::server::open_read_write(&server.db_path)
        .query_row(
            "SELECT is_archived FROM message_headers WHERE remote_id = 'u-fail'",
            [],
            |row| row.get(0),
        )
        .expect("mail row");
    assert_eq!(archived, 0, "nothing moved, so nothing claims it did");
}

#[tokio::test]
async fn unknown_mail_answers_404() {
    let firer = ScriptedFirer::new(lagoon_api::unsubscribe::Reply::Failed {
        reason: "must-not-fire".to_owned(),
    });
    let (server, fixtures) =
        TestServer::spawn_with_unsubscribe_firer("unsub-404", firer.clone()).await;
    let seed = Seed::from_fixtures(&fixtures);
    let client = http::client();

    let observed = post(
        &client,
        &server,
        &format!(
            "/api/messages/nope/unsubscribe?accountId={}",
            seed.account_id
        ),
        None,
    )
    .await;

    assert_eq!(observed.status, 404);
    assert!(firer.seen().is_empty());
}

#[tokio::test]
async fn bulk_asks_each_publisher_once_and_reports_every_mail() {
    let firer = ScriptedFirer::new(lagoon_api::unsubscribe::Reply::Unsubscribed {
        status: 200,
        publisher: "a.example".to_owned(),
    });
    let (server, fixtures) =
        TestServer::spawn_with_unsubscribe_firer("unsub-bulk", firer.clone()).await;
    let seed = Seed::from_fixtures(&fixtures);
    let client = http::client();
    // One newsletter sent twice: one subscription, two mails.
    for remote_id in ["u-b1", "u-b2"] {
        insert_mail(
            &server,
            &seed,
            remote_id,
            "<https://a.example/u>",
            true,
            &one_click_links("https://a.example/u"),
        );
    }

    let observed = post(
        &client,
        &server,
        &format!("/api/unsubscribe-bulk?accountId={}", seed.account_id),
        Some(&serde_json::json!({ "remoteIds": ["u-b1", "u-b2"] })),
    )
    .await;

    assert_eq!(observed.status, 200, "{:?}", observed.body);
    let items = observed.body["items"].as_array().expect("items");
    assert_eq!(items.len(), 2);
    assert!(items.iter().all(|item| item["ok"] == true));
    assert_eq!(
        firer.seen(),
        vec!["https://a.example/u".to_owned()],
        "one subscription is one request"
    );
}
