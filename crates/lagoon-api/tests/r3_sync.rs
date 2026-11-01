//! R3.4a: the sync engine, driven by scripted providers.
//!
//! No mail server, no real IMAP: each round is a MailChangeSet the test wrote,
//! so the semantics under test are exactly UIDVALIDITY resets, batching,
//! backoff, isolation and the single-writer rule.

mod support;

use std::sync::Arc;
use std::time::Instant;

use lagoon_api::crypto::BodyKey;
use lagoon_api::db;
use lagoon_api::provider::fake::FakeProviderFactory;
use lagoon_api::provider::{MailChangeSet, ProviderError, RemoteHeader};
use lagoon_api::store::{self, write};
use lagoon_api::sync::{backoff_seconds, RoundOutcome, SyncEngine, SyncCursor};
use lagoon_api::token::{ImapCredentials, TokenKey};
use lagoon_api::uuid::Uuid;

use support::http;
use support::schema;
use support::server::{token_key, TestServer};
use support::TempDir;

const ACCOUNT_A: &str = "aaaaaaaa-1111-4111-8111-111111111111";
const ACCOUNT_B: &str = "bbbbbbbb-2222-4222-8222-222222222222";

fn body_key() -> Arc<BodyKey> {
    Arc::new(support::server::body_key())
}

fn account_key() -> Arc<TokenKey> {
    Arc::new(token_key())
}

