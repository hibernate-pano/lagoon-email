import Foundation
import LagoonKit

/// Per-message cache of AI briefing classifications.
///
/// Without it every `/api/briefing` request re-sends the whole feed to the LLM:
/// the macOS client refreshes every 30 s, and one 50-message classification
/// measured ~8.3k prompt tokens / ~22 s. The cache reduces steady state to
/// only messages never asked about (typically zero).
///
/// Keys include the read flag, so marking a message read re-classifies it (the
/// group legitimately changes: read + old -> safeToArchive). Entries expire
/// after `ttl` so long-lived mail is eventually re-evaluated.
///
/// Entries carry the whole `ClassificationOutcome`, not just the group: advice
/// arrives on the same call, and caching only the group would throw away the
/// half that cost the most tokens to produce.
public actor BriefingClassificationCache {
    private struct Entry {
        let outcome: ClassificationOutcome?
        let storedAt: Date
    }

    private var entries: [String: Entry] = [:]
    private var inFlight: Set<String> = []
    private let ttl: TimeInterval
    private let limit: Int

    public init(ttl: TimeInterval = 6 * 3600, limit: Int = 4_000) {
        self.ttl = ttl
        self.limit = limit
    }

    /// Splits the feed into groups we already know and messages we still have
    /// to ask the classifier about. A message the classifier had no opinion on
    /// is remembered as `nil` so it is not asked about again.
    public func cached(
        for messages: [MessageHeader],
        now: Date = Date()
    ) -> (known: [String: ClassificationOutcome], pending: [MessageHeader]) {
        var known: [String: ClassificationOutcome] = [:]
        var pending: [MessageHeader] = []
        for message in messages {
            guard let entry = entries[key(message)], now.timeIntervalSince(entry.storedAt) < ttl
            else {
                if !inFlight.contains(key(message)) {
                    pending.append(message)
                }
                continue
            }
            if let outcome = entry.outcome { known[message.remoteId] = outcome }
        }
        return (known, pending)
    }

    /// Records the classifier's answer for `messages`. Ids the classifier
    /// omitted are stored as "asked, no opinion".
    public func store(
        _ outcomes: [String: ClassificationOutcome],
        for messages: [MessageHeader],
        now: Date = Date()
    ) {
        for message in messages {
            let cacheKey = key(message)
            entries[cacheKey] = Entry(outcome: outcomes[message.remoteId], storedAt: now)
            inFlight.remove(cacheKey)
        }
        if entries.count > limit {
            // Drop the oldest half rather than growing without bound.
            let sorted = entries.sorted { $0.value.storedAt < $1.value.storedAt }
            for (key, _) in sorted.prefix(entries.count - limit / 2) {
                entries[key] = nil
            }
        }
    }

    public func count() -> Int { entries.count }

    public func markInFlight(_ messages: [MessageHeader]) {
        inFlight.formUnion(messages.map(key))
    }

    public func clearInFlight(_ messages: [MessageHeader]) {
        inFlight.subtract(messages.map(key))
    }

    /// The cache key of one message.
    ///
    /// **The account id is part of the key**, and it has to be.
    ///
    /// The key used to be `remoteId|isRead` — and `remoteId` is not unique
    /// across mailboxes. When a message carries no `Message-ID` header the
    /// provider falls back to `uid:<n>`, and each account's IMAP UIDs
    /// count up independently, so account A's `uid:42` and account B's
    /// `uid:42` are the same string.
    ///
    /// The cache is one instance for the whole process, so the two accounts
    /// shared it: B's message was served A's classification. The user sees
    /// a mail filed under the wrong category, with a rationale that talks
    /// about a different message, and nothing in the UI says so.
    ///
    /// `MessageHeader` already carries `accountId`, so this is a one-line
    /// fix — but it is the kind of one-liner that has to be *written down*,
    /// because the key looks complete without it.
    private func key(_ message: MessageHeader) -> String {
        "\(message.accountId.uuidString)|\(message.remoteId)|\(message.isRead ? 1 : 0)"
    }
}
