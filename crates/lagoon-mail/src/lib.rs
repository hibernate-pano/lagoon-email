//! Mail protocol layer for Lagoon v4 (R3).
//!
//! Owns IMAP, SMTP, MIME and charset decoding. It knows nothing about the HTTP
//! API or the SQLite store: the sync engine (lagoon-api) drives it.
//!
//! Rules carried over from v3, each earned by an incident:
//! * IMAP/SMTP are implicit TLS only (993 / 465) with full certificate
//!   verification; hosts come from presets, never user input.
//! * GBK / GB18030 / Shift-JIS bodies decode correctly (encoding_rs).
//! * UID EXPUNGE is UIDPLUS-only; without UIDPLUS the delete path is refused
//!   rather than degraded to a plain EXPUNGE (which would expunge every
//!   \Deleted message in the folder, including other clients').
//! * The sync path is read-only by construction: see [`sync::MailSyncReading`].
//!
//! ## Layering
//!
//! ```text
//!   sync::MailSyncReading      <- the only seam the sync engine gets
//!        |
//!   imap::ImapProvider         <- account-level verbs (roles, UIDPLUS gate)
//!        |
//!   imap::ImapClient           <- IMAP commands, response parsing
//!        |
//!   imap::ImapConnection       <- tag/literal framing, IDLE, timeouts
//!        |
//!   transport::Transport       <- bytes; real = implicit TLS, tests = script
//! ```
//!
//! SMTP and MIME hang off the same byte-level transport but do not depend on
//! IMAP: [`mime`] is pure bytes-to-structure and [`smtp`] is a session state
//! machine.
//!
//! ## Blocking by design
//!
//! The transport is a blocking byte stream. The v3 implementation was an async
//! NIO/Task stack; here the sync engine (R3.4) is the only async layer and it
//! runs one provider call at a time on a dedicated thread. A blocking transport
//! keeps the IMAP framing deterministic and, more importantly, makes every test
//! able to run without a runtime, timers, or a socket: the fake transport is
//! just a script of bytes. This is a deliberate shape change, not an accident —
//! see README.md.

#![forbid(unsafe_code)]

pub mod error;
pub mod imap;
pub mod mime;
pub mod preset;
pub mod smtp;
pub mod sync;
pub mod timefmt;
pub mod tls;
pub mod transport;

pub use error::{MailError, MailErrorKind, TransportError};
pub use imap::capabilities::MailCapabilities;
pub use imap::client::{ImapClient, ImapFetchedHeader, ImapMailbox, ImapSelected};
pub use imap::connection::ImapConnection;
pub use imap::membership::{FolderMembership, RemoteMembership, DEFAULT_MEMBERSHIP_BUDGET};
pub use imap::provider::{ImapProvider, ProviderCredentials};
pub use mime::builder::{build_new_message, build_reply, OutboundAttachment, OutboundMessage};
pub use mime::parser::{AttachmentDisposition, ParsedAttachment, ParsedMessage};
pub use preset::{ProviderKind, ProviderPreset};
pub use smtp::SmtpClient;
pub use sync::{ChangeSet, MailSyncReading, RemoteHeader, SyncCursor};

/// v3's provider-neutral folder row (`MailProvider.swift`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MailFolder {
    /// Leaf name for display, e.g. `Projects` out of `INBOX/Projects`.
    pub name: String,
    /// The server's own path, verbatim: never reconstructed from the leaf.
    pub path: String,
    pub has_children: bool,
}
