import Foundation

/// The three-column width solver.
///
/// ## Why this is a single redistribution and not an iteration
///
/// The obvious implementation — repeatedly re-share the free space until no
/// column moves — was measured failing on every input
/// (`docs/三栏宽度求解器-实测结论.md`): dragging the reader to its maximum in a
/// 1000pt window produced `[94, 94, 900]`, 94pt wider than the window, with two
/// columns *below their own minimum*. The iteration's convergence depends on
/// deciding which columns are frozen, and with three simultaneous clamps that
/// decision contradicts itself: a column frozen at its minimum in one pass is a
/// candidate for release in the next.
///
/// So there is no fixed point here, and the solve is four steps:
///
/// 1. **Anchor.** The dragged column is pinned at the pointer's damped width,
///    clamped to what the window can *actually* honour — not merely to its own
///    `[min, max]`, because widening the list is also limited by the reader's
///    `max`. Every other column is anchored at the width it already has, so a
///    layout the user set by hand survives the next drag instead of snapping to
///    a canonical shape.
/// 2. **Delta.** `available − dividers − Σ(anchors)`. Positive is space to hand
///    out, negative is space to take back. Nothing else needs deciding.
/// 3. **Redistribute the delta by weight**, freezing any column that would cross
///    a bound and re-sharing only the remainder. Each pass freezes at least one
///    column, so the loop is bounded by the column count and always terminates;
///    there is nothing to converge.
/// 4. **Bend the soft floors only if the delta is still not placed.** Taking
///    space back stops at `softMin`; past that the columns give it up in
///    descending weight (the reader pays first) and finally down to zero. A
///    negative width is never a legal answer.
///
/// ## The one line worth reviewing first
///
/// Step 3's bookkeeping. A frozen column is subtracted at the width it
/// *actually took*, never at the share it was *offered*. Subtracting the offer
/// is an off-by-`over` that inflates the total, and it is exactly what made the
/// probe's numbers come out 94pt too wide.
///
/// ## The one documented exception to "no column exceeds its max"
///
/// `sum(max) + dividers` is 1662pt. A window wider than that cannot have every
/// column inside its envelope *and* have the total match the window — the two
/// invariants are jointly unsatisfiable past that width. Rather than silently
/// overflowing the window (the historical bug) or silently leaving a gap, the
/// surplus goes to the reader — a wide window existing for the reading pane is
/// the whole reason to allow it — and `isOverflowingMaximums` says so. A *drag*
/// can never cause it: `achievableRange` caps the dragged column at its own
/// `max`, so only a window resize reaches this case.
enum ColumnSolver {
    /// Anything below this is arithmetic noise, not a width.
    ///
    /// Well above the accumulation error of three doubles and well below a
    /// hundredth of a point, so a real 0.4pt violation still fails the
    /// invariant tests instead of being quietly absorbed.
    static let epsilon = 1e-9

    /// A solved layout.
    struct Solution: Equatable {
        /// Width per column.
        var widths: [LagoonColumn: Double]
        /// Sum of the separators between the columns.
        var dividerTotal: Double
        /// The width the solve was asked to fill.
        var totalWidth: Double
        /// The column being resized, if this solve is a drag.
        var dragged: LagoonColumn?
        /// True when some column ended up below its `min` because the window
        /// could not honour every minimum.
        var isSqueezed: Bool
        /// True when the window was wider than every column's `max` together,
        /// so the surplus had to land on the reader past its `max`. See the type
        /// comment — this is the single documented exception to the envelope.
        var isOverflowingMaximums: Bool

        /// Width of one column, or zero when it is not part of this solve.
        func width(of column: LagoonColumn) -> Double {
            widths[column] ?? 0
        }

        /// The invariants the test suite asserts, in one place so the tests and
        /// the solver cannot end up stating them differently.
        ///
        /// The total is checked as `<=` rather than `==` in one case: a window
        /// narrower than its own separators cannot be filled, because the
        /// separators alone are wider than the window. The columns clip to zero
        /// and the sum is honestly *less* than the window, which is the only
        /// legal answer — the alternative is drawing outside the window.
        func isConsistent() -> Bool {
            let total = widths.values.reduce(0, +) + dividerTotal
            guard totalWidth >= dividerTotal - epsilon else { return true }
            return abs(total - totalWidth) < 0.5
        }
    }

