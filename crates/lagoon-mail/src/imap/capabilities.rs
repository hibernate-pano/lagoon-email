//! Capability negotiation and folder-role discovery.
//!
//! Ported from v3 `MailCapabilities.swift` + `IMAPProvider` role resolution.
//!
//! ## The three-state rule
//!
//! The capabilities that **gate a verb** — `archive_folder`, `uidplus`,
//! `sent_folder`, `trash_folder` — are `Option<bool>`:
//!
//! * `None` = not determined (no answer yet);
//! * `Some(false)` = determined: the server does not have it;
//! * `Some(true)` = determined: it does.
//!
//! Collapsing "unknown" into "no" is a data-loss-shaped bug in both directions.
//! v3 records the incident: an account row that had never been negotiated
//! carried the all-false default, so `archive` answered `409
//! archive-unavailable` for a server that had an archive folder all along. The
//! gates therefore read `!= Some(false)` as *allowed*: the server is the
//! authority and answers at request time.
//!
//! `idle`, `supports_move` and `server_snippet` stay plain `bool` because no
//! gate is built on them (they are hints), matching v3.

use crate::error::MailError;
use crate::imap::client::{ImapClient, ImapMailbox};

pub const INBOX: &str = "INBOX";
pub const DEFAULT_ARCHIVE_FOLDER_NAME: &str = "Archive";

/// Negotiated capabilities. See the module docs for the tri-state rule.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct MailCapabilities {
    pub archive_folder: Option<bool>,
    pub idle: bool,
    pub supports_move: bool,
    pub server_snippet: bool,
    pub uidplus: Option<bool>,
    pub sent_folder: Option<bool>,
    pub trash_folder: Option<bool>,
    pub archive_folder_name: Option<String>,
}

impl MailCapabilities {
    /// "Nothing determined": every gated field is `None`.
    pub fn unknown() -> Self {
        Self::default()
    }

    /// Whether the delete verb can be offered at all. "Not determined" reads as
    /// allowed; a settled `false` closes the gate.
    pub fn allows_delete(&self) -> bool {
        self.trash_folder != Some(false)
    }

    /// Whether permanent delete can be offered. A permanent delete is
    /// `UID EXPUNGE` on one message, so it needs UIDPLUS; without it the server
    /// refuses rather than expunging another client's pending deletions.
    pub fn allows_purge(&self) -> bool {
        self.uidplus != Some(false)
    }

    pub fn allows_sent(&self) -> bool {
        self.sent_folder != Some(false)
    }

    pub fn allows_archive(&self) -> bool {
        self.archive_folder != Some(false)
    }
}

/// Folder roles as discovered from one `LIST`.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct FolderRoles {
    pub archive: Option<String>,
    pub trash: Option<String>,
    pub sent: Option<String>,
}

/// The result of one negotiation round: capabilities and the role names they
/// were derived from, so the provider can cache both without a second LIST.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Negotiated {
    pub capabilities: MailCapabilities,
    pub roles: FolderRoles,
}

/// Well-known names for the Sent role (v3 `sentNames`).
const SENT_NAMES: &[&str] = &[
    "sent",
    "sent messages",
    "sent items",
    "sent mail",
    "已发送",
    "已发送邮件",
];

/// Well-known names for the Trash role (v3 `trashNames`).
const TRASH_NAMES: &[&str] = &[
    "trash",
    "deleted",
    "deleted messages",
    "deleted items",
    "deleted mail",
    "废纸篓",
    "已删除",
    "已删除邮件",
];

/// Well-known names for the Archive role (v3 `archiveNames`).
const ARCHIVE_NAMES: &[&str] = &["archive", "archived", "归档"];

/// The leaf segment of a folder path, lowercased — the segment that identifies
/// the role. QQ nests `废纸篓` under the account root in some locales and at
/// the top level in others, so a full-path match would miss half of them.
pub fn role_leaf(name: &str) -> Option<String> {
    let leaf = name.split('/').last()?.trim();
    if leaf.is_empty() {
        None
    } else {
        Some(leaf.to_ascii_lowercase())
    }
}

