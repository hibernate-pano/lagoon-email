import XCTest
import Foundation
import LagoonKit
@testable import LagoonServer

/// Pins what the offline, header-only classifier is allowed to advise.
///
/// This classifier never reads a body. Anything requiring content knowledge is
/// therefore out of reach for it, and the interesting cases are the ones where
/// the temptation is strongest — a stale newsletter looks exactly like a
/// receipt you filed away for tax season.
final class HeuristicAdviceTests: XCTestCase {
    private let accountEmail = "me@example.com"

    private func header(
        _ id: String,
        from: String,
        isRead: Bool = false,
        daysAgo: Double = 0
    ) -> MessageHeader {
        MessageHeader(
            id: UUID(),
            accountId: UUID(),
            remoteId: id,
            threadId: "t-\(id)",
            fromAddress: from,
            fromName: nil,
            subject: "Subject",
            snippet: "snippet",
            receivedAt: Date().addingTimeInterval(-daysAgo * 86_400),
            isRead: isRead,
            isArchived: false
        )
    }

    // MARK: - The hard limit

    /// Deciding that mail has no residual value requires reading it. The
    /// heuristic sees headers only, so it cannot tell a marketing blast from an
    /// invoice — and "delete" is the one suggestion that costs the user
    /// something permanent. Every reason code must stay clear of it.
    func test_neverAdvisesDelete_forAnyReason() {
        for reason in BriefingReason.allCases {
            let advice = HeuristicBriefingClassifier.advice(forReason: reason)
            let why = "\(reason.rawValue) must stay clear of the permanent action"
            XCTAssertNotEqual(advice?.action, .delete, why)
        }
    }

    /// Nor may it invent a deadline it cannot see. `remind` without a `due` is
    /// an unfalsifiable nag, and the phrase has to come from the mail.
    func test_neverAdvisesRemind_withoutEvidence() {
        for reason in BriefingReason.allCases {
            let advice = HeuristicBriefingClassifier.advice(forReason: reason)
            if advice?.action == .remind {
                XCTAssertNotNil(
                    advice?.dueText,
                    "\(reason.rawValue) cannot produce a reminder: no body was read"
                )
            }
        }
    }

    /// No prose from a classifier that cannot see the user's language. The UI
    /// localizes each reason code instead.
    func test_neverProducesProseRationale() {
        for reason in BriefingReason.allCases {
            XCTAssertNil(
                HeuristicBriefingClassifier.advice(forReason: reason)?.rationale,
                "\(reason.rawValue) must leave the rationale to the UI's reason text"
            )
        }
    }

    /// A header-only rule is a guess about intent. Only evidence the store
    /// actually holds may clear `.medium`, and nothing reaches `.high`.
    func test_confidenceNeverReachesHigh() {
        for reason in BriefingReason.allCases {
            let advice = HeuristicBriefingClassifier.advice(forReason: reason)
            XCTAssertNotEqual(
                advice?.confidence, .high,
                "\(reason.rawValue): an offline rule cannot be high confidence"
            )
        }
    }

    // MARK: - Per-reason behaviour

    func test_fromSelf_advisesWait() {
        XCTAssertEqual(
            HeuristicBriefingClassifier.advice(forReason: .fromSelf)?.action, .wait
        )
    }

    func test_replied_advisesArchive() {
        XCTAssertEqual(
            HeuristicBriefingClassifier.advice(forReason: .replied)?.action, .archive
        )
    }

    func test_listUnsubscribeHeader_advisesUnsubscribe() {
        let advice = HeuristicBriefingClassifier.advice(forReason: .listUnsubscribe)
        XCTAssertEqual(advice?.action, .unsubscribe)
        XCTAssertEqual(
            advice?.confidence, .medium,
            "an actual List-Unsubscribe header is hard evidence, unlike a sender pattern"
        )
    }

    /// A sender that merely looks like a robot is weaker: `notifications@` also
    /// sends receipts and security alerts the user wants to keep.
    func test_subscriptionSenderPattern_advisesUnsubscribeAtLowConfidence() {
        let advice = HeuristicBriefingClassifier.advice(forReason: .subscriptionSender)
        XCTAssertEqual(advice?.action, .unsubscribe)
        XCTAssertEqual(advice?.confidence, .low)
    }

    /// Read-and-stale says nothing about value: a receipt filed away for tax
    /// season and a forgotten newsletter look identical in a header.
    func test_readAndOld_advisesArchiveAtLowConfidence() {
        let advice = HeuristicBriefingClassifier.advice(forReason: .readAndOld)
        XCTAssertEqual(advice?.action, .archive)
        XCTAssertEqual(advice?.confidence, .low)
    }

    /// A pin is an explicit user decision. Second-guessing it would be the app
    /// arguing with the person using it.
    func test_pinned_getsNoAdvice() {
        XCTAssertNil(HeuristicBriefingClassifier.advice(forReason: .pinned))
    }

    /// "needs reply" is the fallback bucket, not a finding: the default branch
    /// lands there when no rule matched. Advising a reply on that basis would
    /// put a suggestion on mail that needs none.
    func test_fallbackReason_getsNoAdvice() {
        for reason in [BriefingReason.needsReply, .unclassified] {
            XCTAssertNil(
                HeuristicBriefingClassifier.advice(forReason: reason),
                "\(reason.rawValue) is a fallback, not evidence"
            )
        }
    }

    /// An AI or user-override reason carries no heuristic advice — those rows
    /// came from elsewhere and the offline rules must not second-guess them.
    func test_aiAndUserOverrideReasons_getNoHeuristicAdvice() {
        XCTAssertNil(HeuristicBriefingClassifier.advice(forReason: .ai))
        XCTAssertNil(HeuristicBriefingClassifier.advice(forReason: .userOverride))
    }

    // MARK: - End to end through the classifier

    /// The advice that actually reaches the store is derived from the reason the
    /// classifier produced, so the mapping must hold through `classify` too.
    func test_classify_carriesAdviceDerivedFromItsOwnReason() async throws {
        let messages = [
            header("mine", from: accountEmail),
            header("noise", from: "no-reply@news.example.com"),
            header("old", from: "alice@example.com", isRead: true, daysAgo: 30),
        ]
        let outcomes = try await HeuristicBriefingClassifier().classify(
            messages, accountEmail: accountEmail, language: nil
        )

        XCTAssertEqual(outcomes["mine"]?.advice?.action, .wait)
        XCTAssertEqual(outcomes["noise"]?.advice?.action, .unsubscribe)
        XCTAssertEqual(outcomes["noise"]?.advice?.confidence, .low)
        XCTAssertEqual(outcomes["old"]?.advice?.action, .archive)
        XCTAssertEqual(outcomes["old"]?.advice?.confidence, .low)

        // The heuristic names no model: provenance must say so.
        for outcome in outcomes.values {
            XCTAssertNil(outcome.model)
        }
    }

    /// A pinned message is grouped but carries no advice, and the row id the
    /// advice is keyed by is the message's own remoteId.
    func test_pinnedMessage_isGroupedWithoutAdvice() async throws {
        let classifier = HeuristicBriefingClassifier(
            signals: .init(pinnedRemoteIds: ["p1"])
        )
        let outcomes = try await classifier.classify(
            [header("p1", from: "alice@example.com")],
            accountEmail: accountEmail,
            language: nil
        )
        XCTAssertEqual(outcomes["p1"]?.group, .pinned)
        XCTAssertNil(outcomes["p1"]?.advice)
    }
}