    /// Solves the columns for a window of `totalWidth`.
    ///
    /// - Parameters:
    ///   - columns: the visible columns, in layout order. Two when there is no
    ///     account (the navigation column has nothing to navigate), three
    ///     otherwise. The invariants are stated against the *visible* set, so a
    ///     window without a sidebar cannot fail a test written for one with it.
    ///   - totalWidth: the container's width, separators included.
    ///   - dragged: the column being resized, if this solve is a drag.
    ///   - target: the width that column was asked for, already damped by
    ///     `RubberBand` and pre-clamp by the caller.
    ///   - carried: the widths to anchor the undragged columns at. Absent means
    ///     "start from `ideal`", which is the first-run case.
    ///   - permitsOvershoot: let the dragged column sit outside the achievable
    ///     range for the rubber band. It widens only that column's acceptance;
    ///     the compensation still lands inside the others' bounds, and
    ///     `ColumnLayoutStore.endDrag` re-solves without it.
    static func solve(
        columns: [LagoonColumn],
        totalWidth: Double,
        dragged: LagoonColumn? = nil,
        target: Double? = nil,
        carried: [LagoonColumn: Double]? = nil,
        permitsOvershoot: Bool = false
    ) -> Solution {
        precondition(!columns.isEmpty, "a split view with no columns has no widths")
        let dividerTotal = Double(max(0, columns.count - 1)) * ColumnLayoutMetrics.dividerThickness
        let budget = totalWidth - dividerTotal
        var widths: [LagoonColumn: Double] = [:]
        widths.reserveCapacity(columns.count)

        // Step 1 — anchor. ------------------------------------------------------
        var pinned: LagoonColumn?
        if let dragged, let target, columns.contains(dragged) {
            // Clamped to the *achievable* range, which is the tightest legal
            // answer. Clamping to the column's own `[min, max]` instead would
            // let a drag push a sibling past its `max` — and then the
            // rubber band's wall and the solve's wall would be in different
            // places, so the user would feel the divider stop somewhere the
            // layout had not.
            let range = achievableRange(for: dragged, columns: columns, totalWidth: totalWidth)
            if permitsOvershoot {
                let slack = ColumnLayoutMetrics.rubberBandCap
                widths[dragged] = clamp(target, to: (range.lowerBound - slack)...(range.upperBound + slack))
            } else {
                widths[dragged] = clamp(target, to: range)
            }
            pinned = dragged
        }
        for column in columns where widths[column] == nil {
            let spec = ColumnLayoutMetrics.spec(for: column)
            let anchor = carried?[column] ?? spec.ideal
            widths[column] = clamp(anchor, to: spec.min...spec.max)
        }

        // Step 2/3 — hand out or take back the difference. ----------------------
        let free = columns.filter { $0 != pinned }
        let result = redistribute(
            anchors: widths,
            free: free,
            budget: max(0, budget - (pinned.map { widths[$0] ?? 0 } ?? 0)),
            permitsSoftFloors: permitsOvershoot
        )
        for (column, width) in result.widths {
            widths[column] = width
        }

        // Step 4 — a surplus nothing can absorb goes to the reader. -------------
        var overflowing = result.overflowing
        if result.leftover > epsilon, let absorber = widest(of: columns) {
            widths[absorber, default: 0] += result.leftover
            overflowing = true
        }

        // Last: a pinned column can on its own exceed the window — the window
        // was resized under an in-flight rubber band. By now the free columns
        // are already at zero, so the pinned one has to give the rest back or
        // the layout overflows. Bounded by zero, never by a negative width.
        var squeezed = result.squeezed
        if let pinned, widths[pinned] ?? 0 > budget {
            widths[pinned] = max(0, budget)
            squeezed = true
        }

        // Belt and braces. The algebra above cannot produce a negative width,
        // but the invariant is cheap to state and a violation should surface
        // here rather than as a flipped drawing three layers up.
        for column in columns {
            widths[column] = max(ColumnSpec.absoluteFloor, widths[column] ?? 0)
        }

        return Solution(
            widths: widths,
            dividerTotal: dividerTotal,
            totalWidth: totalWidth,
            dragged: dragged,
            isSqueezed: squeezed,
            isOverflowingMaximums: overflowing
        )
    }

