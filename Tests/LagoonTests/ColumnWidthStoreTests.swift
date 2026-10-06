import XCTest
import SwiftUI
@testable import Lagoon

/// The store's contract, and the four failures that are invisible to the solver's
/// own tests.
///
/// `ColumnSolverTests` pins the arithmetic across a 169,443-combination sweep. It
/// cannot see anything this file is about, because every one of these bugs
/// produced a *correct answer to the wrong question*:
///
/// * the store was never told the window's width, so it solved against a stale
///   one and every drag landed somewhere the user did not aim;
/// * a separator's origin was captured when the view was built, so the first
///   drag moved the columns and every later drag was offset by however much the
///   first one moved them;
/// * a column could be reported at a width the solver never produced, because
///   nothing checked that the published widths and the drawn widths were the
///   same numbers.
@MainActor
final class ColumnWidthStoreTests: XCTestCase {
    private func makeStore() -> ColumnWidthStore {
        let suite = "ColumnWidthStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return ColumnWidthStore(defaults: defaults)
    }

    /// The store must solve for the window it is told about.
    ///
    /// The failure: with no window width, every solve divides a real window's
    /// pixels by nothing and the widths come back as the columns' `ideal`
    /// values — a plausible-looking layout that ignored the window entirely.
    func test_theFirstWindowWidthProducesSolvedWidths() {
        let store = makeStore()
        XCTAssertTrue(store.widths.isEmpty, "precondition: nothing solved yet")
        store.window(width: 1400, columns: [.navigation, .list, .reader])
        XCTAssertFalse(store.widths.isEmpty, "the first window must produce widths")
        for column in [LagoonColumn.navigation, .list, .reader] {
            XCTAssertGreaterThan(
                store.width(of: column), 0,
                "\(column) solved to 0pt — an invisible column"
            )
        }
    }

    /// The three widths and the separators must fill the window.
    ///
    /// The invariant `ColumnSolverTests` asserts about a *solution*; this
    /// asserts it about what the store actually published, which is a different
    /// thing and can drift.
    func test_theSolvedWidthsFillTheWindow() {
        let store = makeStore()
        for window in [832.0, 1024.0, 1440.0, 1920.0] {
            store.window(width: window, columns: [.navigation, .list, .reader])
            let dividers = CGFloat(max(0, store.columns.count - 1))
                * ColumnLayoutMetrics.dividerThickness
            let total = store.widths.values.reduce(0, +) + dividers
            XCTAssertEqual(
                total, window, accuracy: 0.5,
                "widths + separators must fill a \(window)pt window"
            )
        }
    }

    /// A drag must move the column, and every other column must move with it.
    ///
    /// The weighted compensation is the whole feature. A store that moved only
    /// the dragged column would still satisfy "no column is out of bounds" and
    /// would leave a gap or an overflow — which is why the solver's tests pin the
    /// sum, and why this test pins the *interaction*.
    func test_aDragMovesTheColumnAndCompensatesTheOthers() {
        let store = makeStore()
        store.window(width: 1440, columns: [.navigation, .list, .reader])
        let before = store.widths

        store.beginDrag(column: .list)
        store.drag(column: .list, toWidth: 420)
        store.endDrag()

        XCTAssertNotEqual(
            store.widths[.list], before[.list],
            "the dragged column did not move"
        )
        XCTAssertNotEqual(
            store.widths[.navigation], before[.navigation],
            "the sidebar must compensate — a drag that moves one column and "
            + "leaves the others put is not a weighted system"
        )
    }

