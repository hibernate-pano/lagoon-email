import Foundation
import LagoonKit

/// Deterministic, offline classifier used when no LLM provider is configured
/// (and as the fallback when the AI classifier errors).
///
/// Reply detection sees replies sent through Lagoon (audited as send actions)
/// and replies sent from other clients (Sent-folder threading references
/// harvested by the providers, V2 A2 — matched on row remoteId or stored
/// Message-ID header).
public struct HeuristicBriefingClassifier: BriefingClassifying {
    /// Extra context the protocol method cannot carry on `MessageHeader`:
    /// local pins, (when a data source exists) which messages carry a
    /// `List-Unsubscribe` header, and which messages Lagoon has already
    /// sent a reply for.
    public struct Signals: Sendable {
        public let pinnedRemoteIds: Set<String>
        public let listUnsubscribeRemoteIds: Set<String>
        public let repliedRemoteIds: Set<String>

        public init(
            pinnedRemoteIds: Set<String> = [],
            listUnsubscribeRemoteIds: Set<String> = [],
            repliedRemoteIds: Set<String> = []
        ) {
            self.pinnedRemoteIds = pinnedRemoteIds
            self.listUnsubscribeRemoteIds = listUnsubscribeRemoteIds
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
    ) async throws -> [String: ClassificationOutcome] {
        var result: [String: ClassificationOutcome] = [:]
        for message in messages {
            let verdict = group(for: message, accountEmail: accountEmail)
            result[message.remoteId] = ClassificationOutcome(
                group: verdict.group,
                advice: Self.advice(forReason: verdict.reason)
            )
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
            pinnedRemoteIds: signals.pinnedRemoteIds,
            listUnsubscribeRemoteIds: signals.listUnsubscribeRemoteIds,
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
        pinnedRemoteIds: Set<String>,
        listUnsubscribeRemoteIds: Set<String>,
        repliedRemoteIds: Set<String> = [],
        now: Date = Date()
    ) -> (group: BriefingGroup, reason: BriefingReason) {
        if pinnedRemoteIds.contains(message.remoteId) {
            return (.pinned, .pinned)
        }
        if listUnsubscribeRemoteIds.contains(message.remoteId) {
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
        // audit is the stronger signal either way). Rows are keyed by IMAP
        // UID while Sent harvesting yields Message-IDs, so both the row id and
        // the stored Message-ID header are matched.
        if repliedRemoteIds.contains(message.remoteId)
            || message.messageIdHeader.map({ repliedRemoteIds.contains($0) }) == true {
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

    // MARK: - Heuristic advice

    /// The advice that follows from a reason code. A pure function of the
    /// reason: the deterministic classifier sees headers only, so it has no
    /// basis for a content judgment and must not pretend to one.
    ///
    /// Two deliberate limits (advisory-only constitution §2 rule 1):
    ///
    /// * **Never `.delete`.** Deciding that mail has no residual value requires
    ///   reading it. This classifier cannot tell a marketing blast from an
    ///   invoice, and "delete" is the one suggestion that costs the user
    ///   something permanent. Only the model, which sees the content, may
    ///   suggest it.
    /// * **No prose `rationale`.** The UI already localizes each reason code
    ///   (`L10n.reasonText`). Writing a sentence here would mean inventing copy
    ///   in a language this code cannot see, so it returns nil and the UI shows
    ///   the localized reason instead.
    ///
    /// Confidence never reaches `.high`: a header-only rule is a guess about
    /// intent. Only the two cases backed by hard evidence — "you sent the last
    /// message" and "Lagoon recorded your reply" — earn `.medium`.
    static func advice(forReason reason: BriefingReason) -> Advice? {
        switch reason {
        case .pinned:
            // The user pinned this deliberately. Suggesting an action on it
            // would be second-guessing an explicit decision.
            return nil
        case .fromSelf:
            return Advice(action: .wait, confidence: .medium)
        case .replied:
            return Advice(action: .archive, confidence: .medium)
        case .listUnsubscribe:
            return Advice(action: .unsubscribe, confidence: .medium)
        case .subscriptionSender:
            // A sender address matching a noise pattern is weaker evidence than
            // an actual List-Unsubscribe header: `notifications@` also sends
            // things the user may want to keep.
            return Advice(action: .unsubscribe, confidence: .low)
        case .readAndOld:
            // Read and stale says nothing about value. A receipt the user filed
            // away for tax season looks identical to a stale newsletter here.
            return Advice(action: .archive, confidence: .low)
        case .needsReply, .ai, .userOverride, .unclassified:
            // "needs reply" is the fallback bucket, not a finding: the default
            // branch lands here when no rule matched, so there is no evidence a
            // human is waiting. Advising a reply on that basis would put a
            // suggestion on mail that needs none.
            return nil
        }
    }
}