    // MARK: - Redistribution

    private struct Redistribution {
        var widths: [LagoonColumn: Double] = [:]
        /// Space that could not be placed inside any bound. Non-negative, and
        /// non-zero only when every free column is at a hard limit.
        var leftover: Double = 0
        var squeezed = false
        var overflowing = false
    }

    /// Moves `budget` across the free columns, starting from `anchors`.
    ///
    /// Positive headroom is shared by weight, freezing a column that would
    /// exceed its `max` and re-sharing the remainder. A shortfall is taken by
    /// weight the same way, but each column stops at `softMin` first; the part
    /// that survives after every column is on its soft floor is then taken in
    /// descending weight order (the reader pays before the list, the list
    /// before the sidebar) and finally down to zero.
    private static func redistribute(
        anchors: [LagoonColumn: Double],
        free: [LagoonColumn],
        budget: Double,
        permitsSoftFloors: Bool
    ) -> Redistribution {
        var out = Redistribution()
        guard !free.isEmpty else {
            out.leftover = max(0, budget)
            return out
        }
        var current: [LagoonColumn: Double] = [:]
        for column in free {
            let spec = ColumnLayoutMetrics.spec(for: column)
            current[column] = clamp(anchors[column] ?? spec.ideal, to: spec.min...spec.max)
        }
        var delta = budget - current.values.reduce(0, +)

        // Grow: share by weight, freezing anyone who would pass their `max`.
        var growing = free.sorted { $0.rawValue < $1.rawValue }
        var pass = 0
        while delta > epsilon, !growing.isEmpty, pass <= growing.count {
            pass += 1
            let totalWeight = growing.reduce(0) { $0 + ColumnLayoutMetrics.spec(for: $1).weight }
            guard totalWeight > epsilon else { break }
            var frozen: [LagoonColumn] = []
            for column in growing {
                let spec = ColumnLayoutMetrics.spec(for: column)
                let offer = delta * spec.weight / totalWeight
                if (current[column] ?? 0) + offer > spec.max + epsilon { frozen.append(column) }
            }
            if frozen.isEmpty {
                for column in growing {
                    let spec = ColumnLayoutMetrics.spec(for: column)
                    current[column] = (current[column] ?? 0) + delta * spec.weight / totalWeight
                }
                delta = 0
                break
            }
            // Subtract what each frozen column *actually* consumed, not the
            // share it was offered. This is the off-by-over that used to
            // inflate every total.
            for column in frozen {
                let spec = ColumnLayoutMetrics.spec(for: column)
                delta -= max(0, spec.max - (current[column] ?? 0))
                current[column] = spec.max
            }
            let frozenSet = Set(frozen)
            growing.removeAll { frozenSet.contains($0) }
        }
        if delta > epsilon {
            out.leftover = delta
            out.overflowing = true
        }

        // Shrink: share by weight, freezing at each column's `min`.
        //
        // `min` is the floor, not `softMin`. Freezing at `softMin` instead — the
        // obvious reading of "the soft floor is where shrinking stops" — lets a
        // perfectly ordinary resize put the list at 252pt in an 832pt window,
        // 28pt under its own 280pt minimum, while there were 10pt of slack and a
        // sibling that could have given up less. `softMin` is the floor for the
        // *degraded* regime, and the only way into that regime is
        // `sum(min) > budget` — which is computed once, here, rather than
        // per-column, because whether the window can honour the minimums is a
        // property of the window and not of any one column.
        //
        // The `permitsSoftFloors` flag carries the rubber band's intent: while
        // the pointer is out past a limit the user is *asking* for the squeeze,
        // and the band is bounded by `rubberBandCap` anyway.
        let sumOfMins = free.reduce(0) { $0 + ColumnLayoutMetrics.spec(for: $1).min }
        let canHonourMins = permitsSoftFloors || sumOfMins <= budget + epsilon
        var shrinking = free.sorted { $0.rawValue < $1.rawValue }
        var shrinkPass = 0
        while delta < -epsilon, !shrinking.isEmpty, shrinkPass <= shrinking.count {
            shrinkPass += 1
            let need = -delta
            let totalWeight = shrinking.reduce(0) { $0 + ColumnLayoutMetrics.spec(for: $1).weight }
            guard totalWeight > epsilon else { break }
            var frozen: [LagoonColumn] = []
            for column in shrinking {
                let spec = ColumnLayoutMetrics.spec(for: column)
                let floor = canHonourMins ? spec.min : spec.softMin
                let share = need * spec.weight / totalWeight
                if (current[column] ?? 0) - share < floor - epsilon { frozen.append(column) }
            }
            if frozen.isEmpty {
                for column in shrinking {
                    let spec = ColumnLayoutMetrics.spec(for: column)
                    let floor = canHonourMins ? spec.min : spec.softMin
                    current[column] = max(floor, (current[column] ?? 0) - need * spec.weight / totalWeight)
                }
                delta = 0
                break
            }
            for column in frozen {
                let spec = ColumnLayoutMetrics.spec(for: column)
                let floor = canHonourMins ? spec.min : spec.softMin
                let available = max(0, (current[column] ?? 0) - floor)
                delta += available
                current[column] = floor
                if available > epsilon { out.squeezed = !canHonourMins }
            }
            let frozenSet = Set(frozen)
            shrinking.removeAll { frozenSet.contains($0) }
        }

        // Past every soft floor the window is outside what the product
        // promises (the spec puts that at 720pt, and `sum(softMin) + dividers`
        // is 692). Give the rest up in priority order, and never past zero: a
        // negative width would be a crash, not a layout.
        if delta < -epsilon {
            var remaining = -delta
            for column in bySacrificePriority(free) {
                guard remaining > epsilon else { break }
                let available = max(0, current[column] ?? 0)
                let taken = min(available, remaining)
                current[column] = available - taken
                remaining -= taken
                if taken > epsilon { out.squeezed = true }
            }
            // Whatever is still unplaced cannot be taken from anyone. The pinned
            // column keeps it — and its own clamp above already guarantees the
            // result fits the window, so there is nothing to do here.
        }

        for (column, width) in current {
            out.widths[column] = max(ColumnSpec.absoluteFloor, width)
        }
        return out
    }