pub fn has_special_use(mailbox: &ImapMailbox, attribute: &str) -> bool {
    mailbox
        .attributes
        .iter()
        .any(|candidate| candidate.eq_ignore_ascii_case(attribute))
}

pub fn is_sent_mailbox(mailbox: &ImapMailbox) -> bool {
    if has_special_use(mailbox, "\\Sent") {
        return true;
    }
    role_leaf(&mailbox.name)
        .map(|leaf| SENT_NAMES.contains(&leaf.as_str()))
        .unwrap_or(false)
}

pub fn is_trash_mailbox(mailbox: &ImapMailbox) -> bool {
    if has_special_use(mailbox, "\\Trash") {
        return true;
    }
    role_leaf(&mailbox.name)
        .map(|leaf| TRASH_NAMES.contains(&leaf.as_str()))
        .unwrap_or(false)
}

pub fn is_archive_mailbox(mailbox: &ImapMailbox) -> bool {
    if has_special_use(mailbox, "\\Archive") {
        return true;
    }
    role_leaf(&mailbox.name)
        .map(|leaf| ARCHIVE_NAMES.contains(&leaf.as_str()))
        .unwrap_or(false)
}

/// Role discovery over a mailbox list. Pure; no CREATE.
pub fn discover_roles(mailboxes: &[ImapMailbox]) -> FolderRoles {
    FolderRoles {
        archive: mailboxes
            .iter()
            .find(|mailbox| is_archive_mailbox(mailbox))
            .map(|mailbox| mailbox.name.clone()),
        trash: mailboxes
            .iter()
            .find(|mailbox| is_trash_mailbox(mailbox))
            .map(|mailbox| mailbox.name.clone()),
        sent: mailboxes
            .iter()
            .find(|mailbox| is_sent_mailbox(mailbox))
            .map(|mailbox| mailbox.name.clone()),
    }
}

/// The archive role, with the one-time CREATE fallback. A refusal is a verdict
/// about the folder and is remembered as `None`; a transport failure travels
/// out so the caller retries instead of latching "unavailable" from a blip.
pub fn resolve_archive_folder(
    client: &mut ImapClient,
    mailboxes: &[ImapMailbox],
    allow_create: bool,
) -> Result<Option<String>, MailError> {
    if let Some(found) = mailboxes.iter().find(|mailbox| is_archive_mailbox(mailbox)) {
        return Ok(Some(found.name.clone()));
    }
    if !allow_create {
        return Ok(None);
    }
    match client.create_mailbox(DEFAULT_ARCHIVE_FOLDER_NAME) {
        Ok(()) => Ok(Some(DEFAULT_ARCHIVE_FOLDER_NAME.to_owned())),
        Err(error) if error.is_message_verdict() => Ok(None),
        Err(error) => Err(error),
    }
}

/// One capability probe: CAPABILITY + one LIST, three role verdicts, plus the
/// archive CREATE fallback when allowed.
///
/// The probe and the request paths use the *same* mailbox list and the same
/// predicates, so a probe that said "no trash" while the delete path would have
/// found one cannot happen.
pub fn negotiate(
    client: &mut ImapClient,
    allow_create_archive: bool,
) -> Result<Negotiated, MailError> {
    let capabilities = client.capability()?;
    let mailboxes = client.list_mailboxes()?;
    let archive = resolve_archive_folder(client, &mailboxes, allow_create_archive)?;
    let mut roles = discover_roles(&mailboxes);
    if archive.is_some() {
        roles.archive = archive.clone();
    }
    Ok(Negotiated {
        capabilities: MailCapabilities {
            archive_folder: Some(archive.is_some()),
            idle: capabilities.contains("IDLE"),
            supports_move: capabilities.contains("MOVE"),
            // Every IMAP body can be sampled from its message prefix with
            // BODY.PEEK[] and decoded by the MIME parser.
            server_snippet: true,
            uidplus: Some(capabilities.contains("UIDPLUS")),
            sent_folder: Some(roles.sent.is_some()),
            trash_folder: Some(roles.trash.is_some()),
            archive_folder_name: archive,
        },
        roles,
    })
}

