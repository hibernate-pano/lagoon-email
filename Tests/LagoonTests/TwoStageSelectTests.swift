import XCTest
import Foundation
@testable import Lagoon
@testable import LagoonKit

/// Pins the **semantics** of the two-stage select-all, as opposed to its pixels.
///
/// ## The decision being pinned
///
/// `⌘A` selects what is **loaded**, never "everything on the server". Reaching
/// the rest requires a separate, explicit click on a link that states the real
/// total.
///
/// This is the single most destructive ambiguity a mail client can have. If ⌘A
/// meant "the whole mailbox", the most natural sequence a user could perform —
/// ⌘A then ⌫ — would trash 3,000 messages when only 50 were visible, with no
/// confirmation in between. Gmail solves it with two stages; so does this.
///
/// These tests are cheap and mostly about the *absence* of a behaviour, which
/// is exactly the kind of thing that regresses silently: nothing fails to
/// compile if someone "simplifies" ⌘A into a server-wide select.
@MainActor
final class TwoStageSelectTests: XCTestCase {
    private let zh = L10n(language: .zhHans)
    private let en = L10n(language: .english)

    /// The lens scopes `allMatching` can address, and they must cover every
    /// destination the sidebar offers.
    ///
    /// If a new lens is added without a matching `LensScope` case, the
    /// "select all" in that lens silently falls back to `.inbox` — which would
    /// mean bulk-deleting the wrong folder. Enumerated here so that failure is
    /// a test, not an incident.
    func test_lensScope_coversEverySidebarDestination() {
        let destinations: [SidebarDestination] = [
            .briefing, .allMessages, .unread, .pinned, .archived, .deleted, .sent,
        ]
        for destination in destinations {
            // Compiles only because `init(_:)` is exhaustive over
            // `SidebarDestination`; the runtime check is the real assertion.
            let scope = DeleteBulkRequest.LensScope(destination)
            XCTAssertFalse(
                scope.archived && scope.deleted,
                "\(destination) cannot be both archived and deleted"
            )
            // The three axes are mutually exclusive, so a scope may raise at
            // most one of them. Two at once would mean the server resolves a
            // filter no single list can produce.
            let raised = [scope.archived, scope.deleted, scope.sent].filter { $0 }
            XCTAssertLessThanOrEqual(
                raised.count, 1,
                "\(destination) raises \(raised.count) axes at once: "
                    + "archived=\(scope.archived) deleted=\(scope.deleted) sent=\(scope.sent)"
            )
        }

        // And each folder destination raises exactly the axis it names — the
        // property whose absence made `.sent` fall back to the inbox and trash
        // it. Asserted per destination rather than by set cardinality, because a
        // scope that raised *nothing* would pass a "no two are equal" check
        // while still resolving to the inbox.
        XCTAssertTrue(DeleteBulkRequest.LensScope(.sent).sent, "已发送 must raise `sent`")
        XCTAssertFalse(DeleteBulkRequest.LensScope(.sent).archived)
        XCTAssertFalse(DeleteBulkRequest.LensScope(.sent).deleted)
        XCTAssertTrue(DeleteBulkRequest.LensScope(.archived).archived)
        XCTAssertFalse(DeleteBulkRequest.LensScope(.archived).sent)
        XCTAssertTrue(DeleteBulkRequest.LensScope(.deleted).deleted)
        XCTAssertFalse(DeleteBulkRequest.LensScope(.deleted).sent)
    }