fn message(remote_id: &str, uid: i64) -> RemoteHeader {
    RemoteHeader {
        remote_id: remote_id.to_owned(),
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

fn round(
    uid_validity: i64,
    last_uid: i64,
    remote_ids: &[&str],
    reset_required: bool,
) -> MailChangeSet {
    MailChangeSet {
        cursor: SyncCursor {
            uid_validity: Some(uid_validity),
            last_uid: Some(last_uid),
        },
        reset_required,
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
    // Kept alive for the test: dropping it removes the directory.
    _temp: TempDir,
    path: std::path::PathBuf,
    key: Arc<TokenKey>,
}

impl Store {
    fn new(label: &str) -> Self {
        let temp = TempDir::new(label);
        let path = temp.join("sync.sqlite");
        let connection = db::open_writable(&path).expect("open");
        schema::create(&connection).expect("schema");
        drop(connection);
        Self {
            _temp: temp,
            path,
            key: account_key(),
        }
    }

    fn connection(&self) -> rusqlite::Connection {
        db::open_writable(&self.path).expect("open")
    }

    fn add_account(&self, raw_id: &str, email: &str, active: bool) -> Uuid {
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
        write::set_account_active(&connection, id, active).expect("active");
        id
    }

    fn headers(&self, account: Uuid) -> i64 {
        self.connection()
            .query_row(
                "SELECT COUNT(*) FROM message_headers WHERE account_id = ?1",
                rusqlite::params![account.as_bytes().as_slice()],
                |row| row.get(0),
            )
            .expect("count")
    }

    fn sync_state(&self, account: Uuid) -> serde_json::Value {
        let raw = store::accounts::sync_state_json(&self.connection(), account)
            .expect("state")
            .unwrap_or_else(|| "{}".to_owned());
        serde_json::from_str(&raw).expect("json")
    }

    fn health(&self, account: Uuid) -> (String, Option<String>) {
        let account = store::accounts::find(&self.connection(), account)
            .expect("find")
            .expect("account");
        (account.sync_status, account.last_sync_error)
    }
}

fn engine(store: &Store, factory: Arc<FakeProviderFactory>) -> SyncEngine {
    SyncEngine::new(
        store.path.clone(),
        body_key(),
        Some(Arc::clone(&store.key)),
        factory,
    )
}

#[tokio::test]
async fn first_batch_then_incremental_resumes_from_the_cursor() {
    let store = Store::new("sync-incremental");
    let account = store.add_account(ACCOUNT_A, "a@example.invalid", true);
    let ids: Vec<String> = (1..=10).map(|index| format!("m{index}")).collect();
    let first: Vec<&str> = ids.iter().map(String::as_str).collect();
    let factory = Arc::new(FakeProviderFactory::scripted(vec![
        Ok(round(1, 10, &first, false)),
        Ok(round(1, 12, &["m11", "m12"], false)),
    ]));
    let engine = engine(&store, Arc::clone(&factory));

    let outcome = engine.round(account).await;
    assert_eq!(
        outcome,
        RoundOutcome::Applied {
            upserts: 10,
            reset: false
        }
    );
    assert_eq!(store.headers(account), 10);
    let state = store.sync_state(account);
    assert_eq!(state["uidValidity"], 1);
    assert_eq!(state["lastUid"], 10);
    assert_eq!(store.health(account), ("ok".to_owned(), None));

    let outcome = engine.round(account).await;
    assert_eq!(
        outcome,
        RoundOutcome::Applied {
            upserts: 2,
            reset: false
        }
    );
    assert_eq!(store.headers(account), 12);
    assert_eq!(store.sync_state(account)["lastUid"], 12);
    // The second pull resumed from the cursor the first round persisted.
    let cursors = factory.cursors();
    assert_eq!(cursors.len(), 2);
    assert_eq!(
        cursors[1],
        SyncCursor {
            uid_validity: Some(1),
            last_uid: Some(10)
        }
    );
}

#[tokio::test]
async fn uidvalidity_change_resets_live_rows_without_duplicates() {
    let store = Store::new("sync-reset");
    let account = store.add_account(ACCOUNT_A, "a@example.invalid", true);
    let first: Vec<&str> = (1..=5)
        .map(|index| Box::leak(format!("old{index}").into_boxed_str()) as &str)
        .collect();
    // One row is already archived: a UID reset must not touch it, because the
    // archive is addressed by Message-ID and the app never re-reads that folder.
    {
        let connection = store.connection();
        let sealed = ImapCredentials::new("a@example.invalid", "code")
            .seal(&store.key)
            .expect("seal");
        write::upsert_account(
            &connection,
            &write::NewAccount {
                id: account,
                provider: "qq",
                oauth_user: "a@example.invalid",
                email: "a@example.invalid",
                credentials: Some(&sealed),
                capabilities: "{}",
                sync_state: "{}",
            },
        )
        .expect("account");
        connection
            .execute(
                "INSERT INTO message_headers (id, account_id, remote_id, thread_id, from_address, received_at, is_archived)
                 VALUES (?, ?, 'archived-1', 't', 'a@b', '2025-01-01 00:00:00.000', TRUE)",
                rusqlite::params![Uuid::new_v4().as_bytes().as_slice(), account.as_bytes().as_slice()],
            )
            .expect("archived row");
    }
    let factory = Arc::new(FakeProviderFactory::scripted(vec![
        Ok(round(1, 5, &first, false)),
        // Same remote ids on the new UID space: without the reset these would
        // be updates, and the point is that the live rows were wiped first.
        Ok(round(2, 5, &first, true)),
    ]));
    let engine = engine(&store, Arc::clone(&factory));

    assert_eq!(
        engine.round(account).await,
        RoundOutcome::Applied {
            upserts: 5,
            reset: false
        }
    );
    assert_eq!(store.headers(account), 6, "five live plus one archived");
    assert_eq!(
        engine.round(account).await,
        RoundOutcome::Applied {
            upserts: 5,
            reset: true
        }
    );
    assert_eq!(
        store.headers(account),
        6,
        "the reset replaced the five live rows and left the archived one alone"
    );
    let state = store.sync_state(account);
    assert_eq!(state["uidValidity"], 2);
    assert_eq!(state["lastUid"], 5);
}

#[tokio::test]
async fn transient_failures_back_off_and_escalate_to_degraded() {
    let store = Store::new("sync-backoff");
    let account = store.add_account(ACCOUNT_A, "a@example.invalid", true);
    let factory = Arc::new(FakeProviderFactory::scripted(vec![
        Err(ProviderError::Unreachable("dns".to_owned())),
        Err(ProviderError::Unreachable("dns".to_owned())),
        Err(ProviderError::Unreachable("dns".to_owned())),
    ]));
    let engine = engine(&store, Arc::clone(&factory));

    let first = engine.round(account).await;
    match first {
        RoundOutcome::Failed {
            consecutive,
            backoff_seconds,
            ..
        } => {
            assert_eq!(consecutive, 1);
            assert!(
                (0.8..=1.2).contains(&backoff_seconds),
                "first backoff is 1s +/- 20%: {backoff_seconds}"
            );
        }
        other => panic!("expected Failed, got {other:?}"),
    }
    assert_eq!(store.health(account), ("error".to_owned(), Some("unreachable".to_owned())));

    let second = engine.round(account).await;
    match second {
        RoundOutcome::Failed {
            consecutive,
            backoff_seconds,
            ..
        } => {
            assert_eq!(consecutive, 2);
            assert!(
                (1.6..=2.4).contains(&backoff_seconds),
                "second backoff is 2s +/- 20%: {backoff_seconds}"
            );
        }
        other => panic!("expected Failed, got {other:?}"),
    }

    let third = engine.round(account).await;
    match third {
        RoundOutcome::Failed {
            consecutive,
            backoff_seconds,
            ..
        } => {
            assert_eq!(consecutive, 3);
            assert!(
                (3.2..=4.8).contains(&backoff_seconds),
                "third backoff is 4s +/- 20%: {backoff_seconds}"
            );
        }
        other => panic!("expected Failed, got {other:?}"),
    }
    assert_eq!(
        store.health(account),
        ("degraded".to_owned(), Some("unreachable".to_owned())),
        "three consecutive failures escalate to degraded"
    );

    // The cap holds for any number of failures.
    for consecutive in 1..=20 {
        let backoff = backoff_seconds(consecutive);
        assert!(backoff <= 360.0, "backoff must stay bounded: {backoff}");
        assert!(backoff >= 1.0);
    }
}

#[tokio::test]
async fn an_auth_failure_parks_the_account() {
    let store = Store::new("sync-auth");
    let account = store.add_account(ACCOUNT_A, "a@example.invalid", true);
    let factory = Arc::new(FakeProviderFactory::scripted(vec![Err(
        ProviderError::AuthFailed,
    )]));
    let engine = engine(&store, Arc::clone(&factory));
    assert_eq!(
        engine.round(account).await,
        RoundOutcome::Parked(lagoon_api::sync::ParkReason::NeedsReconnect)
    );
    assert_eq!(
        store.health(account),
        ("needsReconnect".to_owned(), Some("auth-failed".to_owned()))
    );
}

#[tokio::test]
async fn accounts_are_isolated_and_concurrent_rounds_apply_cleanly() {
    let store = Store::new("sync-isolation");
    let first = store.add_account(ACCOUNT_A, "a@example.invalid", true);
    let second = store.add_account(ACCOUNT_B, "b@example.invalid", false);
    let ids: Vec<&str> = vec!["a1", "a2"];
    let factory = Arc::new(FakeProviderFactory::scripted(vec![
        Ok(round(1, 2, &ids, false)),
        Ok(round(1, 1, &["b1"], false)),
    ]));
    let engine = engine(&store, Arc::clone(&factory));

    let (left, right) = tokio::join!(engine.round(first), engine.round(second));
    assert_eq!(
        left,
        RoundOutcome::Applied {
            upserts: 2,
            reset: false
        }
    );
    assert_eq!(
        right,
        RoundOutcome::Applied {
            upserts: 1,
            reset: false
        }
    );
    assert_eq!(store.headers(first), 2);
    assert_eq!(store.headers(second), 1);
    // Each account's cursor is its own.
    assert_eq!(store.sync_state(first)["lastUid"], 2);
    assert_eq!(store.sync_state(second)["lastUid"], 1);
}

#[tokio::test]
async fn a_header_only_account_appears_in_the_account_and_message_lists() {
    let store = Store::new("sync-header-only");
    let account = store.add_account(ACCOUNT_A, "only@example.invalid", true);
    let factory = Arc::new(FakeProviderFactory::scripted(vec![Ok(round(
        1,
        1,
        &["only-1"],
        false,
    ))]));
    let engine = engine(&store, Arc::clone(&factory));
    assert_eq!(
        engine.round(account).await,
        RoundOutcome::Applied {
            upserts: 1,
            reset: false
        }
    );
    let connection = store.connection();
    // It is in the account directory...
    assert!(store::accounts::all(&connection)
        .expect("accounts")
        .iter()
        .any(|row| row.email == "only@example.invalid"));
    // ...and its header is in the inbox list even though there is no body row.
    let messages = store::messages::recent(
        &connection,
        &store::messages::MessageFilter::inbox(account),
        50,
    )
    .expect("messages");
    assert_eq!(messages.len(), 1);
    assert_eq!(messages[0].remote_id, "only-1");
    let bodies: i64 = connection
        .query_row("SELECT COUNT(*) FROM message_bodies", [], |row| row.get(0))
        .expect("count");
    assert_eq!(bodies, 0);
}

#[tokio::test]
async fn post_api_sync_answers_204_without_waiting() {
    let factory = Arc::new(FakeProviderFactory::scripted(vec![Ok(round(
        1,
        3,
        &["s1", "s2", "s3"],
        false,
    ))]));
    let (server, _fixtures) = TestServer::spawn_with_provider("sync-http", factory).await;
    let client = http::client();
    let auth = server.auth_headers();
    let started = Instant::now();
    let observed = http::request(
        &client,
        "POST",
        &format!("{}/api/sync", server.base_url),
        &auth,
    )
    .await;
    let elapsed = started.elapsed();
    assert_eq!(observed.status, 204);
    assert_eq!(observed.body_kind, "empty");
    assert!(
        elapsed.as_millis() < 500,
        "POST /api/sync must not wait for the round: {elapsed:?}"
    );
}
