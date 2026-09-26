import Foundation
import LagoonKit

/// A thread of related mail (会话归集): every message sharing the server's
/// `thread_id`, newest first. The server derives `thread_id` from the
/// References chain's root Message-ID (IMAP) or Gmail's native thread id,
/// so this is real threading, not a subject-prefix guess.
struct Conversation: Identifiable, Equatable {
    let threadId: String
    /// Sorted newest → oldest; never empty.
    let messages: [MessageHeader]

    var newest: MessageHeader { messages[0] }
    /// Any unread member makes the whole conversation worth a dot.
    var hasUnread: Bool { messages.contains { !$0.isRead } }
    var id: String { threadId }
}

enum ConversationGrouper {
    /// Group loaded headers into conversations. Threads are ordered by
    /// their newest member; singletons stay single rows.
    static func group(_ messages: [MessageHeader]) -> [Conversation] {
        let byThread = Dictionary(grouping: messages, by: \.threadId)
        return byThread
            .map { Conversation(
                threadId: $0.key,
                messages: $0.value.sorted { $0.receivedAt > $1.receivedAt }
            ) }
            .sorted { $0.newest.receivedAt > $1.newest.receivedAt }
    }
}
