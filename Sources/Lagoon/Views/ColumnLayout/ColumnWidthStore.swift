import Foundation
import Combine
import SwiftUI

/// The three columns' widths, and the window width they are solved against.
///
/// ## One authority
///
/// The window's geometry has exactly one owner: this store. SwiftUI reads the
/// widths it publishes and lays the columns out; nothing else computes a width
/// and nothing outside this type writes a frame. That is the whole design, and
/// it is the discipline the previous attempt lacked — two layout authorities
/// (a SwiftUI `HStack` and an AppKit split view) both claimed the same
/// rectangles, each update invalidated the other, and the window either rendered
/// blank or took the process down with an endless constraint loop.
///
/// ## Why the arithmetic is not here
///
/// `ColumnSolver` is a pure function over value types, with no SwiftUI and no
/// AppKit in its file, and it carries the 29 tests that pin every invariant
/// across a 169,443-combination sweep. This type is the thin shell around it:
/// it owns *when* to solve and *what* to solve against, and delegates every
/// decision about the answer. A bug in the arithmetic belongs in the solver,
/// where it can be tested without a window.
@MainActor
final class ColumnWidthStore: ObservableObject {
    /// The visible columns, in layout order. Three with a connected account,
    /// two without one (nothing to navigate).
    private(set) var columns: [LagoonColumn] = [.navigation, .list, .reader]

    /// The window's content width, separators included.
    ///
    /// Owned by the store rather than derived from a column's width, because
    /// the solve is what *produces* the column widths: reading a total back out
    /// of them would be a circular dependency, and a circular dependency here
    /// is what left the previous version's window blank.
    private(set) var windowWidth: CGFloat = 0

    /// The solved widths. Every column in `columns` has an entry.
    ///
    /// Published so the three `.frame(width:)` calls redraw when a width changes.
    /// That is the whole reason this type can be pure SwiftUI: the drag path
    /// invalidates SwiftUI, so it must be cheap, and it is because a drag only
    /// moves the columns on the far side of one divider — the list itself is a
    /// lazy `List` capped at 500 messages and is never rebuilt.
    @Published private(set) var widths: [LagoonColumn: CGFloat] = [:]

    /// True from mouse-down to mouse-up on a handle.
    ///
    /// A drag must not re-solve from the carried widths: they are the *settled*
    /// ones, not the widths currently under the pointer, so re-solving mid-drag
    /// would fight the pointer instead of following it.
    @Published private(set) var isDragging = false

    /// The column a drag is currently moving, so releasing settles the one the
    /// pointer was last on — including a switch caused by ⌥.
    @Published private(set) var draggingColumn: LagoonColumn?

    /// Fired once when a drag settles, with the widths worth remembering.
    ///
    /// A drag that never moved does not fire: an unchanged layout is not a
    /// preference the user expressed.
    var onSettle: (([LagoonColumn: CGFloat]) -> Void)?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Window geometry

    /// The window changed size, or appeared for the first time.
    ///
    /// Idempotent and cheap: a width that has not moved and a column set that
    /// has not changed both return without publishing, so a redundant resize
    /// cannot schedule a SwiftUI transaction.
    func window(width: CGFloat, columns newColumns: [LagoonColumn]) {
        guard width > 0, !newColumns.isEmpty else { return }
        let widthMoved = abs(width - windowWidth) > ColumnSolver.epsilon
        let columnsMoved = newColumns != columns
        guard widthMoved || columnsMoved else { return }

        windowWidth = width
        columns = newColumns
        // A drag owns the widths while the pointer is down; re-solving here
        // would replace them with the carried (settled) values and the divider
        // would snap back mid-gesture.
        guard !isDragging else { return }
        solve()
    }

    /// The solved widths, for a column.
    func width(of column: LagoonColumn) -> CGFloat {
        widths[column] ?? 0
    }

    /// A column's left edge in the window, separators included.
    ///
    /// The one piece of geometry the panes and the dividers must agree on. A
    /// handle placed from its own arithmetic and a pane placed from another is
    /// how a boundary ends up drawn somewhere the drag does not think it is.
    func leadingEdgeX(of column: LagoonColumn) -> CGFloat {
        var x: CGFloat = 0
        for candidate in columns {
            if candidate == column { return x }
            x += width(of: candidate) + ColumnLayoutMetrics.dividerThickness
        }
        return x
    }

    /// True when this window shows the reading pane.
    ///
    /// A window without an account has no reader to open, and a separator whose
    /// ⌥ inversion names a column that is not on screen is a modifier that does
    /// nothing — worse than one that is never offered.
    var hasReader: Bool {
        columns.contains(.reader)
    }

    /// One column at the width the solver gave it.
    ///
    /// `.frame(width:)` and nothing else: no `minWidth`, no `maxWidth`, no
    /// `fixedSize`. The solver has already decided what this column may be, and a
    /// second opinion here is how a solved width stops being the width on screen.
    /// The height is the parent's, so a short list and a long one are the same
    /// height, which is what makes the boundaries line up down the window.
    func column<C: View>(
        _ column: LagoonColumn,
        @ViewBuilder content: () -> C
    ) -> some View {
        content()
            .frame(width: width(of: column))
            .frame(maxHeight: .infinity)
    }

    /// Recomputes and publishes.
    ///
    /// `carried` is the live widths once they exist and the persisted ones on
    /// the first pass, so a layout the user set by hand survives the next
    /// resize instead of snapping back to a canonical shape.
    private func solve(
        dragged: LagoonColumn? = nil,
        target: CGFloat? = nil,
        carried: [LagoonColumn: CGFloat]? = nil,
        permitsOvershoot: Bool = false
    ) {
        let solution = ColumnSolver.solve(
            columns: columns,
            totalWidth: Double(windowWidth),
            dragged: dragged,
            target: target.map(Double.init),
            carried: carried?.mapValues { Double($0) } ?? restoredWidths(),
            permitsOvershoot: permitsOvershoot
        )
        let solved = solution.widths.mapValues { CGFloat($0) }
        guard solved != widths else { return }
        widths = solved
    }

