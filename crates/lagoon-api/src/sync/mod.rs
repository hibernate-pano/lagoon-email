//! The sync engine: one loop per account, one writer, scripted providers.
//!
//! Semantics follow v3 Sources/LagoonServer/Sync/SyncEngine.swift:
//!
//! * every account owns its cursor (UIDVALIDITY + last UID) and its backoff;
//! * a UIDVALIDITY change means the server's UID space was rebuilt: wipe the
//!   live inbox rows and re-upsert the full set, keeping archive and trash;
//! * a failed round backs off exponentially (1, 2, 4 ... capped at 300 s,
//!   plus or minus 20 percent jitter) and escalates the health to degraded
//!   after three consecutive failures;
//! * auth failures park the account at needsReconnect and stop its loop;
//! * one account's trouble never touches another account;
//! * all writes go through one writer lock, so two accounts syncing at once
//!   cannot interleave a reset with an upsert.
//!
//! The engine only asks the provider for a sync surface (probe + pull). It has
//! no archive/trash/send verbs to call, which is the compile-time version of
//! v3's "sync never writes to the mailbox".

use std::collections::{HashMap, HashSet};
use std::future::Future;
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::Arc;

use rusqlite::Connection;
use serde::{Deserialize, Serialize};

use crate::crypto::BodyKey;
use crate::db;
use crate::provider::{MailChangeSet, ProviderError, ProviderFactory};
use crate::store::{self, write};
use crate::timefmt;
use crate::token::{ImapCredentials, TokenKey};
use crate::uuid::Uuid;

/// The part of accounts.sync_state the sync engine reads and writes.
///
/// The row also holds sent-folder and history fields this engine does not
/// touch; merge_into rewrites only the keys here, so those survive a round.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncCursor {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub uid_validity: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_uid: Option<i64>,
}

impl SyncCursor {
    pub fn from_json(raw: &str) -> Self {
        serde_json::from_str(raw).unwrap_or_default()
    }

