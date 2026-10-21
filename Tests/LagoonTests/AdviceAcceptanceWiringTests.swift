import XCTest
import Foundation
import SwiftUI
@testable import Lagoon
@testable import LagoonKit

/// P1-08: the advice "accepted" state was never written, so the learning
/// loop the constitution describes (Phase 4 — "accepted / rejected
/// suggestions accumulate as read-only preferences, used to improve later
/// suggestions") had no way to start.
///
/// `AdviceDecision.accepted` existed in the enum, `AdviceStore.setDecision`
/// supported it, and **nothing ever sent it**: `grep -rn "setAdviceDecision"
/// Sources/` found two call sites and both passed `.dismissed`. The column
/// was therefore always empty, and the server had nothing to learn from.
///
/// These tests pin the wiring from both ends:
///
/// * the **client** writes `.accepted` when the user acts on the advised
///   action, and does so *after* the mail action (the mail action is the
///   important one; the verdict is best-effort), and
/// * the **server** reads the accepted rows back as a distribution.
///
/// ## Why these are source-level guards
///
/// The wiring is *attachment*: a verdict write that has to sit next to a
/// particular call, in a particular order, on a path the type system cannot
/// reach. A unit test that drives a `@State` view cannot see that the
/// archive path records the verdict, and cannot see that it records it
/// *after* the archive rather than before. So each assertion below pins a
/// string that exists only where the wiring exists, positioned between
/// anchors — the same style as `MailSurfaceWiringTests`.
final class AdviceAcceptanceWiringTests: XCTestCase {
    /// The repo root, from this file's own path.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // LagoonTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // package root

    /// A source file outside `Sources/Lagoon` — the server store and the AI
    /// gateway live in their own targets, and `ViewSource` only reaches the
    /// client's `Sources/Lagoon` tree.
    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: Self.repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    // MARK: - The verdict rule (pure, unit-testable)

    /// The rule that decides whether a performed action counts as accepting
    /// the suggestion.
    ///
    /// This is the heart of the fix, and it is a pure function precisely so
    /// it can be tested directly rather than inferred from a view.
    func test_acceptance_requiresTheAdvisedActionToMatch() {
        let advice = makeAdvice(action: .archive, decision: .pending)
        XCTAssertEqual(
            AdviceAcceptance.verdict(for: advice, performedAction: .archive),
            .accepted,
            "acting on the advised action is the acceptance"
        )
        XCTAssertNil(
            AdviceAcceptance.verdict(for: advice, performedAction: .delete),
            "a different action is not agreement with the suggestion"
        )
        XCTAssertNil(
            AdviceAcceptance.verdict(for: advice, performedAction: .reply),
            "replying to a mail the AI said to archive teaches the model nothing"
        )
    }

    /// A dismissed suggestion is never re-decided.
    ///
    /// The user already said "no". Overwriting that with a "yes" they never
    /// gave is the opposite of learning — and it would silently un-dismiss a
    /// suggestion the constitution says must stop being re-surfaced.
    func test_aDismissedSuggestionIsNeverAccepted() {
        let dismissed = makeAdvice(action: .archive, decision: .dismissed)
        XCTAssertNil(
            AdviceAcceptance.verdict(for: advice(dismissed), performedAction: .archive),
            "a dismissed suggestion must stay dismissed"
        )
    }

    /// An already-accepted suggestion is not accepted twice — the write is
    /// idempotent from the client's point of view.
    func test_anAlreadyAcceptedSuggestionIsNotAcceptedAgain() {
        let accepted = makeAdvice(action: .archive, decision: .accepted)
        XCTAssertNil(
            AdviceAcceptance.verdict(for: advice(accepted), performedAction: .archive)
        )
    }

    /// A message with no suggestion produces no verdict at all.
    func test_noSuggestionProducesNoVerdict() {
        XCTAssertNil(AdviceAcceptance.verdict(for: nil, performedAction: .archive))
    }

    // MARK: - The client writes the verdict

    /// The feed's archive path must record the acceptance, and it must do so
    /// **after** the archive succeeded.
    ///
    /// The order is the point: the mail action is the one the user asked for,
    /// and an archive that failed must not have left an "accepted" verdict
    /// behind — that would teach the model the user likes a suggestion they
    /// never acted on.
    func test_theFeedRecordsAcceptanceAfterTheArchiveSucceeds() throws {
        let source = try ViewSource.read("BriefingFeedView")
        let archive = try XCTUnwrap(
            source.range(of: "private func archiveAndUndo(byId remoteId: String)"),
            "the feed's archive path moved"
        )
        let code = ViewSource.code(after: archive.lowerBound, in: source, limit: 3000)
        XCTAssertTrue(
            code.contains("recordAcceptedAdvice(remoteId: remoteId, performed: .archive"),
            "the archive path does not record the acceptance"
        )
        // The verdict write must come *after* the API call, not before.
        let archiveCall = try XCTUnwrap(
            code.range(of: "api.archiveMessage("), "the archive request is gone"
        )
        let record = try XCTUnwrap(
            code.range(of: "recordAcceptedAdvice("), "the acceptance write is gone"
        )
        XCTAssertLessThan(
            archiveCall.lowerBound, record.lowerBound,
            "the acceptance must be recorded after the mail action succeeded"
        )
    }