/// Folders the app already owns a dedicated verb or surface for (v3
/// `isReservedFolder`). Compared on the leaf, case-insensitively.
pub fn is_reserved_folder(mailbox: &ImapMailbox) -> bool {
    for attribute in ["\\Trash", "\\Sent", "\\Archive", "\\Drafts", "\\Junk"] {
        if has_special_use(mailbox, attribute) {
            return true;
        }
    }
    let Some(leaf) = role_leaf(&mailbox.name) else {
        return true;
    };
    [
        "inbox",
        "sent",
        "sent items",
        "sent mail",
        "已发送",
        "已发送邮件",
        "trash",
        "deleted items",
        "deleted mail",
        "废纸篓",
        "已删除",
        "archive",
        "archived",
        "归档",
        "drafts",
        "草稿",
        "junk",
        "spam",
        "垃圾邮件",
    ]
    .contains(&leaf.as_str())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mailbox(name: &str, attributes: &[&str]) -> ImapMailbox {
        ImapMailbox {
            name: name.to_owned(),
            attributes: attributes.iter().map(|value| (*value).to_owned()).collect(),
        }
    }

    #[test]
    fn special_use_wins_over_names() {
        let boxes = vec![
            mailbox("归档", &["\\Archive"]),
            mailbox("Deleted", &["\\Trash"]),
            mailbox("Sent Items", &["\\Sent"]),
        ];
        let roles = discover_roles(&boxes);
        assert_eq!(roles.archive.as_deref(), Some("归档"));
        assert_eq!(roles.trash.as_deref(), Some("Deleted"));
        assert_eq!(roles.sent.as_deref(), Some("Sent Items"));
    }

    #[test]
    fn chinese_names_are_roles_when_special_use_is_absent() {
        let boxes = vec![
            mailbox("INBOX", &[]),
            mailbox("已删除邮件", &[]),
            mailbox("已发送", &[]),
        ];
        let roles = discover_roles(&boxes);
        assert_eq!(roles.trash.as_deref(), Some("已删除邮件"));
        assert_eq!(roles.sent.as_deref(), Some("已发送"));
        assert_eq!(roles.archive, None);
    }

    #[test]
    fn nested_paths_match_on_the_leaf() {
        let boxes = vec![
            mailbox("QQ/废纸篓", &[]),
            mailbox("QQ/已发送邮件", &[]),
            mailbox("QQ/归档", &[]),
        ];
        let roles = discover_roles(&boxes);
        assert_eq!(roles.trash.as_deref(), Some("QQ/废纸篓"));
        assert_eq!(roles.sent.as_deref(), Some("QQ/已发送邮件"));
        assert_eq!(roles.archive.as_deref(), Some("QQ/归档"));
    }

    #[test]
    fn role_matching_is_case_insensitive_and_ignores_similar_names() {
        assert!(is_sent_mailbox(&mailbox("Sent Messages", &[])));
        assert!(is_trash_mailbox(&mailbox("Deleted Items", &[])));
        assert!(!is_archive_mailbox(&mailbox("My Archive 2020", &[])));
    }

    #[test]
    fn tri_state_gates_read_unknown_as_allowed() {
        let unknown = MailCapabilities::unknown();
        assert!(unknown.allows_archive());
        assert!(unknown.allows_delete());
        assert!(unknown.allows_purge());
        assert!(unknown.allows_sent());

        let settled_no = MailCapabilities {
            archive_folder: Some(false),
            uidplus: Some(false),
            sent_folder: Some(false),
            trash_folder: Some(false),
            ..MailCapabilities::unknown()
        };
        assert!(!settled_no.allows_archive());
        assert!(!settled_no.allows_delete());
        assert!(!settled_no.allows_purge());
        assert!(!settled_no.allows_sent());
    }

    #[test]
    fn reserved_folders_are_hidden_from_the_picker() {
        assert!(is_reserved_folder(&mailbox("INBOX", &[])));
        assert!(is_reserved_folder(&mailbox("Drafts", &[])));
        assert!(is_reserved_folder(&mailbox("QQ/垃圾邮件", &[])));
        assert!(!is_reserved_folder(&mailbox("Projects", &[])));
    }
}