    /// Write this cursor's fields into an existing sync_state object, leaving
    /// every other key (sentFolder, archiveFolder, historyFloorUid) alone.
    pub fn merge_into(&self, base: &str) -> String {
        let mut value: serde_json::Value = serde_json::from_str(base)
            .ok()
            .filter(serde_json::Value::is_object)
            .unwrap_or_else(|| serde_json::json!({}));
        match self.uid_validity {
            Some(uid_validity) => value["uidValidity"] = serde_json::json!(uid_validity),
            None => {
                if let Some(object) = value.as_object_mut() {
                    object.remove("uidValidity");
                }
            }
        }
        match self.last_uid {
            Some(last_uid) => value["lastUid"] = serde_json::json!(last_uid),
            None => {
                if let Some(object) = value.as_object_mut() {
                    object.remove("lastUid");
                }
            }
        }
        value.to_string()
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum ParkReason {
    NeedsReconnect,
    AccountMissing,
}

#[derive(Debug, Clone, PartialEq)]
pub enum RoundOutcome {
    Applied {
        upserts: usize,
        reset: bool,
        /// The pull blocked on IDLE; the loop must not sleep again.
        waited: bool,
    },
    Parked(ParkReason),
    NoProvider,
    NotFound,
    Failed {
        label: String,
        consecutive: u32,
        backoff_seconds: f64,
    },
}

pub struct SyncEngine {
    db_path: PathBuf,
    body_key: Arc<BodyKey>,
    token_key: Option<Arc<TokenKey>>,
    factory: Arc<dyn ProviderFactory>,
    /// Consecutive transient failures per account.
    failures: tokio::sync::Mutex<HashMap<Uuid, u32>>,
    /// The single writer: applies are serialised across every account.
    writer: tokio::sync::Mutex<()>,
}

impl SyncEngine {
    pub fn new(
        db_path: PathBuf,
        body_key: Arc<BodyKey>,
        token_key: Option<Arc<TokenKey>>,
        factory: Arc<dyn ProviderFactory>,
    ) -> Self {
        Self {
            db_path,
            body_key,
            token_key,
            factory,
            failures: tokio::sync::Mutex::new(HashMap::new()),
            writer: tokio::sync::Mutex::new(()),
        }
    }

    pub fn body_key(&self) -> &BodyKey {
        &self.body_key
    }

    /// Whether this build can build a provider for the account. The supervisor
    /// uses it to decide whether an account gets a loop at all: without one,
    /// v3 records a no-provider error, but that would rewrite the health of a
    /// store nothing is actually syncing.
    pub fn has_provider(&self, account_id: Uuid) -> bool {
        let Ok(connection) = db::open_writable(&self.db_path) else {
            return false;
        };
        let Some(token_key) = &self.token_key else {
            return false;
        };
        let Ok(Some(sealed)) = write::credentials(&connection, account_id) else {
            return false;
        };
        let Ok(credentials) = ImapCredentials::open(token_key, &sealed) else {
            return false;
        };
        self.factory.make(&credentials).is_some()
    }

    /// One round for one account. Never panics; failures become state.
    pub async fn round(&self, account_id: Uuid) -> RoundOutcome {
        let connection = match db::open_writable(&self.db_path) {
            Ok(connection) => connection,
            Err(error) => {
                tracing::error!(err = %error, "sync.storeOpenFailed");
                return RoundOutcome::Failed {
                    label: "store".to_owned(),
                    consecutive: self.next_failure(account_id).await,
                    backoff_seconds: 5.0,
                };
            }
        };

        let Some(account) = (match store::accounts::find(&connection, account_id) {
            Ok(account) => account,
            Err(error) => {
                tracing::error!(err = %error, "sync.accountReadFailed");
                return RoundOutcome::NotFound;
            }
        }) else {
            // A row this loop cannot find is not "auth expired"; it is a store
            // problem, and re-entering a code would not fix it (v3 accountMissing).
            tracing::error!("sync.accountMissing");
            return RoundOutcome::Parked(ParkReason::AccountMissing);
        };

        let sealed = write::credentials(&connection, account_id).ok().flatten();
        let credentials = match (&self.token_key, sealed) {
            (Some(token_key), Some(sealed)) => ImapCredentials::open(token_key, &sealed).ok(),
            _ => None,
        };
        let Some(credentials) = credentials else {
            // No usable credentials: retrying cannot fix that (v3 notConfigured).
            self.mark_needs_reconnect(&connection, account_id, "not-configured");
            return RoundOutcome::Parked(ParkReason::NeedsReconnect);
        };
        let Some(provider) = self.factory.make(&credentials) else {
            let _ =
                write::update_health(&connection, account_id, "error", None, Some("no-provider"));
            return RoundOutcome::NoProvider;
        };

        let sync_state = store::accounts::sync_state_json(&connection, account_id)
            .ok()
            .flatten()
            .unwrap_or_else(|| "{}".to_owned());
        let cursor = SyncCursor::from_json(&sync_state);

        let outcome = provider.pull_changes(&cursor).await;
        let changes = match outcome {
            Ok(changes) => changes,
            Err(ProviderError::AuthFailed) => {
                self.mark_needs_reconnect(&connection, account_id, "auth-failed");
                return RoundOutcome::Parked(ParkReason::NeedsReconnect);
            }
            Err(ProviderError::NotConfigured(message)) => {
                tracing::warn!(label = %message, "sync.notConfigured");
                self.mark_needs_reconnect(&connection, account_id, "not-configured");
                return RoundOutcome::Parked(ParkReason::NeedsReconnect);
            }
            Err(error) => {
                let label = match &error {
                    ProviderError::Unreachable(_) => "unreachable",
                    ProviderError::Protocol(_) => "protocol-error",
                    _ => "provider",
                };
                let consecutive = self.next_failure(account_id).await;
                let status = if consecutive >= 3 {
                    "degraded"
                } else {
                    "error"
                };
                let _ = write::update_health(&connection, account_id, status, None, Some(label));
                let backoff = backoff_seconds(consecutive);
                tracing::warn!(
                    account = %account.email,
                    label,
                    consecutive,
                    retry_in_seconds = backoff,
                    "sync.failed"
                );
                return RoundOutcome::Failed {
                    label: label.to_owned(),
                    consecutive,
                    backoff_seconds: backoff,
                };
            }
        };

        // Single writer: from here to the cursor update nothing else applies.
        let _writer = self.writer.lock().await;
        let applied = self.apply(&connection, account_id, &changes, &sync_state);
        if let Err(error) = applied {
            tracing::error!(err = %error, "sync.applyFailed");
            let consecutive = self.next_failure(account_id).await;
            let _ = write::update_health(&connection, account_id, "error", None, Some("store"));
            return RoundOutcome::Failed {
                label: "store".to_owned(),
                consecutive,
                backoff_seconds: backoff_seconds(consecutive),
            };
        }
        self.failures.lock().await.insert(account_id, 0);
        tracing::info!(
            account = %account.email,
            upserts = changes.upserts.len(),
            reset = changes.reset_required,
            "sync.applied"
        );
        RoundOutcome::Applied {
            upserts: changes.upserts.len(),
            reset: changes.reset_required,
            waited: changes.waited,
        }
    }

    fn apply(
        &self,
        connection: &Connection,
        account_id: Uuid,
        changes: &MailChangeSet,
        previous_sync_state: &str,
    ) -> Result<(), write::WriteError> {
        // Order matters: wipe first, land the rows, and only then advance the
        // cursor. A partial write leaves the cursor untouched and the next pull
        // is idempotent.
        if changes.reset_required {
            write::delete_live_rows(connection, account_id)?;
            tracing::warn!(account = %account_id.to_wire_string(), "sync.reset");
        }
        for header in &changes.upserts {
            write::upsert_header(
                connection,
                &write::NewHeader {
                    id: Uuid::new_v4(),
                    account_id,
                    remote_id: &header.remote_id,
                    thread_id: &header.thread_id,
                    from_address: &header.from_address,
                    from_name: header.from_name.as_deref(),
                    subject: header.subject.as_deref(),
                    snippet: header.snippet.as_deref(),
                    received_at: &header.received_at,
                    list_unsubscribe: header.list_unsubscribe,
                    message_id_header: header.message_id_header.as_deref(),
                    in_reply_to: header.in_reply_to.as_deref(),
                    references: header.references.as_deref(),
                    unsubscribe_links: &header.unsubscribe_links,
                    remote_uid: header.remote_uid,
                },
                Some(&self.body_key),
            )?;
        }
        // Rows stored by a build before `remote_uid` existed have no UID, so
        // every body open pays a full-mailbox scan. The membership walk this
        // round already fetched each Message-ID, so fill the column from it.
        if let Some(uids) = &changes.inbox_uids {
            write::fill_remote_uids(connection, account_id, uids)?;
        }
        if let Some(inbox) = &changes.inbox_remote_ids {
            // v3 rule: a local row may be deleted only for a message the
            // provider reports in none of the folders it could be in. If any
            // membership set is unknown, nothing is deleted.
            let removed = match (
                &changes.inbox_remote_ids,
                &changes.archived_remote_ids,
                &changes.trashed_remote_ids,
            ) {
                (Some(inbox), Some(archived), Some(trashed)) => {
                    let mut known: HashSet<&str> = HashSet::new();
                    known.extend(inbox.iter().map(String::as_str));
                    known.extend(archived.iter().map(String::as_str));
                    known.extend(trashed.iter().map(String::as_str));
                    write::live_remote_ids(connection, account_id)?
                        .into_iter()
                        .filter(|remote_id| !known.contains(remote_id.as_str()))
                        .collect()
                }
                _ => changes.removed_remote_ids.clone(),
            };
            write::reconcile_inbox(
                connection,
                account_id,
                inbox,
                changes.archived_remote_ids.as_deref().unwrap_or(&[]),
                changes.trashed_remote_ids.as_deref().unwrap_or(&[]),
                &removed,
            )?;
        }
        // Cross-client replies: record unknown Message-IDs as send actions with
        // the sentFolder marker. Already-known ids are skipped, which also makes
        // a Sent UIDVALIDITY reset idempotent.
        if !changes.replied_message_ids.is_empty() {
            let known =
                store::actions::replied_remote_ids(connection, account_id).unwrap_or_default();
            let known: HashSet<&str> = known.iter().map(String::as_str).collect();
            for message_id in &changes.replied_message_ids {
                if !known.contains(message_id.as_str()) {
                    let _ = write::record_action(
                        connection,
                        account_id,
                        "send",
                        &serde_json::json!({
                            "remoteId": message_id,
                            "sentFolder": "true",
                        })
                        .to_string(),
                    );
                }
            }
        }
        let merged = changes.cursor.merge_into(previous_sync_state);
        write::update_sync_state(
            connection,
            account_id,
            &merged,
            "ok",
            Some(&timefmt::to_stored(timefmt::now())),
            None,
        )?;
        write::update_health(connection, account_id, "ok", None, None)?;
        Ok(())
    }

    fn mark_needs_reconnect(&self, connection: &Connection, account_id: Uuid, label: &str) {
        tracing::warn!(label, "sync.needsReconnect");
        let _ = write::update_health(connection, account_id, "needsReconnect", None, Some(label));
    }

    async fn next_failure(&self, account_id: Uuid) -> u32 {
        let mut failures = self.failures.lock().await;
        let counter = failures.entry(account_id).or_insert(0);
        *counter += 1;
        *counter
    }
}

/// v3 markFailure: base 2^(n-1) capped at 300 s, plus or minus 20 percent.
pub fn backoff_seconds(consecutive: u32) -> f64 {
    let exponent = consecutive.saturating_sub(1).min(9);
    let base = (2f64.powi(exponent as i32)).min(300.0);
    let mut byte = [0u8; 1];
    crate::crypto::random_bytes(&mut byte);
    let unit = (byte[0] as f64) / 255.0 * 2.0 - 1.0;
    (base + base * 0.2 * unit).max(1.0)
}

/// How long an idle round waits before pulling again (v3 waitBudget).
pub const IDLE_WAIT: std::time::Duration = std::time::Duration::from_secs(300);

/// What the loop does once a round returns.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum AfterRound {
    Stop,
    In(std::time::Duration),
}

/// A parked or vanished account ends its loop, a transient failure backs off,
/// a round that already waited on IDLE goes again at once, and anything else
/// waits for the next poll.
fn after_round(outcome: &RoundOutcome) -> AfterRound {
    match outcome {
        RoundOutcome::Parked(_) | RoundOutcome::NotFound => AfterRound::Stop,
        RoundOutcome::Failed {
            backoff_seconds, ..
        } => AfterRound::In(std::time::Duration::from_secs_f64(*backoff_seconds)),
        // The pull blocked on IDLE for up to IDLE_BUDGET; sleeping on top
        // would add back exactly the latency IDLE exists to remove.
        RoundOutcome::Applied { waited: true, .. } => AfterRound::In(std::time::Duration::ZERO),
        _ => AfterRound::In(IDLE_WAIT),
    }
}

/// The loop body, shared by `start_one` and `start_all` so the two cannot
/// drift.
fn spawn_loop(engine: Arc<SyncEngine>, account_id: Uuid) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        loop {
            let outcome = engine.round(account_id).await;
            match after_round(&outcome) {
                AfterRound::Stop => break,
                AfterRound::In(pause) => tokio::time::sleep(pause).await,
            }
        }
    })
}

