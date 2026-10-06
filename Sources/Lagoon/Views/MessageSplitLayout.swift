import SwiftUI

/// The list and reader columns, as one region of the window's layout.
///
/// ## What this is
///
/// `RootView` owns the *window*: it creates the shared `ColumnLayoutStore` and
/// hands the same instance to this view and to its navigation-column region.
/// Two regions, one store, three columns — so the sidebar, the list and the
/// reader solve as a single weighted system.
///
/// The split into two regions is forced by state ownership, not by taste. The
/// reader's selection is per-surface (the Briefing Feed is single-select, the
/// raw list is multi-select for ⌫/⌘⌫), and each surface owns its own
/// `MessageDetailView`, its own poll and its own scroll position. Hoisting the
/// reader into `RootView` would mean inventing a selection model neither
/// surface has — the exact mistake the two `NavigationSplitView`s used to
/// paper over.
///
/// ## The invariant this file exists to protect
///
/// **There is no `NavigationSplitView` in this file, and there must never be
/// one again. There is also no automatic sidebar toggle — deliberately
/// absent, not overlooked.**
///
/// `NavigationSplitView` inserts a sidebar-toggle button into the *window*
/// toolbar on its own. `RootView` keeps both surfaces alive in a ZStack
/// (opacity / disabled / allowsHitTesting / accessibilityHidden hide the view,
/// never a toolbar item — see
/// `.memory/toolbar-items-escape-hidden-zstack-surfaces`), so the two surfaces
/// each produced a toggle and the window showed it twice in the corner. The
/// guard used to be `.toolbar(removing: .sidebarToggle)`, declared in this file
/// so a third surface could not forget it.
///
/// That guard is **gone with the split views it guarded**. The rule now is the
/// absence of the thing that made a toggle appear: no `NavigationSplitView`
/// here means no automatic toggle, which means nothing to remove and nothing to
/// duplicate. `ColumnLayoutGuardTests` asserts the absence from the source,
/// because a guard that lives only in a comment is not a guard — re-adding
/// `NavigationSplitView` would compile, pass every behavioural test, and put
/// two toggles back in the corner.
///
/// The sidebar keeps its own disclosure affordance in `Sidebar`; that is a
/// control the app draws, not one AppKit injects.
struct MessageSplitLayout<List: View, Detail: View>: View {
    /// The shared width store. Injected rather than created here so the
    /// navigation column's region solves against the same numbers.
    let store: ColumnLayoutStore
    /// The message the reader pane shows, nil while nothing is selected.
    let detailId: String?
    /// Non-nil when several rows are selected: the pane says so instead of
    /// silently previewing one of them, because a bulk verb (⌫) is about to
    /// act on all of them and the user should see the count, not one message.
    var multiSelectionCount: Int? = nil
    @ViewBuilder var list: () -> List
    @ViewBuilder var detail: () -> Detail

    @Environment(\.l10n) private var l10n

    /// This region draws the list and the reader. The navigation column is the
    /// window's, drawn by the region beside it.
    private var hostedColumns: [LagoonColumn] { [.list, .reader] }

    var body: some View {
        ColumnRegionView(
            hostedColumns: hostedColumns,
            panes: [AnyView(list()), AnyView(reader)],
            store: store
        )
        // No `.frame(minWidth:)` here. The window's floor is the *window's*
        // business — it depends on all three columns, so `RootView` states it
        // once. The old flat `minWidth: 720` sat on each surface and was
        // arithmetically smaller than the three columns' minimums, so it
        // guaranteed a breach on every narrow window
        // (`docs/三栏宽度求解器-实测结论.md`, conclusion 2).
    }

    /// The reader, or the "nothing selected" placeholder.
    ///
    /// One wording and one affordance, so the empty right pane reads as "pick a
    /// message" on both surfaces instead of as a broken view. Each surface
    /// passes in its own `detailId` rather than a shared selection.
    @ViewBuilder
    private var reader: some View {
        if detailId != nil {
            detail()
        } else if let count = multiSelectionCount, count > 1 {
            ContentUnavailableView(
                l10n.messagesSelected(count),
                systemImage: "checklist",
                description: Text(l10n.multiSelectionHint)
            )
        } else {
            ContentUnavailableView(
                l10n.nothingSelectedTitle,
                systemImage: "envelope.open",
                description: Text(l10n.selectMessageToRead)
            )
        }
    }
}

/// The navigation column, as the other region of the window's layout.
///
/// A separate type from `MessageSplitLayout` on purpose: the sidebar is a
/// control, not a surface, and it has no reader and no placeholder. Keeping it
/// separate means there is no `EmptyView` slot for a column this window does
/// not have, and no way to accidentally give the sidebar a "nothing selected"
/// state.
///
/// It also re-supplies the material the old `NavigationSplitView` provided for
/// free — migration risk #1 from the layout change. Without
/// `.regularMaterial` the column reads as a flat slab against the window
/// instead of a recessed navigation strip. The material is applied here rather
/// than in `Sidebar` because it has to cover the column the split view clips,
/// and `Sidebar` cannot know how wide that is.
struct NavigationColumnView<Content: View>: View {
    let store: ColumnLayoutStore
    @ViewBuilder var content: () -> Content

    var body: some View {
        ColumnRegionView(
            hostedColumns: [.navigation],
            panes: [AnyView(
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.regularMaterial)
            )],
            store: store
        )
    }
}
