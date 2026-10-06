import SwiftUI

/// The window's three columns, and the two things that must not diverge between
/// the mail surfaces.
///
/// ## What this is
///
/// The list/reader pair the Briefing Feed and the raw list share, plus the
/// navigation column the window puts beside them. `RootView` owns the window and
/// hands every surface the same `ColumnWidthStore`, so all three columns solve as
/// one weighted system rather than as two nested ones.
///
/// The shape this replaces was an outer `NavigationSplitView` here wrapping an
/// inner one inside each surface. Two independent constraint systems both answered
/// "how wide is the list?", and the list's width was their *intersection* — which
/// is what the user felt as a divider that drifted behind the pointer and a list
/// that hit an invisible wall well before its own minimum. One store and one
/// `HStack` remove the second opinion.
///
/// ## Why there is no `NavigationSplitView` here, and there must never be one again
///
/// `NavigationSplitView` inserts a sidebar-toggle button into the **window**
/// toolbar on its own. `RootView` keeps both surfaces alive in a ZStack (opacity /
/// disabled / allowsHitTesting / accessibilityHidden hide a view, never a toolbar
/// item — see `.memory/toolbar-items-escape-hidden-zstack-surfaces`), so two
/// surfaces each produced a toggle and the window showed it twice in the corner.
///
/// The old guard was `.toolbar(removing: .sidebarToggle)`, declared here so a third
/// surface could not forget it. That guard is gone with the split views it guarded:
/// the rule now is the absence of the thing that made a toggle appear at all. A
/// behavioural test cannot catch this — re-adding `NavigationSplitView` would
/// compile, every width would still solve, every drag would still work, and the
/// window would show a duplicate toggle — so the guard is a test that reads the
/// source. See `ColumnLayoutGuardTests`.
///
/// The sidebar keeps its own disclosure affordance in `Sidebar`; that is a control
/// the app draws, not one AppKit injects.
///
/// ## The reader is not hoisted
///
/// The reader's selection is per-surface: the Briefing Feed is single-select, the
/// raw list is multi-select for ⌫/⌘⌫, and each owns its own `MessageDetailView`,
/// its own poll and its own scroll position. Hoisting it to `RootView` would mean
/// inventing a selection model neither surface actually has. So each surface
/// supplies its own reader, and this layout decides only the *widths*.
struct MessageSplitLayout<List: View, Detail: View>: View {
    /// The window's shared widths. One store, one authority.
    let store: ColumnWidthStore

    /// The message the reader pane shows, nil while nothing is selected.
    let detailId: String?

    /// Non-nil when several rows are selected: the pane says so instead of
    /// silently previewing one of them, because a bulk verb (⌫) is about to act on
    /// all of them and the user should see the count, not one message.
    var multiSelectionCount: Int? = nil

    /// The list column's content.
    @ViewBuilder var sidebar: () -> List

    /// The reader column's content.
    @ViewBuilder var detail: () -> Detail

    @Environment(\.l10n) private var l10n

    var body: some View {
        TwoColumnLayout(store: store) {
            sidebar()
        } reader: {
            if detailId != nil {
                detail()
            } else {
                placeholder
            }
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if let count = multiSelectionCount, count > 1 {
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

/// The list and the reader, as two columns of the window's shared layout.
///
/// Deliberately **not** a `NavigationSplitView`. This is the inner half of the
/// nesting the layout rewrite removed, expressed as the same `HStack` the outer
/// navigation column uses — so a drag on either boundary moves all three columns
/// through one solve rather than two.
struct TwoColumnLayout<List: View, Reader: View>: View {
    /// The window's shared widths. Injected rather than created here so the
    /// navigation column beside it solves against the same numbers.
    let store: ColumnWidthStore

    @ViewBuilder var list: () -> List
    @ViewBuilder var reader: () -> Reader

    var body: some View {
        // No `.frame(minWidth:)` on this view. The window's floor is the
        // *window's* business — it depends on all three columns — so `RootView`
        // states it once. A per-surface minimum is what previously sat at 720
        // while the three columns needed 820, guaranteeing a breach on every
        // narrow window (`docs/三栏宽度求解器-实测结论.md`, conclusion 2).
        HStack(spacing: 0) {
            store.column(.list) { list() }
            ColumnDivider(
                column: .list,
                invertedColumn: store.hasReader ? .reader : nil,
                store: store,
            )
            .frame(width: ColumnLayoutMetrics.dividerHitWidth)
            store.column(.reader) { reader() }
        }
    }
}

/// The navigation column, as the other side of the window's layout.
///
/// A separate type on purpose: the sidebar is a control, not a surface, and it
/// has no reader and no placeholder. Keeping it separate means there is no
/// `EmptyView` slot for a column this window does not have.
///
/// It also re-supplies the material the old `NavigationSplitView` provided for
/// free. Without `.regularMaterial` the column reads as a flat slab against the
/// window instead of a recessed navigation strip — migration risk #1 from the
/// layout change. The material is applied here rather than in `Sidebar` because
/// it has to cover the column the layout clips, and `Sidebar` cannot know how
/// wide that is.
struct NavigationColumnView<Content: View>: View {
    let store: ColumnWidthStore
    @ViewBuilder var content: () -> Content

    var body: some View {
        store.column(.navigation) {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial)
        }
    }
}