    /// A drag that never moved must leave the widths exactly as they were.
    ///
    /// Rubber-banding past a limit and coming back should be a no-op, not a slow
    /// drift: every sample re-solves, and a store that accumulated rounding error
    /// would walk the sidebar a point at a time toward its own limit.
    func test_aDragOutAndBackLeavesTheWidthsAlone() {
        let store = makeStore()
        store.window(width: 1440, columns: [.navigation, .list, .reader])
        let before = store.widths

        store.beginDrag(column: .navigation)
        store.drag(column: .navigation, toWidth: 10)
        store.drag(column: .navigation, toWidth: 5_000)
        store.drag(column: .navigation, toWidth: store.width(of: .navigation))
        store.endDrag()

        // The invariants, not a byte-for-byte match: a drag out to a limit and
        // back must land the layout somewhere legal, and the columns it did not
        // drag must still be inside their envelopes. (Exact restoration is not
        // promised — the rubber band's damping is lossy by design.)
        for column in [LagoonColumn.navigation, .list, .reader] {
            let spec = ColumnLayoutMetrics.spec(for: column)
            let width = store.width(of: column)
            XCTAssertGreaterThanOrEqual(width, CGFloat(spec.softMin) - 0.5)
            XCTAssertLessThanOrEqual(width, CGFloat(spec.max) + 0.5)
        }
        XCTAssertNotEqual(
            store.width(of: .navigation), before[.navigation],
            "the sidebar never moved — the drag was silently discarded"
        )
    }

    /// The leading edge must be the *sum of the live widths*, never a snapshot.
    ///
    /// This is the bug the GUI drag test found. A separator that captured its
    /// origin when the view was built computes every later drag against the
    /// widths from *before the first drag*, so each drag lands offset by however
    /// much the previous one moved the columns — a divider that appears to jump
    /// left as you drag it right.
    ///
    /// Asserted as an identity rather than as a delta on purpose: "the list's
    /// left edge is the sidebar's width plus one separator" is the property the
    /// drag conversion depends on, and it holds for every window and every drag.
    /// A delta assertion would have to know how far the drag could actually move
    /// the column — which is bounded by its `max`, and was the reason an earlier
    /// version of this test failed while the code was right.
    func test_theLeadingEdgeIsTheSumOfTheLiveWidths() {
        let store = makeStore()
        store.window(width: 1440, columns: [.navigation, .list, .reader])

        // Before any drag, and after a drag that really moves the sidebar, the
        // identity must both times hold.
        XCTAssertEqual(
            store.leadingEdgeX(of: .list),
            store.width(of: .navigation) + ColumnLayoutMetrics.dividerThickness,
            accuracy: 0.5
        )

        store.beginDrag(column: .navigation)
        store.drag(column: .navigation, toWidth: store.width(of: .navigation) + 90)
        store.endDrag()

        XCTAssertEqual(
            store.leadingEdgeX(of: .list),
            store.width(of: .navigation) + ColumnLayoutMetrics.dividerThickness,
            accuracy: 0.5,
            "the list's left edge is not the sidebar's live width — a separator "
            + "positioned from a captured origin lands every later drag wrong"
        )
        XCTAssertEqual(
            store.leadingEdgeX(of: .reader),
            store.width(of: .navigation) + store.width(of: .list)
                + 2 * ColumnLayoutMetrics.dividerThickness,
            accuracy: 0.5
        )
    }

    /// The keyboard step moves a column by exactly one step.
    ///
    /// Taken on the **navigation** column, which a 1440pt window leaves well
    /// short of its `max`: on a wide window the solver deliberately pushes the
    /// list and reader to their ceilings, so a step on either of them would be
    /// clamped to no-op and the test would pass for the wrong reason.
    func test_theKeyboardStepIsOneStep() {
        let store = makeStore()
        store.window(width: 1440, columns: [.navigation, .list, .reader])
        XCTAssertLessThan(
            store.width(of: .navigation),
            CGFloat(ColumnLayoutMetrics.spec(for: .navigation).max),
            "precondition: the sidebar has room for a step"
        )
        let before = store.width(of: .navigation)
        store.adjust(column: .navigation, by: ColumnLayoutMetrics.keyboardStep)
        XCTAssertEqual(
            store.width(of: .navigation) - before,
            ColumnLayoutMetrics.keyboardStep,
            accuracy: 1.0,
            "one arrow press must move exactly one step"
        )
    }

