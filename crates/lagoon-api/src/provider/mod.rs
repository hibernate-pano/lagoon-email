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
    /// The message no longer exists (or is no longer visible) on the server.
    /// Distinct from `Protocol`: the session is healthy, the data is gone.
    MessageGone,
    /// The message exists, but the part asked for is not in it.
    ///
    /// Distinct from `MessageGone`: the mail is readable, this attachment is
    /// not. The download route answers 404 for it and 410 for a gone message.
    NotFound(String),
    /// The bytes are larger than this route is willing to hand out.
    TooLarge(String),
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
            ProviderError::MessageGone => formatter.write_str("message gone"),
            ProviderError::NotFound(message) => write!(formatter, "not found: {message}"),
            ProviderError::TooLarge(message) => write!(formatter, "too large: {message}"),
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
    /// Server UID at sync time; the body route passes it back so opening a
    /// message is one FETCH instead of an identity search plus a scan.
    pub remote_uid: Option<i64>,
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
    /// Inbox `(remoteId, uid)` pairs from the same membership walk. Used to
    /// fill `remote_uid` on rows stored before that column existed; None means
    /// the walk did not report them.
    pub inbox_uids: Option<Vec<(String, i64)>>,
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

pub type RawFuture<'a> = Pin<Box<dyn Future<Output = Result<Vec<u8>, ProviderError>> + Send + 'a>>;

/// One attachment's bytes, as the download route hands them out.
#[derive(Debug, Clone, Default)]
pub struct MailAttachment {
    pub filename: Option<String>,
    pub mime_type: String,
    pub data: Vec<u8>,
}

/// One inline picture: the bytes and the content id the HTML refers to.
#[derive(Debug, Clone, Default)]
pub struct MailInlineImage {
    /// The content id without the angle brackets, as `cid:` uses it.
    pub content_id: String,
    pub mime_type: String,
    pub data: Vec<u8>,
}

pub type AttachmentFuture<'a> =
    Pin<Box<dyn Future<Output = Result<Option<MailAttachment>, ProviderError>> + Send + 'a>>;

pub type InlineImagesFuture<'a> =
    Pin<Box<dyn Future<Output = Result<Vec<MailInlineImage>, ProviderError>> + Send + 'a>>;

/// The read-only body surface.
///
/// Separate from [`MailProvider`] on purpose: a body fetch is not a sync round,
/// and the sync engine must not be able to trigger one. The body route is the
/// only caller, and only after its own cache miss.
pub trait MailBodyProvider: Send + Sync {
    /// `uid_hint` is the UID the store recorded at sync time. It is a hint,
    /// not an identity: an implementation that cannot verify it must fall
    /// back to resolving `remote_id`.
    fn fetch_body(&self, remote_id: &str, uid_hint: Option<i64>) -> BodyFuture<'_>;

    /// The original RFC 5322 bytes. Forwarding needs the whole message as a
    /// `message/rfc822` part, not the parsed text; a provider that cannot
    /// produce it answers `NotConfigured` and the route says the original is
    /// unavailable rather than forwarding a damaged copy.
    fn fetch_raw(&self, remote_id: &str, uid_hint: Option<i64>) -> RawFuture<'_> {
        let _ = (remote_id, uid_hint);
        Box::pin(async { Err(ProviderError::NotConfigured("raw".to_owned())) })
    }

    /// One attachment's bytes, by its part id.
    ///
    /// `Ok(None)` is a fact, not a failure: the message is there and the part
    /// is not. The route answers 404 `attachment-not-found` for it and 410
    /// `message-gone` for a message that is gone.
    ///
    /// The default is "no such capability": a build without mail support
    /// answers 503 on this route, exactly as the contract's fixtures say.
    fn fetch_attachment(
        &self,
        remote_id: &str,
        uid_hint: Option<i64>,
        attachment_id: &str,
    ) -> AttachmentFuture<'_> {
        let _ = (remote_id, uid_hint, attachment_id);
        Box::pin(async { Err(ProviderError::NotConfigured("attachment".to_owned())) })
    }

    /// The message's inline pictures, with the content ids the HTML refers to.
    ///
    /// One fetch for all of them: asking per picture would re-download the
    /// whole message for every `cid:` in the body.
    fn fetch_inline_images(
        &self,
        remote_id: &str,
        uid_hint: Option<i64>,
    ) -> InlineImagesFuture<'_> {
        let _ = (remote_id, uid_hint);
        Box::pin(async { Err(ProviderError::NotConfigured("inline-images".to_owned())) })
    }
}

/// One attachment the user attached to an outgoing message.
#[derive(Debug, Clone)]
pub struct OutgoingAttachment {
    pub filename: String,
    pub mime_type: String,
    pub data: Vec<u8>,
    /// A forwarded original is inline: the recipient's client renders it as a
    /// message rather than offering it as a file.
    pub inline: bool,
}

/// One message to deliver. The seam's shape, not lagoon-mail's: the fake never
/// builds MIME, and the adapter owns the protocol.
#[derive(Debug, Clone, Default)]
pub struct OutgoingMail {
    pub from_email: String,
    pub from_name: Option<String>,
    /// Primary recipients, one entry each. The adapter joins them for `To:`.
    pub to: Vec<String>,
    pub cc: Vec<String>,
    pub bcc: Vec<String>,
    pub subject: String,
    pub body: String,
    pub in_reply_to: Option<String>,
    pub references: Option<String>,
    pub is_reply: bool,
    pub attachments: Vec<OutgoingAttachment>,
}

/// What the transport reported. `provider_message_id` is the Message-ID the
/// sender generated; the store uses it as the sent row's identity.
#[derive(Debug, Clone, Default)]
pub struct SentMail {
    pub provider_message_id: Option<String>,
}

pub type SendFuture<'a> =
    Pin<Box<dyn Future<Output = Result<SentMail, ProviderError>> + Send + 'a>>;

/// The send surface. Deliberately not on [`MailWriteProvider`]: delivery is a
/// different operation from mutating an existing mailbox, and the sync engine
/// must never be able to reach either.
pub trait MailSendProvider: Send + Sync {
    fn send(&self, mail: OutgoingMail) -> SendFuture<'_>;
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

    /// The send half. Default None: every send route answers 503
    /// provider-not-configured, which is the contract's fixture.
    fn make_send(&self, credentials: &ImapCredentials) -> Option<Arc<dyn MailSendProvider>> {
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
