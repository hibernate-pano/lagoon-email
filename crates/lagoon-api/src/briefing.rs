//! The briefing feed's grouping rules.
//!
//! Ported from v3 AI/Heuristics.swift (the deterministic classifier that runs
//! when no model is configured) and AI/BriefingGroupResolver.swift (the user's
//! overrides). The ordering inside both is the product decision, not an
//! implementation detail: pinned beats list-unsubscribe beats subscription
//! sender beats from-self beats replied beats read-and-old, and everything else
//! needs a reply. A pin outranks a group the user set earlier, while a
//! message-scoped override outranks a sender-scoped one.

use std::collections::{HashMap, HashSet};

use crate::store::messages::StoredMessage;
use crate::timefmt::Timestamp;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Group {
    NeedsReply,
    AwaitingReply,
    SafeToArchive,
    SubscriptionNoise,
    Pinned,
}

impl Group {
    pub fn as_str(self) -> &'static str {
        match self {
            Group::NeedsReply => "needsReply",
            Group::AwaitingReply => "awaitingReply",
            Group::SafeToArchive => "safeToArchive",
            Group::SubscriptionNoise => "subscriptionNoise",
            Group::Pinned => "pinned",
        }
    }

    /// The five group identifiers, in the display order the client relies on.
    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "needsReply" => Some(Group::NeedsReply),
            "awaitingReply" => Some(Group::AwaitingReply),
            "safeToArchive" => Some(Group::SafeToArchive),
            "subscriptionNoise" => Some(Group::SubscriptionNoise),
            "pinned" => Some(Group::Pinned),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reason {
    Pinned,
    ListUnsubscribe,
    SubscriptionSender,
    FromSelf,
    Replied,
    ReadAndOld,
    NeedsReply,
    Ai,
    UserOverride,
    Unclassified,
}

impl Reason {
    pub fn as_str(self) -> &'static str {
        match self {
            Reason::Pinned => "pinned",
            Reason::ListUnsubscribe => "list-unsubscribe",
            Reason::SubscriptionSender => "subscription-sender",
            Reason::FromSelf => "from-self",
            Reason::Replied => "replied",
            Reason::ReadAndOld => "read-and-old",
            Reason::NeedsReply => "needs-reply",
            Reason::Ai => "ai",
            Reason::UserOverride => "user-override",
            Reason::Unclassified => "unclassified",
        }
    }
}

/// The three signals the heuristic classifier looks up per mail.
#[derive(Debug, Clone, Default)]
pub struct Signals {
    pub pinned_remote_ids: HashSet<String>,
    pub list_unsubscribe_remote_ids: HashSet<String>,
    pub replied_remote_ids: HashSet<String>,
}

/// One mail's group and the reason shown beside it (v3 HeuristicBriefingClassifier).
pub fn classify(
    message: &StoredMessage,
    account_email: &str,
    signals: &Signals,
    now: Timestamp,
) -> (Group, Reason) {
    if signals.pinned_remote_ids.contains(&message.remote_id) {
        return (Group::Pinned, Reason::Pinned);
    }
    if signals.list_unsubscribe_remote_ids.contains(&message.remote_id) {
        return (Group::SubscriptionNoise, Reason::ListUnsubscribe);
    }
    if matches_subscription_sender(&message.from_address) {
        return (Group::SubscriptionNoise, Reason::SubscriptionSender);
    }
    if message.from_address.eq_ignore_ascii_case(account_email) {
        return (Group::AwaitingReply, Reason::FromSelf);
    }
    if signals.replied_remote_ids.contains(&message.remote_id)
        || message
            .message_id_header
            .as_deref()
            .is_some_and(|header| signals.replied_remote_ids.contains(header))
    {
        return (Group::SafeToArchive, Reason::Replied);
    }
    let seven_days = 7 * 24 * 60 * 60 * 1000;
    if message.is_read && now.millis() - message.received_at.millis() > seven_days {
        return (Group::SafeToArchive, Reason::ReadAndOld);
    }
    (Group::NeedsReply, Reason::NeedsReply)
}

/// v3's subscription-sender pattern, expanded by hand because the crate has no
/// regex engine: (?i)(no-?reply|newsletter|notifications?@|marketing@|mailer|bounce).
pub fn matches_subscription_sender(from_address: &str) -> bool {
    let address = from_address.to_lowercase();
    address.contains("no-reply")
        || address.contains("noreply")
        || address.contains("newsletter")
        || address.contains("notification@")
        || address.contains("notifications@")
        || address.contains("marketing@")
        || address.contains("mailer")
        || address.contains("bounce")
}

/// The user's overrides, already ranked newest-first by the store
/// (v3 BriefingGroupResolver).
#[derive(Debug, Clone, Default)]
pub struct Resolver {
    message_overrides: HashMap<String, Group>,
    sender_overrides: HashMap<String, Group>,
    pinned_remote_ids: HashSet<String>,
}

