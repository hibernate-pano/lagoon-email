import XCTest
import LagoonKit
@testable import LagoonServer

/// Covers `HeuristicBriefingClassifier` (Sources/LagoonServer/AI/Heuristics.swift).
///
/// Pins the spec §7.1 precedence chain, first match wins:
///   pinned > subscriptionNoise(List-Unsubscribe) >
///   subscriptionNoise(no-reply sender regex) > awaitingReply(sender == account) >
///   safeToArchive(isRead && > 7 days) > needsReply.
final class HeuristicBriefingClassifierTests: XCTestCase {

    private let accountEmail = "me@example.com"
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Helpers

    private func header(
        _ gmailId: String,
        from: String,
        isRead: Bool = false,
        daysAgo: Double = 0
    ) -> MessageHeader {
        MessageHeader(
            id: UUID(),
            accountId: UUID(),
            gmailId: gmailId,
            threadId: "t-\(gmailId)",
            fromAddress: from,
            fromName: nil,
            subject: "subject \(gmailId)",
            snippet: nil,
            receivedAt: now.addingTimeInterval(-daysAgo * 24 * 60 * 60),
            isRead: isRead,
            isArchived: false
        )
    }

    /// Convenience wrapper around the static precedence function with a fixed
    /// `now` so the 7-day rule is deterministic.
    private func group(
        _ message: MessageHeader,
        pinned: Set<String> = [],
        listUnsubscribe: Set<String> = []
    ) -> (group: BriefingGroup, reason: String) {
        HeuristicBriefingClassifier.group(
            for: message,
            accountEmail: accountEmail,
            pinnedGmailIds: pinned,
            listUnsubscribeGmailIds: listUnsubscribe,
            now: now
        )
    }

    // MARK: - Precedence chain

    /// pinned beats every other signal (subscription sender, owner sender,
    /// read-and-old).
    func test_pinned_winsOverEverything() {
        let message = header("m1", from: "no-reply@news.example.com", isRead: true, daysAgo: 30)
        let result = group(message, pinned: ["m1"], listUnsubscribe: ["m1"])
        XCTAssertEqual(result.group, .pinned)
        XCTAssertFalse(result.reason.isEmpty)
    }

    /// List-Unsubscribe beats the no-reply sender regex, and both beat
    /// awaitingReply.
    func test_listUnsubscribe_beatsSenderAndAwaitingReply() {
        let message = header("m2", from: "no-reply@example.com")
        let result = group(message, listUnsubscribe: ["m2"])
        XCTAssertEqual(result.group, .subscriptionNoise)
        XCTAssertTrue(result.reason.contains("List-Unsubscribe"))
    }

    /// The no-reply/newsletter sender regex is case-insensitive and matches
    /// without a List-Unsubscribe signal.
    func test_noReplySenderRegex_isCaseInsensitive() {
        let message = header("m3", from: "No-Reply@Example.COM")
        let result = group(message)
        XCTAssertEqual(result.group, .subscriptionNoise)
        XCTAssertFalse(result.reason.isEmpty)
    }

    func test_subscriptionSenderRegex_matchesKnownPatterns() {
        let senders = [
            "noreply@shop.com",
            "no-reply@shop.com",
            "newsletter@site.io",
            "notification@site.io",
            "notifications@site.io",
            "marketing@brand.com",
            "mailer-daemon@brand.com",
            "bounce@list.com",
        ]
        for (index, sender) in senders.enumerated() {
            let message = header("regex-\(index)", from: sender)
            XCTAssertEqual(
                group(message).group, .subscriptionNoise,
                "expected subscriptionNoise for \(sender)"
            )
            XCTAssertTrue(
                HeuristicBriefingClassifier.matchesSubscriptionSender(sender),
                "regex should match \(sender)"
            )
        }
    }

    func test_subscriptionSenderRegex_doesNotMatchNormalSender() {
        XCTAssertFalse(HeuristicBriefingClassifier.matchesSubscriptionSender("alice@example.com"))
        XCTAssertEqual(group(header("m4", from: "alice@example.com")).group, .needsReply)
    }

    /// sender == account email → awaitingReply, even if read and old.
    func test_awaitingReply_whenSenderIsAccount() {
        let message = header("m5", from: accountEmail, isRead: true, daysAgo: 30)
        let result = group(message)
        XCTAssertEqual(result.group, .awaitingReply)
        XCTAssertFalse(result.reason.isEmpty)
    }

    /// Address comparison is case-insensitive.
    func test_awaitingReply_isCaseInsensitive() {
        let message = header("m6", from: "ME@Example.com")
        XCTAssertEqual(group(message).group, .awaitingReply)
    }