    // MARK: - Bounds

    /// The range of widths a dragged column can actually take in this window.
    ///
    /// The tightest legal answer, and the reason the rubber band's wall and the
    /// solve's wall are the same place:
    ///
    /// * the upper bound is the column's `max`, **and** the width that leaves
    ///   every other column at its own `min`;
    /// * the lower bound is the column's `min`, **and** the width that leaves
    ///   every other column at its own `max`.
    ///
    /// The second half matters more than it looks: it is why dragging the list
    /// leftward eventually stops rather than forcing the reader past 900pt. And
    /// because the dragged column is then never the one the deficit path has to
    /// shave, the pointer never fights itself.
    static func achievableRange(
        for column: LagoonColumn,
        columns: [LagoonColumn],
        totalWidth: Double
    ) -> ClosedRange<Double> {
        let spec = ColumnLayoutMetrics.spec(for: column)
        let dividerTotal = Double(max(0, columns.count - 1)) * ColumnLayoutMetrics.dividerThickness
        let others = columns.filter { $0 != column }
        let space = max(0, totalWidth - dividerTotal)
        let sum = { (keyPath: KeyPath<ColumnSpec, Double>) in
            others.reduce(0) { $0 + ColumnLayoutMetrics.spec(for: $1)[keyPath: keyPath] }
        }

        // The other columns' *guaranteed* floor: what they are owed before this
        // column gets anything.
        //
        // Two regimes, and getting the second one wrong is invisible. Normally
        // the window is wide enough for the others' `min`s and that is what they
        // are guaranteed. Below `sum(min) + dividers` the window cannot honour
        // the `min`s at all, and then the guarantee degrades to their
        // `softMin`s — the spec's "按优先级依次突破 softMin".
        let othersFloor = sum(\.min) <= space - spec.softMin ? sum(\.min) : sum(\.softMin)

        // Symmetrically, how much the others could *give back*: their `max` when
        // the window has room for this column to hold its own `min`, and their
        // `softMin` sum when it does not — in which case even their maximums
        // cannot be afforded alongside this column's minimum, and pretending
        // otherwise would put the floor above a width the window cannot hold.
        let othersCeiling = sum(\.min) <= space - spec.min ? sum(\.max) : sum(\.softMin)

        // This column's own floor, which is the same regime question applied to
        // itself — and the reason the two are not simply `min` and `softMin`
        // unconditionally.
        //
        // The failure this prevents: flooring the range at `min` even when the
        // window cannot afford it. At 692pt — exactly `sum(softMin) + dividers`,
        // where the only legal layout is 150/240/300 — flooring the reader at its
        // 360pt `min` leaves 330pt for two columns that need 390, so the deficit
        // has to come out of a *sibling*'s soft floor, landing the list at 180
        // (the sidebar's `min`) while the reader holds 360 it cannot afford. The
        // user dragged the reader; the reader is the one that should have given.
        let sumOfMins = sum(\.min) + spec.min
        let ownFloor = sumOfMins <= space ? spec.min : spec.softMin

        // The floor is the narrowest this column can be while the others are
        // still inside their envelopes — `space − othersCeiling`, but never below
        // this column's own floor and never above its own `max`.
        //
        // The outer `min(...)` is load-bearing at the top end: in a window wider
        // than `sum(max) + dividers` the figure comes out *above* this column's
        // `max`, and without the cap the range would come back as `[338, 338]`
        // for a 170pt-wide sidebar — so dragging it would pin it 38pt past the
        // 300pt maximum with nowhere to put the surplus.
        let low = min(spec.max, max(ownFloor, space - othersCeiling))
        // The ceiling is the width that leaves the others their guaranteed
        // floor, which is why dragging a column wider eventually stops instead of
        // pushing a sibling past its own minimum. And because the dragged column
        // is then never the one the deficit path has to shave, the pointer never
        // fights itself.
        let high = max(low, min(spec.max, max(ownFloor, space - othersFloor)))
        return low...high
    }