    // MARK: - Dragging

    /// Begins a drag. No solve here: the divider is where the user found it.
    func beginDrag(column: LagoonColumn) {
        isDragging = true
        draggingColumn = column
    }

    /// One pointer sample.
    ///
    /// The width is damped and clamped to what the window can actually honour,
    /// which is what makes "there is no more room" a wall the user feels rather
    /// than a silent no-op.
    func drag(column: LagoonColumn, toWidth width: CGFloat) {
        guard columns.contains(column) else { return }
        // ⌥ switches the target mid-drag, so the flag follows the pointer
        // instead of being latched at mouse-down.
        draggingColumn = column
        let range = ColumnSolver.achievableRange(
            for: column,
            columns: columns,
            totalWidth: Double(windowWidth)
        )
        solve(
            dragged: column,
            target: RubberBand.damped(Double(width), range: range),
            carried: widths,
            permitsOvershoot: true
        )
    }

    /// Ends a drag: the rubber band snaps back to the boundary it resisted and
    /// the result is written out once.
    func endDrag() {
        isDragging = false
        guard let column = draggingColumn else { return }
        draggingColumn = nil
        let range = ColumnSolver.achievableRange(
            for: column,
            columns: columns,
            totalWidth: Double(windowWidth)
        )
        let damped = Double(widths[column] ?? range.lowerBound)
        solve(
            dragged: column,
            target: RubberBand.settled(damped: damped, range: range),
            carried: widths
        )
        onSettle?(widths)
    }

    /// Moves a column by a fixed amount.
    ///
    /// The keyboard arrows and the accessibility adjustable action both land
    /// here, so "a step" has exactly one definition. The range used is the
    /// *achievable* one, not the column's own envelope, because a column can
    /// also be stopped by the other columns' minimums and an arrow key that
    /// silently did nothing at that wall would read as a broken key.
    @discardableResult
    func adjust(column: LagoonColumn, by delta: CGFloat) -> CGFloat {
        guard columns.contains(column) else { return 0 }
        let range = ColumnSolver.achievableRange(
            for: column,
            columns: columns,
            totalWidth: Double(windowWidth)
        )
        let target = ColumnSolver.clamp(
            Double(widths[column] ?? range.lowerBound) + Double(delta),
            to: range
        )
        return settle(column: column, target: target)
    }

    /// Jumps a column straight to a bound.
    @discardableResult
    func setColumn(_ column: LagoonColumn, to bound: ColumnBound) -> CGFloat {
        guard columns.contains(column) else { return 0 }
        let range = ColumnSolver.achievableRange(
            for: column,
            columns: columns,
            totalWidth: Double(windowWidth)
        )
        let target = bound == .min ? range.lowerBound : range.upperBound
        return settle(column: column, target: target)
    }

    /// Double-click: every column back to `ideal`, immediately, no animation.
    func resetToIdeal() {
        var ideal: [LagoonColumn: CGFloat] = [:]
        for column in columns {
            ideal[column] = CGFloat(ColumnLayoutMetrics.spec(for: column).ideal)
        }
        solve(carried: ideal)
        onSettle?(widths)
    }

    /// Shared tail for the discrete adjustments: solve, publish, persist.
    private func settle(column: LagoonColumn, target: CGFloat) -> CGFloat {
        solve(dragged: column, target: Double(target), carried: widths)
        onSettle?(widths)
        return widths[column] ?? 0
    }

    // MARK: - Persistence

    /// The stored widths, fitted to this window.
    ///
    /// A reader width saved on a 27" display must not open a 13" window at
    /// 620pt: the solve would hand the surplus to the highest-weight column and
    /// the user would find the app quietly resized. So when the stored widths do
    /// not fit, the *proportions* survive and the absolute values do not.
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
        let available = max(0, windowWidth - dividerTotal)
        let storedTotal = columns.reduce(0) {
            $0 + (stored[$1] ?? ColumnLayoutMetrics.spec(for: $1).ideal)
        }
        guard storedTotal > available else { return stored }

        var scaled: [LagoonColumn: Double] = [:]
        for column in columns {
            let want = stored[column] ?? ColumnLayoutMetrics.spec(for: column).ideal
            scaled[column] = max(ColumnSpec.absoluteFloor, want * available / storedTotal)
        }
        return scaled
    }

    /// Writes the settled widths. Called once per drag, from the drag's end.
    func persist(_ widths: [LagoonColumn: CGFloat]) {
        for column in columns {
            guard let width = widths[column] else { continue }
            // A squeezed width is a property of *this* window, not a preference
            // the user expressed. Writing one back would let a window briefly
            // dragged narrow on a borrowed display reset the layout for every
            // display afterwards.
            let spec = ColumnLayoutMetrics.spec(for: column)
            guard width >= CGFloat(spec.min) - ColumnSolver.epsilon else { continue }
            defaults.set(Double(width), forKey: ColumnLayoutMetrics.storageKey(for: column))
        }
    }
}

/// Which end of a column's range an absolute jump targets.
enum ColumnBound {
    case min
    case max
}

extension ColumnWidthStore {
    /// Writes the settled widths through the store, so persistence always sits
    /// behind an explicit call and a window nobody dragged in never writes.
    func installPersistence() {
        onSettle = { [weak self] widths in
            self?.persist(widths)
        }
    }
}
