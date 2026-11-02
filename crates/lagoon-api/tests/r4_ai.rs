//! R4: the AI plane - a read-only advisor that tells the truth.
//!
//! What these pin:
//! * the status route says what is really true (a key, a wallet, a provider
//!   that keeps failing);
//! * a summary is computed once and cached - the user is not charged twice
//!   for the same mail;
//! * without a key the answer is 503 ai-not-configured, never a 500 and
//!   never a fabricated summary;
//! * a draft is text the user can read back, and the AI **never** touches the
//!   mailbox (constitution §2);
//! * every call lands in the cost ledger.

mod support;

use std::sync::Arc;

use serde_json::{json, Value};

use lagoon_api::ai::config::AiConfig;
use lagoon_api::ai::fake::ScriptedTransport;
use lagoon_api::ai::gateway::AiGateway;
use lagoon_api::ai::transport::{AiReply, AiTransport, AiTransportError};

use support::http;
use support::server::{body_key, open_read_write, TestServer};

const ACCOUNT_A: &str = "11111111-1111-4111-8111-111111111111";
/// Seeded with a header and no body (the `body.provider-unconfigured`
/// fixture).
const REMOTE: &str = "fixture-msg-1";
const KEY_ENV: &str = "LLM_PROVIDER_PRIMARY_API_KEY";

fn uuid_bytes(raw: &str) -> Vec<u8> {
    lagoon_api::uuid::Uuid::parse_strict(raw)
        .expect("uuid")
        .as_bytes()
        .to_vec()
}

/// A gateway whose transport answers from a script and whose key is `key`.
///
/// The key source is injected, so the tests never depend on the environment
/// the suite happens to run in.
fn gateway_with(transport: Arc<ScriptedTransport>, key: Option<&str>) -> Arc<AiGateway> {
    let owned = key.map(str::to_owned);
    Arc::new(
        AiGateway::new(
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
        )),
    )
}

