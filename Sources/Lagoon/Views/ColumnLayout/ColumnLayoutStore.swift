import Foundation
import Combine

/// The live column widths, shared between the AppKit split view and SwiftUI.
///
/// ## Two tiers, on purpose
///
/// * `widths` is a plain stored property. It is always the truth, it is
///   readable synchronously from inside `NSSplitViewDelegate`'s `dragging`
///   callback, and it does **not** publish. A `@Published` write schedules a
///   SwiftUI transaction, and a transaction landing on the drag's sample rate
///   is exactly how a mail list of thousands of rows ends up re-laying out
///   once per pointer event. During a drag the AppKit layer sets the frames
///   directly, so SwiftUI has nothing to do and is told nothing.
/// * `settledWidths` publishes, but only for changes that are *not* drag
///   motion: a window resize, a keyboard step, a double-click reset, a
///   restore. Those do have to reach the accessibility layer and the
///   persisting owner, and none of them happen at 120Hz.
///
/// The split is the whole performance argument. It is also why `isDragging`
/// exists: it is the flag a consumer consults before animating, because "do
/// not animate during a drag" is a promise that later edits break silently
/// unless something forces them to ask.
@MainActor
final class ColumnLayoutStore: ObservableObject {
    /// Live widths per column. Never published — see the type comment.
    private(set) var widths: [LagoonColumn: Double] = [:]
    /// Widths to show SwiftUI. Changes only when nothing is being dragged.
    @Published private(set) var settledWidths: [LagoonColumn: Double] = [:]
    /// The columns currently laid out, in order. Two without an account, three
    /// with one.
    @Published private(set) var columns: [LagoonColumn] = []
    /// True from mouse-down to mouse-up on a handle.
    private(set) var isDragging = false
    /// The solve in force, for the invariant the split view checks before it
    /// hands widths to AppKit.
    private(set) var lastSolution: ColumnSolver.Solution?
    /// Last container width the solve was for. A drag's target is absolute, so
    /// the store needs to know what "absolute" means.
    private(set) var containerWidth: Double = 0

    /// Called once when a drag settles, with the widths to persist.
    ///
    /// A drag that never moved does not fire it: an unchanged layout is not a
    /// preference the user expressed.
    var onSettle: (([LagoonColumn: Double]) -> Void)?

    /// Injected so the tests never touch the real defaults.
    private let defaults: UserDefaults
    /// The regions currently drawing a subset of the columns.
    ///
    /// The three columns are hosted by more than one view (the navigation
    /// column by `RootView`'s region, the list and reader by the surface's), so
    /// a solve has to reach all of them or the window tears. Weak, because a
    /// region must be able to go away without unregistering — a torn-down
    /// window's views would otherwise be kept alive by the store.
    private var regions: [WeakRegion] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Region registry

    /// One hosted region, held weakly.
    private struct WeakRegion {
        weak var container: AnyObject?
        /// The columns this region draws.
        var columns: [LagoonColumn]
    }

    func register(_ container: AnyObject, hosting columns: [LagoonColumn]) {
        regions.removeAll { $0.container == nil }
        guard !regions.contains(where: { $0.container === container }) else {
            regions = regions.map { $0.container === container
                ? WeakRegion(container: container, columns: columns)
                : $0 }
            return
        }
        regions.append(WeakRegion(container: container, columns: columns))
    }

    func unregister(_ container: AnyObject) {
        regions.removeAll { $0.container == nil || $0.container === container }
    }

    /// Redraws every registered region.
    ///
    /// Called after a solve so a drag in one region moves the others in the
    /// *same* pass, on the same frame. Doing it per-region would mean the
    /// sidebar and the list settling a frame apart, which is the tear this
    /// whole rewrite exists to remove.
    func redrawAll() {
        regions.removeAll { $0.container == nil }
        for region in regions {
            (region.container as? ColumnRegionApplier)?.applyLayout()
        }
    }

    /// The region that owns the window's total width.
    ///
    /// The one hosting the *last* column, because only it knows where the
    /// window ends. Exactly one region answers yes, which is what stops two
    /// regions from driving the same solve with two different widths.
    func claimsTotalWidth(for columns: [LagoonColumn]) -> Bool {
        guard let last = columns.last,
              let owner = regions.first(where: { $0.columns.contains(last) }),
              owner.columns.last == last else { return false }
        return owner.container != nil
    }

    /// Re-reads the width without re-solving.
    ///
    /// A non-owning region still needs to know the total so the owner's solve is
    /// correct, but it must not run one: two solves would produce two answers
    /// and the columns would fight.
    func adopt(containerWidth: Double) {
        self.containerWidth = max(0, containerWidth)
    }

    // MARK: - Layout lifecycle

