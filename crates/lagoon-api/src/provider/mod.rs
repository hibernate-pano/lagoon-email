//! The provider seam.
//!
//! Routes never speak IMAP. They ask a ProviderFactory for a MailProvider,
//! probe it, and persist what it reports; everything protocol-shaped lives
//! behind this boundary. That is what lets the account routes and their whole
//! error matrix be tested today, while the real client (v4/crates/lagoon-mail,
//! being written in parallel) lands later without touching the routes.
//!
//! R3.3 ships NoProviderFactory as the production default: it returns None, so
//! the connect route answers 503 provider-not-configured. The lagoon-mail
//! adapter is R3.4's job; no protocol code is copied here.

use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

use crate::token::ImapCredentials;
use crate::wire::MailCapabilities;

pub mod fake;
/// The production adapter over lagoon-mail (IMAP/TLS, no protocol code here).
pub mod lagoon_mail;

/// What a successful probe learned about the mailbox.
///
/// Capabilities are tri-state: None means "the negotiation could not complete",
/// which is not the same answer as "this server has none of these". Writing a
/// failed negotiation as "no capabilities" would permanently disable archive
/// and delete for that account, which is the defect v3's comments warn about.
#[derive(Debug, Clone, Default)]
pub struct ProbeOutcome {
    pub capabilities: Option<MailCapabilities>,
    /// The remote archive folder the probe resolved, if any.
    pub archive_folder: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProviderError {
    /// The server rejected the authorization code.
    AuthFailed,
    /// The host could not be reached (DNS, TCP, TLS, timeout).
    Unreachable(String),
    /// The credentials could not even be turned into a client.
    NotConfigured(String),
    /// The server answered, but not with IMAP we can use.
    Protocol(String),
}

impl std::fmt::Display for ProviderError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ProviderError::AuthFailed => formatter.write_str("imap auth failed"),
            ProviderError::Unreachable(message) => write!(formatter, "imap unreachable: {message}"),
            ProviderError::NotConfigured(message) => {
                write!(formatter, "provider not configured: {message}")
            }
            ProviderError::Protocol(message) => write!(formatter, "imap protocol error: {message}"),
        }
    }
}

impl std::error::Error for ProviderError {}

pub type ProbeFuture<'a> =
    Pin<Box<dyn Future<Output = Result<ProbeOutcome, ProviderError>> + Send + 'a>>;

/// One header as the provider reports it (v3 RemoteHeader).
#[derive(Debug, Clone, Default)]
pub struct RemoteHeader {
    pub remote_id: String,
    pub thread_id: String,
    pub from_address: String,
    pub from_name: Option<String>,
    pub subject: Option<String>,
    pub snippet: Option<String>,
    pub received_at: String,
    pub is_read: bool,
    pub message_id_header: Option<String>,
    pub in_reply_to: Option<String>,
    pub references: Option<String>,
    pub list_unsubscribe: bool,
    pub unsubscribe_links: String,
}

/// One pull's worth of changes, mirroring v3 MailChangeSet.
#[derive(Debug, Clone, Default)]
pub struct MailChangeSet {
    /// The cursor to persist after this set is applied.
    pub cursor: crate::sync::SyncCursor,
    /// The remote UID space changed: wipe live rows before upserting.
    pub reset_required: bool,
    pub upserts: Vec<RemoteHeader>,
    /// Sent-folder Message-IDs (cross-client reply detection).
    pub replied_message_ids: Vec<String>,
    /// None means the provider did not report inbox membership this round.
    pub inbox_remote_ids: Option<Vec<String>>,
    pub archived_remote_ids: Option<Vec<String>>,
    pub trashed_remote_ids: Option<Vec<String>>,
    pub removed_remote_ids: Vec<String>,
    /// This pull blocked waiting for the server (IMAP IDLE). The sync loop
    /// must not sleep on top: the wait already happened inside the pull.
    pub waited: bool,
}

pub type PullFuture<'a> =
    Pin<Box<dyn Future<Output = Result<MailChangeSet, ProviderError>> + Send + 'a>>;

