import Foundation
import LagoonKit

/// A thread of related mail (会话归集): every message sharing one merge key,
/// newest first. The primary key is the server's `thread_id` (References
/// chain root for IMAP, Gmail's native thread id); the affinity rule
/// additionally merges same-sender + same-normalized-subject threads, which
/// QQ/marketing mail routinely splits by omitting References headers.
struct Conversation: Identifiable, Equatable {
    let threadId: String
    /// Sorted newest → oldest; never empty.
    let messages: [MessageHeader]

    var newest: MessageHeader { messages[0] }
    /// Any unread member makes the whole conversation worth a dot.
    var hasUnread: Bool { messages.contains { !$0.isRead } }
    var id: String { threadId }
}

/// Deterministic subject normalization for merge affinity: strips repeated
/// localized reply/forward prefixes ("Re:", "回复：", "轉發：" …), folds case
/// and collapses whitespace, so "Re: 会议纪要" and "会议纪要" from the same
/// sender merge while two different senders' identical subjects do not.
/// Branded 【tag】 prefixes are deliberately KEPT — they differ per campaign
/// and stripping them would over-merge.
enum SubjectNormalizer {
    /// Longest first so "fwd:" wins over bare "fw" overlaps; covers zh-Hans,
    /// zh-Hant and English forms seen in the wild.
    static let prefixes = [
        "自動回覆：", "自动回复：", "自動回復：", "自动答复：",
        "回复：", "回覆：", "答复：", "回覆:", "转发：", "轉發：", "轉寄：",
        "re:", "fw:", "fwd:", "aw:", "自动回复:", "回复:", "答复:", "转发:", "轉發:",
    ]

    static func normalize(_ subject: String?) -> String? {
        guard var out = subject?.trimmingCharacters(in: .whitespacesAndNewlines),
              !out.isEmpty
        else { return nil }
        // Repeat: "Re: Fw: 回复: x" must peel to "x".
        var changed = true
        while changed {
            changed = false
            let lowered = out.lowercased()
            for prefix in prefixes {
                if lowered.hasPrefix(prefix) {
                    out = out.dropFirst(prefix.count)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    changed = true
                    break
                }
            }
        }
        guard !out.isEmpty else { return nil }
        // Case-fold + collapse internal runs of whitespace.
        out = out.lowercased()
        out = out.replacingOccurrences(
            of: #"\s+"#, with: " ", options: .regularExpression
        )
        return out
    }
}

enum ConversationGrouper {
    /// How messages are bucketed into conversations. `.thread` = protocol
    /// thread plus same-sender/same-subject affinity; `.sender` = every
    /// message from one address (Outlook's group-by-sender).
    enum Mode {
        case thread
        case sender
    }

    /// Group loaded headers into conversations. Threads are ordered by
    /// their newest member; singletons stay single rows.
    static func group(_ messages: [MessageHeader], mode: Mode = .thread) -> [Conversation] {
        switch mode {
        case .sender: return groupBySender(messages)
        case .thread: return groupByThread(messages)
        }
    }

    private static func groupBySender(_ messages: [MessageHeader]) -> [Conversation] {
        let bySender = Dictionary(grouping: messages, by: \.fromAddress)
        return bySender
            .map { Conversation(
                threadId: "sender:\($0.key)",
                messages: $0.value.sorted { $0.receivedAt > $1.receivedAt }
            ) }
            .sorted { $0.newest.receivedAt > $1.newest.receivedAt }
    }

    private static func groupByThread(_ messages: [MessageHeader]) -> [Conversation] {
        // Pass 1: protocol threads (References-derived). These are truth.
        let byThread = Dictionary(grouping: messages, by: \.threadId)

        // Pass 2: affinity bridges — same sender + same normalized subject
        // links their thread_ids into one conversation even when the mail
        // system broke the References chain. Different senders never link.
        var affinity: [String: Set<String>] = [:]
        for message in messages {
            guard let norm = SubjectNormalizer.normalize(message.subject) else { continue }
            let key = "\(norm)\u{1}\(message.fromAddress)"
            affinity[key, default: []].insert(message.threadId)
        }
        // Union-find over thread ids; every message's thread gets a
        // canonical root, then regroup by root.
        var parent: [String: String] = [:]
        func find(_ id: String) -> String {
            var root = id
            while let next = parent[root], next != root { root = next }
            return root
        }
        func union(_ a: String, _ b: String) {
            let (ra, rb) = (find(a), find(b))
            if ra != rb { parent[rb] = ra }
        }
        for id in byThread.keys { parent[id] = id }
        for bridge in affinity.values where bridge.count > 1 {
            let ids = Array(bridge)
            for id in ids.dropFirst() {
                union(ids[0], id)
            }
        }

        var byRoot: [String: [MessageHeader]] = [:]
        for (threadId, members) in byThread {
            byRoot[find(threadId), default: []].append(contentsOf: members)
        }
        return byRoot
            .map { Conversation(
                threadId: $0.key,
                messages: $0.value.sorted { $0.receivedAt > $1.receivedAt }
            ) }
            .sorted { $0.newest.receivedAt > $1.newest.receivedAt }
    }
}
