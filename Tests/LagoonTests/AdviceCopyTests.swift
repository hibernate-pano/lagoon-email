import XCTest
import Foundation
@testable import Lagoon
@testable import LagoonKit

/// The advice surface is the first place the user reads the product's core
/// promise, so its copy is load-bearing rather than cosmetic.
///
/// The rule these enforce: nothing on screen may read as though Lagoon already
/// did something. A user who glances at this panel must come away believing
/// their mailbox is untouched — because it is.
@MainActor
final class AdviceCopyTests: XCTestCase {
    private let zh = L10n(language: .zhHans)
    private let en = L10n(language: .english)

    /// Every action label exists in both languages and differs.
    func test_everyActionLabel_isTranslated() {
        for action in AdvisedAction.allCases {
            let chinese = zh.adviceAction(action)
            let english = en.adviceAction(action)
            XCTAssertFalse(chinese.isEmpty, "missing zh for \(action.rawValue)")
            XCTAssertFalse(english.isEmpty, "missing en for \(action.rawValue)")
            XCTAssertNotEqual(chinese, english, "untranslated \(action.rawValue)")
        }
    }

    func test_everyCategoryLabel_isTranslated() {
        for category in ContentCategory.allCases {
            let chinese = zh.adviceCategory(category)
            let english = en.adviceCategory(category)
            XCTAssertFalse(chinese.isEmpty, "missing zh for \(category.rawValue)")
            XCTAssertFalse(english.isEmpty, "missing en for \(category.rawValue)")
            XCTAssertNotEqual(chinese, english, "untranslated \(category.rawValue)")
        }
    }

    func test_everyConfidenceLabel_isTranslated() {
        for confidence in AdviceConfidence.allCases {
            XCTAssertNotEqual(
                zh.adviceConfidence(confidence), en.adviceConfidence(confidence),
                "untranslated \(confidence.rawValue)"
            )
        }
    }

    /// The single most important assertion in this file. Every action label
    /// describes what the AI *proposes*, in a form that cannot be read as a
    /// completed action. "Archived" or "Deleted" here would tell the user
    /// their mail was already touched — the exact lie the constitution forbids.
    func test_noActionLabel_readsAsACompletedAction() {
        // Words that would mean the action already happened.
        let completions = [
            "已归档", "已删除", "已退订", "已发送", "已处理",
            "archived", "deleted", "unsubscribed", "sent", "handled",
        ]
        for action in AdvisedAction.allCases {
            for label in [zh.adviceAction(action), en.adviceAction(action)] {
                let lowered = label.lowercased()
                for word in completions {
                    XCTAssertFalse(
                        lowered.contains(word.lowercased()),
                        "\(action.rawValue) reads as completed: \"\(label)\" contains \"\(word)\""
                    )
                }
            }
        }
    }

    /// A mutating suggestion must be phrased as a proposal. `.reply` and
    /// `.remind` change nothing by themselves and read as advice already; the
    /// three that touch the mailbox when accepted must carry the "建议" framing.
    func test_mutatingActions_arePhrasedAsSuggestions() {
        for action in [AdvisedAction.archive, .delete, .unsubscribe] {
            XCTAssertTrue(
                zh.adviceAction(action).hasPrefix("建议"),
                "\(action.rawValue) must be phrased as a suggestion in Chinese"
            )
            XCTAssertTrue(
                en.adviceAction(action).lowercased().contains("suggest"),
                "\(action.rawValue) must be phrased as a suggestion in English"
            )
        }
    }

    /// The panel's standing notice states the whole promise. It must name the
    /// operations that are off-limits, or it is reassurance without content.
    func test_advisoryNotice_namesWhatLagoonWillNotDo() {
        // Each language names the operations in its own words. Asserting one
        // language's vocabulary against the other text is how a copy assertion
        // rots: it fails for the wrong reason and teaches the next reader that
        // the notice should be in English.
        let required: [(text: String, verbs: [String])] = [
            (zh.adviceAdvisoryOnlyNotice, ["归档", "删除", "退订", "发送"]),
            (en.adviceAdvisoryOnlyNotice, ["archive", "delete", "unsubscribe", "send"]),
        ]
        for entry in required {
            for verb in entry.verbs {
                XCTAssertTrue(
                    entry.text.lowercased().contains(verb.lowercased()),
                    "the notice must name '\(verb)' so the promise is concrete: \"\(entry.text)\""
                )
            }
        }
    }

    /// Provenance is not decoration: a free offline rule and a paid model
    /// judgment do not deserve the same trust, so the labels must differ.
    func test_provenance_distinguishesTheModelFromTheOfflineRule() {
        XCTAssertNotEqual(
            zh.adviceSource(.heuristic, model: nil),
            zh.adviceSource(.ai, model: "MiniMax-M3")
        )
        XCTAssertTrue(
            zh.adviceSource(.ai, model: "MiniMax-M3").contains("MiniMax-M3"),
            "the model's name must reach the user"
        )
        XCTAssertFalse(
            zh.adviceSource(.ai, model: nil).isEmpty,
            "an AI row with no model name still needs a label"
        )
    }

    /// "Dismissed" must not read as a mailbox operation — the user dismissed a
    /// suggestion, which is not the same as having archived or deleted anything.
    func test_dismissCopy_doesNotImplyAMailboxChange() {
        for text in [zh.adviceDismiss, zh.adviceDismissed, en.adviceDismiss, en.adviceDismissed] {
            let lowered = text.lowercased()
            for word in ["archived", "deleted", "unsubscribed", "已归档", "已删除", "已退订"] {
                XCTAssertFalse(
                    lowered.contains(word.lowercased()),
                    "dismissing a suggestion is not a mailbox action: \"\(text)\""
                )
            }
        }
    }

    /// The "message is gone" banner must not suggest Lagoon removed it. It may
    /// have been archived or unsubscribed by the user, or by another client.
    func test_goneMessageCopy_doesNotBlameLagoon() {
        for text in [zh.adviceMessageGoneTitle, zh.adviceMessageGoneDetail] {
            XCTAssertFalse(
                text.contains("Lagoon 已") || text.contains("Lagoon 自动"),
                "Lagoon did not remove the message, and the copy must not say it did: \"\(text)\""
            )
        }
    }
}
