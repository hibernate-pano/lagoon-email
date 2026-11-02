//! The read-only seam the sync engine is allowed to hold.
//!
//! v3's `MailSyncReading` protocol is the whole point: the sync loop holds
//! `any MailSyncReading`, never `any MailProvider`, so "sync never writes to
//! the mailbox" is a compile-time guarantee rather than a convention
//! (advisory-only constitution §2 rule 2).
//!
//! This trait is the Rust equivalent and is deliberately smaller than
//! [`crate::imap::provider::ImapProvider`]: capabilities, one pull, shutdown.
//! No archive, no set-read, no trash, no send, no permanent delete. R3.4's
//! engine takes `&mut dyn MailSyncReading` and cannot name the write verbs.
//!
//! `ChangeSet` mirrors v3's fields, including the "nil means unknown, and
//! unknown never licenses a delete" contract:
//!
//! * `removed_remote_ids` is the **only** set that licenses deleting a local
//!   row. "Not in the inbox" is not enough — a message can be filed by another
//!   client, and dropping the local row also drops its cached body and its
//!   paid-for AI advice.
//! * `archived_remote_ids` / `trashed_remote_ids` say where the mail went.
//! * `reset_required` means the UID space changed (UIDVALIDITY) and the store
//!   must be wiped before any UID is reused.

use std::collections::BTreeSet;
use std::time::Duration;

use crate::error::MailError;
use crate::imap::capabilities::MailCapabilities;

/// The sync position for one account/mailbox.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct SyncCursor {
    /// The next UID the server expects; 0 means "not synced yet".
    pub uid_next: i64,
    /// The UIDVALIDITY the cursor belongs to; a change forces a reset.
    pub uid_validity: i64,
}

/// Provider-neutral header row as it arrives from the wire, before it becomes a
/// stored row. `remote_id` is provider-native and only unique within one
/// account.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteHeader {
    pub remote_id: String,
    pub thread_id: String,
    pub from_address: String,
    pub from_name: Option<String>,
    pub subject: Option<String>,
    pub snippet: Option<String>,
    /// Epoch seconds (the wire carries `INTERNALDATE`).
    pub received_at: i64,
    pub is_read: bool,
    pub list_unsubscribe: bool,
    pub message_id: Option<String>,
    pub in_reply_to: Option<String>,
    pub references: Option<String>,
}

/// One pull's worth of change.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ChangeSet {
    pub upserts: Vec<RemoteHeader>,
    pub reset_required: bool,
    pub cursor: SyncCursor,
    /// Complete set of provider IDs currently in the source mailbox. `None`
    /// means "not known"; the store then removes nothing on that basis.
    pub inbox_remote_ids: Option<BTreeSet<String>>,
    pub archived_remote_ids: Option<BTreeSet<String>>,
    pub trashed_remote_ids: Option<BTreeSet<String>>,
    /// The only set that licenses a local delete.
    pub removed_remote_ids: Option<BTreeSet<String>>,
    /// Message-IDs seen referenced from sent mail (In-Reply-To/References of
    /// Sent-folder messages).
    pub replied_message_ids: BTreeSet<String>,
    /// The pull actually used IDLE and spent up to the caller's budget waiting.
    /// A loop that would otherwise sleep between rounds must not sleep again:
    /// the wait already happened inside this call.
    pub waited: bool,
}

/// Everything the sync engine may do to a mailbox. Read-only by construction.
pub trait MailSyncReading {
    /// Negotiated once after connect and cached on the account row. `None`
    /// means "could not determine" — a caller must keep whatever it already
    /// knew and try again later; it must not record "none".
    fn capabilities(&mut self) -> Option<MailCapabilities>;

    /// Fetch changes newer than `cursor`, waiting up to `wait_up_to` for
    /// something to happen (IDLE, bounded by the caller's cadence).
    fn pull_changes(
        &mut self,
        cursor: SyncCursor,
        wait_up_to: Duration,
    ) -> Result<ChangeSet, MailError>;

    /// Release what the provider holds between calls — above all an open IMAP
    /// session, which QQ counts against a per-account limit.
    fn shutdown(&mut self);
}

/// Split a threading header into whitespace-separated tokens, verbatim. Tokens
/// keep their `<...>` brackets: the store's Message-ID identity is the exact
/// header string, so stripping brackets would break the match.
pub fn message_id_tokens(value: &str) -> BTreeSet<String> {
    value
        .split_whitespace()
        .filter(|token| !token.is_empty())
        .map(str::to_owned)
        .collect()
}

/// Conversation key: the first References entry (the thread root), else the
/// Message-ID, else `uid:N` for mail that carries neither.
pub fn thread_id(references: Option<&str>, message_id: Option<&str>, uid: i64) -> String {
    if let Some(root) = references
        .and_then(|value| value.split_whitespace().next())
        .filter(|root| !root.is_empty())
    {
        return root.to_owned();
    }
    if let Some(message_id) = message_id.filter(|value| !value.trim().is_empty()) {
        return message_id.to_owned();
    }
    format!("uid:{uid}")
}

/// Whether a FETCH flag list says the message has been read.
pub fn is_read(flags: &[String]) -> bool {
    flags.iter().any(|flag| flag.eq_ignore_ascii_case("\\Seen"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn thread_identity_prefers_the_reference_root() {
        assert_eq!(
            thread_id(Some("<root@x> <parent@x>"), Some("<me@x>"), 7),
            "<root@x>"
        );
        assert_eq!(thread_id(None, Some("<me@x>"), 7), "<me@x>");
        assert_eq!(thread_id(None, None, 7), "uid:7");
    }

    #[test]
    fn message_id_tokens_keep_brackets() {
        let tokens = message_id_tokens("<a@x> b@x");
        assert!(tokens.contains("<a@x>"));
        assert!(tokens.contains("b@x"));
        assert_eq!(tokens.len(), 2);
    }

    #[test]
    fn read_flag_is_case_insensitive() {
        assert!(is_read(&["\\Seen".to_owned()]));
        assert!(is_read(&["\\seen".to_owned()]));
        assert!(!is_read(&["\\Answered".to_owned()]));
    }
}
