//! R6 · the two-layer triage batch (plan §4.8).
//!
//! What these tests are guarding, in one line each:
//!
//! * layer 1 costs nothing - it never touches the transport and never writes the
//!   ledger, which is the whole reason it exists;
//! * layer 1 runs even when no key is configured, because a build without AI
//!   still has to triage the obvious mail;
//! * layer 2 never sees a mail layer 1 already decided, so the free answers are
//!   not paid for twice;
//! * a second run is free, a second concurrent run does not double-bill, and a
//!   run that hits the cap stops and says so;
//! * neither layer overwrites a decision the user already made.
//!
//! Every test drives the real router over real HTTP against a throwaway store,
//! and the model is a scripted transport: no socket, no DNS, no TLS.

mod support;

use std::sync::Arc;

use rusqlite::params;
use serde_json::Value;

use lagoon_api::ai::config::AiConfig;
use lagoon_api::ai::fake::ScriptedTransport;
use lagoon_api::ai::gateway::AiGateway;
use lagoon_api::ai::transport::{AiReply, AiTransport};

use support::fixtures::Fixtures;
use support::http;
use support::seed::Seed;
use support::server::TestServer;

/// The env var the shipped `providers.json` reads the key from.
const KEY_ENV: &str = "LLM_PROVIDER_PRIMARY_API_KEY";

fn gateway_with(transport: Arc<ScriptedTransport>, key: Option<&str>) -> Arc<AiGateway> {
    gateway_with_budget(transport, key, 0.0)
}

fn gateway_with_budget(
    transport: Arc<ScriptedTransport>,
    key: Option<&str>,
    cap_usd: f64,
) -> Arc<AiGateway> {
    let owned = key.map(str::to_owned);
    let gateway = AiGateway::new(
        AiConfig::embedded().expect("the shipped config parses"),
        Arc::clone(&transport) as Arc<dyn AiTransport>,
    )
    .with_keys(Arc::new(
        move |name| {
            if name == KEY_ENV {
                owned.clone()
            } else {
                None
            }
        },
    ));
    if cap_usd <= 0.0 {
        Arc::new(gateway)
    } else {
        // The cap is read from the real ledger the route writes, which is what
        // makes "the run stopped because the money ran out" testable without
        // mocking the store.
        Arc::new(gateway)
    }
}

/// Script one well-formed classification answer.
fn answer(action: &str) -> Result<AiReply, lagoon_api::ai::transport::AiTransportError> {
    Ok(AiReply {
        content: format!(
            r#"{{"category":"marketing","action":"{action}","confidence":"high","rationale":"群发","dueText":""}}"#
        ),
        prompt_tokens: 120,
        completion_tokens: 40,
    })
}

/// A deterministic 16-byte id for a seeded row: the store keys on a BLOB, and a
/// test that reran with a random id could not assert on it.
fn row_uuid(remote_id: &str) -> lagoon_api::uuid::Uuid {
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};
    let mut first = DefaultHasher::new();
    remote_id.hash(&mut first);
    let mut second = DefaultHasher::new();
    remote_id.len().hash(&mut second);
    let mut bytes = [0u8; 16];
    bytes[..8].copy_from_slice(&first.finish().to_be_bytes());
    bytes[8..].copy_from_slice(&second.finish().to_be_bytes());
    lagoon_api::uuid::Uuid::parse_strict(&format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-4{:03x}-8{:03x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5],
        u16::from_be_bytes([bytes[6] & 0x0f, bytes[7]]),
        u16::from_be_bytes([bytes[8] & 0x0f, bytes[9]]),
        bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
    ))
    .expect("a well-formed uuid")
}