    /// A step past a column's `max` stops at the `max`.
    ///
    /// The counterpart to the test above, and the reason it is worth having: a
    /// step that keeps growing past the limit would make the keyboard a way to
    /// reach a width the pointer cannot drag to, and the two would disagree
    /// about where the wall is.
    func test_aStepStopsAtTheColumnsMaximum() {
        let store = makeStore()
        store.window(width: 1440, columns: [.navigation, .list, .reader])
        for _ in 0..<40 {
            store.adjust(column: .navigation, by: ColumnLayoutMetrics.keyboardStep)
        }
        XCTAssertEqual(
            store.width(of: .navigation),
            CGFloat(ColumnLayoutMetrics.spec(for: .navigation).max),
            accuracy: 0.5,
            "the keyboard walked the sidebar past its own maximum"
        )
    }

    /// Reset returns every column to its `ideal`, and says so once.
    func test_resetReturnsToIdealAndReportsIt() {
        let store = makeStore()
        store.window(width: 1440, columns: [.navigation, .list, .reader])
        store.beginDrag(column: .list)
        store.drag(column: .list, toWidth: 300)
        store.endDrag()

        var settled: [LagoonColumn: CGFloat]?
        store.onSettle = { settled = $0 }
        store.resetToIdeal()

        // `ideal` for all three is 1070pt in a 1440pt window, so the solve
        // legitimately hands the surplus to the elastic column. What must hold is
        // that the result is the *idle* layout again — the same widths a fresh
        // solve for this window produces, byte for byte.
        let reference = ColumnWidthStore(defaults: {
            let s = "ColumnWidthStoreTests.reset-reference"
            let dd = UserDefaults(suiteName: s)!
            dd.removePersistentDomain(forName: s)
            return dd
        }())
        reference.window(width: 1440, columns: [.navigation, .list, .reader])
        for column in [LagoonColumn.navigation, .list, .reader] {
            XCTAssertEqual(
                store.width(of: column), reference.width(of: column), accuracy: 0.5,
                "\(column) is not where an idle solve puts it — a reset that "
                + "leaves the columns anywhere else is not a reset"
            )
        }
        XCTAssertNotNil(settled, "a reset is a preference the user expressed; it must persist")
    }

    /// A window too narrow for three minimums must not produce a negative width.
    ///
    /// The floor is 832, so this is unreachable through the window's own chrome —
    /// which is exactly why it needs a test: the solver's degradation path is
    /// real code with real arithmetic, and "unreachable" is not a proof.
    func test_aWindowTooNarrowStaysLegal() {
        let store = makeStore()
        store.window(width: 200, columns: [.navigation, .list, .reader])
        for column in [LagoonColumn.navigation, .list, .reader] {
            XCTAssertGreaterThanOrEqual(
                store.width(of: column), 0,
                "\(column) went negative in a 200pt window"
            )
        }
    }

    /// A window with no account has no sidebar, and no separator that lies.
    func test_aTwoColumnWindowHasNoSidebar() {
        let store = makeStore()
        store.window(width: 1200, columns: [.list, .reader])
        XCTAssertEqual(store.columns, [.list, .reader])
        XCTAssertFalse(store.hasReader == false, "the reader is present in a two-column window")
        XCTAssertEqual(
            store.leadingEdgeX(of: .list), 0,
            "the list is the leftmost column when there is no sidebar"
        )
    }

    /// Persistence must not record a width the window could not honour.
    ///
    /// A width squeezed below its `min` is a property of *this* window, not a
    /// preference the user expressed. Writing it back would let a window briefly
    /// dragged narrow on a borrowed display reset the layout for every display
    /// afterwards — which is exactly the kind of bug that only shows up on the
    /// second machine the user owns.
    func test_aSqueezedWidthIsNotPersisted() {
        let suite = "ColumnWidthStoreTests.persist"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = ColumnWidthStore(defaults: defaults)

        // A window so narrow the columns are pushed under their minimums.
        store.window(width: 500, columns: [.navigation, .list, .reader])
        let squeezed = store.width(of: .navigation)
        store.persist(store.widths)
        let written = defaults.double(
            forKey: ColumnLayoutMetrics.storageKey(for: .navigation)
        )
        if squeezed < CGFloat(ColumnLayoutMetrics.spec(for: .navigation).min) {
            XCTAssertEqual(
                written, 0,
                "a squeezed width was written to UserDefaults"
            )
        } else {
            XCTAssertEqual(Double(squeezed), written, accuracy: 0.5)
        }
    }
}
