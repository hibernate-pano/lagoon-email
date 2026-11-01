//! One-session folder membership (R3.4b-2a).
//!
//! The sync engine needs to know what each folder contains so it can tell a
//! message that was *filed* (archive/trash) from one that is actually gone.
//! Asking per folder used to cost one fresh IMAP session per folder; QQ caps
//! concurrent sessions per account, and a membership read must never be able to
//! exhaust that budget. [`crate::imap::provider::ImapProvider::remote_membership`]
//! therefore does INBOX, archive and trash on **one already logged-in
//! session**.
//!
//! ## None is "unknown", never "empty"
//!
//! A folder that is missing, forbidden, too large to walk within the budget, or
//! whose UID set cannot be mapped completely yields `None`. The caller must
//! treat that as unknown and must **not delete local rows** from it — the same
//! v3 rule as `MailChangeSet.archived_remote_ids` / `trashed_remote_ids`.
//! `Some(empty)` means "the server says this folder exists and is empty"; those
//! are very different permissions.

use std::collections::BTreeSet;

use crate::error::MailError;
use crate::imap::client::{ImapClient, ImapSelected};

/// Default walk budget, matching lagoon-api's adapter threshold.
pub const DEFAULT_MEMBERSHIP_BUDGET: usize = 5000;

/// One folder's complete membership within the budget.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct FolderMembership {
    /// The UIDs `UID SEARCH ALL` returned (protocol-native identity).
    pub uids: BTreeSet<i64>,
    /// The store-facing identities: the RFC 5322 `Message-ID` when present,
    /// else `uid:<n>` — exactly the rule used for `RemoteHeader.remote_id`.
    pub remote_ids: BTreeSet<String>,
}

impl FolderMembership {
    pub fn remote_ids_vec(&self) -> Vec<String> {
        self.remote_ids.iter().cloned().collect()
    }
}

/// The three folder memberships from one session. Each field is independently
/// tri-state: `None` = unknown, `Some` = complete set (possibly empty).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct RemoteMembership {
    pub inbox: Option<FolderMembership>,
    pub archive: Option<FolderMembership>,
    pub trash: Option<FolderMembership>,
}

impl RemoteMembership {
    /// Whether all three sets are known. This is the precondition for deriving
    /// a deletion: if any is unknown, nothing may be deleted.
    pub fn is_complete(&self) -> bool {
        self.inbox.is_some() && self.archive.is_some() && self.trash.is_some()
    }

    /// Store-facing inbox ids, or `None` when this folder is unknown.
    pub fn inbox_remote_ids(&self) -> Option<Vec<String>> {
        self.inbox.as_ref().map(FolderMembership::remote_ids_vec)
    }

    pub fn archived_remote_ids(&self) -> Option<Vec<String>> {
        self.archive.as_ref().map(FolderMembership::remote_ids_vec)
    }

    pub fn trashed_remote_ids(&self) -> Option<Vec<String>> {
        self.trash.as_ref().map(FolderMembership::remote_ids_vec)
    }
}

/// Walk one folder on an already-open session.
///
/// * `Ok(Some(set))` — complete membership within `budget`;
/// * `Ok(None)` — the folder exists but its size exceeds the budget;
/// * `Err(error)` — the SELECT/SEARCH/FETCH failed (missing, forbidden,
///   transport). The caller decides whether the session is still usable.
pub(crate) fn collect_folder(
    client: &mut ImapClient,
    selected: &mut Option<ImapSelected>,
    folder: &str,
    budget: usize,
) -> Result<Option<FolderMembership>, MailError> {
    let state = client.select(folder)?;
    *selected = Some(state.clone());
    if state.exists > budget {
        return Ok(None);
    }

    let uids = client.all_uids()?;
    if uids.len() > budget {
        return Ok(None);
    }
    if uids.is_empty() {
        return Ok(Some(FolderMembership::default()));
    }

    // Map UIDs to the store's identity. The extra header walk happens on the
    // same session; a missing header would leave a UID unaccounted for, which
    // makes the set incomplete — return unknown rather than a short set that
    // could license a wrong delete.
    let uid_list: Vec<i64> = uids.iter().copied().collect();
    let headers = client.fetch_headers_for_uids(&uid_list, &["MESSAGE-ID"])?;
    let mut seen = BTreeSet::new();
    let mut remote_ids = BTreeSet::new();
    for header in &headers {
        if !uids.contains(&header.uid) {
            continue;
        }
        seen.insert(header.uid);
        let remote_id = header
            .raw_headers
            .get("message-id")
            .map(|value| value.trim())
            .filter(|value| !value.is_empty())
            .map(str::to_owned)
            .unwrap_or_else(|| format!("uid:{}", header.uid));
        remote_ids.insert(remote_id);
    }
    if seen != uids {
        return Ok(None);
    }
    Ok(Some(FolderMembership { uids, remote_ids }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_membership_is_known_not_unknown() {
        let empty = RemoteMembership {
            inbox: Some(FolderMembership::default()),
            archive: Some(FolderMembership::default()),
            trash: Some(FolderMembership::default()),
        };
        assert!(empty.is_complete());
        assert_eq!(empty.inbox_remote_ids(), Some(Vec::new()));
    }

    #[test]
    fn any_unknown_folder_makes_the_union_unknown() {
        let partial = RemoteMembership {
            inbox: Some(FolderMembership::default()),
            archive: None,
            trash: Some(FolderMembership::default()),
        };
        assert!(!partial.is_complete());
        assert_eq!(partial.archived_remote_ids(), None);
    }

    #[test]
    fn remote_ids_vec_is_sorted_and_owned() {
        let mut folder = FolderMembership::default();
        folder.remote_ids.insert("uid:2".to_owned());
        folder.remote_ids.insert("<a@example.com>".to_owned());
        assert_eq!(
            folder.remote_ids_vec(),
            ["<a@example.com>".to_owned(), "uid:2".to_owned()]
        );
    }
}
