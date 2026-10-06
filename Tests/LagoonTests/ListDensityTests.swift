import XCTest
import Foundation
@testable import Lagoon
@testable import LagoonKit

/// The density preference and the hover card.
///
/// Both are small, and both are places where a plausible-looking default ships
/// a wrong behaviour: a density that only applies to one surface (so the two
/// views of one mailbox disagree), or a hover card that carries an action (so
/// moving the mouse can change the mailbox).
@MainActor
final class ListDensityTests: XCTestCase {
    private let zh = L10n(language: .zhHans)
    private let en = L10n(language: .english)

    override func tearDown() {
        // The preference is process-wide; a test that set it must not leak the
        // choice into the next test or into the next run of the suite.
        UserDefaults.standard.removeObject(forKey: ListDensityPreference.key)
        super.tearDown()
    }

    /// `compact` is the default, deliberately: a triage tool should show one
    /// more message per screen before it shows one more line of a message the
    /// user will probably archive.
    func test_defaultDensity_isCompact() {
        XCTAssertEqual(ListDensityPreference.current(), .compact)
    }

    /// An unset or corrupt stored value falls back to the default rather than
    /// leaving the list with no row height at all.
    func test_unreadableStoredValue_fallsBackToDefault() {
        UserDefaults.standard.set("not-a-density", forKey: ListDensityPreference.key)
        XCTAssertEqual(ListDensityPreference.current(), .compact)
        UserDefaults.standard.removeObject(forKey: ListDensityPreference.key)
        XCTAssertEqual(ListDensityPreference.current(), .compact)
    }

    /// The preference round-trips, and both mail surfaces read the same key —
    /// which is the whole reason the key lives in one enum.
    func test_preference_roundTripsEveryDensity() {
        for density in ListDensity.allCases {
            ListDensityPreference.set(density)
            XCTAssertEqual(ListDensityPreference.current(), density)
        }
    }

    /// Only `dense` drops the snippet line.
    ///
    /// Pinned because the tempting version of this feature is "let every mode
    /// hide the snippet" — which would give the user a setting that does nothing
    /// in two of its three positions.
    func test_onlyDenseModeHidesTheSnippet() {
        XCTAssertTrue(ListDensity.comfortable.showsSnippet)
        XCTAssertTrue(ListDensity.compact.showsSnippet)
        XCTAssertFalse(ListDensity.dense.showsSnippet)
    }

    /// `comfortable` hands the platform default back rather than pinning a
    /// number, so it keeps tracking macOS row-height changes across versions.
    func test_comfortableDefersToThePlatformRowHeight() {
        XCTAssertNil(ListDensity.comfortable.minRowHeight)
        // And the two packed modes must actually differ, or the picker offers
        // two positions that render identically.
        XCTAssertNotEqual(
            ListDensity.compact.minRowHeight, ListDensity.dense.minRowHeight
        )
    }

    /// Every density has a label in both languages, and none of them is empty —
    /// a blank row in the picker is worse than no picker.
    func test_everyDensityLabel_isTranslatedAndDistinct() {
        var seen: Set<String> = []
        for density in ListDensity.allCases {
            let chinese: String
            let english: String
            switch density {
            case .comfortable:
                chinese = zh.densityComfortable
                english = en.densityComfortable
            case .compact:
                chinese = zh.densityCompact
                english = en.densityCompact
            case .dense:
                chinese = zh.densityDense
                english = en.densityDense
            }
            XCTAssertFalse(chinese.isEmpty, "missing zh for \(density.rawValue)")
            XCTAssertFalse(english.isEmpty, "missing en for \(density.rawValue)")
            XCTAssertNotEqual(chinese, english, "untranslated \(density.rawValue)")
            // Distinct within each language: two identical labels would make the
            // choice a guess.
            XCTAssertTrue(seen.insert(chinese).inserted, "duplicate zh label \(chinese)")
            seen.remove(chinese)
            XCTAssertFalse(chinese == english)
        }
    }

    /// The hover card is text and nothing else.
    ///
    /// This is the constitutional one. A hover affordance that could archive
    /// would make "moving the pointer across a list" a mutation, which is
    /// exactly what constitution §2 rule 3 forbids — every change must come from
    /// a gesture the user meant. The card therefore renders no verbs at all, and
    /// `RowHoverPreview` takes no callback, which is the strongest form of that
    /// guarantee available at compile time.
    func test_hoverPreviewOffersNoActions() {
        // The initializer is the contract: it accepts a message and an optional
        // advice record, and nothing else. There is no closure parameter, so
        // there is no way for a caller to wire a write into it.
        let message = MessageHeader(
            id: UUID(),
            accountId: UUID(),
            remoteId: "r1",
            threadId: "t1",
            fromAddress: "sender@example.com",
            fromName: "Sender",
            subject: "Subject",
            snippet: "snippet",
            receivedAt: Date(),
            isRead: false,
            isArchived: false
        )
        let mirror = Mirror(reflecting: RowHoverPreview(message: message, advice: nil))
        // `_l10n` is the injected environment value SwiftUI adds to every view
        // that reads one; it is not part of the card's own surface.
        let storedProperties = mirror.children.compactMap { $0.label }
            .filter { !$0.hasPrefix("_") }
        XCTAssertEqual(
            Set(storedProperties), ["message", "advice"],
            "the hover card must stay read-only: no action closures may be stored"
        )
        for name in storedProperties {
            XCTAssertFalse(
                name.lowercased().contains("on"),
                "a stored property named \(name) looks like a callback; the card has no verbs"
            )
        }
    }
}