/// Store a sealed body for the message, so the AI has something to read.
fn seed_body(server: &TestServer, text: &str) {
    let connection = open_read_write(&server.db_path);
    let sealed = body_key().seal(text).expect("seal");
    connection
        .execute(
            "INSERT INTO message_bodies (account_id, remote_id, body_cipher)
             VALUES (?1, ?2, ?3)
             ON CONFLICT (account_id, remote_id)
             DO UPDATE SET body_cipher = excluded.body_cipher",
            rusqlite::params![uuid_bytes(ACCOUNT_A), REMOTE, sealed],
        )
        .expect("seed body");
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

fn usage_rows(server: &TestServer) -> i64 {
    let connection = open_read_write(&server.db_path);
    connection
        .query_row("SELECT count(*) FROM usage_log", [], |row| row.get(0))
        .expect("usage count")
}

#[tokio::test]
async fn the_status_says_not_configured_when_there_is_no_key() {
    let transport = Arc::new(ScriptedTransport::new());
    let gateway = gateway_with(transport, None);
    let (server, _fixtures) =
        TestServer::spawn_with_provider_and_ai("r4-status-off", Arc::new(NoProvider), gateway)
            .await;
    let client = http::client();

    let observed = get(&client, &server, "/api/ai-status").await;
    assert_eq!(observed.status, 200, "{:?}", observed.body);
    assert_eq!(observed.body["configured"], json!(false));
    assert_eq!(observed.body["creditExhausted"], json!(false));
    assert_eq!(observed.body["circuitOpen"], json!(false));
}

#[tokio::test]
async fn the_status_says_configured_when_the_key_is_there() {
    let transport = Arc::new(ScriptedTransport::new());
    let gateway = gateway_with(transport, Some("secret"));
    let (server, _fixtures) =
        TestServer::spawn_with_provider_and_ai("r4-status-on", Arc::new(NoProvider), gateway).await;
    let client = http::client();

    let observed = get(&client, &server, "/api/ai-status").await;
    assert_eq!(observed.status, 200, "{:?}", observed.body);
    assert_eq!(observed.body["configured"], json!(true));
}

#[tokio::test]
async fn a_summary_is_computed_once_and_then_comes_from_the_cache() {
    let transport = Arc::new(ScriptedTransport::new());
    transport.script(vec![Ok(AiReply {
        content: r#"{"summary":"请在周五前确认订单","actionItems":["回复确认"]}"#.to_owned(),
        prompt_tokens: 1000,
        completion_tokens: 1000,
    })]);
    let gateway = gateway_with(Arc::clone(&transport), Some("secret"));
    let (server, _fixtures) =
        TestServer::spawn_with_provider_and_ai("r4-summary", Arc::new(NoProvider), gateway).await;
    seed_body(&server, "这是一封关于订单的邮件。");
    let client = http::client();

    let path = format!("/api/messages/{REMOTE}/summary?accountId={ACCOUNT_A}");
    let first = get(&client, &server, &path).await;
    assert_eq!(first.status, 200, "{:?}", first.body);
    assert_eq!(first.body["remoteId"], json!(REMOTE));
    assert_eq!(first.body["summary"], json!("请在周五前确认订单"));
    assert_eq!(first.body["actionItems"], json!(["回复确认"]));
    assert_eq!(first.body["provider"], json!("MiniMax-M3"));

    // The prompt carried the mail, and the model was addressed with the key.
    let calls = transport.calls();
    assert_eq!(calls.len(), 1);
    assert!(calls[0].user.contains("这是一封关于订单的邮件"));
    assert_eq!(calls[0].api_key, "secret");

    // The second open is free: the summary is cached, not recomputed.
    let second = get(&client, &server, &path).await;
    assert_eq!(second.status, 200, "{:?}", second.body);
    assert_eq!(second.body["summary"], json!("请在周五前确认订单"));
    assert_eq!(transport.calls().len(), 1, "the cache must be used");
}

#[tokio::test]
async fn the_cost_of_a_call_lands_in_the_ledger() {
    let transport = Arc::new(ScriptedTransport::new());
    transport.script(vec![Ok(AiReply {
        content: r#"{"summary":"一句摘要","actionItems":[]}"#.to_owned(),
        prompt_tokens: 1000,
        completion_tokens: 1000,
    })]);
    let gateway = gateway_with(Arc::clone(&transport), Some("secret"));
    let (server, _fixtures) =
        TestServer::spawn_with_provider_and_ai("r4-usage", Arc::new(NoProvider), gateway).await;
    seed_body(&server, "邮件正文。");
    let client = http::client();

    let observed = get(
        &client,
        &server,
        &format!("/api/messages/{REMOTE}/summary?accountId={ACCOUNT_A}"),
    )
    .await;
    assert_eq!(observed.status, 200, "{:?}", observed.body);

    assert_eq!(usage_rows(&server), 1, "the call must be recorded");
    let usage = get(&client, &server, "/api/usage").await;
    assert_eq!(usage.status, 200);
    assert_eq!(usage.body["callCount"], json!(1));
    // 1000 prompt + 1000 completion tokens = 0.003 USD.
    assert_eq!(usage.body["monthUSD"], json!(0.003));
}

#[tokio::test]
async fn without_a_key_the_summary_is_503_ai_not_configured() {
    let transport = Arc::new(ScriptedTransport::new());
    let gateway = gateway_with(Arc::clone(&transport), None);
    let (server, _fixtures) =
        TestServer::spawn_with_provider_and_ai("r4-summary-nokey", Arc::new(NoProvider), gateway)
            .await;
    seed_body(&server, "邮件正文。");
    let client = http::client();

    let observed = get(
        &client,
        &server,
        &format!("/api/messages/{REMOTE}/summary?accountId={ACCOUNT_A}"),
    )
    .await;
    assert_eq!(observed.status, 503, "{:?}", observed.body);
    assert_eq!(observed.body["error"], json!("ai-not-configured"));
    assert!(
        transport.calls().is_empty(),
        "a missing key must not reach the provider"
    );
}

#[tokio::test]
async fn a_mail_whose_body_cannot_be_read_is_503_provider_not_configured() {
    let transport = Arc::new(ScriptedTransport::new());
    let gateway = gateway_with(Arc::clone(&transport), Some("secret"));
    let (server, _fixtures) =
        TestServer::spawn_with_provider_and_ai("r4-summary-nobody", Arc::new(NoProvider), gateway)
            .await;
    let client = http::client();

    // No cached body and no provider: the contract's answer, and the model is
    // never asked about a mail nobody could read.
    let observed = get(
        &client,
        &server,
        &format!("/api/messages/{REMOTE}/summary?accountId={ACCOUNT_A}"),
    )
    .await;
    assert_eq!(observed.status, 503, "{:?}", observed.body);
    assert_eq!(observed.body["error"], json!("provider-not-configured"));
    assert!(transport.calls().is_empty());
}

#[tokio::test]
async fn a_summary_of_a_mail_that_is_not_there_is_404() {
    let transport = Arc::new(ScriptedTransport::new());
    let gateway = gateway_with(Arc::clone(&transport), Some("secret"));
    let (server, _fixtures) =
        TestServer::spawn_with_provider_and_ai("r4-summary-404", Arc::new(NoProvider), gateway)
            .await;
    let client = http::client();

    let observed = get(
        &client,
        &server,
        &format!("/api/messages/fixture-missing/summary?accountId={ACCOUNT_A}"),
    )
    .await;
    assert_eq!(observed.status, 404, "{:?}", observed.body);
    assert_eq!(observed.body["error"], json!("unknown-message"));
}

#[tokio::test]
async fn a_provider_that_cannot_be_reached_is_502_not_500() {
    let transport = Arc::new(ScriptedTransport::new());
    transport.script(vec![Err(AiTransportError::Unreachable(
        "no route".to_owned(),
    ))]);
    let gateway = gateway_with(Arc::clone(&transport), Some("secret"));
    let (server, _fixtures) =
        TestServer::spawn_with_provider_and_ai("r4-summary-502", Arc::new(NoProvider), gateway)
            .await;
    seed_body(&server, "邮件正文。");
    let client = http::client();

    let observed = get(
        &client,
        &server,
        &format!("/api/messages/{REMOTE}/summary?accountId={ACCOUNT_A}"),
    )
    .await;
    assert_eq!(observed.status, 502, "{:?}", observed.body);
    assert_eq!(observed.body["error"], json!("provider-unreachable"));
}

#[tokio::test]
async fn a_draft_is_generated_and_can_be_read_back() {
    let transport = Arc::new(ScriptedTransport::new());
    transport.script(vec![Ok(AiReply {
        content: r#"["好的，谢谢。","收到，我今天处理。"]"#.to_owned(),
        prompt_tokens: 500,
        completion_tokens: 200,
    })]);
    let gateway = gateway_with(Arc::clone(&transport), Some("secret"));
    let (server, _fixtures) =
        TestServer::spawn_with_provider_and_ai("r4-draft", Arc::new(NoProvider), gateway).await;
    seed_body(&server, "请问什么时候能发货？");
    let client = http::client();

    let path = format!("/api/messages/{REMOTE}/draft?accountId={ACCOUNT_A}");
    let observed = post(&client, &server, &path, &json!({})).await;
    assert_eq!(observed.status, 200, "{:?}", observed.body);
    assert_eq!(observed.body["remoteId"], json!(REMOTE));
    assert_eq!(
        observed.body["variants"],
        json!(["好的，谢谢。", "收到，我今天处理。"])
    );
    assert!(observed.body["id"].as_i64().unwrap() > 0);

    // The draft is stored, so the list route finds it again.
    let listed = get(
        &client,
        &server,
        &format!("/api/messages/{REMOTE}/drafts?accountId={ACCOUNT_A}"),
    )
    .await;
    assert_eq!(listed.status, 200, "{:?}", listed.body);
    assert_eq!(listed.body["drafts"].as_array().unwrap().len(), 1);
    assert_eq!(
        listed.body["drafts"][0]["variants"],
        json!(["好的，谢谢。", "收到，我今天处理。"])
    );
}

#[tokio::test]
async fn the_ai_never_touches_the_mailbox() {
    // The constitution: the AI plane is read-only. A summary and a draft must
    // leave the mailbox exactly as they found it.
    let transport = Arc::new(ScriptedTransport::new());
    transport.script(vec![
        Ok(AiReply {
            content: r#"{"summary":"摘要","actionItems":[]}"#.to_owned(),
            prompt_tokens: 10,
            completion_tokens: 10,
        }),
        Ok(AiReply {
            content: r#"["草稿"]"#.to_owned(),
            prompt_tokens: 10,
            completion_tokens: 10,
        }),
    ]);
    let gateway = gateway_with(Arc::clone(&transport), Some("secret"));
    let (server, _fixtures) =
        TestServer::spawn_with_provider_and_ai("r4-readonly", Arc::new(NoProvider), gateway).await;
    seed_body(&server, "邮件正文。");
    let client = http::client();

    let summary = get(
        &client,
        &server,
        &format!("/api/messages/{REMOTE}/summary?accountId={ACCOUNT_A}"),
    )
    .await;
    assert_eq!(summary.status, 200, "{:?}", summary.body);
    let draft = post(
        &client,
        &server,
        &format!("/api/messages/{REMOTE}/draft?accountId={ACCOUNT_A}"),
        &json!({}),
    )
    .await;
    assert_eq!(draft.status, 200, "{:?}", draft.body);

    // No write verb was ever called on the provider.
    let calls = NO_PROVIDER_CALLS.with(|calls| calls.borrow().clone());
    assert!(
        calls.is_empty(),
        "the AI plane wrote to the mailbox: {calls:?}"
    );
}

#[tokio::test]
async fn an_unusable_draft_answer_is_502_and_still_lands_in_the_ledger() {
    let transport = Arc::new(ScriptedTransport::new());
    transport.script(vec![Ok(AiReply {
        content: "   ".to_owned(),
        prompt_tokens: 400,
        completion_tokens: 3,
    })]);
    let gateway = gateway_with(Arc::clone(&transport), Some("secret"));
    let (server, _fixtures) =
        TestServer::spawn_with_provider_and_ai("r4-draft-empty", Arc::new(NoProvider), gateway)
            .await;
    seed_body(&server, "请问什么时候能发货？");
    let client = http::client();

    let observed = post(
        &client,
        &server,
        &format!("/api/messages/{REMOTE}/draft?accountId={ACCOUNT_A}"),
        &json!({}),
    )
    .await;
    assert_eq!(observed.status, 502, "{:?}", observed.body);
    assert_eq!(observed.body["error"], json!("ai-error"));
    // The model ran and billed tokens: the ledger must say so even though the
    // answer was thrown away.
    assert_eq!(usage_rows(&server), 1);
}

#[tokio::test]
async fn a_month_at_the_cap_is_503_ai_budget_exceeded() {
    let transport = Arc::new(ScriptedTransport::new());
    let gateway = {
        let owned = Some("secret".to_owned());
        Arc::new(
            AiGateway::new(
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
            ))
            .with_budget(Arc::new(|| lagoon_api::ai::gateway::Budget {
                spent_micro_usd: 5_000_000,
                cap_micro_usd: 5_000_000,
            })),
        )
    };
    let (server, _fixtures) =
        TestServer::spawn_with_provider_and_ai("r4-summary-budget", Arc::new(NoProvider), gateway)
            .await;
    seed_body(&server, "邮件正文。");
    let client = http::client();

    let observed = get(
        &client,
        &server,
        &format!("/api/messages/{REMOTE}/summary?accountId={ACCOUNT_A}"),
    )
    .await;
    assert_eq!(observed.status, 503, "{:?}", observed.body);
    assert_eq!(observed.body["error"], json!("ai-budget-exceeded"));
    assert!(
        transport.calls().is_empty(),
        "a spent budget must not reach the provider"
    );
}