    /// Same rule for the unsubscribe path — and unsubscribe is the one that
    /// cannot be undone, so the verdict is even more clearly *after* the fact.
    func test_theFeedRecordsAcceptanceAfterTheUnsubscribeSucceeds() throws {
        let source = try ViewSource.read("BriefingFeedView")
        let unsubscribe = try XCTUnwrap(
            source.range(of: "private func unsubscribeFrom"),
            "the feed's unsubscribe path moved"
        )
        let code = ViewSource.code(after: unsubscribe.lowerBound, in: source, limit: 2500)
        XCTAssertTrue(
            code.contains("recordAcceptedAdvice("),
            "the unsubscribe path does not record the acceptance"
        )
        XCTAssertTrue(
            code.contains("performed: .unsubscribe"),
            "the unsubscribe path must record the acceptance as `.unsubscribe`"
        )
        let call = try XCTUnwrap(
            code.range(of: "api.unsubscribeMessage("), "the unsubscribe request is gone"
        )
        let record = try XCTUnwrap(
            code.range(of: "recordAcceptedAdvice("), "the acceptance write is gone"
        )
        XCTAssertLessThan(
            call.lowerBound, record.lowerBound,
            "the acceptance must be recorded after the mail action succeeded"
        )
    }

    /// The raw list's archive and delete paths record it too.
    ///
    /// The list is the *other* half of the product's mail surface; a
    /// learning loop that only learns from the feed is a loop that misses
    /// every mail the user triages where they actually work.
    func test_theRawListRecordsAcceptanceForArchiveAndDelete() throws {
        let source = try ViewSource.read("MessageListView")
        XCTAssertTrue(
            source.contains("recordAcceptedAdvice(remoteId: m.remoteId, performed: .archive"),
            "the list's archive path does not record the acceptance"
        )
        XCTAssertTrue(
            source.contains("recordAcceptedAdvice(remoteId: m.remoteId, performed: .delete"),
            "the list's delete path does not record the acceptance"
        )
    }

    /// The detail view's own archive button records it as well.
    ///
    /// The reading pane has its own archive button, and it does **not** go
    /// through the feed's or the list's archive path — it calls the API
    /// itself and reports back through `onArchived`. So without a write on
    /// that path, archiving from the reading pane — the place a user who
    /// reads one mail and files it actually works — would leave the
    /// learning signal empty for exactly the most deliberate triage.
    func test_theDetailViewArchivePathRecordsAcceptance() throws {
        for (view, marker) in [
            ("BriefingFeedView", "private func handleArchived"),
            ("MessageListView", "onArchived: { id, _ in"),
        ] {
            let source = try ViewSource.read(view)
            let anchor = try XCTUnwrap(
                source.range(of: marker), "\(view): the detail-view archive path moved"
            )
            let code = ViewSource.code(after: anchor.lowerBound, in: source, limit: 900)
            XCTAssertTrue(
                code.contains("recordAcceptedAdvice("),
                "\(view): archiving from the reading pane does not record the acceptance"
            )
            XCTAssertTrue(
                code.contains("performed: .archive"),
                "\(view): the detail-view archive must record the acceptance as `.archive`"
            )
        }
    }

    /// The write must be `.accepted` — the whole point of the audit item.
    ///
    /// A recorder that sent `.dismissed` would keep the suite green (the
    /// column would still be written) while the learning signal stayed
    /// exactly as empty as it was before.
    func test_theRecorderWritesTheAcceptedDecision() throws {
        let source = try String(
            contentsOf: ViewSource.url(under: "Services", "AdviceAcceptance"),
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains("decision: .accepted"),
            "the recorder must write `.accepted` — anything else leaves the learning signal empty"
        )
        XCTAssertFalse(
            source.contains("decision: .dismissed"),
            "the recorder must not write `.dismissed` — that is the rejection signal"
        )
    }

    /// The verdict write must never take the mail action down with it.
    ///
    /// The recorder returns the failure instead of throwing, and the call
    /// sites surface it — a `try` that propagates out of the archive path
    /// would turn "the preference could not be written" into "the mail was
    /// not filed", which is the opposite of what happened.
    func test_aFailedVerdictWriteDoesNotFailTheMailAction() throws {
        let source = try String(
            contentsOf: ViewSource.url(under: "Services", "AdviceAcceptance"),
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains("return error"),
            "the recorder must return the failure rather than throw it"
        )
        XCTAssertFalse(
            source.contains(") async throws ->"),
            "the recorder must not throw — the mail action already succeeded"
        )
    }

    // MARK: - The row offers the verb