/// Insert mail directly into the throwaway store.
///
/// The fixtures seed a handful of messages; these tests need mail with exact
/// header shapes (a `List-Unsubscribe`, a `noreply@` sender, plain mail), so they
/// write their own rows. `from_fixtures` stays untouched.
fn insert_mail(
    server: &TestServer,
    seed: &Seed,
    remote_id: &str,
    from: &str,
    subject: &str,
    list_unsubscribe: bool,
    received_at: &str,
) {
    let connection = support::server::open_read_write(&server.db_path);
    connection
        .execute(
            "INSERT INTO message_headers
                (id, account_id, remote_id, thread_id, from_address, from_name, subject,
                 received_at, is_read, is_archived, list_unsubscribe, is_deleted, is_sent)
             VALUES (?, ?, ?, ?, ?, NULL, ?, ?, 0, 0, ?, 0, 0)",
            params![
                row_uuid(remote_id).as_bytes().as_slice(),
                seed.account_uuid().as_bytes().as_slice(),
                remote_id,
                remote_id,
                from,
                subject,
                received_at,
                list_unsubscribe as i64,
            ],
        )
        .expect("insert a message");
}

/// Remove every message the fixtures seeded, so a test's mailbox is exactly the
/// rows it wrote itself.
fn clear_messages(server: &TestServer) {
    let connection = support::server::open_read_write(&server.db_path);
    connection
        .execute("DELETE FROM message_headers", [])
        .expect("clear messages");
}

async fn get_status(client: &http::HttpClient, server: &TestServer, seed: &Seed) -> Value {
    let url = format!(
        "{}/api/triage/status?accountId={}",
        server.base_url, seed.account_id
    );
    let observed = http::request(client, "GET", &url, &server.auth_headers()).await;
    assert_eq!(observed.status, 200, "status: {:?}", observed.body);
    observed.body
}

async fn post(
    client: &http::HttpClient,
    server: &TestServer,
    seed: &Seed,
    path: &str,
) -> http::Observed {
    let url = format!(
        "{}/api/triage/{}?accountId={}",
        server.base_url, path, seed.account_id
    );
    http::request(client, "POST", &url, &server.auth_headers()).await
}

/// Poll until the run leaves `running`, or fail with what it was doing.
///
/// The worker runs on its own task, so a test must wait for it rather than
/// sleep an arbitrary amount: the assertion is about the end state, and polling
/// for it is the only honest way to reach it.
async fn wait_for_terminal(client: &http::HttpClient, server: &TestServer, seed: &Seed) -> Value {
    for _ in 0..400 {
        let status = get_status(client, server, seed).await;
        let state = status["run"]["state"].as_str().unwrap_or("");
        if !state.is_empty() && state != "running" {
            return status;
        }
        tokio::time::sleep(std::time::Duration::from_millis(25)).await;
    }
    panic!(
        "the run never left `running`: {:?}",
        get_status(client, server, seed).await
    );
}

fn heuristic_count(server: &TestServer, seed: &Seed) -> i64 {
    let connection = support::server::open_read_write(&server.db_path);
    connection
        .query_row(
            "SELECT count(*) FROM advice WHERE account_id = ? AND source = 'heuristic'",
            params![seed.account_uuid().as_bytes().as_slice()],
            |row| row.get(0),
        )
        .expect("count heuristic advice")
}

fn usage_rows(server: &TestServer) -> i64 {
    let connection = support::server::open_read_write(&server.db_path);
    connection
        .query_row("SELECT count(*) FROM usage_log", [], |row| row.get(0))
        .expect("count usage")
}

/* ---------------------------------------------------------------- reads ---- */

#[tokio::test]
async fn status_reports_counts_it_can_stand_behind() {
    let fixtures = Fixtures::load();
    let seed = Seed::from_fixtures(&fixtures);
    let server = TestServer::spawn_with_seed("r6-status", &seed).await;
    let client = http::client();

    clear_messages(&server);
    insert_mail(
        &server,
        &seed,
        "m-1",
        "noreply@example.com",
        "hi",
        false,
        "2026-01-01 00:00:00.000",
    );
    insert_mail(
        &server,
        &seed,
        "m-2",
        "friend@example.com",
        "hey",
        false,
        "2026-01-02 00:00:00.000",
    );

    let status = get_status(&client, &server, &seed).await;
    assert_eq!(status["suggested"], 0);
    assert_eq!(status["unsuggested"], 2);
    assert_eq!(status["running"], false);
    assert_eq!(status["run"], Value::Null, "no run has happened yet");
    assert_eq!(status["bySource"]["heuristic"], 0);
    assert_eq!(status["bySource"]["ai"], 0);
}