impl Resolver {
    /// Build both maps from the store's ranked pairs. A group name this build
    /// does not know is ignored, exactly like v3's BriefingGroup(rawValue:).
    pub fn from_store(
        message_pairs: &[(String, String)],
        sender_pairs: &[(String, String)],
        pinned_remote_ids: HashSet<String>,
    ) -> Self {
        let message_overrides = message_pairs
            .iter()
            .filter_map(|(remote_id, group)| {
                Group::parse(group).map(|group| (remote_id.clone(), group))
            })
            .collect();
        let sender_overrides = sender_pairs
            .iter()
            .filter_map(|(address, group)| Group::parse(group).map(|group| (address.clone(), group)))
            .collect();
        Self {
            message_overrides,
            sender_overrides,
            pinned_remote_ids,
        }
    }

    /// The group a mail is in, with the reason the feed shows beside it.
    ///
    /// The narrow rule wins over the broad one, and a pin wins over both: a pin
    /// is an explicit user action, a message-scoped override is the more
    /// specific statement, and the classifier's answer is consulted last.
    pub fn resolve(&self, message: &StoredMessage, fallback: (Group, Reason)) -> (Group, Reason) {
        if self.pinned_remote_ids.contains(&message.remote_id) {
            return (Group::Pinned, Reason::Pinned);
        }
        if let Some(group) = self.message_overrides.get(&message.remote_id) {
            return (*group, Reason::UserOverride);
        }
        if let Some(group) = self.sender_overrides.get(&message.from_address) {
            return (*group, Reason::UserOverride);
        }
        fallback
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn message(from: &str, read: bool, received_at: Timestamp) -> StoredMessage {
        StoredMessage {
            id: crate::uuid::Uuid::parse_strict("22222222-2222-4222-8222-222222222223").unwrap(),
            account_id: crate::uuid::Uuid::parse_strict("11111111-1111-4111-8111-111111111111")
                .unwrap(),
            remote_id: "fixture-msg-3".to_owned(),
            thread_id: "thread".to_owned(),
            from_address: from.to_owned(),
            from_name: None,
            subject: None,
            snippet_cipher: None,
            received_at,
            is_read: read,
            is_archived: false,
            is_deleted: false,
            is_sent: false,
            is_pinned: false,
            message_id_header: None,
            in_reply_to: None,
            references: None,
        }
    }

    #[test]
    fn unread_recent_mail_needs_a_reply() {
        let now = Timestamp::from_millis(1_700_000_000_000);
        let verdict = classify(
            &message("alice@example.invalid", false, now),
            "me@example.invalid",
            &Signals::default(),
            now,
        );
        assert_eq!(verdict, (Group::NeedsReply, Reason::NeedsReply));
    }

    #[test]
    fn read_and_old_mail_is_safe_to_archive() {
        let now = Timestamp::from_millis(1_700_000_000_000);
        let old = Timestamp::from_millis(now.millis() - 8 * 24 * 60 * 60 * 1000);
        let verdict = classify(
            &message("alice@example.invalid", true, old),
            "me@example.invalid",
            &Signals::default(),
            now,
        );
        assert_eq!(verdict, (Group::SafeToArchive, Reason::ReadAndOld));
    }

    #[test]
    fn subscription_senders_and_self_are_recognised() {
        assert!(matches_subscription_sender("no-reply@shop.example"));
        assert!(matches_subscription_sender("Newsletter <news@example.invalid>"));
        assert!(matches_subscription_sender("notifications@github.example"));
        assert!(!matches_subscription_sender("alice.fixture@example.invalid"));

        let now = Timestamp::from_millis(1_700_000_000_000);
        let verdict = classify(
            &message("me@example.invalid", false, now),
            "me@example.invalid",
            &Signals::default(),
            now,
        );
        assert_eq!(verdict, (Group::AwaitingReply, Reason::FromSelf));
    }

    #[test]
    fn a_pin_outranks_every_override() {
        let now = Timestamp::from_millis(1_700_000_000_000);
        let mail = message("alice@example.invalid", false, now);
        let resolver = Resolver::from_store(
            &[("fixture-msg-3".to_owned(), "safeToArchive".to_owned())],
            &[("alice@example.invalid".to_owned(), "subscriptionNoise".to_owned())],
            HashSet::from(["fixture-msg-3".to_owned()]),
        );
        assert_eq!(
            resolver.resolve(&mail, (Group::NeedsReply, Reason::NeedsReply)),
            (Group::Pinned, Reason::Pinned)
        );
    }

    #[test]
    fn message_override_outranks_sender_override() {
        let now = Timestamp::from_millis(1_700_000_000_000);
        let mail = message("alice@example.invalid", false, now);
        let resolver = Resolver::from_store(
            &[("fixture-msg-3".to_owned(), "safeToArchive".to_owned())],
            &[("alice@example.invalid".to_owned(), "subscriptionNoise".to_owned())],
            HashSet::new(),
        );
        assert_eq!(
            resolver.resolve(&mail, (Group::NeedsReply, Reason::NeedsReply)),
            (Group::SafeToArchive, Reason::UserOverride)
        );
    }
}
