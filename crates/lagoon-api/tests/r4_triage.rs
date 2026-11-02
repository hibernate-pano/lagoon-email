//! R4: the triage step - the advice queue is real.
//!
//! What these pin:
//! * a synced mail gets one suggestion, and the suggestion lands in the
//!   advice queue (not in the action history - a suggestion is not an act);
//! * a mail that already has a suggestion is not asked about again (the
//!   model would cost money for the same words);
//! * a model that is down does not break the round: the mail is synced
//!   either way;
//! * without a key nothing happens at all: no calls, no rows.

mod support;

use std::sync::Arc;

use lagoon_api::ai::config::AiConfig;
use lagoon_api::ai::fake::ScriptedTransport;
use lagoon_api::ai::gateway::AiGateway;
use lagoon_api::ai::transport::{AiReply, AiTransport, AiTransportError};
use lagoon_api::db;
use lagoon_api::provider::fake::FakeProviderFactory;
use lagoon_api::provider::{MailChangeSet, RemoteHeader};
use lagoon_api::store::write;
use lagoon_api::sync::{RoundOutcome, SyncCursor, SyncEngine};
use lagoon_api::token::{ImapCredentials, TokenKey};
use lagoon_api::uuid::Uuid;

use support::schema;
use support::server::token_key;
use support::TempDir;

const ACCOUNT_A: &str = "aaaaaaaa-1111-4111-8111-111111111111";
const KEY_ENV: &str = "LLM_PROVIDER_PRIMARY_API_KEY";

fn message(remote_id: &str, uid: i64) -> RemoteHeader {
    RemoteHeader {
        remote_id: remote_id.to_owned(),
        remote_uid: Some(uid),
        thread_id: format!("thread-{remote_id}"),
        from_address: "sender@example.invalid".to_owned(),
        from_name: Some("Sender".to_owned()),
        subject: Some(format!("Subject {remote_id}")),
        snippet: Some(format!("snippet {remote_id}")),
        received_at: format!("2025-03-01 09:{:02}:00.000", uid % 60),
        is_read: false,
        message_id_header: Some(format!("<{remote_id}@example.invalid>")),
        in_reply_to: None,
        references: None,
        list_unsubscribe: false,
        unsubscribe_links: "[]".to_owned(),
    }
}

fn round(remote_ids: &[&str]) -> MailChangeSet {
    MailChangeSet {
        cursor: SyncCursor {
            uid_validity: Some(1),
            last_uid: Some(remote_ids.len() as i64),
        },
        reset_required: false,
        upserts: remote_ids
            .iter()
            .enumerate()
            .map(|(index, remote_id)| message(remote_id, index as i64 + 1))
            .collect(),
        inbox_remote_ids: Some(remote_ids.iter().map(|id| (*id).to_owned()).collect()),
        ..MailChangeSet::default()
    }
}

struct Store {
    _temp: TempDir,
    path: std::path::PathBuf,
    key: Arc<TokenKey>,
}

impl Store {
    fn new(label: &str) -> Self {
        let temp = TempDir::new(label);
        let path = temp.join("triage.sqlite");
        let connection = db::open_writable(&path).expect("open");
        schema::create(&connection).expect("schema");
        drop(connection);
        Self {
            _temp: temp,
            path,
            key: Arc::new(token_key()),
        }
    }

    fn connection(&self) -> rusqlite::Connection {
        db::open_writable(&self.path).expect("open")
    }

    fn add_account(&self, raw_id: &str, email: &str) -> Uuid {
        let id = Uuid::parse_strict(raw_id).expect("uuid");
        let connection = self.connection();
        let sealed = ImapCredentials::new(email, "auth-code")
            .seal(&self.key)
            .expect("seal");
        write::upsert_account(
            &connection,
            &write::NewAccount {
                id,
                provider: "qq",
                oauth_user: email,
                email,
                credentials: Some(&sealed),
                capabilities: "{}",
                sync_state: "{}",
            },
        )
        .expect("account");
        write::set_account_active(&connection, id, true).expect("active");
        id
    }
}

/// A gateway whose key is (or is not) there.
fn gateway(transport: Arc<ScriptedTransport>, key: Option<&str>) -> Arc<AiGateway> {
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

fn advice_rows(store: &Store, account: Uuid) -> Vec<(String, String, String, String)> {
    let connection = store.connection();
    let mut statement = connection
        .prepare(
            "SELECT remote_id, action, source, model FROM advice
             WHERE account_id = ?1 ORDER BY remote_id",
        )
        .expect("prepare");
    let rows = statement
        .query_map(rusqlite::params![account.as_bytes().as_slice()], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
            ))
        })
        .expect("query");
    rows.map(|row| row.expect("row")).collect()
}

fn usage_rows(store: &Store) -> i64 {
    store
        .connection()
        .query_row("SELECT count(*) FROM usage_log", [], |row| row.get(0))
        .expect("usage count")
}