    /// Declares the visible columns and lays them out for `newWidth`.
    ///
    /// Called from `layoutSubviews`, so it must be cheap and idempotent: a
    /// width that has not moved and a column set that has not changed both
    /// return without publishing.
    func layout(columns newColumns: [LagoonColumn], containerWidth newWidth: Double) {
        guard newWidth > 0, !newColumns.isEmpty else { return }
        let columnsChanged = newColumns != columns
        let widthChanged = abs(newWidth - containerWidth) > ColumnSolver.epsilon
        guard columnsChanged || widthChanged || lastSolution == nil else { return }

        columns = newColumns
        containerWidth = newWidth

        // A drag owns the widths while the pointer is down. Re-solving from the
        // carried widths mid-drag would fight the pointer, because the carried
        // value for the dragged column is the settled one, not the damped one
        // currently under the pointer.
        guard !isDragging else { return }
        commit(solve(dragged: nil, target: nil, permitsOvershoot: false), publish: true)
    }

    /// The solve for the current geometry. `carried` is the live widths once
    /// they exist, and the persisted ones on the very first pass.
    private func solve(
        dragged: LagoonColumn?,
        target: Double?,
        permitsOvershoot: Bool
    ) -> ColumnSolver.Solution {
        ColumnSolver.solve(
            columns: columns,
            totalWidth: containerWidth,
            dragged: dragged,
            target: target,
            carried: widths.isEmpty ? restoredWidths() : widths,
            permitsOvershoot: permitsOvershoot
        )
    }

    /// Installs a solution. `publish: false` is the drag path.
    private func commit(_ solution: ColumnSolver.Solution, publish: Bool) {
        lastSolution = solution
        // Columns that left the layout (the sidebar, when the account goes
        // away) must not linger: a stale `.navigation` entry would be handed
        // to `UserDefaults` and later restored into a window with no such
        // column.
        if widths.count == solution.widths.count,
           widths.allSatisfy({ abs((widths[$0.key] ?? -1) - $0.value) < ColumnSolver.epsilon }) {
            return
        }
        widths = solution.widths
        if publish {
            settledWidths = solution.widths
        }
    }

    // MARK: - Dragging

    /// Begins a drag. No solve here: the divider is where the user found it.
    func beginDrag() {
        isDragging = true
    }

    /// Moves a divider, resizing `column`.
    ///
    /// The column is named rather than derived from a handle index, and that is
    /// not a style choice. The three columns are hosted by two regions — the
    /// navigation column by `RootView`'s, the list and reader by the surface's —
    /// so a region's divider `0` is a *different* boundary from the store's
    /// divider `0`. Passing the index made the surface's list divider resolve to
    /// the **sidebar**: dragging the list would have resized the navigation
    /// column, and the widths would still have solved correctly, so no invariant
    /// test could see it. The column the handle names is the only thing the
    /// solver should be told.
    @discardableResult
    func drag(column: LagoonColumn, toWidth width: Double) -> [LagoonColumn: Double] {
        guard columns.contains(column) else { return widths }
        let range = ColumnSolver.achievableRange(for: column, columns: columns, totalWidth: containerWidth)
        let solution = solve(
            dragged: column,
            target: RubberBand.damped(width, range: range),
            permitsOvershoot: true
        )
        commit(solution, publish: false)
        return widths
    }

    /// Ends a drag: the rubber band snaps back to the boundary it resisted and
    /// the result is written out once.
    @discardableResult
    func endDrag(column: LagoonColumn) -> [LagoonColumn: Double] {
        isDragging = false
        guard columns.contains(column) else { return widths }
        let range = ColumnSolver.achievableRange(for: column, columns: columns, totalWidth: containerWidth)
        let solution = solve(
            dragged: column,
            target: RubberBand.settled(damped: widths[column] ?? range.lowerBound, range: range),
            permitsOvershoot: false
        )
        commit(solution, publish: true)
        onSettle?(solution.widths)
        return widths
    }

    // MARK: - Discrete adjustment

    /// Moves a column by a fixed amount.
    ///
    /// The keyboard arrows and the accessibility adjustable action both land
    /// here, so "a step" has exactly one definition. The range used is the
    /// *achievable* one, not the column's own envelope, because a column can
    /// also be stopped by the other columns' minimums and an arrow key that
    /// silently did nothing at that wall would read as a broken key.
    @discardableResult
    func adjust(column: LagoonColumn, by delta: Double) -> Double {
        guard columns.contains(column) else { return 0 }
        let range = ColumnSolver.achievableRange(for: column, columns: columns, totalWidth: containerWidth)
        let current = widths[column] ?? range.lowerBound
        let target = ColumnSolver.clamp(current + delta, to: range)
        guard abs(target - current) > ColumnSolver.epsilon else { return current }
        return settle(column: column, target: target)
    }

