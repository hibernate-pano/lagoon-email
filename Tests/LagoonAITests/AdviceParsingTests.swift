import XCTest
import Foundation
import LagoonKit
@testable import LagoonAI

/// Pins how the gateway turns one model answer into advice. Every case here is
/// a way a real model behaves badly: prose, a missing field, an invented id, an
/// over-long sentence. None of them may cost the user their grouping.
final class AdviceParsingTests: XCTestCase {

    // MARK: - Outcome shapes

    /// The full object shape the prompt asks for.
    func test_parsesFullOutcomeWithEveryField() throws {
        let raw: [String: Any] = [
            "group": "needsReply",
            "action": "reply",
            "category": "work",
            "confidence": "high",
            "rationale": "同事在等你对方案的确认。",
            "due": "本周五前",
        ]
        let outcome = try XCTUnwrap(AIGateway.parseOutcome(raw))
        XCTAssertEqual(outcome.group, .needsReply)
        let advice = try XCTUnwrap(outcome.advice)
        XCTAssertEqual(advice.action, .reply)
        XCTAssertEqual(advice.category, .work)
        XCTAssertEqual(advice.confidence, .high)
        XCTAssertEqual(advice.rationale, "同事在等你对方案的确认。")
        XCTAssertEqual(advice.dueText, "本周五前")
    }

    /// The pre-advice shape. A model answering a grouped batch with bare
    /// strings still gave usable groups; dropping them would silently degrade
    /// the whole feed for a cosmetic gain.
    func test_parsesBareGroupString_asGroupOnlyOutcome() throws {
        let outcome = try XCTUnwrap(AIGateway.parseOutcome("safeToArchive" as Any))
        XCTAssertEqual(outcome.group, .safeToArchive)
        XCTAssertNil(outcome.advice, "a bare string carries no advice")
    }

    /// A usable group with an unusable action loses the advice, not the group.
    func test_unknownAction_keepsTheGroupAndDropsTheAdvice() throws {
        let outcome = try XCTUnwrap(AIGateway.parseOutcome([
            "group": "subscriptionNoise",
            "action": "summon-demons",
            "confidence": "high",
        ] as [String: Any]))
        XCTAssertEqual(outcome.group, .subscriptionNoise)
        XCTAssertNil(outcome.advice)
    }

    /// A missing group is unusable — the route would have nothing to file the
    /// row under — so the whole entry is rejected.
    func test_missingGroup_isRejected() {
        XCTAssertNil(AIGateway.parseOutcome(["action": "archive"] as [String: Any]))
        XCTAssertNil(AIGateway.parseOutcome(["group": "nonsense"] as [String: Any]))
        XCTAssertNil(AIGateway.parseOutcome(nil))
        XCTAssertNil(AIGateway.parseOutcome(42 as Any))
    }

    // MARK: - Defensive field handling

    /// A model that omits confidence has not told us how sure it is. Defaulting
    /// to `.medium` would let an unhedged guess speak with a confident voice, so
    /// the floor is `.low`.
    func test_missingConfidence_defaultsToLow() throws {
        let outcome = try XCTUnwrap(AIGateway.parseOutcome([
            "group": "safeToArchive",
            "action": "archive",
        ] as [String: Any]))
        XCTAssertEqual(try XCTUnwrap(outcome.advice).confidence, .low)
    }

    /// An unrecognised category is dropped rather than stored raw: the UI
    /// switches over it, and a novel value would render as a blank label.
    func test_unknownCategory_isDroppedNotStored() throws {
        let outcome = try XCTUnwrap(AIGateway.parseOutcome([
            "group": "safeToArchive",
            "action": "archive",
            "category": "astrology",
        ] as [String: Any]))
        XCTAssertNil(try XCTUnwrap(outcome.advice).category)
    }

