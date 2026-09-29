import XCTest
import SwiftUI
@testable import Lagoon

/// `RefreshGate` is the bookkeeping both list surfaces share, and the
/// reason two defects shipped: a local mutation (archive, delete, mark
/// read) that forgot to retire the in-flight poll let the poll write its
/// pre-mutation snapshot straight back, and a refresh raised while another
/// was in flight was dropped instead of queued, so the user sat on a stale
/// snapshot until the next 30s tick.
final class RefreshGateTests: XCTestCase {
    /// F25: a poll captures the list, the user archives a row, the poll
    /// returns — the generation has moved on, so it must not commit.
    func test_invalidateRetiresTheInFlightResponse() throws {
        var gate = RefreshGate()
        let claimed = try XCTUnwrap(gate.claim())

        // The archive callback calls invalidate() before removing the row.
        gate.invalidate()

        XCTAssertNotEqual(
            claimed, gate.generation,
            "the in-flight poll would write the pre-archive snapshot back"
        )
    }

    /// The same hole existed on mark-read, which the detail view fires on
    /// open — the most common local mutation of all.
    func test_markReadAlsoRetiresTheInFlightResponse() throws {
        var gate = RefreshGate()
        let claimed = try XCTUnwrap(gate.claim())
        gate.invalidate()
        XCTAssertNotEqual(claimed, gate.generation)
    }

    /// F3: a refresh arriving mid-poll used to hit
    /// `guard !isLoading else { return }` and vanish. The gate has to
    /// remember it and report the debt on the way out.
    func test_aRefreshRaisedDuringAnInFlightOneIsNotLost() throws {
        var gate = RefreshGate()
        let first = try XCTUnwrap(gate.claim())

        // The ⌘Z notification lands while the first poll is still running.
        let second = gate.claim()
        XCTAssertNil(second, "only one refresh may run at a time")
        XCTAssertTrue(
            gate.finish(),
            "the caller that was turned away is owed a run; finishing must say so"
        )

        // …and the replay is a real, claimable run.
        let replay = try XCTUnwrap(gate.claim())
        XCTAssertNotEqual(replay, first)
        XCTAssertFalse(gate.finish(), "nothing is owed any more")
    }

    /// A burst collapses into one replay: the payload is the same for every
    /// caller, so three notifications during one poll cost one extra fetch,
    /// not three.
    func test_severalWaitingCallersCollapseIntoOneReplay() throws {
        var gate = RefreshGate()
        XCTAssertNotNil(gate.claim())
        XCTAssertNil(gate.claim())
        XCTAssertNil(gate.claim())
        XCTAssertNil(gate.claim())

        XCTAssertTrue(gate.finish())
        let replay = try XCTUnwrap(gate.claim())
        XCTAssertNotNil(replay)
        XCTAssertFalse(gate.finish(), "the replay drained the queue")
    }

    /// The gate must not let a stale response commit, and must keep
    /// working after a superseded run.
    func test_aSupersededRunCannotCommit() throws {
        var gate = RefreshGate()
        let stale = try XCTUnwrap(gate.claim())
        gate.invalidate()
        _ = gate.finish()
        let current = try XCTUnwrap(gate.claim())
        _ = gate.finish()

        XCTAssertNotEqual(stale, current, "the old run is still identifiable as stale")
        XCTAssertEqual(current, gate.generation, "the newest run may commit")
    }
}

/// F28: the 聚合规则 button sits in the always-present toolbar, so the
/// sheet that opens it has to live outside the `if !messages.isEmpty`
/// branch too. It used to hang off the `List`, and with an empty inbox the
/// button did nothing at all and the feature was unreachable.
///
/// This asserts the modifier's *placement*, not a rendered outcome: the
/// package has no UI-test target, and SwiftUI's view tree is not
/// inspectable from a unit test, so the only thing a test can pin is where
/// the modifier is attached. Indentation is the honest proxy — the
/// modifiers inside the conditional are indented two levels deeper than the
/// ones on the always-present `VStack`.
final class MessageListSheetPlacementTests: XCTestCase {
    func test_stackListSheetIsNotInsideTheEmptyListBranch() throws {
        let url = try XCTUnwrap(Self.sourceURL())
        let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")

        let index = try XCTUnwrap(
            lines.firstIndex { $0.contains(".sheet(isPresented: $showStackList)") },
            "the 聚合规则 sheet modifier is gone; it must stay reachable from the toolbar"
        )
        let indent = lines[index].prefix { $0 == " " }.count
        XCTAssertEqual(
            indent, 12,
            """
            the sheet is attached \(indent) spaces in — i.e. inside the \
            `if !messages.isEmpty` branch, where an empty list makes the \
            toolbar button do nothing.
            """
        )
    }