pub struct SyncSupervisor {
    engine: Arc<SyncEngine>,
    tasks: tokio::sync::Mutex<HashMap<Uuid, tokio::task::JoinHandle<()>>>,
}

impl SyncSupervisor {
    pub fn new(engine: Arc<SyncEngine>) -> Self {
        Self {
            engine,
            tasks: tokio::sync::Mutex::new(HashMap::new()),
        }
    }

    pub fn engine(&self) -> Arc<SyncEngine> {
        Arc::clone(&self.engine)
    }

    /// Start the loop for ONE account, if this build can build a provider for
    /// it and no loop is *still running*.
    ///
    /// The connect route needs this: start_all ran at backend startup, when a
    /// freshly connected account did not exist yet - without this call the
    /// account would sit in the store with health "ok" and never pull a single
    /// message (observed 2026-11-01: a real QQ connect produced an empty inbox).
    ///
    /// The liveness check is `is_finished`, not "is there a key": a loop that
    /// parked on an auth failure ended, but its JoinHandle stayed in the map.
    /// Treating a finished handle as "already running" made re-authentication a
    /// no-op that still answered 201 with health "ok" - the account stopped
    /// syncing for good until the backend restarted.
    pub async fn start_one(&self, account_id: Uuid) {
        if !self.engine.has_provider(account_id) {
            return;
        }
        let mut tasks = self.tasks.lock().await;
        if tasks
            .get(&account_id)
            .is_some_and(|task| !task.is_finished())
        {
            return;
        }
        let task = spawn_loop(Arc::clone(&self.engine), account_id);
        tasks.insert(account_id, task);
    }