fn engine(store: &Store, factory: Arc<FakeProviderFactory>, ai: Arc<AiGateway>) -> SyncEngine {
    SyncEngine::new(
        store.path.clone(),
        Arc::new(support::server::body_key()),
        Some(Arc::clone(&store.key)),
        factory,
    )
    .with_ai(ai)
}

#[tokio::test]
async fn a_synced_mail_gets_one_suggestion_in_the_advice_queue() {
    let store = Store::new("triage-advice");
    let account = store.add_account(ACCOUNT_A, "a@example.invalid");
    let transport = Arc::new(ScriptedTransport::new());
    transport.script(vec![Ok(AiReply {
        content: r#"{"category":"work","action":"reply","confidence":"high","rationale":"对方在等你回复","dueText":""}"#
            .to_owned(),
        prompt_tokens: 100,
        completion_tokens: 50,
    })]);
    let factory = Arc::new(FakeProviderFactory::scripted(vec![Ok(round(&["m-1"]))]));
    let engine = engine(
        &store,
        factory,
        gateway(Arc::clone(&transport), Some("secret")),
    );

    let outcome = engine.round(account).await;
    assert!(
        matches!(outcome, RoundOutcome::Applied { .. }),
        "{outcome:?}"
    );

    let advice = advice_rows(&store, account);
    assert_eq!(advice.len(), 1, "{advice:?}");
    assert_eq!(advice[0].0, "m-1");
    assert_eq!(advice[0].1, "reply");
    assert_eq!(advice[0].2, "ai");
    assert_eq!(advice[0].3, "MiniMax-M3");
    // The suggestion cost money, so it is in the ledger.
    assert_eq!(usage_rows(&store), 1);

    // The prompt carried the header, not the body.
    let calls = transport.calls();
    assert_eq!(calls.len(), 1);
    assert!(calls[0].user.contains("sender@example.invalid"));
    assert!(calls[0].user.contains("Subject m-1"));
}

#[tokio::test]
async fn a_mail_that_already_has_a_suggestion_is_not_asked_about_again() {
    let store = Store::new("triage-once");
    let account = store.add_account(ACCOUNT_A, "a@example.invalid");
    let transport = Arc::new(ScriptedTransport::new());
    transport.script(vec![Ok(AiReply {
        content: r#"{"category":"work","action":"reply","confidence":"high"}"#.to_owned(),
        prompt_tokens: 10,
        completion_tokens: 10,
    })]);
    // Two rounds, both carrying the same mail.
    let factory = Arc::new(FakeProviderFactory::scripted(vec![
        Ok(round(&["m-1"])),
        Ok(round(&["m-1"])),
    ]));
    let engine = engine(
        &store,
        factory,
        gateway(Arc::clone(&transport), Some("secret")),
    );

    engine.round(account).await;
    engine.round(account).await;

    assert_eq!(transport.calls().len(), 1, "the second round must not ask");
    assert_eq!(advice_rows(&store, account).len(), 1);
    assert_eq!(usage_rows(&store), 1);
}

#[tokio::test]
async fn a_model_that_is_down_does_not_break_the_round() {
    let store = Store::new("triage-down");
    let account = store.add_account(ACCOUNT_A, "a@example.invalid");
    let transport = Arc::new(ScriptedTransport::new());
    transport.script(vec![Err(AiTransportError::Unreachable(
        "no route".to_owned(),
    ))]);
    let factory = Arc::new(FakeProviderFactory::scripted(vec![Ok(round(&["m-1"]))]));
    let engine = engine(
        &store,
        factory,
        gateway(Arc::clone(&transport), Some("secret")),
    );

    let outcome = engine.round(account).await;
    assert!(
        matches!(outcome, RoundOutcome::Applied { .. }),
        "the round must still succeed: {outcome:?}"
    );
    // The mail is synced even though the model is down.
    let headers: i64 = store
        .connection()
        .query_row(
            "SELECT count(*) FROM message_headers WHERE account_id = ?1",
            rusqlite::params![account.as_bytes().as_slice()],
            |row| row.get(0),
        )
        .expect("count");
    assert_eq!(headers, 1);
    assert!(advice_rows(&store, account).is_empty());
}

#[tokio::test]
async fn without_a_key_nothing_happens() {
    let store = Store::new("triage-nokey");
    let account = store.add_account(ACCOUNT_A, "a@example.invalid");
    let transport = Arc::new(ScriptedTransport::new());
    let factory = Arc::new(FakeProviderFactory::scripted(vec![Ok(round(&["m-1"]))]));
    let engine = engine(&store, factory, gateway(Arc::clone(&transport), None));

    let outcome = engine.round(account).await;
    assert!(matches!(outcome, RoundOutcome::Applied { .. }));
    assert!(transport.calls().is_empty(), "no key, no call");
    assert!(advice_rows(&store, account).is_empty());
    assert_eq!(usage_rows(&store), 0);
}
