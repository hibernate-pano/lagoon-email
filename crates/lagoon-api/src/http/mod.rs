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
pub mod routes_r2;
pub mod routes_r3;
pub mod routes_r5;
pub mod routes_send;

use std::collections::HashSet;
use std::sync::Arc;

use axum::routing::get;
use axum::{middleware, Router};

use crate::config::Config;
use crate::crypto::BodyKey;
use crate::db::Db;

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
}

impl AppState {
    pub fn new(db: Arc<Db>, config: &Config) -> Self {
        let body_key = Arc::new(config.body_key.clone());
        let token_key = config.token_key.clone().map(Arc::new);
        let provider_factory: Arc<dyn crate::provider::ProviderFactory> =
            Arc::new(crate::provider::NoProviderFactory);
        let sync = build_supervisor(&db, &body_key, &token_key, &provider_factory);
        Self {
            db,
            body_key,
            api_token: config.api_token.as_deref().map(Arc::from),
            allowed_hosts: Arc::new(config.allowed_host_names()),
            budget_cap_usd: config.budget_cap_usd,
            token_key,
            provider_factory,
            sync,
        }
    }

    /// Replace the provider factory (tests, and R3.4b's lagoon-mail wiring).
    /// The supervisor is rebuilt around it so the loops and POST /api/sync use
    /// the same providers the account routes do.
    pub fn with_provider_factory(
        mut self,
        factory: Arc<dyn crate::provider::ProviderFactory>,
    ) -> Self {
        self.provider_factory = Arc::clone(&factory);
        self.sync = build_supervisor(&self.db, &self.body_key, &self.token_key, &factory);
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
}

fn build_supervisor(
    db: &Arc<Db>,
    body_key: &Arc<BodyKey>,
    token_key: &Option<Arc<crate::token::TokenKey>>,
    factory: &Arc<dyn crate::provider::ProviderFactory>,
) -> Arc<crate::sync::SyncSupervisor> {
    Arc::new(crate::sync::SyncSupervisor::new(Arc::new(
        crate::sync::SyncEngine::new(
            db.path().to_path_buf(),
            Arc::clone(body_key),
            token_key.clone(),
            Arc::clone(factory),
        ),
    )))
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
        .route("/api/ai-status", get(routes_r2::ai_status))
        .route("/api/actions", get(routes_r2::actions))
        .route("/api/reminders", get(routes_r2::reminders))
        .route("/api/export/index", get(routes_r2::export_index))
        .route("/api/search", get(routes_r2::search))
        .route("/api/messages/{remote_id}/drafts", get(routes_r2::drafts))
        .route("/api/messages/{remote_id}/summary", get(routes_r2::summary))
        .route(
            "/api/messages/{remote_id}/inline-images",
            get(routes_r2::inline_images),
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
            axum::routing::post(routes_r2::draft_generate),
        )
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
        .fallback(routes::not_found)
        // One middleware, with the Host check before the token check inside it:
        // v3's stack order is Host -> auth -> routes (Runtime.swift:187-191).
        .layer(middleware::from_fn_with_state(
            state.clone(),
            guard::enforce,
        ))
        .with_state(state)
}
