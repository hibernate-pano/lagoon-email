import Foundation
import LagoonKit

/// Deterministic, offline classifier used when no LLM provider is configured
/// (and as the fallback when the AI classifier errors).
///
/// Reply detection is wired but partial (spec 2026-09-19 §2): it sees replies
/// sent through Lagoon (audited as send actions). Mail replied to from other
/// clients is invisible — the Sent folder is not synced — so those messages
/// can still land in `needsReply`.
public struct HeuristicBriefingClassifier: BriefingClassifying {
    /// Extra context the protocol method cannot carry on `MessageHeader`:
    /// local pins, (when a data source exists) which messages carry a
    /// `List-Unsubscribe` header, and which messages Lagoon has already
    /// sent a reply for.
    public struct Signals: Sendable {
        public let pinnedGmailIds: Set<String>
        public let listUnsubscribeGmailIds: Set<String>
        public let repliedRemoteIds: Set<String>

        public init(
            pinnedGmailIds: Set<String> = [],
            listUnsubscribeGmailIds: Set<String> = [],
            repliedRemoteIds: Set<String> = []
        ) {
            self.pinnedGmailIds = pinnedGmailIds
            self.listUnsubscribeGmailIds = listUnsubscribeGmailIds
            self.repliedRemoteIds = repliedRemoteIds
        }
    }

    public let signals: Signals

    public init(signals: Signals = .init()) {
        self.signals = signals
    }

    // MARK: - BriefingClassifying

    public func classify(
        _ messages: [MessageHeader],
        accountEmail: String,
        language: String?
    ) async throws -> [String: BriefingGroup] {
        var result: [String: BriefingGroup] = [:]
        for message in messages {
            result[message.remoteId] = group(for: message, accountEmail: accountEmail).group
        }
        return result
    }

    /// Same precedence as `classify`, but keeps the per-item reason code the
    /// Briefing Feed renders under "Why?" (spec §3 step 3).
    public func classifyWithReasons(
        _ messages: [MessageHeader],
        accountEmail: String
    ) -> [String: (group: BriefingGroup, reason: BriefingReason)] {
        var result: [String: (group: BriefingGroup, reason: BriefingReason)] = [:]
        for message in messages {
            result[message.remoteId] = group(for: message, accountEmail: accountEmail)
        }
        return result
    }

    public func group(
        for message: MessageHeader,
        accountEmail: String
    ) -> (group: BriefingGroup, reason: BriefingReason) {
        Self.group(
            for: message,
            accountEmail: accountEmail,
            pinnedGmailIds: signals.pinnedGmailIds,
            listUnsubscribeGmailIds: signals.listUnsubscribeGmailIds,
            repliedRemoteIds: signals.repliedRemoteIds
        )
    }

    // MARK: - Precedence (spec §7.1)

    /// Precedence, first match wins:
    ///   1. pinned                       → .pinned
    ///   2. List-Unsubscribe or no-reply → .subscriptionNoise
    ///   3. sender is the account owner  → .awaitingReply
    ///   4. Lagoon recorded a reply      → .safeToArchive (reason .replied)
    ///   5. read and older than 7 days   → .safeToArchive
    ///   6. otherwise                    → .needsReply
    public static func group(
        for message: MessageHeader,
        accountEmail: String,
        pinnedGmailIds: Set<String>,
        listUnsubscribeGmailIds: Set<String>,
        repliedRemoteIds: Set<String> = [],
        now: Date = Date()
    ) -> (group: BriefingGroup, reason: BriefingReason) {
        if pinnedGmailIds.contains(message.remoteId) {
            return (.pinned, .pinned)
        }
        if listUnsubscribeGmailIds.contains(message.remoteId) {
            return (.subscriptionNoise, .listUnsubscribe)
        }
        if matchesSubscriptionSender(message.fromAddress) {
            return (.subscriptionNoise, .subscriptionSender)
        }
        if message.fromAddress.caseInsensitiveCompare(accountEmail) == .orderedSame {
            return (.awaitingReply, .fromSelf)
        }
        // Already replied = already handled: leave "needs reply" even when the
        // message is unread (replies usually follow a read, but the send
        // audit is the stronger signal either way).
        if repliedRemoteIds.contains(message.remoteId) {
            return (.safeToArchive, .replied)
        }
        let sevenDays: TimeInterval = 7 * 24 * 60 * 60
        if message.isRead, now.timeIntervalSince(message.receivedAt) > sevenDays {
            return (.safeToArchive, .readAndOld)
        }
        return (.needsReply, .needsReply)
    }

    /// `(?i)(no-?reply|newsletter|notifications?@|marketing@|mailer|bounce)`
    /// compiled once. Failure to compile degrades to "no match" rather than
    /// failing the whole briefing.
    private static let subscriptionSenderRegex = try? NSRegularExpression(
        pattern: #"(?i)(no-?reply|newsletter|notifications?@|marketing@|mailer|bounce)"#
    )

    static func matchesSubscriptionSender(_ fromAddress: String) -> Bool {
        guard let regex = subscriptionSenderRegex else { return false }
        let range = NSRange(fromAddress.startIndex..., in: fromAddress)
        return regex.firstMatch(in: fromAddress, range: range) != nil
    }
}
