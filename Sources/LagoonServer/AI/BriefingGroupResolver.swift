import Foundation
import LagoonKit

/// The one place that answers 「这封邮件现在在哪个分组」.
///
/// ## Why this type exists
///
/// Three pieces of the server used to answer that question *separately*:
/// the briefing route (which groups the feed), the classify route (which
/// decides whether a 「改分组」 request changes anything), and the undo path
/// (which restores what the change replaced). Each had its own copy of the
/// precedence, and copies drift.
///
/// The drift was not academic. The classify route resolved a mail's group
/// from the **sender** map, so a mail that already carried its own narrow
/// rule was compared against the *sender's* group — and the change was
/// then either refused with 「分组没变」 while the mail sat in a different
/// group, or accepted while it moved nothing.
///
/// So the precedence lives here, once:
///
///   1. pinned                    → `.pinned`
///   2. message-scoped override   → the narrow rule
///   3. sender-scoped override    → the broad rule
///   4. otherwise                 → the classifier's answer
///
/// The briefing uses it to group the feed, and the classify route uses it
/// to decide whether a change is a no-op — so the guard and the feed
/// cannot disagree about which group a mail is in.
///
/// ## Why the classifier's answer is a parameter
///
/// The briefing's fallback is the **AI** classification when one is
/// configured, and the heuristic otherwise. The classify route has no
/// classifier and cannot ask for one (a model call per user gesture, and
/// one message classified alone does not answer the same as the same
/// message in a batch).
///
/// So the fallback is passed in, and the two callers supply what they
/// know:
///
/// * the briefing passes the AI's answer (or the heuristic's);
/// * the classify route passes the group the **client is showing** — the
///   feed the user acted on — and falls back to the heuristic when the
///   client did not say.
///
/// A user override — the case the narrow scope exists for — is resolved
/// entirely from the database, with no classifier involved, so it is
/// exact. The fallback only decides a mail nobody has ever overridden.
public struct BriefingGroupResolver: Sendable {
    /// The outcome of resolving one mail: the group, and why.
    public struct Resolution: Sendable {
        public let group: BriefingGroup
        public let reason: BriefingReason

        public init(group: BriefingGroup, reason: BriefingReason) {
            self.group = group
            self.reason = reason
        }
    }

    /// Message-scoped overrides, keyed by remote id.
    public let messageOverrides: [String: BriefingGroup]
    /// Sender-scoped overrides, keyed by the sender's address.
    public let senderOverrides: [String: BriefingGroup]
    /// The mails the user pinned.
    public let pinnedRemoteIds: Set<String>

    public init(
        messageOverrides: [String: BriefingGroup],
        senderOverrides: [String: BriefingGroup],
        pinnedRemoteIds: Set<String>
    ) {
        self.messageOverrides = messageOverrides
        self.senderOverrides = senderOverrides
        self.pinnedRemoteIds = pinnedRemoteIds
    }

    /// Reads the three maps from the store.
    ///
    /// One call so a caller cannot load the sender map and forget the
    /// message map — the omission that made the narrow scope unreachable
    /// for any sender who already had a broad rule.
    public static func load(
        accountId: UUID,
        db: LagoonDB
    ) async throws -> BriefingGroupResolver {
        let messageOverrides = try await AIActionStore.overridesByMessage(
            accountId: accountId, db: db
        )
        let senderOverrides = try await AIActionStore.overridesBySender(
            accountId: accountId, db: db
        )
        let pinned = try await MessageStore.pinnedIds(forAccount: accountId, db: db)
        return BriefingGroupResolver(
            messageOverrides: messageOverrides,
            senderOverrides: senderOverrides,
            pinnedRemoteIds: pinned
        )
    }

    /// The group a mail is in, with the reason the feed shows beside it.
    ///
    /// `fallback` is the classifier's answer for this mail — the AI's when
    /// one is configured, the heuristic otherwise, and on the classify
    /// route the group the client is showing. It is consulted **last**, so
    /// a user override always wins over it.
    public func resolve(
        for message: MessageHeader,
        fallback: (group: BriefingGroup, reason: BriefingReason)
    ) -> Resolution {
        // A pin is an explicit user action, so it outranks everything else
        // — including a 「改分组」 the user made earlier.
        if pinnedRemoteIds.contains(message.remoteId) {
            return Resolution(group: .pinned, reason: .pinned)
        }
        // The narrow rule is the more specific statement, so it wins over
        // the broad one for the mail it names.
        if let override = messageOverrides[message.remoteId] {
            return Resolution(group: override, reason: .userOverride)
        }
        if let override = senderOverrides[message.fromAddress] {
            return Resolution(group: override, reason: .userOverride)
        }
        return Resolution(group: fallback.group, reason: fallback.reason)
    }
}