    /// The column with the largest weight — where a surplus wider than every
    /// `max` goes, and which gives up space first.
    ///
    /// Ties break on layout order rather than on whatever an unordered
    /// collection happens to yield, because determinism is an invariant: two
    /// runs on the same input must produce identical widths.
    ///
    /// Exposed rather than private because `isOverflowingMaximums` is only
    /// meaningful together with *which* column absorbed the surplus, and the
    /// invariant test has to check that pairing.
    static func widestColumn(of columns: [LagoonColumn]) -> LagoonColumn? {
        columns.max { lhs, rhs in
            let left = ColumnLayoutMetrics.spec(for: lhs)
            let right = ColumnLayoutMetrics.spec(for: rhs)
            return left.weight != right.weight
                ? left.weight < right.weight
                : lhs.rawValue < rhs.rawValue
        }
    }

    /// Same ordering, as the solve's own call site.
    private static func widest(of columns: [LagoonColumn]) -> LagoonColumn? {
        widestColumn(of: columns)
    }

    /// Columns in the order they give up width: heaviest first.
    private static func bySacrificePriority(_ columns: [LagoonColumn]) -> [LagoonColumn] {
        columns.sorted { lhs, rhs in
            let left = ColumnLayoutMetrics.spec(for: lhs)
            let right = ColumnLayoutMetrics.spec(for: rhs)
            if left.weight != right.weight { return left.weight > right.weight }
            return lhs.rawValue < rhs.rawValue
        }
    }

    /// Clamps into `bounds`, tolerating an inverted range by returning `lower`.
    static func clamp(_ value: Double, to bounds: ClosedRange<Double>) -> Double {
        if bounds.isEmpty { return bounds.lowerBound }
        return Swift.min(Swift.max(value, bounds.lowerBound), bounds.upperBound)
    }
}
