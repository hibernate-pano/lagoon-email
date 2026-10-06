import SwiftUI
import AppKit

/// The window's three columns, assembled from independently hosted regions.
///
/// ## Why the columns are split across two regions
///
/// The reader pane's state is per-surface: the Briefing Feed is single-select,
/// the raw list is multi-select for ⌫/⌘⌫, and each owns its own selection,
/// its own `MessageDetailView` and its own poll. Hoisting the reader out to
/// `RootView` would mean inventing a selection model neither surface has — the
/// exact mistake the old `MessageSplitLayout` doc comment warns about.
///
/// So the reader stays inside its surface, and the surface is handed **two**
/// columns (list + reader) while `RootView` holds the third (navigation). Both
/// regions solve against **one shared `ColumnLayoutStore`**, which is what
/// makes the three columns a single weighted system rather than two nested
/// ones. The old layout's defect was precisely that nesting: two constraint
/// systems, so the list's width was their intersection.
///
/// ## Why the drag never goes through SwiftUI state
///
/// The load-bearing decision, and the reason the regions are `NSView`s rather
/// than SwiftUI layout. A mail list can be thousands of rows; a `DragGesture`
/// writing to `@State` republishes on every pointer sample and SwiftUI answers
/// each publication with a transaction over the whole tree. The pointer moves at
/// 120Hz; that cannot. So the drag:
///
/// * writes frames straight onto the AppKit views (`ColumnContainer.applyLayout`),
/// * reaches *both* regions through the store's registry, so the sidebar and the
///   list+reader pair move in the same pass and in the same frame,
/// * publishes nothing until mouse-up.
///
/// ## Animation
///
/// `allowsImplicitAnimation = false` and `duration = 0` around every frame
/// write, because `NSView` is an `NSAnimatablePropertyContainer` and a frame set
/// inside an animation context interpolates — which is precisely the "width
/// chasing the finger" lag the spec forbids as its first rule. Enforced in the
/// one place frames are written.
struct ColumnRegionView: NSViewRepresentable {
    /// The columns this region is responsible for drawing, in layout order.
    let hostedColumns: [LagoonColumn]
    /// One hosted view per entry in `hostedColumns`.
    let panes: [AnyView]
    /// The shared store. Every region holds the same one, which is what makes
    /// the three columns solve as a single system.
    let store: ColumnLayoutStore

    func makeNSView(context: Context) -> ColumnContainer {
        let container = ColumnContainer(store: store)
        container.set(hostedColumns: hostedColumns)
        return container
    }

    func updateNSView(_ container: ColumnContainer, context: Context) {
        container.attach(store: store)
        container.set(hostedColumns: hostedColumns)
        container.set(panes: panes)
        container.layoutNow()
    }

    /// One region's panes, its dividers, and nothing else.
    final class ColumnContainer: NSView, ColumnRegionApplier {
        private let splitView = NSSplitView()
        /// Dividers live here, above the panes. A separate layer rather than
        /// subviews of the split view because `NSSplitView` derives its
        /// children's frames from its own divider arithmetic.
        private let dividerLayer = NSView()
        private var store: ColumnLayoutStore
        private var hostedColumns: [LagoonColumn] = []
        private var hostedViews: [NSHostingView<AnyView>] = []
        /// Strong because `NSSplitView.delegate` is weak.
        private let splitDelegate = SplitSuppressor()
        /// Guards a layout pass re-entering through `applyLayout`.
        private var isApplyingLayout = false