    /// Jumps a column straight to a bound, or home for a double-click.
    @discardableResult
    func setColumn(_ column: LagoonColumn, to bound: ColumnBound) -> Double {
        guard columns.contains(column) else { return 0 }
        let range = ColumnSolver.achievableRange(for: column, columns: columns, totalWidth: containerWidth)
        let target = bound == .min ? range.lowerBound : range.upperBound
        guard abs(target - (widths[column] ?? range.lowerBound)) > ColumnSolver.epsilon else {
            return widths[column] ?? 0
        }
        return settle(column: column, target: target)
    }

    /// Double-click: every column back to `ideal`, immediately, no animation.
    func resetToIdeal() {
        var ideal: [LagoonColumn: Double] = [:]
        for column in columns {
            ideal[column] = ColumnLayoutMetrics.spec(for: column).ideal
        }
        // A window too narrow for the three ideals still gets a legal layout:
        // solving with nothing dragged resolves the overflow through the normal
        // weighted path, which is the same answer a resize would have given.
        let solution = ColumnSolver.solve(
            columns: columns,
            totalWidth: containerWidth,
            carried: ideal
        )
        commit(solution, publish: true)
        onSettle?(solution.widths)
    }

    /// Shared tail for the discrete adjustments: solve, publish, persist.
    private func settle(column: LagoonColumn, target: Double) -> Double {
        let solution = solve(dragged: column, target: target, permitsOvershoot: false)
        commit(solution, publish: true)
        onSettle?(solution.widths)
        return solution.width(of: column)
    }

    /// The current width of a column.
    func width(of column: LagoonColumn) -> Double {
        widths[column] ?? 0
    }

    // MARK: - Persistence

    /// The stored widths, fitted to this window.
    ///
    /// A reader width saved on a 27" display must not open a 13" window at
    /// 620pt: the solve would hand the surplus to the highest-weight column
    /// and the user would find the app quietly resized. So when the stored
    /// widths do not fit, the *proportions* survive and the absolute values do
    /// not.
    private func restoredWidths() -> [LagoonColumn: Double] {
        var stored: [LagoonColumn: Double] = [:]
        for column in LagoonColumn.allCases {
            let raw = defaults.double(forKey: ColumnLayoutMetrics.storageKey(for: column))
            // `double(forKey:)` answers 0 for a missing key, which is not a
            // width anyone can mean. Treat it as absent so a first run gets
            // `ideal` rather than a collapsed column.
            guard raw > ColumnSolver.epsilon else { continue }
            let spec = ColumnLayoutMetrics.spec(for: column)
            stored[column] = ColumnSolver.clamp(raw, to: spec.min...spec.max)
        }
        guard !stored.isEmpty else { return [:] }

        let dividerTotal = Double(max(0, columns.count - 1)) * ColumnLayoutMetrics.dividerThickness
        let available = max(0, containerWidth - dividerTotal)
        let storedTotal = columns.reduce(0) { $0 + (stored[$1] ?? ColumnLayoutMetrics.spec(for: $1).ideal) }
        guard storedTotal > available else { return stored }

        var scaled: [LagoonColumn: Double] = [:]
        for column in columns {
            let want = stored[column] ?? ColumnLayoutMetrics.spec(for: column).ideal
            scaled[column] = max(ColumnSpec.absoluteFloor, want * available / storedTotal)
        }
        return scaled
    }

    /// Writes the settled widths. Called once per drag, from the drag's end.
    func persist(_ widths: [LagoonColumn: Double]) {
        for column in columns {
            guard let width = widths[column] else { continue }
            // A squeezed width is a property of *this* window, not a preference
            // the user expressed. Writing one back would let a window briefly
            // dragged narrow on a borrowed display reset the layout for every
            // display afterwards.
            let spec = ColumnLayoutMetrics.spec(for: column)
            guard width >= spec.min - ColumnSolver.epsilon else { continue }
            defaults.set(width, forKey: ColumnLayoutMetrics.storageKey(for: column))
        }
    }
}

/// Which end of a column's range an absolute jump targets.
enum ColumnBound {
    case min
    case max
}

/// What a region has to be able to do for the store to drive it.
///
/// A protocol rather than a concrete type so `ColumnLayoutStore` — which is
/// pure layout logic and the most heavily tested thing in this directory — does
/// not have to know about `NSView`. The test suite exercises the solver and the
/// store with no AppKit types in scope at all, which is why the arithmetic can
/// be pinned without a window.
@MainActor
protocol ColumnRegionApplier: AnyObject {
    /// Writes the store's current widths onto this region's panes and dividers.
    func applyLayout()
}
