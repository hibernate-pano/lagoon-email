//! The HTTP surface: router, guard, envelopes.
//!
//! Only the five R1 routes exist. Everything else - the other 52 endpoints of
//! the v3 contract, any path that merely *looks* like one - falls through to
//! the bare 404, which is what v3 does and what "m1-checklist.md" §1 records.

// Helpers here return `Result<_, Response>` so a failure can be returned
// verbatim from an axum handler. `Response` is 128 bytes; boxing it would add
// an allocation to every error path and force `Err(Box::new(..))` at every
// call site, so the size is accepted deliberately.
#![allow(clippy::result_large_err)]

pub mod guard;
pub mod query;
pub mod respond;
pub mod routes;
/// The AI routes: status, summary, draft, reload, probe.
pub mod routes_advice;
pub mod routes_ai;
/// The mailbox reads that need a provider: inline images and attachments.
pub mod routes_attachments;
pub mod routes_r2;
pub mod routes_r3;
pub mod routes_r5;
pub mod routes_send;
pub mod routes_triage;

use std::collections::HashSet;
use std::sync::Arc;

use axum::routing::get;
use axum::{middleware, Router};

use crate::ai::config::AiConfig;
use crate::ai::gateway::{AiGateway, Budget, BudgetSource};
use crate::ai::transport::HttpChatTransport;
use crate::config::Config;
use crate::crypto::BodyKey;
use crate::db::Db;

/// The budget the gateway enforces: this month's spend from the ledger the
/// usage route shows, and the cap from the environment (0 = no cap).
fn budget_source(db: Arc<Db>, cap_usd: f64) -> BudgetSource {
    let cap_micro_usd = (cap_usd * 1_000_000.0).round() as i64;
    Arc::new(move || {
        let month = chrono::Local::now().format("%Y-%m").to_string();
        let spent_micro_usd = db
            .with_connection(move |connection| {
                crate::store::usage::month_summary(connection, &month)
            })
            .map(|summary| summary.cost_micro_usd)
            .unwrap_or(0);
        Budget {
            spent_micro_usd,
            cap_micro_usd,
        }
    })
}

/// Everything a handler needs, cloned per request.
#[derive(Clone)]
pub struct AppState {
    pub db: Arc<Db>,
    pub body_key: Arc<BodyKey>,
    /// None keeps the legacy loopback posture: no token, no authentication
    /// (v3 APIAuthMiddleware). A token set makes every path except /healthz
    /// fail-closed.
    pub api_token: Option<Arc<str>>,
    pub allowed_hosts: Arc<HashSet<String>>,
    /// The monthly AI cap /api/usage reports (v3 LAGOON_BUDGET_USD_PER_MONTH).
    pub budget_cap_usd: f64,
    /// Seals credential blobs (v3 AccessTokenCipher). None is a read-only
    /// deployment: the connect route refuses to store a plaintext secret.
    pub token_key: Option<Arc<crate::token::TokenKey>>,
    /// The provider seam. Production is NoProviderFactory until the
    /// lagoon-mail adapter lands; tests inject a scripted fake.
    pub provider_factory: Arc<dyn crate::provider::ProviderFactory>,
    /// The sync supervisor: one loop per account with a provider, plus the
    /// trigger POST /api/sync uses.
    pub sync: Arc<crate::sync::SyncSupervisor>,
    /// The AI gateway: the read-only advisor (constitution §2).
    ///
    /// It is always present. What varies is whether it is *configured*: a
    /// build with no provider key answers `configured:false` and every AI
    /// route answers 503 ai-not-configured, which is the truth rather than a
    /// crash.
    pub ai: Arc<AiGateway>,
    /// The two-layer triage batch (plan §4): the rules layer is free and always
    /// available, the model layer needs a configured gateway.
    ///
    /// It holds its own handle to the gateway so `with_ai_gateway` can rebuild
    /// both, exactly like the supervisor.
    pub triage: Arc<crate::triage::TriageWorker>,
}

impl AppState {
    pub fn new(db: Arc<Db>, config: &Config) -> Self {
        let body_key = Arc::new(config.body_key.clone());
        let token_key = config.token_key.clone().map(Arc::new);
        let provider_factory: Arc<dyn crate::provider::ProviderFactory> =
            Arc::new(crate::provider::NoProviderFactory);
        // One gateway for the routes and the sync supervisor. Two instances
        // would keep two breaker states, and `POST /api/ai/reload` would
        // reach only one of them.
        //
        // A configuration that does not load is an empty one: the AI is then
        // simply not configured, and the status route says so.
        let ai = Arc::new(
            AiGateway::new(
                AiConfig::load_current().unwrap_or_default(),
                Arc::new(HttpChatTransport::new()),
            )
            .with_budget(budget_source(Arc::clone(&db), config.budget_cap_usd)),
        );
        let sync = build_supervisor(&db, &body_key, &token_key, &provider_factory, &ai);
        let triage = Arc::new(crate::triage::TriageWorker::new(
            db.path().to_path_buf(),
            Arc::clone(&ai),
            config.budget_cap_usd,
        ));
        Self {
            db,
            body_key,
            api_token: config.api_token.as_deref().map(Arc::from),
            allowed_hosts: Arc::new(config.allowed_host_names()),
            budget_cap_usd: config.budget_cap_usd,
            token_key,
            provider_factory,
            sync,
            ai,
            triage,
        }
    }