#[tokio::test]
async fn a_reload_reports_the_providers_it_found() {
    let transport = Arc::new(ScriptedTransport::new());
    let gateway = gateway_with(Arc::clone(&transport), Some("secret"));
    let (server, _fixtures) =
        TestServer::spawn_with_provider_and_ai("r4-reload", Arc::new(NoProvider), gateway).await;
    let client = http::client();

    let observed = post(&client, &server, "/api/ai/reload", &json!({})).await;
    assert_eq!(observed.status, 200, "{:?}", observed.body);
    assert_eq!(observed.body["ok"], json!(true));
    assert_eq!(observed.body["providers"], json!(["minimax"]));
    assert_eq!(observed.body["configured"], json!(true));
}

#[tokio::test]
async fn a_probe_without_a_key_is_503_and_with_one_answers() {
    let transport = Arc::new(ScriptedTransport::new());
    transport.script(vec![Ok(AiReply {
        content: "OK".to_owned(),
        prompt_tokens: 5,
        completion_tokens: 1,
    })]);
    let gateway = gateway_with(Arc::clone(&transport), Some("secret"));
    let (server, _fixtures) =
        TestServer::spawn_with_provider_and_ai("r4-probe", Arc::new(NoProvider), gateway).await;
    let client = http::client();

    let observed = post(&client, &server, "/api/ai/probe", &json!({})).await;
    assert_eq!(observed.status, 200, "{:?}", observed.body);
    assert_eq!(observed.body["ok"], json!(true));
    assert_eq!(observed.body["model"], json!("MiniMax-M3"));
    assert_eq!(observed.body["provider"], json!("minimax"));
}