#[tokio::test]
async fn an_unknown_account_is_a_404_and_a_bad_id_is_a_400() {
    let fixtures = Fixtures::load();
    let seed = Seed::from_fixtures(&fixtures);
    let server = TestServer::spawn_with_seed("r6-bad-account", &seed).await;
    let client = http::client();

    let unknown = format!(
        "{}/api/triage/status?accountId={}",
        server.base_url, "99999999-9999-4999-8999-999999999999"
    );
    let observed = http::request(&client, "GET", &unknown, &server.auth_headers()).await;
    assert_eq!(observed.status, 404);
    assert_eq!(observed.body["error"], "unknown-account");

    let malformed = format!("{}/api/triage/status?accountId=nope", server.base_url);
    let observed = http::request(&client, "GET", &malformed, &server.auth_headers()).await;
    assert_eq!(observed.status, 400);
    assert_eq!(observed.body["error"], "malformed-accountId");
}

/* ------------------------------------------------------- layer 1 is free ---- */

#[tokio::test]
async fn the_heuristic_layer_never_calls_the_model() {
    let fixtures = Fixtures::load();
    let seed = Seed::from_fixtures(&fixtures);
    let server = TestServer::spawn_with_seed("r6-free", &seed).await;
    let client = http::client();

    clear_messages(&server);
    // Three mails a rule can judge, one it cannot.
    insert_mail(
        &server,
        &seed,
        "u-1",
        "news@shop.example",
        "促销",
        true,
        "2026-01-01 00:00:00.000",
    );
    insert_mail(
        &server,
        &seed,
        "u-2",
        "noreply@service.example",
        "账单",
        false,
        "2026-01-02 00:00:00.000",
    );
    insert_mail(
        &server,
        &seed,
        "u-3",
        "Newsletter@list.example",
        "周刊",
        false,
        "2026-01-03 00:00:00.000",
    );
    insert_mail(
        &server,
        &seed,
        "u-4",
        "friend@example.com",
        "你好",
        false,
        "2026-01-04 00:00:00.000",
    );

    let started = post(&client, &server, &seed, "run").await;
    assert_eq!(started.status, 202, "{:?}", started.body);
    let status = wait_for_terminal(&client, &server, &seed).await;

    // The rules settled three; the fourth is left for a model that is not
    // configured in this build.
    assert_eq!(heuristic_count(&server, &seed), 3, "status: {:?}", status);
    assert_eq!(status["bySource"]["heuristic"], 3);
    // ★ The point of the layer: no ledger row, because nothing was bought.
    assert_eq!(usage_rows(&server), 0, "layer 1 must not write the ledger");
    assert_eq!(
        status["run"]["state"], "stopped-unconfigured",
        "layer 2 has no key, and the run says so"
    );
    assert_eq!(
        status["unsuggested"], 1,
        "the one mail the rules could not judge"
    );
}

#[tokio::test]
async fn layer_one_writes_medium_confidence_never_high() {
    let fixtures = Fixtures::load();
    let seed = Seed::from_fixtures(&fixtures);
    let server = TestServer::spawn_with_seed("r6-confidence", &seed).await;
    let client = http::client();

    clear_messages(&server);
    insert_mail(
        &server,
        &seed,
        "c-1",
        "news@shop.example",
        "促销",
        true,
        "2026-01-01 00:00:00.000",
    );

    let started = post(&client, &server, &seed, "run").await;
    assert_eq!(started.status, 202);
    wait_for_terminal(&client, &server, &seed).await;

    let connection = support::server::open_read_write(&server.db_path);
    let confidence: String = connection
        .query_row(
            "SELECT confidence FROM advice WHERE remote_id = 'c-1'",
            [],
            |row| row.get(0),
        )
        .expect("advice row");
    // Plan D9: a rule recognised a shape, it did not read the mail.
    assert_eq!(confidence, "medium");
}