    /// Start one loop per account that this build can build a provider for.
    pub async fn start_all(&self) {
        let account_ids = {
            let Ok(connection) = db::open_writable(&self.engine.db_path) else {
                return;
            };
            match store::accounts::all(&connection) {
                Ok(accounts) => accounts
                    .into_iter()
                    .map(|account| account.id)
                    .collect::<Vec<_>>(),
                Err(error) => {
                    tracing::error!(err = %error, "sync.accountListFailed");
                    return;
                }
            }
        };
        for account_id in account_ids {
            if !self.engine.has_provider(account_id) {
                continue;
            }
            let task = spawn_loop(Arc::clone(&self.engine), account_id);
            self.tasks.lock().await.insert(account_id, task);
        }
    }

    /// One round for every account with a provider, concurrently; returns at
    /// once. POST /api/sync uses this: v3 does not wait for the round.
    pub fn trigger_all(&self) -> impl Future<Output = ()> + Send + 'static {
        let engine = Arc::clone(&self.engine);
        async move {
            let account_ids = {
                let Ok(connection) = db::open_writable(&engine.db_path) else {
                    return;
                };
                match store::accounts::all(&connection) {
                    Ok(accounts) => accounts
                        .into_iter()
                        .map(|account| account.id)
                        .collect::<Vec<_>>(),
                    Err(_) => return,
                }
            };
            let mut tasks = Vec::new();
            for account_id in account_ids {
                if !engine.has_provider(account_id) {
                    continue;
                }
                let engine = Arc::clone(&engine);
                tasks.push(tokio::spawn(async move {
                    let _ = engine.round(account_id).await;
                }));
            }
            for task in tasks {
                let _ = task.await;
            }
        }
    }

    /// One round in the caller's context - tests use this instead of a loop.
    pub async fn run_once(&self, account_id: Uuid) -> RoundOutcome {
        self.engine.round(account_id).await
    }

    pub async fn stop(&self) {
        let tasks: Vec<_> = self
            .tasks
            .lock()
            .await
            .drain()
            .map(|(_, task)| task)
            .collect();
        for task in tasks {
            task.abort();
        }
    }
}

