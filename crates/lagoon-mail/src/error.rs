//! Typed mail failures with stable, log-safe codes.
//!
//! ## Why no server text
//!
//! v3's SMTP path deliberately maps status codes to stable labels because the
//! server's explanation can name the recipient's mailbox ("550 5.1.1
//! <someone@example.com> user unknown") and that text ends up in logs and,
//! before the fix, in user-facing errors. The Rust port makes that structural:
//! [`MailError`] can only carry a `&'static str` code and an optional numeric
//! status. There is no field a remote string can be stored in.
//!
//! The same type covers IMAP, where the v3 mapping was:
//! `authFailed` / `unreachable` / `protocolError` / `messageGone` /
//! `archiveUnavailable` / `trashUnavailable` / `sentUnavailable` /
//! `notConfigured` / `accountMissing` (`MailProvider.swift:238-280`).

use std::fmt;

/// v3's `MailError` cases, plus the two verdicts R3 needs to name explicitly.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum MailErrorKind {
    /// The server rejected the credentials (or the auth code is not valid).
    AuthFailed,
    /// Socket/DNS/TLS/timing problem: the session is no longer usable.
    Unreachable,
    /// The server answered, but refused the command (tagged NO/BAD, SMTP 5xx).
    Protocol,
    /// The UID is no longer in the selected mailbox.
    MessageGone,
    /// The account has no archive folder and none could be created.
    ArchiveUnavailable,
    /// The account has no Trash-role folder. Delete is refused, never faked.
    TrashUnavailable,
    /// The account has no Sent-role folder. Distinct from an empty Sent folder.
    SentUnavailable,
    /// Credentials are missing or unreadable; the account is not configured.
    NotConfigured,
    /// The store has no account row for the id the caller holds.
    AccountMissing,
    /// A verb was attempted without the capability that makes it safe
    /// (chiefly: permanent delete without UIDPLUS).
    MissingCapability,
    /// The operation was refused because a safe implementation does not exist
    /// on this server (e.g. archive via COPY+EXPUNGE without UIDPLUS).
    UnsafeOperation,
    /// A protocol frame exceeded a hard bound.
    TooLarge,
    /// The message is there, but the part asked for is not in it.
    ///
    /// Distinct from `MessageGone`: the mail still exists, this part does not.
    /// The download route answers 404 for it and 410 for a gone message.
    AttachmentNotFound,
}

impl MailErrorKind {
    /// Stable, log-safe label. Never contains remote text.
    pub fn label(self) -> &'static str {
        match self {
            Self::AuthFailed => "auth-failed",
            Self::Unreachable => "unreachable",
            Self::Protocol => "protocol-error",
            Self::MessageGone => "message-gone",
            Self::ArchiveUnavailable => "archive-unavailable",
            Self::TrashUnavailable => "trash-unavailable",
            Self::SentUnavailable => "sent-unavailable",
            Self::NotConfigured => "not-configured",
            Self::AccountMissing => "account-missing",
            Self::MissingCapability => "capability-missing",
            Self::UnsafeOperation => "unsafe-operation",
            Self::TooLarge => "too-large",
            Self::AttachmentNotFound => "attachment-not-found",
        }
    }
}

/// A mail-layer failure.
///
/// `code` is a stable machine-readable token (`tagged-NO`, `smtp-status`,
/// `uidplus-missing`, …). `status` is the numeric protocol status when the
/// server supplied one. Neither can hold server prose.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MailError {
    kind: MailErrorKind,
    code: &'static str,
    status: Option<u16>,
}

impl MailError {
    pub fn new(kind: MailErrorKind, code: &'static str) -> Self {
        Self {
            kind,
            code,
            status: None,
        }
    }

    pub fn with_status(kind: MailErrorKind, code: &'static str, status: u16) -> Self {
        Self {
            kind,
            code,
            status: Some(status),
        }
    }

    pub fn auth_failed() -> Self {
        Self::new(MailErrorKind::AuthFailed, "auth-failed")
    }

    pub fn unreachable(code: &'static str) -> Self {
        Self::new(MailErrorKind::Unreachable, code)
    }

    pub fn unreachable_status(code: &'static str, status: u16) -> Self {
        Self::with_status(MailErrorKind::Unreachable, code, status)
    }

    pub fn protocol(code: &'static str) -> Self {
        Self::new(MailErrorKind::Protocol, code)
    }

    pub fn protocol_status(code: &'static str, status: u16) -> Self {
        Self::with_status(MailErrorKind::Protocol, code, status)
    }

    pub fn message_gone() -> Self {
        Self::new(MailErrorKind::MessageGone, "message-gone")
    }

    pub fn archive_unavailable() -> Self {
        Self::new(MailErrorKind::ArchiveUnavailable, "archive-unavailable")
    }

    pub fn trash_unavailable() -> Self {
        Self::new(MailErrorKind::TrashUnavailable, "trash-unavailable")
    }

    pub fn sent_unavailable() -> Self {
        Self::new(MailErrorKind::SentUnavailable, "sent-unavailable")
    }

    pub fn not_configured(code: &'static str) -> Self {
        Self::new(MailErrorKind::NotConfigured, code)
    }

    pub fn account_missing() -> Self {
        Self::new(MailErrorKind::AccountMissing, "account-missing")
    }

    pub fn missing_capability(code: &'static str) -> Self {
        Self::new(MailErrorKind::MissingCapability, code)
    }

    pub fn unsafe_operation(code: &'static str) -> Self {
        Self::new(MailErrorKind::UnsafeOperation, code)
    }

    pub fn too_large(code: &'static str) -> Self {
        Self::new(MailErrorKind::TooLarge, code)
    }

    pub fn attachment_not_found() -> Self {
        Self::new(MailErrorKind::AttachmentNotFound, "attachment-not-found")
    }