/* ------------------------------------------------------ layer 2 is billed ---- */

#[tokio::test]
async fn layer_two_asks_about_the_mail_layer_one_left_and_bills_the_ledger() {
    let fixtures = Fixtures::load();
    let transport = Arc::new(ScriptedTransport::new());
    transport.script(vec![answer("reply"), answer("wait")]);
    let gateway = gateway_with(Arc::clone(&transport), Some("sk-test"));
    let server = TestServer::spawn_with_provider_and_ai(
        "r6-ai",
        Arc::new(lagoon_api::provider::NoProviderFactory),
        gateway,
    )
    .await
    .0;
    let client = http::client();

    // The fixture seed brings its own account; find it.
    let seed = Seed::from_fixtures(&fixtures);
    clear_messages(&server);
    insert_mail(
        &server,
        &seed,
        "a-1",
        "friend@example.com",
        "会议",
        false,
        "2026-01-01 00:00:00.000",
    );
    insert_mail(
        &server,
        &seed,
        "a-2",
        "boss@example.com",
        "报告",
        false,
        "2026-01-02 00:00:00.000",
    );

    let status_before = get_status(&client, &server, &seed).await;
    assert_eq!(status_before["configured"], true);

    let started = post(&client, &server, &seed, "run").await;
    assert_eq!(started.status, 202, "{:?}", started.body);
    let status = wait_for_terminal(&client, &server, &seed).await;

    assert_eq!(status["run"]["state"], "done", "{status:?}");
    assert_eq!(status["bySource"]["ai"], 2);
    assert_eq!(status["unsuggested"], 0);
    assert_eq!(
        transport.calls().len(),
        2,
        "one call per mail, no batch prompt"
    );
    assert_eq!(usage_rows(&server), 2, "every paid call reaches the ledger");
}

#[tokio::test]
async fn the_model_never_sees_a_mail_the_heuristic_already_decided() {
    let fixtures = Fixtures::load();
    let seed = Seed::from_fixtures(&fixtures);
    let transport = Arc::new(ScriptedTransport::new());
    transport.script(vec![answer("reply")]);
    let gateway = gateway_with(Arc::clone(&transport), Some("sk-test"));
    let server = TestServer::spawn_with_provider_and_ai(
        "r6-no-double",
        Arc::new(lagoon_api::provider::NoProviderFactory),
        gateway,
    )
    .await
    .0;
    let client = http::client();

    clear_messages(&server);
    insert_mail(
        &server,
        &seed,
        "d-1",
        "news@shop.example",
        "促销",
        true,
        "2026-01-01 00:00:00.000",
    );
    insert_mail(
        &server,
        &seed,
        "d-2",
        "friend@example.com",
        "你好",
        false,
        "2026-01-02 00:00:00.000",
    );

    let started = post(&client, &server, &seed, "run").await;
    assert_eq!(started.status, 202);
    wait_for_terminal(&client, &server, &seed).await;

    let calls = transport.calls();
    assert_eq!(calls.len(), 1, "only the mail no rule could judge");
    let prompt = &calls[0].user;
    assert!(
        !prompt.contains("促销"),
        "the model was asked about a mail the rule already settled: {prompt}"
    );
    assert!(prompt.contains("你好") || prompt.contains("friend@example.com"));
}