/// Type alias so callers can name the engine's future without importing pin.
pub type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_waited_round_does_not_sleep_again() {
        assert_eq!(
            after_round(&RoundOutcome::Applied {
                upserts: 0,
                reset: false,
                waited: true,
            }),
            AfterRound::In(std::time::Duration::ZERO),
            "IDLE already blocked inside the round"
        );
    }

    #[test]
    fn a_polled_round_keeps_the_polling_cadence() {
        assert_eq!(
            after_round(&RoundOutcome::Applied {
                upserts: 3,
                reset: false,
                waited: false,
            }),
            AfterRound::In(IDLE_WAIT)
        );
    }

    #[test]
    fn a_parked_or_missing_account_ends_the_loop() {
        assert_eq!(
            after_round(&RoundOutcome::Parked(ParkReason::NeedsReconnect)),
            AfterRound::Stop
        );
        assert_eq!(
            after_round(&RoundOutcome::Parked(ParkReason::AccountMissing)),
            AfterRound::Stop
        );
        assert_eq!(after_round(&RoundOutcome::NotFound), AfterRound::Stop);
    }

    #[test]
    fn a_failed_round_uses_its_backoff() {
        let outcome = RoundOutcome::Failed {
            label: "unreachable".to_owned(),
            consecutive: 2,
            backoff_seconds: 4.0,
        };
        assert_eq!(
            after_round(&outcome),
            AfterRound::In(std::time::Duration::from_secs(4))
        );
    }
}