    /// The strip must carry a 「照做」 button.
    ///
    /// Without it there is no way to say "yes, do that" from the row the
    /// user is reading, so the loop has no entry point: the acceptance can
    /// only ever come from a user who happens to archive a mail the AI
    /// happened to have suggested archiving.
    func test_theStripOffersTheDoItButton() throws {
        let source = try ViewSource.read("RowAdviceStrip")
        XCTAssertTrue(
            source.contains("l10n.adviceAccept"),
            "the strip has no 「照做」 button — the learning loop has no entry point"
        )
        XCTAssertTrue(
            source.contains("onAccept"),
            "the strip does not take an `onAccept` callback"
        )
    }

    /// The button must be hidden once the suggestion has been decided.
    ///
    /// A dismissed suggestion that offers to be performed is exactly the
    /// nagging constitution §3 forbids, and an accepted one has already been
    /// performed.
    func test_theDoItButtonIsHiddenOnceTheSuggestionIsDecided() throws {
        let source = try ViewSource.read("RowAdviceStrip")
        XCTAssertTrue(
            source.contains("if !isDecided, advice.action.isMutating, let onAccept"),
            "the 「照做」 button must not be offered for a decided suggestion"
        )
        XCTAssertTrue(
            source.contains("private var isDecided: Bool { record.decision != .pending }"),
            "the strip lost its decided check — the button would re-offer a dismissed suggestion"
        )
    }

    /// The button must be wired from the row that owns the advice, and the
    /// feed must route it to the ordinary user-triggered mail actions.
    func test_theFeedRoutesTheDoItButtonToTheOrdinaryActions() throws {
        let source = try ViewSource.read("BriefingFeedView")
        XCTAssertTrue(
            source.contains("onAcceptAdvice: { record in"),
            "the feed does not pass an acceptance callback to the row"
        )
        XCTAssertTrue(
            source.contains("onAccept: Self.acceptableActions.contains(advice.advice.action)"),
            "the row does not offer 「照做」 for the performable suggestions"
        )
        // The action must go through the *existing* user-triggered paths —
        // a new write path would be a second way to mutate the mailbox, and
        // the constitution allows exactly one.
        XCTAssertTrue(
            source.contains("case .archive:\n            await archiveAndUndo(item)"),
            "「照做」 must archive through the same path the swipe gesture uses"
        )
        XCTAssertTrue(
            source.contains("case .unsubscribe:\n            await unsubscribeFrom(item)"),
            "「照做」 must unsubscribe through the same path the context menu uses"
        )
        XCTAssertTrue(
            source.contains("case .delete:\n            await deleteOne(item)"),
            "「照做」 must delete through a real delete — the button promised it"
        )
    }

    /// Only the actions the feed can actually perform are offered.
    ///
    /// `.reply` and `.remind` open a composer or a sheet, and `.wait` /
    /// `.nothing` are not actions at all — offering 「照做」 for them would
    /// render a button that does nothing.
    func test_onlyPerformableSuggestionsOfferTheButton() throws {
        let source = try ViewSource.read("BriefingFeedView")
        XCTAssertTrue(
            source.contains("static let acceptableActions: Set<AdvisedAction> = [.archive, .delete, .unsubscribe]"),
            "the performable set changed — check that every action in it has a route"
        )
    }

    // MARK: - The server reads the verdict back

    /// The server must expose the accepted distribution, and the classifier
    /// prompt must carry it.
    ///
    /// This is the half that makes it a *loop*: a verdict that is written and
    /// never read is a log, not learning.
    func test_theServerExposesTheAcceptedDistribution() throws {
        let store = try source("Sources/LagoonServer/Storage/AdviceStore.swift")
        XCTAssertTrue(
            store.contains("public static func acceptedStats("),
            "the store has no accepted-distribution query"
        )
        // Only accepted rows may count. `dismissed` is the opposite signal
        // and `pending` is no signal at all.
        XCTAssertTrue(
            store.contains("AdviceDecision.accepted.rawValue"),
            "the query must filter on the accepted decision"
        )
    }

    /// The prompt must carry the preferences as a small few-shot hint.
    func test_theClassifierPromptCarriesThePreferences() throws {
        let gateway = try source("Sources/LagoonAI/AIGateway.swift")
        XCTAssertTrue(
            gateway.contains("private static func preferenceHint("),
            "the gateway has no preference hint — the learned preferences never reach the prompt"
        )
        XCTAssertTrue(
            gateway.contains("Tendencies this user has shown by acting on past suggestions"),
            "the hint is missing from the prompt"
        )
    }

    // MARK: - Helpers

    private func makeAdvice(
        action: AdvisedAction,
        decision: AdviceDecision
    ) -> AdviceRecord {
        AdviceRecord(
            id: 1,
            accountId: UUID(),
            remoteId: "r1",
            advice: Advice(action: action, category: .marketing, confidence: .medium),
            source: .ai,
            model: "stub",
            decision: decision,
            createdAt: Date()
        )
    }

    /// The verdict function takes the record itself; the helper exists so
    /// the test reads as "a suggestion the user dismissed" rather than as a
    /// constructor call.
    private func advice(_ record: AdviceRecord) -> AdviceRecord { record }
}
