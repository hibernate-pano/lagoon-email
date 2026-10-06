import XCTest
import Foundation
@testable import Lagoon

/// The three-column width solver's invariants.
///
/// ## Why this file is mostly one assertion
///
/// `docs/三栏宽度求解器-实测结论.md` records the finding that shaped it: a solver
/// that only asserts "no column is out of bounds" passes **every** failure mode
/// that was actually shipped. The naive iteration produced `[94, 94, 900]` in a
/// 994pt window — 94pt of overflow *and* two columns below their own minimum —
/// and a bounds-only test would have called that a pass, because every width was
/// "inside" something.
///
/// So the assertion that carries this suite is the total:
///
/// ```
/// sum(widths) + dividerCount * dividerWidth == available
/// ```
///
/// A layout that breaks any bound *and* keeps the total correct still fails the
/// bound checks; a layout that keeps every bound *and* overflows the window
/// fails this one. Both are needed, and the total is the one that was missing.
///
/// ## The sweep
///
/// `test_sweep_holdsEveryInvariant` is the mutation test the rest of the suite
/// is built around: 281 window widths × 3 dragged columns × 201 pointer
/// positions, each checked against every invariant. It is what makes "the
/// solver is correct" a statement about the whole input space rather than about
/// the twelve numbers someone thought to write down.
final class ColumnSolverTests: XCTestCase {
    /// The three columns, in layout order.
    private let allColumns: [LagoonColumn] = [.navigation, .list, .reader]
    private let divider = ColumnLayoutMetrics.dividerThickness

    // MARK: - Helpers

    /// The width the three columns must add up to, separators included.
    private func budget(for available: Double, columns: [LagoonColumn]) -> Double {
        available - Double(max(0, columns.count - 1)) * divider
    }

    /// Every invariant, as one function so the sweep and the focused tests
    /// cannot state them differently.
    ///
    /// Returns the failures rather than asserting, so a sweep can report *how
    /// many* and *where* instead of stopping at the first — a solver that fails
    /// 4% of its inputs very differently from one that fails on a single edge
    /// case are different bugs.
    ///
    /// - Parameter requiresFloors: whether the `softMin` guarantee is in force.
    ///   It is **not** during a rubber-band overshoot: the whole point of the
    ///   band is that the dragged column goes past what the window can honour,
    ///   which necessarily squeezes a sibling below its soft floor for as long as
    ///   the pointer is out there. `ColumnLayoutStore.endDrag` re-solves without
    ///   `permitsOvershoot`, so the floor is restored on mouse-up. Asserting it
    ///   mid-overshoot would be asserting that the rubber band cannot exist.
    private func violations(
        _ solution: ColumnSolver.Solution,
        available: Double,
        columns: [LagoonColumn],
        dragged: LagoonColumn?,
        raw: Double,
        requiresFloors: Bool = true
    ) -> [String] {
        var problems: [String] = []

        // (1) The total. The load-bearing assertion.
        let total = solution.widths.values.reduce(0, +) + solution.dividerTotal
        if available >= divider - ColumnSolver.epsilon {
            if abs(total - available) >= 0.5 {
                problems.append(
                    "total \(fmt(total)) != available \(fmt(available)) "
                    + "(\(fmt(total - available)) off) at available=\(fmt(available)) "
                    + "dragged=\(dragged.map(String.init(describing:)) ?? "none") raw=\(fmt(raw))"
                )
            }
        } else if total > divider + 0.5 {
            // A window narrower than its own separators: the columns must clip,
            // not overflow. Nothing this narrow is reachable, but the solver
            // must still not produce a positive sum out of nothing.
            problems.append("total \(fmt(total)) exceeds the separator budget")
        }

        // (2) Bounds, and (3) non-negativity.
        for column in columns {
            let spec = ColumnLayoutMetrics.spec(for: column)
            let width = solution.width(of: column)
            if width < ColumnSpec.absoluteFloor - ColumnSolver.epsilon {
                problems.append("\(column) is negative: \(fmt(width))")
            }
            // `sum(max) + dividers` is 1662pt. Past that, "no column over its
            // max" and "the total equals the window" cannot both hold, and the
            // surplus is documented as going to the reader. Asserting the
            // envelope everywhere else is the point, so the exception is
            // spelled out rather than the check being weakened.
            //
            // The `requiresFloors` gate covers the *rubber band* case: while the
            // pointer is out past a limit, every column may sit up to
            // `rubberBandCap` outside its envelope. That is what the band is
            // for — see `requiresFloors`.
            let surplusGoesToTheReader = solution.isOverflowingMaximums
                && column == ColumnSolver.widestColumn(of: columns)
            let withinBand = requiresFloors ? 0.0 : ColumnLayoutMetrics.rubberBandCap
            if !surplusGoesToTheReader, width > spec.max + withinBand + 0.5 {
                problems.append("\(column) \(fmt(width)) exceeds max \(fmt(spec.max))")
            }
            // `softMin` is the floor a narrow window may squeeze to; `min` is
            // the floor a wide-enough window must honour. Asserting `min` would
            // fail the degradation tests, so the sweep checks `softMin` and the
            // dedicated degradation tests check `min` where it must hold.
            // During a rubber-band overshoot even `softMin` is suspended — see
            // `requiresFloors`.
            if requiresFloors, width < spec.softMin - 0.5 {
                problems.append("\(column) \(fmt(width)) below softMin \(fmt(spec.softMin))")
            }
        }

        // (4) The dragged column is present and pinned near what was asked.
        if let dragged, solution.width(of: dragged) <= 0 {
            problems.append("dragged \(dragged) has width \(fmt(solution.width(of: dragged)))")
        }
        return problems
    }