    /// The rationale is display text in a feed row. An unbounded sentence is a
    /// layout bug and a way to blow the completion budget, so it is trimmed.
    func test_overlongRationale_isTrimmed() throws {
        let long = String(repeating: "很长的理由。", count: 200)
        let outcome = try XCTUnwrap(AIGateway.parseOutcome([
            "group": "needsReply",
            "action": "reply",
            "rationale": long,
        ] as [String: Any]))
        let advice = try XCTUnwrap(outcome.advice)
        XCTAssertLessThanOrEqual(advice.rationale?.count ?? 0, 240)
        XCTAssertTrue(long.hasPrefix(advice.rationale ?? ""), "trimming must keep the head")
    }

    /// Whitespace-only prose is not a rationale.
    func test_blankRationale_isTreatedAsAbsent() throws {
        let outcome = try XCTUnwrap(AIGateway.parseOutcome([
            "group": "needsReply",
            "action": "reply",
            "rationale": "   \n  ",
            "due": "  ",
        ] as [String: Any]))
        let advice = try XCTUnwrap(outcome.advice)
        XCTAssertNil(advice.rationale)
        XCTAssertNil(advice.dueText)
    }

    /// `due` is the email's own date phrase, quoted. Trimming is still applied
    /// because a model that pastes a whole paragraph into the field would
    /// otherwise reach the UI unbounded.
    func test_dueText_isTrimmedAndBlankDropped() throws {
        let long = String(repeating: "x", count: 500)
        let outcome = try XCTUnwrap(AIGateway.parseOutcome([
            "group": "needsReply",
            "action": "remind",
            "due": long,
        ] as [String: Any]))
        let advice = try XCTUnwrap(outcome.advice)
        XCTAssertEqual(advice.dueText?.count, 120)
        XCTAssertEqual(advice.action, .remind)
    }

    // MARK: - The decision vocabulary the UI depends on

    /// Every action and category the prompt names must survive a round trip.
    /// A typo in either list would make the model suggest something the UI
    /// cannot render, and it would fail silently at display time.
    func test_everyPromptIdentifier_parses() throws {
        for action in AdvisedAction.allCases {
            let outcome = try XCTUnwrap(AIGateway.parseOutcome([
                "group": "needsReply",
                "action": action.rawValue,
            ] as [String: Any]), "\(action.rawValue) must parse")
            XCTAssertEqual(try XCTUnwrap(outcome.advice).action, action)
        }
        for category in ContentCategory.allCases {
            let outcome = try XCTUnwrap(AIGateway.parseOutcome([
                "group": "needsReply",
                "action": "reply",
                "category": category.rawValue,
            ] as [String: Any]), "\(category.rawValue) must parse")
            XCTAssertEqual(try XCTUnwrap(outcome.advice).category, category)
        }
        for confidence in AdviceConfidence.allCases {
            let outcome = try XCTUnwrap(AIGateway.parseOutcome([
                "group": "needsReply",
                "action": "reply",
                "confidence": confidence.rawValue,
            ] as [String: Any]), "\(confidence.rawValue) must parse")
            XCTAssertEqual(try XCTUnwrap(outcome.advice).confidence, confidence)
        }
    }

    // MARK: - The properties the UI relies on

    /// `delete` is the one suggestion that costs something permanent, so it must
    /// be flagged as mutating. `reply` also changes the mailbox (by sending)
    /// but is not flagged as mutating here — it is flagged on the route that
    /// performs it, and the UI treats a reply suggestion as "open the composer".
    func test_mutatingAndIrreversibleFlags_matchTheUserRisk() {
        XCTAssertTrue(AdvisedAction.delete.isMutating)
        XCTAssertTrue(AdvisedAction.unsubscribe.isMutating)
        XCTAssertTrue(AdvisedAction.archive.isMutating)
        XCTAssertFalse(AdvisedAction.remind.isMutating)
        XCTAssertFalse(AdvisedAction.wait.isMutating)
        XCTAssertFalse(AdvisedAction.nothing.isMutating)

        // An unsubscribe cannot be undone through the 30-day window: the
        // publisher has already been told.
        XCTAssertTrue(AdvisedAction.unsubscribe.isIrreversible)
        XCTAssertFalse(AdvisedAction.delete.isIrreversible, "delete goes to Trash and is restorable")
    }
}