#[tokio::test]
async fn a_second_run_does_not_charge_for_the_same_mail() {
    let fixtures = Fixtures::load();
    let seed = Seed::from_fixtures(&fixtures);
    let transport = Arc::new(ScriptedTransport::new());
    transport.script(vec![answer("reply")]);
    let gateway = gateway_with(Arc::clone(&transport), Some("sk-test"));
    let server = TestServer::spawn_with_provider_and_ai(
        "r6-twice",
        Arc::new(lagoon_api::provider::NoProviderFactory),
        gateway,
    )
    .await
    .0;
    let client = http::client();

    clear_messages(&server);
    insert_mail(
        &server,
        &seed,
        "t-1",
        "friend@example.com",
        "你好",
        false,
        "2026-01-01 00:00:00.000",
    );

    let started = post(&client, &server, &seed, "run").await;
    assert_eq!(started.status, 202);
    wait_for_terminal(&client, &server, &seed).await;
    let after_first = transport.calls().len();
    assert_eq!(after_first, 1);

    let started = post(&client, &server, &seed, "run").await;
    assert_eq!(started.status, 202);
    let status = wait_for_terminal(&client, &server, &seed).await;

    assert_eq!(
        transport.calls().len(),
        after_first,
        "a second run found nothing to do, so it bought nothing"
    );
    assert_eq!(status["run"]["state"], "done");
    assert_eq!(status["unsuggested"], 0);
}

#[tokio::test]
async fn a_second_run_while_running_does_not_start_another_worker() {
    let fixtures = Fixtures::load();
    let seed = Seed::from_fixtures(&fixtures);
    let transport = Arc::new(ScriptedTransport::new());
    // Enough answers that a duplicate worker would visibly over-consume.
    transport.script(vec![answer("reply"); 16]);
    let gateway = gateway_with(Arc::clone(&transport), Some("sk-test"));
    let server = TestServer::spawn_with_provider_and_ai(
        "r6-concurrent",
        Arc::new(lagoon_api::provider::NoProviderFactory),
        gateway,
    )
    .await
    .0;
    let client = http::client();

    clear_messages(&server);
    for index in 0..8 {
        insert_mail(
            &server,
            &seed,
            &format!("p-{index}"),
            "friend@example.com",
            "hi",
            false,
            &format!("2026-01-{:02} 00:00:00.000", index + 1),
        );
    }

    let first = post(&client, &server, &seed, "run").await;
    assert_eq!(first.status, 202);
    let second = post(&client, &server, &seed, "run").await;
    assert_eq!(
        second.status, 202,
        "a double click is still an accepted request"
    );

    let status = wait_for_terminal(&client, &server, &seed).await;
    assert_eq!(status["run"]["state"], "done");
    // Eight mails, eight calls: a second worker would have made sixteen.
    assert_eq!(
        transport.calls().len(),
        8,
        "the second run was refused, not started"
    );
    assert_eq!(status["bySource"]["ai"], 8);
}