#[tokio::test]
async fn a_probe_without_a_key_says_not_configured() {
    let transport = Arc::new(ScriptedTransport::new());
    let gateway = gateway_with(Arc::clone(&transport), None);
    let (server, _fixtures) =
        TestServer::spawn_with_provider_and_ai("r4-probe-off", Arc::new(NoProvider), gateway).await;
    let client = http::client();

    let observed = post(&client, &server, "/api/ai/probe", &json!({})).await;
    assert_eq!(observed.status, 503, "{:?}", observed.body);
    assert_eq!(observed.body["error"], json!("ai-not-configured"));
    assert!(transport.calls().is_empty());
}

// ------------------------------------------------------------------ helpers ----

thread_local! {
    /// Every write verb the provider was asked to perform.
    static NO_PROVIDER_CALLS: std::cell::RefCell<Vec<String>> =
        const { std::cell::RefCell::new(Vec::new()) };
}

/// A provider factory that refuses to do anything, and remembers if it was
/// asked to.
struct NoProvider;

impl lagoon_api::provider::ProviderFactory for NoProvider {
    fn make(
        &self,
        _credentials: &lagoon_api::token::ImapCredentials,
    ) -> Option<Arc<dyn lagoon_api::provider::MailProvider>> {
        None
    }

    fn make_write(
        &self,
        _credentials: &lagoon_api::token::ImapCredentials,
    ) -> Option<Arc<dyn lagoon_api::provider::MailWriteProvider>> {
        Some(Arc::new(RecordingWriter))
    }
}