    pub fn kind(&self) -> MailErrorKind {
        self.kind
    }

    pub fn code(&self) -> &'static str {
        self.code
    }

    pub fn status(&self) -> Option<u16> {
        self.status
    }

    pub fn is_auth_failed(&self) -> bool {
        self.kind == MailErrorKind::AuthFailed
    }

    /// Whether the error is a verdict about the *message or folder* rather than
    /// about the socket (v3 `IMAPClient.isMessageVerdict`).
    ///
    /// A message verdict consumes the command's whole response set, so the
    /// session is still aligned and must **not** be torn down. A transport
    /// failure is the opposite.
    pub fn is_message_verdict(&self) -> bool {
        match self.kind {
            MailErrorKind::Protocol
            | MailErrorKind::MessageGone
            | MailErrorKind::ArchiveUnavailable
            | MailErrorKind::TrashUnavailable
            | MailErrorKind::SentUnavailable
            | MailErrorKind::MissingCapability
            | MailErrorKind::UnsafeOperation
            | MailErrorKind::TooLarge
            | MailErrorKind::AttachmentNotFound => true,
            MailErrorKind::AuthFailed
            | MailErrorKind::Unreachable
            | MailErrorKind::NotConfigured
            | MailErrorKind::AccountMissing => false,
        }
    }
}

impl fmt::Display for MailError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.kind.label())?;
        if self.code != self.kind.label() {
            write!(f, " ({})", self.code)?;
            if let Some(status) = self.status {
                write!(f, " {}", status)?;
            }
            return write!(f, ")");
        }
        if let Some(status) = self.status {
            write!(f, " [{}]", status)?;
        }
        Ok(())
    }
}

impl std::error::Error for MailError {}

/// Byte-transport failures. Carries no remote text either: an IO error is
/// reduced to its `ErrorKind`, and a TLS failure to a static label, so no
/// server-controlled bytes can ride an error into a log or a response.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransportError {
    NotConnected,
    Closed,
    TimedOut,
    Malformed(&'static str),
    Io(std::io::ErrorKind),
    Tls(&'static str),
}

impl TransportError {
    pub fn is_timed_out(&self) -> bool {
        matches!(self, Self::TimedOut)
    }

    /// Map onto the mail surface. `channel` is `"imap"` or `"smtp"` and is
    /// only used to pick a static code.
    pub fn to_mail(self, channel: &'static str) -> MailError {
        match self {
            Self::TimedOut => MailError::unreachable(if channel == "imap" {
                "imap-timeout"
            } else {
                "smtp-timeout"
            }),
            Self::Closed => MailError::unreachable(if channel == "imap" {
                "imap-closed"
            } else {
                "smtp-closed"
            }),
            Self::NotConnected => MailError::unreachable(if channel == "imap" {
                "imap-not-connected"
            } else {
                "smtp-not-connected"
            }),
            Self::Tls(_) => MailError::unreachable(if channel == "imap" {
                "imap-tls"
            } else {
                "smtp-tls"
            }),
            Self::Malformed(_) => MailError::protocol(if channel == "imap" {
                "imap-malformed"
            } else {
                "smtp-malformed"
            }),
            Self::Io(_) => MailError::unreachable(if channel == "imap" {
                "imap-transport"
            } else {
                "smtp-transport"
            }),
        }
    }
}

impl fmt::Display for TransportError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotConnected => f.write_str("not-connected"),
            Self::Closed => f.write_str("closed"),
            Self::TimedOut => f.write_str("timed-out"),
            Self::Malformed(code) => write!(f, "malformed ({code})"),
            Self::Io(kind) => write!(f, "io ({kind:?})"),
            Self::Tls(code) => write!(f, "tls ({code})"),
        }
    }
}

impl std::error::Error for TransportError {}

impl From<std::io::Error> for TransportError {
    fn from(error: std::io::Error) -> Self {
        match error.kind() {
            std::io::ErrorKind::UnexpectedEof => Self::Closed,
            // A socket read timeout is `WouldBlock` on Unix (SO_RCVTIMEO sets
            // EAGAIN) and `TimedOut` on Windows. Both mean the wait expired;
            // keeping them as opaque IO errors hid the one signal IDLE uses to
            // end its wait normally.
            std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut => Self::TimedOut,
            other => Self::Io(other),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A socket read timeout is not one error kind on every platform: Unix
    /// `SO_RCVTIMEO` reports `WouldBlock` (EAGAIN), Windows reports
    /// `TimedOut`. IDLE ends its wait by recognizing the timeout, so a
    /// `WouldBlock` classified as a generic IO failure makes every IDLE round
    /// die at the budget's end — observed on the real mailbox as
    /// `sync.failed label=unreachable` after exactly 290s, with no mail ever
    /// applied.
    #[test]
    fn a_unix_socket_read_timeout_is_a_timeout() {
        let error = TransportError::from(std::io::Error::from(std::io::ErrorKind::WouldBlock));
        assert!(error.is_timed_out());
        assert_eq!(error.to_mail("imap").code(), "imap-timeout");
    }

    #[test]
    fn a_windows_socket_read_timeout_is_also_a_timeout() {
        let error = TransportError::from(std::io::Error::from(std::io::ErrorKind::TimedOut));
        assert!(error.is_timed_out());
        assert_eq!(error.to_mail("imap").code(), "imap-timeout");
    }

    /// The conversion must not swallow real failures: a reset socket is still
    /// unreachable, not a timeout.
    #[test]
    fn a_reset_socket_is_not_a_timeout() {
        let error = TransportError::from(std::io::Error::from(std::io::ErrorKind::ConnectionReset));
        assert!(!error.is_timed_out());
        assert_eq!(error.to_mail("imap").code(), "imap-transport");
    }
}