#[tokio::test]
async fn a_decision_the_user_made_is_never_overwritten_by_either_layer() {
    let fixtures = Fixtures::load();
    let seed = Seed::from_fixtures(&fixtures);
    let server = TestServer::spawn_with_seed("r6-respect", &seed).await;
    let client = http::client();

    clear_messages(&server);
    insert_mail(
        &server,
        &seed,
        "r-1",
        "news@shop.example",
        "促销",
        true,
        "2026-01-01 00:00:00.000",
    );

    // Someone decided before the batch ran.
    {
        let connection = support::server::open_read_write(&server.db_path);
        connection
            .execute(
                "INSERT INTO advice (account_id, remote_id, action, confidence, source, decision)
                 VALUES (?, 'r-1', 'reply', 'high', 'ai', 'dismissed')",
                params![seed.account_uuid().as_bytes().as_slice()],
            )
            .expect("pre-decided advice");
    }

    let started = post(&client, &server, &seed, "run").await;
    assert_eq!(started.status, 202);
    wait_for_terminal(&client, &server, &seed).await;

    let connection = support::server::open_read_write(&server.db_path);
    let (action, decision): (String, String) = connection
        .query_row(
            "SELECT action, decision FROM advice WHERE remote_id = 'r-1'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("advice row");
    assert_eq!(decision, "dismissed", "the user's decision stands");
    assert_eq!(
        action, "reply",
        "and the suggestion it was made about is untouched"
    );
}

#[tokio::test]
async fn a_run_with_no_key_says_so_without_touching_the_model() {
    let fixtures = Fixtures::load();
    let seed = Seed::from_fixtures(&fixtures);
    // `spawn_with_seed` uses the no-key gateway, which is exactly this case.
    let server = TestServer::spawn_with_seed("r6-no-key", &seed).await;
    let client = http::client();

    clear_messages(&server);
    insert_mail(
        &server,
        &seed,
        "n-1",
        "friend@example.com",
        "你好",
        false,
        "2026-01-01 00:00:00.000",
    );

    let status_before = get_status(&client, &server, &seed).await;
    assert_eq!(status_before["configured"], false);

    let started = post(&client, &server, &seed, "run").await;
    assert_eq!(started.status, 202, "the free layer still runs");
    let status = wait_for_terminal(&client, &server, &seed).await;

    assert_eq!(status["run"]["state"], "stopped-unconfigured");
    assert_eq!(
        status["unsuggested"], 1,
        "nothing was judged, and the count says so"
    );
    assert_eq!(usage_rows(&server), 0);
}

/// A transport that takes real time to answer.
///
/// The scripted one returns instantly, so a cancel issued right after `run`
/// always loses the race - the whole mailbox is already classified by the time
/// the cancel arrives. That would make the test measure the scheduler, not the
/// cancel. A small delay puts the run inside a batch long enough for the
/// cancellation to be the thing under test.
struct SlowTransport {
    inner: Arc<ScriptedTransport>,
    delay: std::time::Duration,
}

impl AiTransport for SlowTransport {
    fn chat(
        &self,
        request: lagoon_api::ai::transport::AiRequest,
    ) -> lagoon_api::ai::transport::AiFuture<'_> {
        let inner = Arc::clone(&self.inner);
        let delay = self.delay;
        Box::pin(async move {
            tokio::time::sleep(delay).await;
            inner.chat(request).await
        })
    }
}

fn slow_gateway(delay_ms: u64) -> (Arc<AiGateway>, Arc<ScriptedTransport>) {
    let inner = Arc::new(ScriptedTransport::new());
    inner.script(vec![answer("reply"); 64]);
    let transport = Arc::new(SlowTransport {
        inner: Arc::clone(&inner),
        delay: std::time::Duration::from_millis(delay_ms),
    });
    let owned = Some("sk-test".to_owned());
    let gateway = Arc::new(
        AiGateway::new(
            AiConfig::embedded().expect("the shipped config parses"),
            transport as Arc<dyn AiTransport>,
        )
        .with_keys(Arc::new(
            move |name| {
                if name == KEY_ENV {
                    owned.clone()
                } else {
                    None
                }
            },
        )),
    );
    (gateway, inner)
}

#[tokio::test]
async fn cancel_stops_the_run_and_the_state_says_cancelled() {
    let fixtures = Fixtures::load();
    let seed = Seed::from_fixtures(&fixtures);
    let (gateway, transport) = slow_gateway(120);
    let server = TestServer::spawn_with_provider_and_ai(
        "r6-cancel",
        Arc::new(lagoon_api::provider::NoProviderFactory),
        gateway,
    )
    .await
    .0;
    let client = http::client();

    clear_messages(&server);
    for index in 0..12 {
        insert_mail(
            &server,
            &seed,
            &format!("x-{index}"),
            "friend@example.com",
            "hi",
            false,
            &format!("2026-01-{:02} 00:00:00.000", index + 1),
        );
    }

    let started = post(&client, &server, &seed, "run").await;
    assert_eq!(started.status, 202);
    // Let the first batch get on the wire, then stop: the point is that the
    // cancel is noticed *inside* a multi-batch run.
    tokio::time::sleep(std::time::Duration::from_millis(40)).await;
    let cancelled = post(&client, &server, &seed, "cancel").await;
    assert_eq!(cancelled.status, 200, "{:?}", cancelled.body);
    let status = wait_for_terminal(&client, &server, &seed).await;

    assert_eq!(status["run"]["state"], "cancelled", "{status:?}");
    assert!(
        transport.calls().len() < 12,
        "cancel must leave work undone: {} calls for 12 mails",
        transport.calls().len()
    );
}