/// A write provider that records every verb instead of doing it.
struct RecordingWriter;

impl lagoon_api::provider::MailWriteProvider for RecordingWriter {
    fn set_read(&self, remote_id: &str, _is_read: bool) -> lagoon_api::provider::WriteFuture<'_> {
        record("set_read", remote_id);
        Box::pin(async { Ok(()) })
    }
    fn archive(&self, remote_id: &str) -> lagoon_api::provider::WriteFuture<'_> {
        record("archive", remote_id);
        Box::pin(async { Ok(()) })
    }
    fn unarchive(&self, remote_id: &str) -> lagoon_api::provider::WriteFuture<'_> {
        record("unarchive", remote_id);
        Box::pin(async { Ok(()) })
    }
    fn trash(&self, remote_id: &str) -> lagoon_api::provider::WriteFuture<'_> {
        record("trash", remote_id);
        Box::pin(async { Ok(()) })
    }
    fn restore_from_trash(&self, remote_id: &str) -> lagoon_api::provider::WriteFuture<'_> {
        record("restore_from_trash", remote_id);
        Box::pin(async { Ok(()) })
    }
    fn permanently_delete(&self, remote_id: &str) -> lagoon_api::provider::WriteFuture<'_> {
        record("permanently_delete", remote_id);
        Box::pin(async { Ok(()) })
    }
    fn empty_trash(&self) -> lagoon_api::provider::WriteFuture<'_> {
        record("empty_trash", "");
        Box::pin(async { Ok(()) })
    }
}

fn record(verb: &str, remote_id: &str) {
    NO_PROVIDER_CALLS.with(|calls| {
        calls.borrow_mut().push(format!("{verb} {remote_id}"));
    });
}