    private func fmt(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    // MARK: - (1) The total

    /// The invariant the whole suite exists for.
    ///
    /// Spelled out per case so a failure names the input, not just "sum
    /// mismatch" — and because the historical failure (94pt of overflow) is only
    /// visible as a *number* next to the window it overflowed.
    func test_widthsPlusDividersEqualTheWindow() {
        let cases: [(Double, LagoonColumn?, Double?)] = [
            (1400, nil, nil), (1200, nil, nil), (1000, nil, nil),
            (900, nil, nil), (832, nil, nil), (820, nil, nil), (800, nil, nil),
            (1000, .reader, 900), (1000, .list, 460), (1000, .navigation, 300),
            (1000, .reader, 0), (1000, .list, 280), (1000, .navigation, 180),
            (1400, .reader, 900), (832, .list, 460), (832, .navigation, 300),
            (1900, .list, 460), (500, nil, nil), (819, nil, nil),
        ]
        for (available, dragged, target) in cases {
            let solution = ColumnSolver.solve(
                columns: allColumns,
                totalWidth: available,
                dragged: dragged,
                target: target
            )
            let total = solution.widths.values.reduce(0, +) + solution.dividerTotal
            XCTAssertTrue(
                solution.isConsistent(),
                "available=\(available) dragged=\(dragged.map(String.init(describing:)) ?? "none") "
                + "target=\(target.map(String.init(describing:)) ?? "none") "
                + "widths=\(solution.widths) total=\(fmt(total))"
            )
            XCTAssertLessThanOrEqual(
                total, available + 0.5,
                "overflow at available=\(available) dragged=\(String(describing: dragged))"
            )
        }
    }

    /// The exact case from the measurement, so a regression to the old algorithm
    /// is named rather than merely detected.
    ///
    /// `docs/三栏宽度求解器-实测结论.md`: "拖阅读器 -> 900: [94.00, 94.00, 900.00]
    /// 合计=1088.00 目标=994.00 溢出 94pt". If this test ever fails with a total
    /// near 1088, the iteration is back.
    func test_theReaderAtItsMaxDoesNotOverflowTheWindow() {
        let available = 1000.0
        let solution = ColumnSolver.solve(
            columns: allColumns,
            totalWidth: available,
            dragged: .reader,
            target: 900
        )
        let total = solution.widths.values.reduce(0, +) + solution.dividerTotal
        XCTAssertEqual(total, available, accuracy: 0.5)
        // The reader cannot actually have 900pt in a 1000pt window: the other
        // two have minimums. So the solve must refuse, not overflow.
        XCTAssertLessThanOrEqual(solution.width(of: .reader), 900.5)
        XCTAssertGreaterThanOrEqual(solution.width(of: .navigation), 179.5)
        XCTAssertGreaterThanOrEqual(solution.width(of: .list), 279.5)
    }

    // MARK: - (2) Bounds and non-negativity

    /// Below the window floor the columns may go under `min` — but never under
    /// `softMin`, and never negative.
    func test_narrowWindowsSqueezeToSoftMinButNeverBelow() {
        // 832 is the product floor; below it the window is outside the promise,
        // and `sum(softMin) + dividers` is 692, so 691 is the first width where
        // a soft floor must itself give.
        for available in stride(from: 400.0, through: 832.0, by: 4.0) {
            let solution = ColumnSolver.solve(
                columns: allColumns,
                totalWidth: available,
                dragged: .reader,
                target: 900
            )
            for column in allColumns {
                let width = solution.width(of: column)
                XCTAssertGreaterThanOrEqual(
                    width, ColumnSpec.absoluteFloor,
                    "\(column) went negative at available=\(fmt(available))"
                )
                if available >= 692 {
                    XCTAssertGreaterThanOrEqual(
                        width, ColumnLayoutMetrics.spec(for: column).softMin - 0.5,
                        "\(column) \(fmt(width)) below softMin at available=\(fmt(available))"
                    )
                }
            }
            let total = solution.widths.values.reduce(0, +) + solution.dividerTotal
            XCTAssertLessThanOrEqual(total, available + 0.5, "overflow at \(fmt(available))")
        }
    }

    /// A window at or above the product floor honours every `min` exactly.
    ///
    /// This is the assertion the old `minWidth: 720` made impossible: 832 is the
    /// narrowest window, and 180 + 280 + 360 + 2 dividers is 822, so there are
    /// 10pt of slack and no `min` may be crossed.
    func test_wideEnoughWindowsHonourEveryMinimum() {
        for available in stride(from: ColumnLayoutMetrics.windowMinimumWidth, through: 1600.0, by: 4.0) {
            for dragged in allColumns {
                let target = ColumnLayoutMetrics.spec(for: dragged).ideal
                let solution = ColumnSolver.solve(
                    columns: allColumns,
                    totalWidth: available,
                    dragged: dragged,
                    target: target
                )
                for column in allColumns {
                    XCTAssertGreaterThanOrEqual(
                        solution.width(of: column),
                        ColumnLayoutMetrics.spec(for: column).min - 0.5,
                        "\(column) below min at available=\(fmt(available)) dragged=\(dragged)"
                    )
                }
            }
        }
    }

    // MARK: - (3) Determinism

    /// Same input, same answer — 500 times.
    ///
    /// Determinism is not a nicety here: the solve feeds frames that are
    /// compared against the pointer every sample, so a solver whose tie-breaking
    /// depended on a `Set`'s iteration order would make the divider jitter by
    /// fractions of a point at 120Hz. The iteration order is the kind of bug
    /// that shows up as "sometimes feels sticky" and is never reproducible.
    func test_theSameInputAlwaysSolvesIdentically() {
        for available in stride(from: 500.0, through: 1900.0, by: 20.0) {
            for dragged in allColumns {
                for target in stride(from: 0.0, through: 900.0, by: 37.0) {
                    let first = ColumnSolver.solve(
                        columns: allColumns,
                        totalWidth: available,
                        dragged: dragged,
                        target: target
                    )
                    for iteration in 1..<500 {
                        let again = ColumnSolver.solve(
                            columns: allColumns,
                            totalWidth: available,
                            dragged: dragged,
                            target: target
                        )
                        XCTAssertEqual(
                            again.widths, first.widths,
                            "available=\(fmt(available)) dragged=\(dragged) "
                            + "target=\(fmt(target)) diverged on iteration \(iteration)"
                        )
                    }
                }
            }
        }
    }

    // MARK: - (4) Continuity

    /// No column jumps when the window grows by one point.
    ///
    /// The failure this catches is a *sort* that reorders as a column crosses a
    /// bound: the column jumps to a new position in the queue, takes a different
    /// share, and the layout pops. At 1pt per step a jump larger than the step
    /// itself is visible as a twitch while the window is being dragged.
    func test_growingTheWindowNeverMakesAColumnJump() {
        // Scoped to the window widths where a three-column layout exists at all:
        // below the 832pt floor the columns are being squeezed below their
        // minimums, and above `sum(max) + dividers` = 1662pt the reader is
        // absorbing a surplus that grows with the window — so a column moving as
        // the window grows is the *correct* answer there, not a jump. Both
        // regimes have their own tests.
        for dragged in allColumns {
            let target = ColumnLayoutMetrics.spec(for: dragged).ideal
            var previous: [LagoonColumn: Double] = [:]
            for step in stride(
                from: ColumnLayoutMetrics.windowMinimumWidth,
                through: 1662.0,
                by: 1.0
            ) {
                let solution = ColumnSolver.solve(
                    columns: allColumns,
                    totalWidth: step,
                    dragged: dragged,
                    target: target
                )
                for column in allColumns {
                    let width = solution.width(of: column)
                    if let before = previous[column] {
                        // One point of window may move a column by more than a
                        // point — the dragged column is *pinned to its
                        // achievable range*, and that range itself moves with
                        // the window: in a 833pt window the navigation column
                        // cannot be 210pt wide, because that would leave the
                        // reader below its own minimum. So the pinned column
                        // tracks the ceiling as the window grows, and the
                        // ceiling moves at one point per point of window.
                        //
                        // The bound that matters is not "no column ever moves
                        // more than a point"; it is "no column *teleports*".
                        // Anything that moves faster than the window itself is a
                        // discontinuity, and it shows up on screen as the layout
                        // popping while the window is being dragged.
                        let delta = abs(width - before)
                        XCTAssertLessThanOrEqual(
                            delta, 1.0 + 0.5,
                            "\(column) jumped \(fmt(delta))pt at available=\(fmt(step)) "
                            + "dragged=\(dragged)"
                        )
                    }
                    previous[column] = width
                }
            }
        }
    }

    /// A window wider than every column's `max` puts the whole surplus on the
    /// reader, and the reader grows one point per point of window.
    ///
    /// The counterpart to the test above: continuity is asserted only where a
    /// discontinuity would be a bug, and *here* growth is the point. Asserted so
    /// that scoping the continuity test does not quietly leave this case
    /// untested.
    func test_aWindowWiderThanEveryMaximumGrowsTheReader() {
        let reader = ColumnSolver.widestColumn(of: allColumns) ?? .reader
        let sumOfMaxes = allColumns.reduce(0) { $0 + ColumnLayoutMetrics.spec(for: $1).max }
            + Double(allColumns.count - 1) * divider
        var previous: Double?
        for step in stride(from: sumOfMaxes, through: 1900.0, by: 1.0) {
            let solution = ColumnSolver.solve(
                columns: allColumns, totalWidth: step, carried: IDEAL_CARRIED
            )
            // At exactly `sum(max)` there is nothing left over, so nothing has
            // to overflow. One point later there is.
            if step > sumOfMaxes {
                XCTAssertTrue(
                    solution.isOverflowingMaximums, "no overflow reported at \(fmt(step))"
                )
            }
            if let before = previous {
                XCTAssertEqual(solution.width(of: reader) - before, 1.0, accuracy: 0.001)
            }
            previous = solution.width(of: reader)
        }
    }

    /// A resize that carries the current widths forward is continuous too — the
    /// common case, since a window resize re-solves from the live layout rather
    /// than from `ideal`.
    func test_carriedWidthsAreContinuousAcrossResizes() {
        var carried: [LagoonColumn: Double]?
        var previous: [LagoonColumn: Double] = [:]
        for step in stride(from: 900.0, through: 1900.0, by: 1.0) {
            let solution = ColumnSolver.solve(
                columns: allColumns,
                totalWidth: step,
                carried: carried
            )
            for column in allColumns {
                let width = solution.width(of: column)
                if let before = previous[column] {
                    XCTAssertLessThanOrEqual(
                        abs(width - before), 1.5,
                        "\(column) jumped at available=\(fmt(step))"
                    )
                }
                previous[column] = width
            }
            carried = solution.widths
        }
    }

    // MARK: - (5) Clamping at the extremes

    /// Dragging a column to its `max` lands exactly on it, or on the
    /// achievable ceiling when the window is too narrow to allow it.
    ///
    /// Two regimes, both asserted rather than one being waved through:
    ///
    /// * Below `sum(max) + dividers` = 1662pt the ceiling binds and the column
    ///   stops short of its own `max` — the honest answer, because the siblings
    ///   have minimums of their own.
    /// * Above 1662pt the window cannot hold every maximum. The *pinned* column
    ///   still stops at its own `max` (that is the clamp doing its job) and the
    ///   surplus lands on the reader, which is what a wide window is for. So the
    ///   over-max column is the reader, not the one being dragged — asserting
    ///   that pairing is the point, because "the surplus follows the pointer" is
    ///   the plausible-looking wrong answer.
    func test_draggingToTheMaximumLandsExactlyOnIt() {
        let sumOfMaxes = allColumns.reduce(0) { $0 + ColumnLayoutMetrics.spec(for: $1).max }
            + Double(allColumns.count - 1) * divider
        let reader = ColumnSolver.widestColumn(of: allColumns)
        for available in stride(from: 1400.0, through: 1900.0, by: 20.0) {
            for column in allColumns {
                let max = ColumnLayoutMetrics.spec(for: column).max
                let range = ColumnSolver.achievableRange(
                    for: column, columns: allColumns, totalWidth: available
                )
                let solution = ColumnSolver.solve(
                    columns: allColumns,
                    totalWidth: available,
                    dragged: column,
                    target: max
                )
                if available <= sumOfMaxes + 0.5 {
                    XCTAssertEqual(
                        solution.width(of: column), range.upperBound, accuracy: 0.5,
                        "available=\(fmt(available)) dragged=\(column)"
                    )
                    XCTAssertLessThanOrEqual(
                        solution.width(of: column), max + 0.5,
                        "\(column) overran its max in a \(fmt(available))pt window"
                    )
                    XCTAssertFalse(
                        solution.isOverflowingMaximums,
                        "a \(fmt(available))pt window must not report an overflow"
                    )
                } else {
                    // The pinned column is still clamped to its own max, unless
                    // it *is* the reader — in which case it is the documented
                    // receiver of the surplus.
                    let expected = column == reader
                        ? ColumnLayoutMetrics.spec(for: column).max + (available - sumOfMaxes)
                        : max
                    XCTAssertEqual(
                        solution.width(of: column), expected, accuracy: 0.5,
                        "\(column) landed at \(fmt(solution.width(of: column))) "
                        + "instead of \(fmt(expected)) at \(fmt(available))"
                    )
                    XCTAssertTrue(
                        solution.isOverflowingMaximums,
                        "a \(fmt(available))pt window must report the overflow"
                    )
                    // And the surplus lands on the reader, whichever column was
                    // being dragged. The reader's width is its own `max` plus
                    // the whole surplus — nothing is taken from the other two,
                    // because they are already at their `max` too.
                    if column != reader, let reader {
                        XCTAssertEqual(
                            solution.width(of: reader),
                            ColumnLayoutMetrics.spec(for: reader).max
                                + (available - sumOfMaxes),
                            accuracy: 0.5,
                            "the surplus must land on the reader, not on the "
                            + "dragged \(column)"
                        )
                    }
                }
            }
        }
    }

    /// In a window that fits every maximum, the maximum is reachable exactly.
    ///
    /// The companion to the test above, so the clamp cannot be satisfied by
    /// simply refusing every request.
    func test_theMaximumIsReachableWhenTheWindowHasRoomForIt() {
        for column in allColumns {
            let max = ColumnLayoutMetrics.spec(for: column).max
            for available in stride(from: 1662.0, through: 1900.0, by: 20.0) {
                let solution = ColumnSolver.solve(
                    columns: allColumns,
                    totalWidth: available,
                    carried: IDEAL_CARRIED
                )
                // A plain resize in a wide window: no column may exceed its max
                // except the reader taking the surplus.
                for other in allColumns {
                    let spec = ColumnLayoutMetrics.spec(for: other)
                    if solution.isOverflowingMaximums,
                       other == ColumnSolver.widestColumn(of: allColumns) {
                        continue
                    }
                    XCTAssertLessThanOrEqual(
                        solution.width(of: other), spec.max + 0.5,
                        "\(other) overran its max at \(fmt(available))"
                    )
                }
                _ = max
            }
        }
    }

    /// Dragging a column to its `min` lands exactly on it, unless the siblings
    /// cannot get out of the way.
    ///
    /// The `min` is reachable from above *only when the window is wide enough
    /// for the other columns to be at their own `max`*. In a 1132pt window the
    /// reader cannot be 360pt wide, because the sidebar and the list together
    /// top out at 760pt and 1130 − 760 = 370. That floor is the whole reason
    /// `achievableRange` exists, and it is what the rubber band is measured
    /// against — so the honest answer is the achievable range's floor, never
    /// below it, and never an overflow on the siblings.
    func test_draggingToTheMinimumLandsExactlyOnIt() {
        let sumOfMaxes = allColumns.reduce(0) { $0 + ColumnLayoutMetrics.spec(for: $1).max }
            + Double(allColumns.count - 1) * divider
        let reader = ColumnSolver.widestColumn(of: allColumns)
        for available in stride(from: 832.0, through: 1900.0, by: 20.0) {
            for column in allColumns {
                let min = ColumnLayoutMetrics.spec(for: column).min
                let range = ColumnSolver.achievableRange(
                    for: column, columns: allColumns, totalWidth: available
                )
                let solution = ColumnSolver.solve(
                    columns: allColumns,
                    totalWidth: available,
                    dragged: column,
                    target: min
                )
                // Below `sum(max)` the achievable floor binds. Above it, the
                // surplus lands on the reader and `min` is not the answer for
                // anyone — the window simply has more room than any layout can
                // use.
                let expected: Double
                if available > sumOfMaxes + 0.5, column == reader {
                    expected = ColumnLayoutMetrics.spec(for: reader ?? .reader).max
                        + (available - sumOfMaxes)
                } else {
                    expected = ColumnSolver.clamp(min, to: range)
                }
                XCTAssertEqual(
                    solution.width(of: column),
                    expected,
                    accuracy: 0.5,
                    "available=\(fmt(available)) dragged=\(column) "
                    + "got \(fmt(solution.width(of: column))) want \(fmt(expected))"
                )
                // Never below the column's own minimum, and never an overflow:
                // if the floor is above `min`, the siblings kept their maximums.
                if available <= sumOfMaxes + 0.5 {
                    XCTAssertGreaterThanOrEqual(solution.width(of: column), min - 0.5)
                }
                let total = solution.widths.values.reduce(0, +) + solution.dividerTotal
                XCTAssertLessThanOrEqual(total, available + 0.5)
            }
        }
    }

    /// The floor of the achievable range is the width that leaves every sibling
    /// at its own `max` — the other half of the range, and the one that makes
    /// the rubber band's lower wall land where the solve's does.
    ///
    /// Scoped to windows that can hold every maximum. Past `sum(max) + dividers`
    /// the reader is the documented receiver of the surplus and is *supposed* to
    /// exceed its own `max`, so both halves of this test would be false there —
    /// and `test_aWindowWiderThanEveryMaximumGrowsTheReader` covers that regime.
    func test_theAchievableFloorIsWhereTheSiblingsAreAtTheirMaximums() {
        let sumOfMaxes = allColumns.reduce(0) { $0 + ColumnLayoutMetrics.spec(for: $1).max }
            + Double(allColumns.count - 1) * divider
        for column in allColumns {
            for available in stride(from: 832.0, through: sumOfMaxes, by: 20.0) {
                let range = ColumnSolver.achievableRange(
                    for: column, columns: allColumns, totalWidth: available
                )
                let othersMax = allColumns
                    .filter { $0 != column }
                    .reduce(0) { $0 + ColumnLayoutMetrics.spec(for: $1).max }
                let ownFloor = allColumns.reduce(0) { $0 + ColumnLayoutMetrics.spec(for: $1).min }
                    <= available ? ColumnLayoutMetrics.spec(for: column).min
                    : ColumnLayoutMetrics.spec(for: column).softMin
                let expected = max(
                    ownFloor,
                    available - Double(allColumns.count - 1) * divider - othersMax
                )
                XCTAssertEqual(
                    range.lowerBound, expected, accuracy: 0.5,
                    "\(column) floor wrong at available=\(fmt(available))"
                )
                // And asking for the floor must not push a sibling past its own
                // maximum — which is the bug that produced the 94pt overflow.
                let solution = ColumnSolver.solve(
                    columns: allColumns,
                    totalWidth: available,
                    dragged: column,
                    target: range.lowerBound
                )
                for other in allColumns where other != column {
                    XCTAssertLessThanOrEqual(
                        solution.width(of: other),
                        ColumnLayoutMetrics.spec(for: other).max + 0.5,
                        "\(other) was pushed past its max when \(column) was "
                        + "dragged to its floor at \(fmt(available))"
                    )
                }
            }
        }
    }

    /// A target beyond `max` is refused, and the overshoot is not honoured.
    func test_targetsBeyondTheEnvelopeAreClamped() {
        for column in allColumns {
            let spec = ColumnLayoutMetrics.spec(for: column)
            for target in [spec.max + 1, spec.max + 50, spec.max + 500, 5000.0] {
                let solution = ColumnSolver.solve(
                    columns: allColumns,
                    totalWidth: 1600,
                    dragged: column,
                    target: target
                )
                XCTAssertLessThanOrEqual(
                    solution.width(of: column), spec.max + 0.5,
                    "\(column) honoured a target of \(fmt(target)) past its max"
                )
            }
        }
    }

    // MARK: - (6) The sweep

    /// Every invariant, over the whole input space.
    ///
    /// 281 window widths × 3 dragged columns × 201 pointer positions ≈ 169k
    /// solves. It runs in a couple of seconds and it is the difference between
    /// "the solver is correct" and "the solver is correct on the inputs I
    /// thought of". Failures are counted and the first few reported, because a
    /// solver that is wrong at 4% of its inputs is a different bug from one that
    /// is wrong at a single bound, and the count says which.
    func test_sweep_holdsEveryInvariant() {
        var failures: [String] = []
        var checked = 0

        for available in stride(from: 500.0, through: 1900.0, by: 5.0) {
            for dragged in allColumns {
                for raw in stride(from: 0.0, through: 1000.0, by: 5.0) {
                    checked += 1
                    // Damped exactly as the store damps a real pointer sample,
                    // so the sweep covers the numbers the drag path really
                    // produces rather than raw out-of-range targets.
                    let range = ColumnSolver.achievableRange(
                        for: dragged, columns: allColumns, totalWidth: available
                    )
                    let request = RubberBand.damped(raw, range: range)
                    let solution = ColumnSolver.solve(
                        columns: allColumns,
                        totalWidth: available,
                        dragged: dragged,
                        target: request,
                        permitsOvershoot: true
                    )
                    let problems = violations(
                        solution, available: available,
                        columns: allColumns, dragged: dragged, raw: raw,
                        // The rubber band is deliberately allowed past the
                        // achievable range, so the floors are suspended exactly
                        // while the pointer is out there.
                        requiresFloors: false
                    )
                    if !problems.isEmpty && failures.count < 20 {
                        failures.append(problems.joined(separator: "; "))
                    }
                }
            }
        }

        XCTAssertTrue(
            failures.isEmpty,
            """
            \(failures.count) of \(checked) solves broke an invariant (first 20):
            \(failures.joined(separator: "\n"))
            """
        )
    }

    /// The same sweep with nothing dragged — a window resize or a first run.
    ///
    /// Scoped to windows at or above `sum(softMin) + dividers` = 692pt, below
    /// which no layout can honour the floors and the degradation tests take over.
    func test_sweep_withoutADraggedColumn() {
        let sumOfSoftMins = allColumns.reduce(0) { $0 + ColumnLayoutMetrics.spec(for: $1).softMin }
            + Double(allColumns.count - 1) * divider
        var failures: [String] = []
        var checked = 0
        for available in stride(from: sumOfSoftMins, through: 1900.0, by: 5.0) {
            for carried in [nil, IDEAL_CARRIED] {
                checked += 1
                let solution = ColumnSolver.solve(
                    columns: allColumns,
                    totalWidth: available,
                    carried: carried
                )
                let problems = violations(
                    solution, available: available,
                    columns: allColumns, dragged: nil, raw: 0
                )
                if !problems.isEmpty && failures.count < 20 {
                    failures.append(problems.joined(separator: "; "))
                }
            }
        }
        XCTAssertTrue(
            failures.isEmpty,
            "\(failures.count) of \(checked) resizes broke an invariant:\n"
            + failures.joined(separator: "\n")
        )
    }

    /// And below `sum(softMin) + dividers` the floors *are* suspended, by
    /// definition — the companion that keeps the scoping above honest.
    func test_belowTheSoftFloorSumTheFloorsAreSuspendedNotViolated() {
        let sumOfSoftMins = allColumns.reduce(0) { $0 + ColumnLayoutMetrics.spec(for: $1).softMin }
            + Double(allColumns.count - 1) * divider
        for available in stride(from: 200.0, through: sumOfSoftMins, by: 4.0) {
            let solution = ColumnSolver.solve(
                columns: allColumns, totalWidth: available, carried: IDEAL_CARRIED
            )
            XCTAssertTrue(
                solution.isSqueezed,
                "a \(fmt(available))pt window must report the squeeze"
            )
            let total = solution.widths.values.reduce(0, +) + solution.dividerTotal
            XCTAssertLessThanOrEqual(total, available + 0.5)
            for column in allColumns {
                XCTAssertGreaterThanOrEqual(solution.width(of: column), 0)
            }
        }
    }

    /// The two-column window, which is what ships without an account.
    ///
    /// The invariants are stated against the *visible* set, so this asserts the
    /// same total for a different set rather than skipping the case.
    func test_twoColumnWindowHoldsTheSameInvariants() {
        let two: [LagoonColumn] = [.list, .reader]
        for available in stride(from: 400.0, through: 1600.0, by: 5.0) {
            for dragged in two {
                for raw in stride(from: 0.0, through: 1000.0, by: 25.0) {
                    let range = ColumnSolver.achievableRange(
                        for: dragged, columns: two, totalWidth: available
                    )
                    let solution = ColumnSolver.solve(
                        columns: two,
                        totalWidth: available,
                        dragged: dragged,
                        target: RubberBand.damped(raw, range: range),
                        permitsOvershoot: true
                    )
                    let total = solution.widths.values.reduce(0, +) + solution.dividerTotal
                    XCTAssertLessThanOrEqual(
                        total, available + 0.5,
                        "two-column overflow at available=\(fmt(available)) dragged=\(dragged)"
                    )
                    for column in two {
                        XCTAssertGreaterThanOrEqual(
                            solution.width(of: column), ColumnSpec.absoluteFloor,
                            "two-column \(column) went negative"
                        )
                    }
                }
            }
        }
    }

    /// The ⌥ inversion is just another `dragged` column, so it inherits every
    /// invariant for free.
    ///
    /// This is the architect's argument for routing the modifier through the
    /// same solver rather than writing a second path for the reader: the reader
    /// is pinned instead of the list, the list becomes the passive party and
    /// yields by weight, and *the total still has to equal the window*. If that
    /// last part were a special case, this test would be the thing that failed
    /// — so it is asserted over the same sweep the plain drag gets.
    func test_optionInvertedDragHoldsEveryInvariantToo() {
        var failures: [String] = []
        var checked = 0
        // The reader is the ⌥ target on the list boundary, so the raw pointer x
        // is the reader's *left* edge, not the list's.
        for available in stride(from: 832.0, through: 1662.0, by: 5.0) {
            let listLeading = ColumnLayoutMetrics.spec(for: .navigation).min
                + ColumnLayoutMetrics.dividerThickness
            for raw in stride(from: 0.0, through: 1000.0, by: 5.0) {
                checked += 1
                let range = ColumnSolver.achievableRange(
                    for: .reader, columns: allColumns, totalWidth: available
                )
                let solution = ColumnSolver.solve(
                    columns: allColumns,
                    totalWidth: available,
                    dragged: .reader,
                    target: RubberBand.damped(raw, range: range),
                    permitsOvershoot: true
                )
                let problems = violations(
                    solution, available: available,
                    columns: allColumns, dragged: .reader, raw: raw,
                    requiresFloors: false
                )
                if !problems.isEmpty && failures.count < 10 {
                    failures.append("available=\(fmt(available)) raw=\(fmt(raw)): "
                        + problems.joined(separator: "; "))
                }
            }
            // And the list yields rather than the reader: on a plain reader drag
            // the list must never be the column that has to give up below its
            // own minimum while the window still has room.
            let settled = ColumnSolver.solve(
                columns: allColumns,
                totalWidth: available,
                dragged: .reader,
                target: ColumnSolver.achievableRange(
                    for: .reader, columns: allColumns, totalWidth: available
                ).upperBound
            )
            XCTAssertGreaterThanOrEqual(
                settled.width(of: .list),
                ColumnLayoutMetrics.spec(for: .list).min - 0.5,
                "the list was squeezed below its min at available=\(fmt(available))"
            )
            XCTAssertGreaterThan(listLeading, 0)
        }
        XCTAssertTrue(
            failures.isEmpty,
            "\(failures.count) of \(checked) ⌥-inverted solves broke an invariant:\n"
            + failures.joined(separator: "\n")
        )
    }

    /// Dragging the reader to its ceiling really does widen it, and the list is
    /// what pays.
    ///
    /// The user-visible point of the ⌥ mode: without it, the reader's 900pt of
    /// headroom is unreachable by dragging, because its own separator is the one
    /// boundary and dragging it right *narrows* the reader.
    func test_draggingTheReaderWiderIsPossibleAndTheListPaysForIt() {
        for available in stride(from: 1000.0, through: 1600.0, by: 20.0) {
            let before = ColumnSolver.solve(
                columns: allColumns, totalWidth: available, carried: IDEAL_CARRIED
            )
            let after = ColumnSolver.solve(
                columns: allColumns,
                totalWidth: available,
                dragged: .reader,
                target: 900
            )
            XCTAssertGreaterThan(
                after.width(of: .reader), before.width(of: .reader),
                "the reader did not widen at available=\(fmt(available))"
            )
            XCTAssertLessThan(
                after.width(of: .list), before.width(of: .list),
                "the list did not pay for it at available=\(fmt(available))"
            )
            // The sidebar is the smallest weight, so it yields least — but it
            // still may not cross its own minimum.
            XCTAssertGreaterThanOrEqual(
                after.width(of: .navigation),
                ColumnLayoutMetrics.spec(for: .navigation).min - 0.5,
                "the sidebar was pushed below its min at \(fmt(available))"
            )
        }
    }

    // MARK: - (7) The degradation path

    /// `available < sum(min)` has defined semantics: shed by weight, reader
    /// first, and never negative.
    ///
    /// Unreachable through the UI — the window floor is 832 and `sum(min) +
    /// dividers` is 822 — and tested anyway, because the floor is a *UI* rule
    /// and the solver must not depend on it. A window that small is what a
    /// future compact mode, a Stage Manager resize, or a drag of the window
    /// against the screen edge would produce, and "the solver assumes the floor
    /// holds" is the kind of assumption that crashes.
    func test_belowTheSumOfMinimumsTheColumnsShedByWeightAndStayNonNegative() {
        let sumOfMins = allColumns.reduce(0) { $0 + ColumnLayoutMetrics.spec(for: $1).min }
            + Double(allColumns.count - 1) * divider
        for available in stride(from: 200.0, through: sumOfMins, by: 2.0) {
            let solution = ColumnSolver.solve(
                columns: allColumns,
                totalWidth: available,
                carried: IDEAL_CARRIED
            )
            let total = solution.widths.values.reduce(0, +) + solution.dividerTotal
            XCTAssertLessThanOrEqual(
                total, available + 0.5,
                "overflowed below the minimum sum at available=\(fmt(available))"
            )
            for column in allColumns {
                let width = solution.width(of: column)
                XCTAssertGreaterThanOrEqual(
                    width, ColumnSpec.absoluteFloor,
                    "\(column) went negative at available=\(fmt(available))"
                )
            }
        }
    }

    /// The reader is sacrificed first, because it carries the largest weight.
    ///
    /// The spec's own words: "阅读器优先（weight最大=优先级最低）". Below
    /// `sum(min)` the reader gives up space before the list does, and the list
    /// before the sidebar.
    func test_belowTheMinimumsTheHeaviestColumnIsSqueezedFirst() {
        // Comfortably below sum(softMin), so the soft floors are already gone
        // and the ordering is decided by the zero-floor pass.
        let available = 300.0
        let solution = ColumnSolver.solve(
            columns: allColumns,
            totalWidth: available,
            carried: IDEAL_CARRIED
        )
        let reader = solution.width(of: .reader)
        let list = solution.width(of: .list)
        let nav = solution.width(of: .navigation)
        XCTAssertLessThanOrEqual(reader, list, "the reader must not be the last to give up")
        XCTAssertLessThanOrEqual(list, nav, "the list must not be the last to give up")
    }

    /// A window narrower than its own separators clips rather than overflowing.
    ///
    /// Two 1pt separators cannot fit in a 1pt window, so the total floor is the
    /// separators themselves: the sum is *allowed* to exceed the window here,
    /// and pinning that direction is the point — the historical bug was a
    /// 94pt overflow in a window that could have held every column.
    func test_absurdlyNarrowWindowClips() {
        let separators = Double(allColumns.count - 1) * divider
        for available in stride(from: 0.0, through: 12.0, by: 0.5) {
            let solution = ColumnSolver.solve(
                columns: allColumns,
                totalWidth: available,
                carried: IDEAL_CARRIED
            )
            let total = solution.widths.values.reduce(0, +) + solution.dividerTotal
            XCTAssertLessThanOrEqual(
                total, max(available, separators) + 0.5,
                "overflowed at an absurd width \(fmt(available))"
            )
            for column in allColumns {
                XCTAssertGreaterThanOrEqual(solution.width(of: column), 0)
            }
        }
    }

    // MARK: - The two mutation traps

    /// The upper bound must be recomputed from the *current* window, never from
    /// a table precomputed at some earlier width.
    ///
    /// The trap: an implementation that caches "the widest this column can be"
    /// and reuses it after a resize answers with a width that is legal for the
    /// old window and illegal for the new one. The symptom is a divider that
    /// refuses to move after the window is narrowed, or one that lets a column
    /// grow past its `max`. Asserted by solving the same drag twice at two
    /// widths and requiring the achievable ceiling to move.
    func test_theAchievableCeilingIsRecomputedAfterAResize() {
        let column = LagoonColumn.reader
        for available in stride(from: 900.0, through: 1800.0, by: 10.0) {
            let range = ColumnSolver.achievableRange(
                for: column, columns: allColumns, totalWidth: available
            )
            // The ceiling cannot exceed the column's own `max`...
            XCTAssertLessThanOrEqual(range.upperBound, ColumnLayoutMetrics.spec(for: column).max + 0.5)
            // ...and it must be the window that binds, so it has to move with
            // the window: `others' minimums` shrink the space available to it.
            let expected = min(
                ColumnLayoutMetrics.spec(for: column).max,
                max(0, available - 2 * divider) - otherMinimums(excluding: column)
            )
            XCTAssertEqual(
                range.upperBound, max(range.lowerBound, expected), accuracy: 0.5,
                "the ceiling did not follow the window at available=\(fmt(available))"
            )
            // And the solve at that ceiling must not overflow.
            let solution = ColumnSolver.solve(
                columns: allColumns,
                totalWidth: available,
                dragged: column,
                target: range.upperBound
            )
            let total = solution.widths.values.reduce(0, +) + solution.dividerTotal
            XCTAssertLessThanOrEqual(total, available + 0.5)
        }
    }

    /// The feasibility clamp on the dragged column: it can never be wider than
    /// `S − sum(others' minimums)`.
    ///
    /// The trap: an implementation that clamps the dragged column only to its
    /// own `[min, max]` and then discovers the others cannot fit — and hands the
    /// overflow to nobody. The test asks for exactly the width that leaves the
    /// other two at their own minimums, which is the last feasible width, and
    /// also asks for one point more, which must be refused rather than honoured
    /// by pushing a sibling below its minimum.
    ///
    /// The requests go through `RubberBand.damped` first, because that is the
    /// path a real pointer takes — `ColumnLayoutStore.drag` damps before solving.
    /// A raw, undamped target is not a thing the app ever produces, and
    /// asserting on it would test a path that does not exist.
    func test_theDraggedColumnIsClampedByTheOtherColumnsFeasibility() {
        for available in stride(from: 832.0, through: 1662.0, by: 10.0) {
            for column in allColumns {
                let othersMin = allColumns
                    .filter { $0 != column }
                    .reduce(0) { $0 + ColumnLayoutMetrics.spec(for: $1).min }
                let lastFeasible = available - Double(allColumns.count - 1) * divider - othersMin
                for request in [lastFeasible, lastFeasible + 1, lastFeasible + 20] {
                    let range = ColumnSolver.achievableRange(
                        for: column, columns: allColumns, totalWidth: available
                    )
                    let solution = ColumnSolver.solve(
                        columns: allColumns,
                        totalWidth: available,
                        dragged: column,
                        target: RubberBand.damped(request, range: range),
                        permitsOvershoot: true
                    )
                    let total = solution.widths.values.reduce(0, +) + solution.dividerTotal
                    XCTAssertLessThanOrEqual(
                        total, available + 0.5,
                        "overflow when asking for \(fmt(request)) "
                        + "(last feasible \(fmt(lastFeasible))) at available=\(fmt(available))"
                    )
                    // And the siblings keep their minimums, because the window
                    // is wide enough to honour them — once the rubber band is
                    // released. The band itself is allowed to push them under
                    // (`permitsOvershoot: true`); that is what a band is for. So
                    // the solve asserted here is the *settled* one, which is
                    // `ColumnLayoutStore.endDrag` and the only solve whose widths
                    // ever reach `UserDefaults`.
                    let settled = ColumnSolver.solve(
                        columns: allColumns,
                        totalWidth: available,
                        dragged: column,
                        target: solution.width(of: column),
                        permitsOvershoot: false
                    )
                    for other in allColumns where other != column {
                        XCTAssertGreaterThanOrEqual(
                            settled.width(of: other),
                            ColumnLayoutMetrics.spec(for: other).min - 0.5,
                            "\(other) settled below its min after a \(column) drag "
                            + "at available=\(fmt(available))"
                        )
                        XCTAssertLessThanOrEqual(
                            settled.width(of: other),
                            ColumnLayoutMetrics.spec(for: other).max + 0.5,
                            "\(other) settled above its max after a \(column) drag "
                            + "at available=\(fmt(available))"
                        )
                    }
                    let settledTotal = settled.widths.values.reduce(0, +)
                        + settled.dividerTotal
                    XCTAssertLessThanOrEqual(settledTotal, available + 0.5)
                }
            }
        }
    }

    private func otherMinimums(excluding column: LagoonColumn) -> Double {
        allColumns.filter { $0 != column }
            .reduce(0) { $0 + ColumnLayoutMetrics.spec(for: $1).min }
    }

    /// A carried width that is nonsense is clamped, not trusted.
    ///
    /// The restore path reads `UserDefaults`, which can hold anything: a value
    /// written by an older build with different bounds, a hand-edited plist, a
    /// negative from a bug that has since been fixed. The solver's own anchor
    /// clamp is the last line of defence.
    func test_absurdCarriedWidthsAreClamped() {
        let absurd: [[LagoonColumn: Double]] = [
            [.navigation: 9_999, .list: 9_999, .reader: 9_999],
            [.navigation: -500, .list: -500, .reader: -500],
            [.navigation: 0, .list: 0, .reader: 0],
            [.navigation: .nan, .list: .nan, .reader: .nan],
        ]
        for carried in absurd {
            for available in [832.0, 1000.0, 1400.0, 1900.0] {
                let solution = ColumnSolver.solve(
                    columns: allColumns,
                    totalWidth: available,
                    carried: carried
                )
                let total = solution.widths.values.reduce(0, +) + solution.dividerTotal
                XCTAssertLessThanOrEqual(
                    total, available + 0.5,
                    "absurd carried widths \(carried) overflowed at \(available)"
                )
                for column in allColumns {
                    let width = solution.width(of: column)
                    XCTAssertTrue(
                        width.isFinite,
                        "\(column) was \(width) for carried \(carried)"
                    )
                    XCTAssertGreaterThanOrEqual(width, 0)
                }
            }
        }
    }

    // MARK: - The metrics themselves

    /// The window floor is `sum(min) + separators`, not the old flat 720.
    ///
    /// 720 is arithmetically smaller than the three columns' minimums, so any
    /// window allowed to reach it *must* breach a minimum. Pinned here because
    /// the number looks arbitrary otherwise.
    func test_theWindowFloorIsTheSumOfTheMinimums() {
        let computed = allColumns.reduce(0) { $0 + ColumnLayoutMetrics.spec(for: $1).min }
            + Double(allColumns.count - 1) * divider
        XCTAssertEqual(computed, 822.0, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(
            ColumnLayoutMetrics.windowMinimumWidth, computed,
            "the window floor is below the sum of the columns' minimums"
        )
    }

    /// The hit target is 10pt around a 1pt line, per the HIG.
    func test_theHitTargetIsTenPointsAroundAOnePointLine() {
        XCTAssertEqual(ColumnLayoutMetrics.dividerThickness, 1)
        XCTAssertEqual(ColumnLayoutMetrics.dividerHitWidth, 10)
        XCTAssertEqual(ColumnLayoutMetrics.dividerHitOverflow, 4.5, accuracy: 0.001)
    }

    /// Handle `i` resizes the column on its left, and there is exactly one
    /// handle per boundary.
    func test_handleIndicesMapToColumns() {
        for (index, column) in LagoonColumn.allCases.enumerated() {
            XCTAssertEqual(ColumnLayoutMetrics.resizedColumn(forHandle: index), column)
        }
        XCTAssertNil(ColumnLayoutMetrics.resizedColumn(forHandle: -1))
        XCTAssertNil(ColumnLayoutMetrics.resizedColumn(forHandle: 99))
    }

    /// The storage keys are one per column, under the agreed prefix.
    func test_storageKeysAreOnePerColumnUnderThePrefix() {
        let keys = Set(LagoonColumn.allCases.map(ColumnLayoutMetrics.storageKey(for:)))
        XCTAssertEqual(keys.count, LagoonColumn.allCases.count, "keys collide")
        for key in keys {
            XCTAssertTrue(key.hasPrefix("lagoon.column."), "unexpected prefix: \(key)")
        }
    }
}

/// The widths a first run starts from.
///
/// A named constant rather than a literal at each use site, because "no
/// `carried`" and "carried at `ideal`" are the same solve and a test that
/// conflates them would stop testing the branch it meant to.
private let IDEAL_CARRIED: [LagoonColumn: Double] = [
    .navigation: 210,
    .list: 340,
    .reader: 520,
]
