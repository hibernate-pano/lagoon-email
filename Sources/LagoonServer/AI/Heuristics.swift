import Foundation
import LagoonKit

/// Deterministic, offline classifier used when no LLM provider is configured
/// (and as the fallback when the AI classifier errors).
///
/// ponytail: ceiling — this is header/address heuristics only. There is no
/// thread analysis and no reply detection, so a read message you already
/// replied to can still land in `needsReply`.
public struct HeuristicBriefingClassifier: BriefingClassifying {
    /// Extra context the protocol method cannot carry on `MessageHeader`:
    /// local pins and (when a data source exists) which messages carry a
    /// `List-Unsubscribe` header.
    public struct Signals: Sendable {
        public let pinnedGmailIds: Set<String>
        public let listUnsubscribeGmailIds: Set<String>

        public init(
            pinnedGmailIds: Set<String> = [],
            listUnsubscribeGmailIds: Set<String> = []
        ) {
            self.pinnedGmailIds = pinnedGmailIds
            self.listUnsubscribeGmailIds = listUnsubscribeGmailIds
        }
    }

    public let signals: Signals

    public init(signals: Signals = .init()) {
        self.signals = signals
    }

    // MARK: - BriefingClassifying

    public func classify(
        _ messages: [MessageHeader],
        accountEmail: String
    ) async throws -> [String: BriefingGroup] {
        var result: [String: BriefingGroup] = [:]
        for message in messages {
            result[message.gmailId] = group(for: message, accountEmail: accountEmail).group
        }
        return result
    }

    /// Same precedence as `classify`, but keeps the per-item reason string the
    /// Briefing Feed renders under "Why?" (spec §3 step 3).
    public func classifyWithReasons(
        _ messages: [MessageHeader],
        accountEmail: String
    ) -> [String: (group: BriefingGroup, reason: String)] {
        var result: [String: (group: BriefingGroup, reason: String)] = [:]
        for message in messages {
            result[message.gmailId] = group(for: message, accountEmail: accountEmail)
        }
        return result
    }

    public func group(
        for message: MessageHeader,
        accountEmail: String
    ) -> (group: BriefingGroup, reason: String) {
        Self.group(
            for: message,
            accountEmail: accountEmail,
            pinnedGmailIds: signals.pinnedGmailIds,
            listUnsubscribeGmailIds: signals.listUnsubscribeGmailIds
        )
    }

    // MARK: - Precedence (spec §7.1)

    /// Precedence, first match wins:
    ///   1. pinned                       → .pinned
    ///   2. List-Unsubscribe or no-reply → .subscriptionNoise
    ///   3. sender is the account owner  → .awaitingReply
    ///   4. read and older than 7 days   → .safeToArchive
    ///   5. otherwise                    → .needsReply
    public static func group(
        for message: MessageHeader,
        accountEmail: String,
        pinnedGmailIds: Set<String>,
        listUnsubscribeGmailIds: Set<String>,
        now: Date = Date()
    ) -> (group: BriefingGroup, reason: String) {
        if pinnedGmailIds.contains(message.gmailId) {
            return (.pinned, "你置顶了这封")
        }
        if listUnsubscribeGmailIds.contains(message.gmailId) {
            return (.subscriptionNoise, "带有退订链接")
        }
        if matchesSubscriptionSender(message.fromAddress) {
            return (.subscriptionNoise, "Newsletter or no-reply sender")
        }
        if message.fromAddress.caseInsensitiveCompare(accountEmail) == .orderedSame {
            return (.awaitingReply, "你发出的 —— 等待对方回复")
        }
        let sevenDays: TimeInterval = 7 * 24 * 60 * 60
        if message.isRead, now.timeIntervalSince(message.receivedAt) > sevenDays {
            return (.safeToArchive, "已读且超过 7 天")
        }
        return (.needsReply, "需要你回复")
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