    /// Replace the whole AI gateway (tests that need their own keys).
    ///
    /// The sync supervisor is rebuilt around the new gateway, so the advice
    /// step and the routes use the same advisor.
    pub fn with_ai_gateway(mut self, gateway: Arc<AiGateway>) -> Self {
        self.ai = Arc::clone(&gateway);
        self.sync = build_supervisor(
            &self.db,
            &self.body_key,
            &self.token_key,
            &self.provider_factory,
            &self.ai,
        );
        // The worker must see the same gateway, or `POST /api/ai/reload` would
        // reach the routes and leave the batch on the old keys.
        self.triage = Arc::new(crate::triage::TriageWorker::new(
            self.db.path().to_path_buf(),
            Arc::clone(&self.ai),
            self.budget_cap_usd,
        ));
        self
    }

    /// Replace the provider factory (tests, and R3.4b's lagoon-mail wiring).
    /// The supervisor is rebuilt around it so the loops and POST /api/sync use
    /// the same providers the account routes do.
    pub fn with_provider_factory(
        mut self,
        factory: Arc<dyn crate::provider::ProviderFactory>,
    ) -> Self {
        self.provider_factory = Arc::clone(&factory);
        self.sync = build_supervisor(
            &self.db,
            &self.body_key,
            &self.token_key,
            &factory,
            &self.ai,
        );
        self
    }

    /// A writable connection for the account routes.
    ///
    /// One connection per write, opened on demand: the server's pool is
    /// read-only by design, and R3.3 does not yet serve enough write traffic to
    /// justify a second pool. WAL makes the short-lived writer safe next to the
    /// readers.
    pub fn write_connection(&self) -> Result<rusqlite::Connection, crate::db::DbError> {
        crate::db::open_writable(self.db.path())
    }

    /// Run `f` on a fresh writable connection, off the async reactor.
    ///
    /// The read pool is read-only by design, so a write opens its own
    /// connection. It runs on a blocking worker for the same reason the reads
    /// do: rusqlite is synchronous, and a write on the reactor thread would
    /// stall every other request behind a fsync.
    pub async fn write<T, F>(&self, f: F) -> Result<T, crate::db::DbError>
    where
        F: FnOnce(&rusqlite::Connection) -> Result<T, crate::store::StoreError> + Send + 'static,
        T: Send + 'static,
    {
        let path = self.db.path().to_path_buf();
        tokio::task::spawn_blocking(move || {
            let connection = crate::db::open_writable(&path)?;
            f(&connection).map_err(crate::db::DbError::Store)
        })
        .await?
    }

    /// Build a body provider from the account's stored credentials.
    ///
    /// `None` is every reason the cache-miss path cannot reach a mailbox: no
    /// token key, no stored blob, a blob that will not open, or a build with no
    /// body provider. Every one of them answers 503 provider-not-configured,
    /// which is what v3 does when its provider cannot be constructed.
    /// Build a send provider from the account's stored credentials.
    ///
    /// `None` is every reason a send cannot reach the mailbox: no token key,
    /// no stored blob, a blob that will not open, or a build with no send
    /// provider. All of them answer 503 provider-not-configured.
    pub fn send_provider(
        &self,
        account_id: crate::uuid::Uuid,
    ) -> Option<Arc<dyn crate::provider::MailSendProvider>> {
        let token_key = self.token_key.as_ref()?;
        let connection = crate::db::open_writable(self.db.path()).ok()?;
        let blob = crate::store::write::credentials(&connection, account_id)
            .ok()
            .flatten()?;
        let credentials = crate::token::ImapCredentials::open(token_key, &blob).ok()?;
        self.provider_factory.make_send(&credentials)
    }

    pub fn body_provider(
        &self,
        account_id: crate::uuid::Uuid,
    ) -> Option<Arc<dyn crate::provider::MailBodyProvider>> {
        let token_key = self.token_key.as_ref()?;
        let connection = crate::db::open_writable(self.db.path()).ok()?;
        let blob = crate::store::write::credentials(&connection, account_id)
            .ok()
            .flatten()?;
        let credentials = crate::token::ImapCredentials::open(token_key, &blob).ok()?;
        self.provider_factory.make_body(&credentials)
    }

