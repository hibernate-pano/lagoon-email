import XCTest
import LagoonKit
@testable import Lagoon

/// 会话归集: threading correctness lives in the server's `thread_id`
/// derivation; these tests pin the pure grouping the list view renders.
final class ConversationGrouperTests: XCTestCase {
    private func header(
        remoteId: String,
        threadId: String,
        from: String = "alice@example.com",
        minutesAgo: Int = 0,
        isRead: Bool = true
    ) -> MessageHeader {
        MessageHeader(
            id: UUID(),
            accountId: UUID(),
            remoteId: remoteId,
            threadId: threadId,
            fromAddress: from,
            fromName: nil,
            subject: "subject \(remoteId)",
            snippet: nil,
            receivedAt: Date().addingTimeInterval(TimeInterval(-minutesAgo * 60)),
            isRead: isRead,
            isArchived: false
        )
    }

    func test_singletonsStaySingleRows() {
        let messages = [
            header(remoteId: "a", threadId: "t1", minutesAgo: 5),
            header(remoteId: "b", threadId: "t2", minutesAgo: 1),
        ]
        let conversations = ConversationGrouper.group(messages)
        XCTAssertEqual(conversations.count, 2)
        XCTAssertEqual(conversations.map(\.newest.remoteId), ["b", "a"], "threads sort by newest member")
    }

    func test_threadMembersGroupNewestFirst() {
        let messages = [
            header(remoteId: "root", threadId: "t1", minutesAgo: 90),
            header(remoteId: "reply", threadId: "t1", minutesAgo: 10, isRead: false),
            header(remoteId: "reply2", threadId: "t1", minutesAgo: 30),
            header(remoteId: "other", threadId: "t2", minutesAgo: 60),
        ]
        let conversations = ConversationGrouper.group(messages)
        XCTAssertEqual(conversations.count, 2)

        let thread = conversations.first { $0.threadId == "t1" }
        XCTAssertNotNil(thread)
        XCTAssertEqual(thread?.messages.map(\.remoteId), ["reply", "reply2", "root"])
        XCTAssertTrue(thread?.hasUnread ?? false)

        // The thread's slot in the list is the newest member's slot.
        XCTAssertEqual(conversations.first?.threadId, "t1")
    }

    func test_allReadThreadHasNoUnreadDot() {
        let messages = [
            header(remoteId: "a", threadId: "t1", minutesAgo: 20),
            header(remoteId: "b", threadId: "t1", minutesAgo: 10),
        ]
        XCTAssertEqual(ConversationGrouper.group(messages).first?.hasUnread, false)
    }

    func test_emptyInputYieldsEmptyOutput() {
        XCTAssertTrue(ConversationGrouper.group([]).isEmpty)
    }
}