        init(store: ColumnLayoutStore) {
            self.store = store
            super.init(frame: .zero)
            splitView.dividerStyle = .thin
            splitView.isVertical = true
            splitView.delegate = splitDelegate
            dividerLayer.translatesAutoresizingMaskIntoConstraints = false
            addSubview(splitView)
            addSubview(dividerLayer)
            NSLayoutConstraint.activate([
                splitView.leadingAnchor.constraint(equalTo: leadingAnchor),
                splitView.trailingAnchor.constraint(equalTo: trailingAnchor),
                splitView.topAnchor.constraint(equalTo: topAnchor),
                splitView.bottomAnchor.constraint(equalTo: bottomAnchor),
                dividerLayer.leadingAnchor.constraint(equalTo: leadingAnchor),
                dividerLayer.trailingAnchor.constraint(equalTo: trailingAnchor),
                dividerLayer.topAnchor.constraint(equalTo: topAnchor),
                dividerLayer.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            // Registered so a drag in *any* region can move this one in the
            // same pass. Weak: the store must not keep a torn-down window's
            // views alive.
            store.register(self, hosting: hostedColumns)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("ColumnContainer is created in code, not from a nib")
        }

        deinit {
            // `deinit` cannot touch a `@MainActor` type, so the unregister is
            // driven from `detach()` at the SwiftUI teardown point instead —
            // and the store prunes dead entries on every access regardless, so
            // a missed unregister leaks nothing.
        }

        /// Releases this region's claim on the shared store.
        func detach() {
            store.unregister(self)
        }

        func attach(store: ColumnLayoutStore) {
            guard self.store !== store else { return }
            store.unregister(self)
            self.store = store
            store.register(self, hosting: hostedColumns)
        }

        func set(hostedColumns newColumns: [LagoonColumn]) {
            guard newColumns != hostedColumns else { return }
            hostedColumns = newColumns
            store.register(self, hosting: newColumns)
            reconcilePaneCount(to: newColumns.count)
        }

        func set(panes newPanes: [AnyView]) {
            // Assigned unconditionally: `AnyView` is not `Equatable`, so there is
            // no way to ask "did this change?" and a guess would be worse than
            // the cost. This runs on SwiftUI's update cycle, never on the drag's
            // sample rate.
            for (index, pane) in newPanes.enumerated() where index < hostedViews.count {
                // Filled in place: rebuilding a hosting view would drop the
                // reader's scroll position, the one thing a resize must not do.
                hostedViews[index].rootView = pane
            }
        }

        private func reconcilePaneCount(to count: Int) {
            while splitView.arrangedSubviews.count > count {
                guard let view = splitView.arrangedSubviews.last else { break }
                splitView.removeArrangedSubview(view)
                view.removeFromSuperview()
                if !hostedViews.isEmpty { hostedViews.removeLast() }
            }
            while splitView.arrangedSubviews.count < count {
                let hosted = NSHostingView(rootView: AnyView(EmptyView()))
                hosted.translatesAutoresizingMaskIntoConstraints = false
                hostedViews.append(hosted)
                splitView.addArrangedSubview(hosted)
            }
        }

        override func layout() {
            super.layout()
            layoutNow()
        }

        /// Solves for the current bounds and writes this region's frames.
        ///
        /// Idempotent and cheap when nothing changed: `store.layout` returns
        /// without publishing when neither the column set nor the total width
        /// moved. Only the region that *hosts* the total width drives the solve;
        /// the others just read it, which is what stops the two from disagreeing.
        func layoutNow() {
            guard !isApplyingLayout, !hostedColumns.isEmpty, bounds.width > 0 else { return }
            isApplyingLayout = true
            defer { isApplyingLayout = false }
            if store.claimsTotalWidth(for: hostedColumns) {
                store.layout(columns: store.columns, containerWidth: Double(bounds.width))
            } else {
                store.adopt(containerWidth: Double(bounds.width))
            }
            applyLayout()
        }

        /// Writes the solved widths onto this region's panes and dividers.
        func applyLayout() {
            guard !isApplyingLayout, !hostedColumns.isEmpty else { return }
            let widths = store.widths
            let divider = CGFloat(ColumnLayoutMetrics.dividerThickness)
            NSAnimationContext.runAnimationGroup { context in
                context.allowsImplicitAnimation = false
                context.duration = 0
                var x: CGFloat = 0
                for (index, subview) in splitView.arrangedSubviews.enumerated() {
                    guard let column = hostedColumns[safe: index] else { continue }
                    let width = CGFloat(widths[column] ?? 0)
                    if index > 0 { x += divider }
                    var frame = subview.frame
                    frame.origin = NSPoint(x: x, y: frame.origin.y)
                    frame.size = NSSize(width: width, height: frame.height)
                    subview.frame = frame
                    x += width
                }
            }
            rebuildDividers(widths: widths)
        }

        /// One divider per boundary *inside* this region.
        ///
        /// A region's first column has no left edge here, so the divider between
        /// the navigation column and the list column is drawn by whichever
        /// region hosts the list — the surface region, whose first column is the
        /// list. That is why the boundary is drawn by the region's *second*
        /// column rather than between its own two.
        private func rebuildDividers(widths: [LagoonColumn: Double]) {
            dividerLayer.subviews.forEach { $0.removeFromSuperview() }
            guard hostedColumns.count > 1 else { return }
            let hit = CGFloat(ColumnLayoutMetrics.dividerHitWidth)
            let divider = CGFloat(ColumnLayoutMetrics.dividerThickness)
            var x: CGFloat = 0
            for (index, column) in hostedColumns.enumerated() {
                if index > 0 {
                    // The column on this boundary's left, named from *this*
                    // region's own list rather than from a global index.
                    let left = hostedColumns[index - 1]
                    let handle = makeHandle(
                        for: index - 1,
                        column: left,
                        invertedColumn: invertedTarget(for: left),
                        at: x,
                        width: hit,
                        height: bounds.height
                    )
                    dividerLayer.addSubview(handle)
                    x += divider
                }
                x += CGFloat(widths[column] ?? 0)
            }
        }

        /// What ⌥ on the boundary left of `column` resizes instead.
        ///
        /// The reader, and only on the second boundary.
        ///
        /// The reasoning, because the asymmetry is the whole design: handle₂
        /// sits between the list and the reader, so dragging it *right* narrows
        /// the reader — the one column with 900pt of headroom is the one you
        /// cannot widen by dragging its own edge. ⌥ makes that reachable by
        /// targeting the reader directly, with the list yielding as the passive
        /// party (it is the *narrower* of the two, so it gives up space by
        /// weight first and the reader gains it).
        ///
        /// ⌥ on handle₁ would target the list, which is already the column to its
        /// left — there would be nothing to invert, and a tooltip advertising it
        /// would be a lie. So it is nil there, and the tooltip says so by
        /// omission.
        private func invertedTarget(for column: LagoonColumn) -> LagoonColumn? {
            guard column == .list, store.columns.contains(.reader) else { return nil }
            return .reader
        }

        /// Builds one handle and wires all four of its inputs.
        ///
        /// Every path — drag, double-click, arrow keys, VoiceOver increment —
        /// lands on the same `store` calls, so "a step is 16pt" has exactly one
        /// definition and the four input methods cannot drift apart.
        ///
        /// - Parameters:
        ///   - column: the column this handle resizes normally — the one on its
        ///     left, named from `hostedColumns` rather than derived from a
        ///     handle index. A region's divider `0` is not the store's divider
        ///     `0`: the surface region hosts `[.list, .reader]`, so its only
        ///     divider is the *global* boundary 1, and indexing globally made a
        ///     list drag resize the **sidebar**. The widths still solved, so no
        ///     invariant test could have seen it.
        ///   - invertedColumn: what ⌥ targets instead. Nil on the first
        ///     separator, where inverting would name the column already to the
        ///     left.
        private func makeHandle(
            for index: Int,
            column: LagoonColumn,
            invertedColumn: LagoonColumn?,
            at x: CGFloat,
            width: CGFloat,
            height: CGFloat
        ) -> ColumnDividerView {
            let handle = ColumnDividerView(handleIndex: index)
            handle.frame = NSRect(x: x - width / 2, y: 0, width: width, height: height)
            handle.onDrag = { [weak self] pointerX, isInverted in
                self?.handleDrag(
                    handle: handle,
                    column: isInverted ? (invertedColumn ?? column) : column,
                    pointerX: pointerX
                )
            }
            handle.onEnd = { [weak self] in
                self?.handleEnd()
            }
            handle.onReset = { [weak self] in
                self?.handleReset()
            }
            handle.currentWidth = store.width(of: column)
            handle.helpText = ColumnWidthFormatter.tooltip(for: column)
            handle.configureAccessibility(
                label: ColumnWidthFormatter.label(for: column),
                onAdjust: { [weak self] delta in
                    guard let self else { return }
                    if delta == 0 {
                        // The accessibility press gesture, mapped onto the same
                        // action as a double-click.
                        store.resetToIdeal()
                    } else {
                        _ = store.adjust(column: column, by: delta)
                    }
                    store.redrawAll()
                }
            )
            handle.onJump = { [weak self] bound in
                guard let self else { return }
                _ = store.setColumn(column, to: bound)
                store.redrawAll()
            }
            return handle
        }

        // MARK: - Drag lifecycle

        /// The column a drag settled on, so mouse-up settles the same one the
        /// pointer was last moving. Nil when no drag is in flight.
        private var draggingColumn: LagoonColumn?

        private func handleDrag(handle: ColumnDividerView, column: LagoonColumn, pointerX: CGFloat) {
            if draggingColumn == nil {
                draggingColumn = column
                store.beginDrag()
            } else if draggingColumn != column {
                // ⌥ pressed or released mid-drag. The flag follows the pointer
                // rather than being latched at mouse-down, so the switch is
                // instant and the solve simply re-anchors on the new column.
                draggingColumn = column
            }
            // The pointer is in container coordinates; the solver wants a
            // *width*. They differ by however much this region draws to the left
            // of the column being resized — zero for the region's first column,
            // the list's width for the second. Getting this wrong makes the
            // second divider jump by the list's width on mouse-down, which is the
            // most visible possible form of 发飘.
            let leading = leadingEdgeX(of: column)
            _ = store.drag(column: column, toWidth: Double(pointerX - leading))
            store.redrawAll()
        }

        /// The container x of the left edge of `column`, within this region.
        ///
        /// Written once because the divider layout and the drag conversion must
        /// not compute it differently — a disagreement is a divider drawn
        /// somewhere the drag does not think it is.
        private func leadingEdgeX(of column: LagoonColumn) -> CGFloat {
            let widths = store.widths
            var x: CGFloat = 0
            for (offset, candidate) in hostedColumns.enumerated() {
                if offset > 0 { x += CGFloat(ColumnLayoutMetrics.dividerThickness) }
                if candidate == column { return x }
                x += CGFloat(widths[candidate] ?? 0)
            }
            return x
        }

        private func handleEnd() {
            guard let column = draggingColumn else { return }
            draggingColumn = nil
            _ = store.endDrag(column: column)
            store.redrawAll()
        }

        private func handleReset() {
            draggingColumn = nil
            store.resetToIdeal()
            store.redrawAll()
        }
    }

    /// Tells `NSSplitView` to stay out of the layout. All four answers are "no":
    ///
    /// * `shouldHideDivider` — we draw our own; two dividers on one boundary
    ///   means the user sees a 3pt bar and grabs whichever half they aimed at.
    /// * `canCollapseSubview` — double-click means "reset to ideal", and a
    ///   collapsed mail column is unrecoverable without a window resize.
    /// * `shouldAdjustSizeOfSubview` — every frame is written by `applyLayout`;
    ///   letting AppKit resize one too is how two systems end up fighting.
    /// * `resizeSubviewsWithOldSize` — the solve redistributes by weight on a
    ///   resize, rather than proportionally.
    private final class SplitSuppressor: NSObject, NSSplitViewDelegate {
        func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
        func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool { true }
        func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool { false }
        func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {}
    }
}

extension Array {
    /// Bounds-checked subscript. The solver's columns and a region's subviews
    /// are two independently maintained lists that are supposed to agree; a
    /// mismatch should read as a missing column rather than a crash.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