/// One mailbox connection.
///
/// R3.4a needs exactly the sync surface: probe and pull. The write verbs live
/// on [`MailWriteProvider`], a separate trait the sync engine never receives,
/// so "sync never writes the mailbox" stays a compile-time fact in Rust too
/// (v3 enforced the same thing with `MailSyncReading`).
pub trait MailProvider: Send + Sync {
    fn probe(&self) -> ProbeFuture<'_>;
    fn pull_changes(&self, after: &crate::sync::SyncCursor) -> PullFuture<'_>;
}

pub type WriteFuture<'a> = Pin<Box<dyn Future<Output = Result<(), ProviderError>> + Send + 'a>>;

/// One fetched body, in the shape the store and the wire want.
///
/// Lagoon-mail's `ParsedMessage` is converted into this at the seam so the
/// trait carries no protocol types: the store, the fake and the routes all see
/// one struct.
#[derive(Debug, Clone, Default)]
pub struct MailBody {
    pub text: String,
    pub html: Option<String>,
    pub has_more: bool,
    pub attachments: Vec<crate::wire::Attachment>,
    pub to: Vec<String>,
    pub cc: Vec<String>,
}

pub type BodyFuture<'a> =
    Pin<Box<dyn Future<Output = Result<MailBody, ProviderError>> + Send + 'a>>;

/// The read-only body surface.
///
/// Separate from [`MailProvider`] on purpose: a body fetch is not a sync round,
/// and the sync engine must not be able to trigger one. The body route is the
/// only caller, and only after its own cache miss.
pub trait MailBodyProvider: Send + Sync {
    fn fetch_body(&self, remote_id: &str) -> BodyFuture<'_>;
}

/// The mutating verbs, reachable only from the action routes.
///
/// Every verb maps one v3 write: `archive` = UID MOVE to the archive folder,
/// `trash` = UID MOVE to Trash, `permanently_delete` = UID EXPUNGE (UIDPLUS
/// only - lagoon-mail refuses, never degrades), `empty_trash` = batch EXPUNGE,
/// `set_read` = UID STORE \\Seen. Errors keep v3's mapping: AuthFailed -> 401,
/// Unreachable -> 502, capability gates -> 409 (the caller turns
/// ArchiveUnavailable into `archive-unavailable` and so on).
pub trait MailWriteProvider: Send + Sync {
    fn set_read(&self, remote_id: &str, is_read: bool) -> WriteFuture<'_>;
    fn archive(&self, remote_id: &str) -> WriteFuture<'_>;
    fn unarchive(&self, remote_id: &str) -> WriteFuture<'_>;
    fn trash(&self, remote_id: &str) -> WriteFuture<'_>;
    fn restore_from_trash(&self, remote_id: &str) -> WriteFuture<'_>;
    fn permanently_delete(&self, remote_id: &str) -> WriteFuture<'_>;
    fn empty_trash(&self) -> WriteFuture<'_>;
}

/// Builds a provider for one set of credentials, or returns None when this
/// build has no provider for them (the 503 path).
pub trait ProviderFactory: Send + Sync {
    fn make(&self, credentials: &ImapCredentials) -> Option<Arc<dyn MailProvider>>;

    /// The write half. Default None: a build without mail support (contract
    /// runs) answers 503 provider-not-configured on every action route.
    fn make_write(&self, credentials: &ImapCredentials) -> Option<Arc<dyn MailWriteProvider>> {
        let _ = credentials;
        None
    }

    /// The body half. Default None: the body route answers 503
    /// provider-not-configured on a cache miss, which is what the contract
    /// fixtures pin for a build without mail support.
    fn make_body(&self, credentials: &ImapCredentials) -> Option<Arc<dyn MailBodyProvider>> {
        let _ = credentials;
        None
    }
}

/// The R3.3 production default.
///
/// Until the lagoon-mail adapter lands, this is the honest answer: the server
/// has no provider, so the connect route reports provider-not-configured
/// instead of pretending the mailbox was unreachable.
#[derive(Debug, Default, Clone, Copy)]
pub struct NoProviderFactory;

impl ProviderFactory for NoProviderFactory {
    fn make(&self, _credentials: &ImapCredentials) -> Option<Arc<dyn MailProvider>> {
        // TODO(R3.4): return the lagoon-mail adapter built from these credentials.
        None
    }
}