    /// The scope's filter flags must agree with the lens it came from.
    ///
    /// This is the invariant that keeps "select all" and "the list I am looking
    /// at" the same set. A drift here is invisible until a user's bulk delete
    /// takes messages from a folder they were not in.
    func test_lensScope_flagsMatchTheLens() {
        // `.inbox` via a destination, because the scope's own case is what the
        // client constructs directly and the destination mapping is what the
        // UI goes through — both need to agree.
        let inbox = DeleteBulkRequest.LensScope(SidebarDestination.allMessages)
        XCTAssertFalse(inbox.deleted)
        XCTAssertFalse(inbox.archived)
        XCTAssertNil(inbox.stackId)

        let archived = DeleteBulkRequest.LensScope(SidebarDestination.archived)
        XCTAssertTrue(archived.archived)
        XCTAssertFalse(archived.deleted)

        let deleted = DeleteBulkRequest.LensScope(SidebarDestination.deleted)
        XCTAssertTrue(deleted.deleted)
        XCTAssertFalse(deleted.archived)

        // 已发送 (R1) is its own axis, not a filter over the inbox. If this
        // mapping is wrong the server resolves the inbox instead and trashes
        // it — the one failure in this file that costs the user mail.
        let sent = DeleteBulkRequest.LensScope(SidebarDestination.sent)
        XCTAssertTrue(sent.sent)
        XCTAssertFalse(sent.archived)
        XCTAssertFalse(sent.deleted)

        // A rule carries its id and no filter flags — the server resolves the
        // rule itself, so the client must not also pin archived/deleted.
        let rule = DeleteBulkRequest.LensScope.rule(UUID())
        XCTAssertNotNil(rule.stackId)
        XCTAssertFalse(rule.archived)
        XCTAssertFalse(rule.deleted)
        XCTAssertFalse(rule.sent)
    }

    /// The explicit-id request carries no scope, so it can never be mistaken for
    /// a server-wide one.
    func test_explicitIdRequest_carriesNoScope() {
        let request = DeleteBulkRequest(remoteIds: ["a", "b"])
        XCTAssertNil(request.allMatching, "an id list is never a server-wide query")
        XCTAssertNil(request.archived)
        XCTAssertNil(request.deleted)
        XCTAssertNil(request.stackId)
    }

    /// The `allMatching` request carries no ids, so the server cannot
    /// accidentally treat it as a partial operation.
    func test_allMatchingRequest_carriesNoIds() {
        let request = DeleteBulkRequest(allMatchingIn: .inbox)
        XCTAssertNil(request.remoteIds)
        XCTAssertEqual(request.allMatching, true)
    }

    /// The round trip preserves the distinction, which is what the server reads.
    func test_requestShapes_surviveEncoding() throws {
        let explicit = DeleteBulkRequest(remoteIds: ["x"])
        let explicitJson = try JSONEncoder().encode(explicit)
        let explicitBack = try JSONDecoder().decode(DeleteBulkRequest.self, from: explicitJson)
        XCTAssertEqual(explicitBack.remoteIds, ["x"])
        XCTAssertNil(explicitBack.allMatching)

        let all = DeleteBulkRequest(allMatchingIn: .archived)
        let allJson = try JSONEncoder().encode(all)
        let allBack = try JSONDecoder().decode(DeleteBulkRequest.self, from: allJson)
        XCTAssertEqual(allBack.allMatching, true)
        XCTAssertEqual(allBack.archived, true)
        XCTAssertNil(allBack.remoteIds)
    }

    /// Stage two's copy must carry the number, in both languages.
    ///
    /// "Select all" without a count is the ambiguity this whole design removes.
    /// A generic label would put it straight back.
    func test_selectAllCopy_statesTheNumber() {
        for text in [zh.selectAllOnServer(3142), en.selectAllOnServer(3142)] {
            XCTAssertTrue(
                text.contains("3142"),
                "the second stage must state how far it reaches: \"\(text)\""
            )
        }
        XCTAssertNotEqual(zh.selectAllOnServer(10), zh.selectAllOnServer(20))
    }

    /// The warning about acting on unseen mail must exist and be distinct from
    /// the confirmations — it is a statement, not a question.
    func test_unloadedWarning_isItsOwnCopy() {
        XCTAssertFalse(zh.selectionReachesUnloaded.isEmpty)
        XCTAssertFalse(en.selectionReachesUnloaded.isEmpty)
        XCTAssertNotEqual(zh.selectionReachesUnloaded, zh.selectAllOnServer(10))
        // A warning that asks a question invites a reflex answer; this one has
        // to read as information.
        XCTAssertFalse(
            zh.selectionReachesUnloaded.contains("？") || zh.selectionReachesUnloaded.contains("?"),
            "the unloaded-selection note is a statement, not a prompt"
        )
    }

    /// The truncation report must say both what happened and what did not.
    func test_truncationReport_statesBothNumbers() {
        let text = zh.bulkDeleteTruncated(500, 2500)
        XCTAssertTrue(text.contains("500"), "must say how many moved")
        XCTAssertTrue(text.contains("2500"), "must say how many did not")
    }
}