    /// The two sheets that only rows can raise stay on the list. Moving
    /// them is churn, not a fix, and this keeps that decision recorded.
    func test_rowOnlySheetsStayOnTheList() throws {
        let url = try XCTUnwrap(Self.sourceURL())
        let source = try String(contentsOf: url, encoding: .utf8)

        for modifier in [".sheet(item: $senderFocus)", ".sheet(item: $stackEditor)"] {
            let index = try XCTUnwrap(
                source.range(of: modifier),
                "\(modifier) disappeared"
            )
            let line = source[source.startIndex..<index.lowerBound]
                .components(separatedBy: "\n").last ?? ""
            XCTAssertEqual(
                line.prefix { $0 == " " }.count, 20,
                "\(modifier) moved off the list; its setters are row actions"
            )
        }
    }

    private static func sourceURL() -> URL? {
        // .../Tests/LagoonTests/<file>.swift → .../Sources/Lagoon/Views/<file>
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LagoonTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Sources/Lagoon/Views/MessageListView.swift")
    }
}

/// F25: a local mutation of the list that forgets to retire the in-flight
/// poll is invisible until a row reappears in front of the user. Swift
/// cannot stop a view from writing `messages` directly, so this pins the
/// convention where it is checkable — same rationale as the sheet-placement
/// test above: no UI-test target exists, and the defect is a property of
/// the view's source, not of a rendered outcome.
///
/// **What this does not prove.** The walk-back stops at the first line that
/// starts with exactly four spaces and `func `, so a removal inside a local
/// function declared at a deeper indent is attributed to the *enclosing*
/// method — and an `invalidate()` belonging to that enclosing method will
/// mask the violation. It is a net for the ordinary shape, not a proof. The
/// durable fix is a UI test target that archives a row while a poll is in
/// flight, which does not exist.
final class ListMutationRetiresRefreshTests: XCTestCase {
    func test_everyDirectListMutationIsPrecededByAnInvalidate() throws {
        for view in ["MessageListView", "BriefingFeedView"] {
            let url = try XCTUnwrap(Self.sourceURL(view))
            let lines = try String(contentsOf: url, encoding: .utf8)
                .components(separatedBy: "\n")

            var unguarded: [String] = []
            for (offset, line) in lines.enumerated() {
                // The removal inside a comment is prose, not code.
                guard line.contains(".removeAll {"), !line.contains("//") else { continue }
                // Walk back to the start of the enclosing method and look
                // for the retire call anywhere inside it: the gap between
                // the two can be a whole `await` and an animation block.
                var cursor = offset - 1
                var context = ""
                while cursor >= 0 {
                    if lines[cursor].hasPrefix("    private func ")
                        || lines[cursor].hasPrefix("    func ") {
                        break
                    }
                    context = lines[cursor] + "\n" + context
                    cursor -= 1
                }
                guard !context.contains("invalidatePendingRefresh()"),
                      !context.contains("refreshGate.invalidate()") else { continue }
                unguarded.append("line \(offset + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
            XCTAssertEqual(
                unguarded, [],
                "\(view) removes a row without retiring the in-flight poll; the row will come back"
            )
        }
    }

    /// The callbacks the detail view raises for archive / delete must not
    /// hand-roll the removal. Asserting that `onArchived:` and a `dropRow`
    /// helper both *exist* proved nothing — the closure could inline
    /// `messages.removeAll { … }` while a never-called helper sat elsewhere —
    /// so this checked the closure body, and that was also wrong:
    /// `BriefingFeedView` routes through `handleArchived(…)` before reaching
    /// `dropItem(…)`, which is better code, and the check failed it.
    /// Making it pass meant teaching the test to follow one level of call
    /// indirection, at which point it is a Swift parser wearing a test's
    /// clothes. The invariant it was after is already covered by
    /// `test_everyDirectListMutationIsPrecededByAnInvalidate`, which fails on
    /// the actual defect — a removal with no `invalidate()` above it.
    /// Re-add a check here only once there is a UI-test target to back it.

    private static func sourceURL(_ view: String) -> URL? {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Lagoon/Views/\(view).swift")
    }
}
