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

    // MARK: - Inline strip (direction one)
    //
    // The strip moved advice from behind a sheet onto the row the user is
    // already reading. That raises the stakes on this file's rule: copy the
    // user now sees *while triaging* must not read as a completed action, or
    // the fast path becomes the lying path.

    /// The inline strip reuses `adviceAction`, so the no-completed-action rule
    /// is inherited — this test pins that the strip has no second wording of
    /// its own that could drift from it.
    func test_inlineStrip_hasNoActionWordingOfItsOwn() {
        // The strip renders exactly two action-bearing strings: the action
        // label and the irreversibility badge. Both are checked for the
        // forbidden completion wording here.
        for text in [
            zh.adviceIrreversibleBadge, en.adviceIrreversibleBadge,
            zh.adviceWhyHelp, en.adviceWhyHelp,
        ] {
            for word in ["archived", "deleted", "已归档", "已删除"] {
                XCTAssertFalse(
                    text.lowercased().contains(word.lowercased()),
                    "inline strip copy must not read as a completed action: \"\(text)\""
                )
            }
        }
    }

    /// Only irreversible advice carries the badge. A "suggest archiving" row
    /// wearing an "irreversible" badge trains the user to ignore the badge,
    /// which is the one place it must be believed.
    func test_irreversibleBadge_isOnlyUsedForIrreversibleActions() {
        var irreversible: Set<AdvisedAction> = []
        for action in AdvisedAction.allCases where action.isIrreversible {
            irreversible.insert(action)
        }
        XCTAssertEqual(
            irreversible, [.unsubscribe],
            "if a second action becomes irreversible, the strip must badge it too"
        )
        // And the badge wording itself must not imply the row was acted on.
        for text in [zh.adviceIrreversibleBadge, en.adviceIrreversibleBadge] {
            XCTAssertFalse(text.isEmpty)
            XCTAssertNotEqual(text, zh.adviceIrreversibleBadge == text ? en.adviceIrreversibleBadge : "")
        }
    }

    /// The strip invites the user to ask "why?" — so the affordance copy has to
    /// read as an invitation, and must not promise an action.
    func test_whyHelp_isAnInvitationInBothLanguages() {
        XCTAssertFalse(zh.adviceWhyHelp.isEmpty)
        XCTAssertFalse(en.adviceWhyHelp.isEmpty)
        XCTAssertNotEqual(zh.adviceWhyHelp, en.adviceWhyHelp)
    }

    /// Dismissing from the row is a write the user can trigger by misclick,
    /// since it sits one tap from the message itself. The failure copy must
    /// name the *suggestion*, not advice loading — otherwise a failed dismissal
    /// reads as "the suggestions never loaded", which is a different problem
    /// with a different fix.
    func test_dismissFailureCopy_namesTheDismissalNotTheLoad() {
        XCTAssertFalse(zh.adviceDismissFailedTitle.isEmpty)
        XCTAssertFalse(en.adviceDismissFailedTitle.isEmpty)
        XCTAssertNotEqual(zh.adviceDismissFailedTitle, en.adviceDismissFailedTitle)
        for text in [zh.adviceDismissFailedTitle, en.adviceDismissFailedTitle] {
            XCTAssertFalse(
                text.contains("加载") || text.lowercased().contains("load"),
                "the failure is in saving the dismissal, not in loading: \"\(text)\""
            )
        }
    }
}
