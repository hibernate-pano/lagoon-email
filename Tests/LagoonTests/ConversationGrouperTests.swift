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

    // MARK: - 亲和合并 (same sender + same normalized subject)

    private func header(
        remoteId: String, threadId: String, subject: String?,
        from: String = "news@example.com", minutesAgo: Int = 0
    ) -> MessageHeader {
        MessageHeader(
            id: UUID(), accountId: UUID(), remoteId: remoteId, threadId: threadId,
            fromAddress: from, fromName: nil, subject: subject, snippet: nil,
            receivedAt: Date().addingTimeInterval(TimeInterval(-minutesAgo * 60)),
            isRead: true, isArchived: false
        )
    }

    func test_affinityMergesBrokenChainAcrossThreadIds() {
        // Same sender, same subject, but the mail system dropped References:
        // two protocol threads must still land in one conversation.
        let messages = [
            header(remoteId: "a", threadId: "t1", subject: "【云】每日精选", minutesAgo: 60),
            header(remoteId: "b", threadId: "t2", subject: "Re: 【云】每日精选", minutesAgo: 30),
        ]
        let conversations = ConversationGrouper.group(messages)
        XCTAssertEqual(conversations.count, 1)
        XCTAssertEqual(conversations[0].messages.map(\.remoteId), ["b", "a"])
    }

    func test_affinityNeverMergesDifferentSenders() {
        let messages = [
            header(remoteId: "a", threadId: "t1", subject: "report", from: "alice@x.com"),
            header(remoteId: "b", threadId: "t2", subject: "report", from: "bob@y.com"),
        ]
        XCTAssertEqual(ConversationGrouper.group(messages).count, 2)
    }

    func test_protocolThreadBeatsSubjectMismatch() {
        // One References chain, wildly different subjects: stays together.
        let messages = [
            header(remoteId: "a", threadId: "t1", subject: "kickoff"),
            header(remoteId: "b", threadId: "t1", subject: "RE: pricing update"),
        ]
        XCTAssertEqual(ConversationGrouper.group(messages).count, 1)
    }

    func test_nilSubjectSingletonsStayAlone() {
        let messages = [
            header(remoteId: "a", threadId: "t1", subject: nil, from: "x@y.com"),
            header(remoteId: "b", threadId: "t2", subject: nil, from: "x@y.com"),
        ]
        XCTAssertEqual(ConversationGrouper.group(messages).count, 2)
    }

    func test_senderModeGroupsByAddress() {
        let messages = [
            header(remoteId: "a", threadId: "t1", subject: "one", from: "a@x.com", minutesAgo: 50),
            header(remoteId: "b", threadId: "t2", subject: "two", from: "a@x.com", minutesAgo: 10),
            header(remoteId: "c", threadId: "t3", subject: "three", from: "b@y.com"),
        ]
        let conversations = ConversationGrouper.group(messages, mode: .sender)
        XCTAssertEqual(conversations.count, 2)
        let fromA = conversations.first { $0.threadId == "sender:a@x.com" }
        XCTAssertEqual(fromA?.messages.map(\.remoteId), ["b", "a"])
    }

    // MARK: - SubjectNormalizer

    func test_normalizerStripsStackedLocalizedPrefixes() {
        XCTAssertEqual(SubjectNormalizer.normalize("回复：Re: Fwd: 会议纪要"), "会议纪要")
        XCTAssertEqual(SubjectNormalizer.normalize("轉發：週報"), "週報")
        XCTAssertEqual(SubjectNormalizer.normalize("Re: Re: Report"), "report")
        XCTAssertEqual(SubjectNormalizer.normalize("自动回复: 已收到"), "已收到")
    }

    func test_normalizerFoldsCaseAndWhitespace() {
        XCTAssertEqual(SubjectNormalizer.normalize("  Quarterly   REPORT "), "quarterly report")
        XCTAssertEqual(SubjectNormalizer.normalize("Report"), "report")
    }

    func test_normalizerKeepsBrandedTagPrefixes() {
        // 【】campaign tags differ per blast and must survive: stripping them
        // would over-merge distinct campaigns from one sender.
        XCTAssertEqual(SubjectNormalizer.normalize("【腾讯云】账单已出"), "【腾讯云】账单已出")
    }

    func test_normalizerRejectsEmptyAndPrefixOnly() {
        XCTAssertNil(SubjectNormalizer.normalize(nil))
        XCTAssertNil(SubjectNormalizer.normalize("   "))
        XCTAssertNil(SubjectNormalizer.normalize("Re:"))
        XCTAssertNil(SubjectNormalizer.normalize("回复： "))
    }
}
