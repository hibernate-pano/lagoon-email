import SwiftUI

/// The pointer target for one separator.
///
/// ## What this is not
///
/// Not an `NSSplitView` divider, and not a `DragGesture` whose every sample
/// writes width into view state. The previous attempt used AppKit for this and
/// it was the wrong tool for two measurable reasons: AppKit's split-view drag
/// callbacks never fired on this SDK, and a second layout authority made the
/// window's geometry a fight it eventually lost.
///
/// ## The drag loop
///
/// `DragGesture` with `minimumDistance: 0`, so the divider responds on the
/// press — a drag separator needs no "confirm intent" threshold, and a threshold
/// makes a user who aimed well believe they missed.
///
/// ## Animation
///
/// Disabled for the duration of the gesture, and nowhere else. A width that
/// eases toward the pointer is the single most common source of the "chasing
/// the finger" feel this layout exists to avoid, and the spec's first rule is
/// that no width animates while it is being dragged. The rebound on release is
/// the one deliberate exception, and it is 0.15s — fast enough to read as
/// "that was the limit" rather than as an animation.
struct ColumnDivider: View {
    /// The column this separator resizes: the one on its **left**.
    ///
    /// Stated once because it is genuinely ambiguous otherwise — two of the
    /// three boundaries have no handle at all, so "handle 1" and "the list's
    /// handle" are not the same thing and deriving one from the other produced
    /// a drag that moved the wrong column while every width assertion stayed
    /// green.
    let column: LagoonColumn

    /// What ⌥ resizes instead: the reader, and only on the second boundary.
    ///
    /// Handle₂ sits between the list and the reader, so dragging it *right*
    /// narrows the reader — the one column with real headroom is the one you
    /// cannot widen by dragging its own edge. ⌥ makes it reachable by naming the
    /// reader directly, with the list yielding as the passive party.
    ///
    /// Nil on the first separator, where inverting would target the column
    /// already to the left; a tooltip advertising it there would be a lie, so
    /// it is nil and the tooltip says so by omission.
    let invertedColumn: LagoonColumn?

    /// The shared widths.
    let store: ColumnWidthStore

    @State private var isHovering = false

    /// The separator's own height is the window's; it spans the full column.
    var body: some View {
        Rectangle()
            .fill(separatorColor)
            // 1pt of line inside a 10pt target: visible enough to aim at,
            // thin enough that the boundary reads as a rule rather than a bar.
            .frame(width: ColumnLayoutMetrics.dividerThickness)
            // The target is wider than the line. Without this the hit area
            // would be the same 1pt the eye aims at, which is below the HIG
            // floor and genuinely hard to catch on a Retina display.
            .frame(width: ColumnLayoutMetrics.dividerHitWidth)
            .contentShape(Rectangle())
            .onHover { inside in
                isHovering = inside
                // The standard two-way resize cursor. Free, and the only
                // affordance that needs no learning.
                if inside {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(dragGesture)
            .onTapGesture(count: 2) {
                // Double-click means "back to ideal", not "collapse". A
                // collapsed mail column would be unrecoverable without a
                // window resize.
                store.resetToIdeal()
            }
            .help(ColumnWidthStrings.tooltip(for: column))
            .accessibilityElement()
            .accessibilityLabel(ColumnWidthStrings.label(for: column))
            .accessibilityValue(ColumnWidthStrings.spoken(Int(store.width(of: column).rounded())))
            // The arrow keys and Page Up/Down land on the same adjustment
            // entry point the drag uses, so a keyboard user and a VoiceOver
            // user get byte-identical behaviour and "a step" has one definition.
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    store.adjust(column: column, by: ColumnLayoutMetrics.keyboardStep)
                case .decrement:
                    store.adjust(column: column, by: -ColumnLayoutMetrics.keyboardStep)
                @unknown default:
                    break
                }
            }
            .accessibilityAction(named: Text(ColumnWidthStrings.toMin)) {
                store.setColumn(column, to: .min)
            }
            .accessibilityAction(named: Text(ColumnWidthStrings.toMax)) {
                store.setColumn(column, to: .max)
            }
    }

    /// The line's colour. Hover and drag are the only two changes, and both
    /// are colour only — a handle that resizes on hover moves the boundary the
    /// user was aiming at.
    private var separatorColor: Color {
        if store.isDragging && store.draggingColumn == column {
            return .accentColor
        }
        if store.isDragging || isHovering {
            return .secondary.opacity(0.6)
        }
        // `Color.separator` does not exist — `.separator` is a *shape* style, so
        // naming it here would have compiled into the wrong overload had the
        // context been a `ShapeStyle` rather than a `Color`. Going through
        // `NSColor.separatorColor` is the only spelling that is a colour.
        return Color(nsColor: .separatorColor)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // No implicit animation, here or anywhere else on this path.
                // A frame set inside an animation context interpolates, and an
                // interpolating separator is precisely the lag the whole
                // layout exists to remove.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    store.beginDrag(column: column)
                    // The pointer's x in the *container*, minus where this
                    // separator's column actually starts.
                    //
                    // Reading the column's live leading edge rather than an
                    // origin captured when the view was built is what makes a
                    // second drag land where the user aimed: a captured origin
                    // is a snapshot of the widths *before* the first drag, so
                    // every subsequent drag would be offset by however much the
                    // first one moved the columns.
                    let leading = store.leadingEdgeX(of: column)
                    let width = value.location.x - leading
                    // The ⌥ flag is read from the *event*, not from the gesture's
                    // value: `DragGesture.Value` carries no modifier state, and a
                    // modifier nobody can see is a modifier that cannot be used.
                    // Reading it per sample is what makes ⌥ switch the target
                    // mid-drag rather than only at mouse-down.
                    let isInverted = NSEvent.modifierFlags.contains(.option)
                    let target = isInverted ? (invertedColumn ?? column) : column
                    store.drag(column: target, toWidth: width)
                }
            }
            .onEnded { _ in
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    store.endDrag()
                }
            }
    }
}

/// The separator's user-facing strings.
///
/// Split out so both languages live in one place and a test can pin them
/// without standing up a window.
enum ColumnWidthStrings {
    static func tooltip(for column: LagoonColumn) -> String {
        switch column {
        case .navigation: return L10n.current.columnResizeTooltip("navigation")
        case .list: return L10n.current.columnResizeTooltip("list")
        case .reader: return L10n.current.columnResizeTooltip("reader")
        }
    }

    static func label(for column: LagoonColumn) -> String {
        switch column {
        case .navigation: return L10n.current.columnWidthNoun("navigation")
        case .list: return L10n.current.columnWidthNoun("list")
        case .reader: return L10n.current.columnWidthNoun("reader")
        }
    }

    static func spoken(_ points: Int) -> String {
        L10n.current.columnWidthPoints(points)
    }

    static var toMin: String { L10n.current.columnWidthToMin }
    static var toMax: String { L10n.current.columnWidthToMax }
}