    /// Whether the store knows this account.
    ///
    /// `None` means the store could not answer - which is not the same as
    /// "no such account". A route that treats it as "no" would answer 404
    /// unknown-account for a database hiccup.
    pub async fn account_exists(&self, account_id: crate::uuid::Uuid) -> Option<bool> {
        self.db
            .read(move |connection| crate::store::accounts::exists(connection, account_id))
            .await
            .ok()
    }
}

fn build_supervisor(
    db: &Arc<Db>,
    body_key: &Arc<BodyKey>,
    token_key: &Option<Arc<crate::token::TokenKey>>,
    factory: &Arc<dyn crate::provider::ProviderFactory>,
    ai: &Arc<AiGateway>,
) -> Arc<crate::sync::SyncSupervisor> {
    let mut engine = crate::sync::SyncEngine::new(
        db.path().to_path_buf(),
        Arc::clone(body_key),
        token_key.clone(),
        Arc::clone(factory),
    );
    engine = engine.with_ai(Arc::clone(ai));
    Arc::new(crate::sync::SyncSupervisor::new(Arc::new(engine)))
}

/// The R1 router.
pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/healthz", get(routes::healthz))
        .route("/api/accounts", get(routes::accounts))
        .route("/api/messages", get(routes::messages))
        .route("/api/messages/{remote_id}/body", get(routes::message_body))
        .route("/api/folder-counts", get(routes::folder_counts))
        // R2: the local-only reads.
        .route("/api/briefing", get(routes_r2::briefing))
        .route("/api/advice", get(routes_r2::advice))
        .route("/api/advice/accepted-stats", get(routes_r2::accepted_stats))
        .route("/api/stacks", get(routes_r2::stacks))
        .route("/api/senders", get(routes_r2::senders))
        .route("/api/sent", get(routes_r2::sent))
        .route("/api/store-notices", get(routes_r2::store_notices))
        .route("/api/time-saved", get(routes_r2::time_saved))
        .route("/api/usage", get(routes_r2::usage))
        .route("/api/ai-status", get(routes_ai::ai_status))
        .route("/api/actions", get(routes_r2::actions))
        .route("/api/reminders", get(routes_r2::reminders))
        .route("/api/export/index", get(routes_r2::export_index))
        .route("/api/search", get(routes_r2::search))
        .route("/api/messages/{remote_id}/drafts", get(routes_r2::drafts))
        .route("/api/messages/{remote_id}/summary", get(routes_ai::summary))
        .route(
            "/api/messages/{remote_id}/inline-images",
            get(routes_attachments::inline_images),
        )
        .route(
            "/api/messages/{remote_id}/attachments/{attachment_id}",
            get(routes_attachments::attachment),
        )
        .route("/api/messages/{remote_id}/raw.eml", get(routes_r2::raw_eml))
        // R3.5a: the write paths. archive replaces the R2 503 stub; the rest
        // are new registrations (axum panics on duplicates, so each stub that
        // an R3.5 route replaces must be removed here).
        .route(
            "/api/messages/{remote_id}/archive",
            axum::routing::post(routes_r5::archive),
        )
        .route(
            "/api/messages/{remote_id}/unarchive",
            axum::routing::post(routes_r5::unarchive),
        )
        .route(
            "/api/messages/{remote_id}/delete",
            axum::routing::post(routes_r5::delete),
        )
        .route(
            "/api/messages/{remote_id}/restore",
            axum::routing::post(routes_r5::restore),
        )
        .route(
            "/api/messages/{remote_id}/purge",
            axum::routing::post(routes_r5::purge),
        )
        .route(
            "/api/messages/{remote_id}/read",
            axum::routing::post(routes_r5::mark_read),
        )
        .route(
            "/api/messages/{remote_id}/pin",
            axum::routing::post(routes_r5::pin),
        )
        .route(
            "/api/trash/empty",
            axum::routing::post(routes_r5::empty_trash),
        )
        .route(
            "/api/archive-bulk",
            axum::routing::post(routes_r5::archive_bulk),
        )
        .route(
            "/api/delete-bulk",
            axum::routing::post(routes_r5::delete_bulk),
        )
        .route(
            "/api/actions/{id}/undo",
            axum::routing::post(routes_r5::undo_action),
        )
        .route(
            "/api/actions/undo-bulk",
            axum::routing::post(routes_r5::undo_bulk),
        )
        .route(
            "/api/messages/{remote_id}/draft",
            axum::routing::post(routes_ai::draft_generate),
        )
        // R4: the AI configuration. reload is the user's "try again" after
        // fixing the key; probe is the cheapest way to find out whether the
        // provider answers at all.
        .route("/api/ai/reload", axum::routing::post(routes_ai::ai_reload))
        .route("/api/ai/probe", axum::routing::post(routes_ai::ai_probe))
        // R3.5b: the three send paths. Attachments make these bodies big,
        // so they get the contract's 64 MB ceiling instead of axum's 2 MB
        // default; the other routes stay at the default.
        .route(
            "/api/messages/{remote_id}/send",
            axum::routing::post(routes_send::reply)
                .layer(axum::extract::DefaultBodyLimit::max(64 * 1024 * 1024)),
        )
        .route(
            "/api/compose/send",
            axum::routing::post(routes_send::compose)
                .layer(axum::extract::DefaultBodyLimit::max(64 * 1024 * 1024)),
        )
        .route(
            "/api/messages/{remote_id}/forward",
            axum::routing::post(routes_send::forward)
                .layer(axum::extract::DefaultBodyLimit::max(64 * 1024 * 1024)),
        )
        // R3.3: account lifecycle over the provider seam.
        .route(
            "/api/accounts/imap",
            axum::routing::post(routes_r3::connect_imap),
        )
        .route(
            "/api/accounts/{id}/activate",
            axum::routing::post(routes_r3::activate),
        )
        .route(
            "/api/accounts/{id}",
            axum::routing::delete(routes_r3::delete_account),
        )
        // R3.4a: trigger a sync round and answer immediately (v3 204).
        .route("/api/sync", axum::routing::post(routes_r3::sync_now))
        // R6: the two-layer triage batch (plan §4.6). `status` is a read; `run`
        // answers 202 immediately and `cancel` is the only way to stop one.
        .route("/api/triage/status", get(routes_triage::status))
        .route("/api/triage/run", axum::routing::post(routes_triage::run))
        .route(
            "/api/triage/cancel",
            axum::routing::post(routes_triage::cancel),
        )
        // R6: recording what the user decided about a suggestion. Separate from
        // the mail write paths on purpose - see routes_advice's header.
        .route(
            "/api/advice/{id}/decision",
            axum::routing::post(routes_advice::decision),
        )
        .route(
            "/api/advice/decisions-bulk",
            axum::routing::post(routes_advice::decisions_bulk),
        )
        .fallback(routes::not_found)
        // One middleware, with the Host check before the token check inside it:
        // v3's stack order is Host -> auth -> routes (Runtime.swift:187-191).
        .layer(middleware::from_fn_with_state(
            state.clone(),
            guard::enforce,
        ))
        .with_state(state)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The budget the gateway enforces is the same ledger `/api/usage`
    /// shows: one number, one source. If this wiring breaks, the cap the
    /// user set silently stops protecting them.
    #[test]
    fn the_budget_is_the_ledger_and_the_cap() {
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("clock")
            .as_nanos();
        let directory =
            std::env::temp_dir().join(format!("lagoon-budget-{}-{unique}", std::process::id()));
        std::fs::create_dir_all(&directory).expect("temp dir");
        let path = directory.join("lagoon.sqlite");
        {
            let connection = crate::db::open_writable(&path).expect("open for writing");
            crate::store::migrate::migrate(&connection, None).expect("schema");
            let month = chrono::Local::now().format("%Y-%m").to_string();
            crate::store::usage::record(
                &connection,
                &crate::store::usage::UsageRecord {
                    year_month: &month,
                    account_email: "a@example.invalid",
                    capability: "summary",
                    model: "MiniMax-M3",
                    prompt_tokens: 1,
                    completion_tokens: 1,
                    cost_micro_usd: 2_500_000,
                },
            )
            .expect("usage row");
        }
        let db = Arc::new(Db::open_read_only(&path).expect("read only"));
        let budget = budget_source(Arc::clone(&db), 5.0)();
        assert_eq!(budget.spent_micro_usd, 2_500_000, "this month's ledger");
        assert_eq!(budget.cap_micro_usd, 5_000_000, "$5 in micro-USD");
        let _ = std::fs::remove_dir_all(&directory);
    }

    /// A dollar cap that cannot be parsed is no cap, not a zero cap: the
    /// config already normalises it, and the gateway must agree.
    #[test]
    fn a_zero_budget_means_no_cap_at_all() {
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("clock")
            .as_nanos();
        let directory = std::env::temp_dir().join(format!(
            "lagoon-budget-zero-{}-{unique}",
            std::process::id()
        ));
        std::fs::create_dir_all(&directory).expect("temp dir");
        let path = directory.join("lagoon.sqlite");
        {
            let connection = crate::db::open_writable(&path).expect("open for writing");
            crate::store::migrate::migrate(&connection, None).expect("schema");
        }
        let db = Arc::new(Db::open_read_only(&path).expect("read only"));
        let budget = budget_source(db, 0.0)();
        assert_eq!(budget.cap_micro_usd, 0);
        assert!(!budget.is_spent(), "zero is 'no cap', never 'all spent'");
        let _ = std::fs::remove_dir_all(&directory);
    }
}