    /// read AND strictly older than 7 days → safeToArchive.
    func test_safeToArchive_whenReadAndOlderThanSevenDays() {
        let message = header("m7", from: "alice@example.com", isRead: true, daysAgo: 8)
        let result = group(message)
        XCTAssertEqual(result.group, .safeToArchive)
        XCTAssertFalse(result.reason.isEmpty)
    }

    /// Exactly 7 days is NOT older than 7 days (strict `>`), and unread old
    /// mail also stays in needsReply.
    func test_safeToArchive_requiresStrictlyOlderAndRead() {
        XCTAssertEqual(
            group(header("m8", from: "a@b.com", isRead: true, daysAgo: 7)).group,
            .needsReply
        )
        XCTAssertEqual(
            group(header("m9", from: "a@b.com", isRead: false, daysAgo: 30)).group,
            .needsReply
        )
        XCTAssertEqual(
            group(header("m10", from: "a@b.com", isRead: true, daysAgo: 1)).group,
            .needsReply
        )
    }

    /// Fallthrough: unread, recent, ordinary sender → needsReply.
    func test_needsReply_isDefault() {
        let result = group(header("m11", from: "alice@example.com"))
        XCTAssertEqual(result.group, .needsReply)
        XCTAssertFalse(result.reason.isEmpty)
    }

    /// Full table: each row exercises the highest-precedence signal present.
    func test_precedenceChain_table() {
        let cases: [(MessageHeader, Set<String>, Set<String>, BriefingGroup)] = [
            (header("p", from: "no-reply@x.com", isRead: true, daysAgo: 30), ["p"], ["p"], .pinned),
            (header("l", from: "no-reply@x.com", isRead: true, daysAgo: 30), [], ["l"], .subscriptionNoise),
            (header("s", from: "no-reply@x.com", isRead: true, daysAgo: 30), [], [], .subscriptionNoise),
            (header("a", from: accountEmail, isRead: true, daysAgo: 30), [], [], .awaitingReply),
            (header("r", from: "alice@x.com", isRead: true, daysAgo: 30), [], [], .safeToArchive),
            (header("n", from: "alice@x.com", isRead: false, daysAgo: 0), [], [], .needsReply),
        ]
        for (message, pinned, listUnsub, expected) in cases {
            let result = group(message, pinned: pinned, listUnsubscribe: listUnsub)
            XCTAssertEqual(
                result.group, expected,
                "gmailId \(message.gmailId) expected \(expected.rawValue)"
            )
            XCTAssertFalse(result.reason.isEmpty, "reason must be non-empty for \(message.gmailId)")
        }
    }

    // MARK: - Bulk API

    func test_emptyInput_returnsEmpty() async throws {
        let classifier = HeuristicBriefingClassifier()
        let groups = try await classifier.classify([], accountEmail: accountEmail)
        XCTAssertTrue(groups.isEmpty)
        XCTAssertTrue(classifier.classifyWithReasons([], accountEmail: accountEmail).isEmpty)
    }

    /// Every classified item carries a non-empty reason, and `classify` agrees
    /// with `classifyWithReasons`.
    func test_everyItemHasNonEmptyReason() async throws {
        let messages = [
            header("m1", from: "no-reply@news.com"),
            header("m2", from: accountEmail),
            header("m3", from: "alice@example.com", isRead: true, daysAgo: 30),
            header("m4", from: "bob@example.com"),
        ]
        let classifier = HeuristicBriefingClassifier(
            signals: .init(pinnedGmailIds: ["m1"], listUnsubscribeGmailIds: ["m4"])
        )
        let withReasons = classifier.classifyWithReasons(messages, accountEmail: accountEmail)
        XCTAssertEqual(withReasons.count, messages.count)
        for message in messages {
            let entry = try XCTUnwrap(withReasons[message.gmailId])
            XCTAssertFalse(
                entry.reason.isEmpty,
                "empty reason for \(message.gmailId) in \(entry.group.rawValue)"
            )
        }
        let groups = try await classifier.classify(messages, accountEmail: accountEmail)
        XCTAssertEqual(groups, withReasons.mapValues(\.group))
    }

    /// Pins the Signals-based instance path end-to-end (pinned via Signals).
    func test_instanceSignals_drivePinnedGroup() {
        let classifier = HeuristicBriefingClassifier(
            signals: .init(pinnedGmailIds: ["m1"], listUnsubscribeGmailIds: [])
        )
        let result = classifier.group(for: header("m1", from: "alice@example.com"), accountEmail: accountEmail)
        XCTAssertEqual(result.group, .pinned)
        XCTAssertFalse(result.reason.isEmpty)
    }
}
