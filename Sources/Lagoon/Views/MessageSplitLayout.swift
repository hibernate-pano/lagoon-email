import SwiftUI

/// The list/reader split both mail surfaces share: list on the left, the
/// selected message reading on the right.
///
/// This container exists so the two things that must not diverge between the
/// surfaces cannot:
///
/// * **`.toolbar(removing: .sidebarToggle)`.** `NavigationSplitView` inserts a
///   sidebar-toggle button into the *window* toolbar on its own. `RootView`
///   keeps both surfaces alive in a ZStack (opacity/disabled/allowsHitTesting
///   hides the view, never the toolbar item — see
///   `.memory/toolbar-items-escape-hidden-zstack-surfaces`), so an unremoved
///   toggle shows up twice in the corner. Declaring the removal here makes it
///   impossible to add a third surface and forget.
/// * **The "nothing selected" placeholder.** One wording, one affordance, so
///   the empty right pane reads as "pick a message" on both surfaces instead
///   of as a broken view.
///
/// It is deliberately *not* a generic detail host: the two surfaces disagree
/// about what "selected" means (the Briefing Feed is single-select, the raw
/// list is multi-select for ⌫/⌘⌫), so each derives its own `detailId` and
/// passes it in. Sharing that derivation would mean inventing a selection
/// model neither surface actually has.
struct MessageSplitLayout<Sidebar: View, Detail: View>: View {
    /// The message the reader pane shows, nil while nothing is selected.
    let detailId: String?
    /// Non-nil when several rows are selected: the pane says so instead of
    /// silently previewing one of them, because a bulk verb (⌫) is about to
    /// act on all of them and the user should see the count, not one message.
    var multiSelectionCount: Int? = nil
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var detail: () -> Detail

    @Environment(\.l10n) private var l10n

    var body: some View {
        NavigationSplitView {
            sidebar()
                // A mail list is a scannable column, not a reading surface:
                // wide enough for a subject line plus a snippet, narrow enough
                // that the reader keeps the window's better half.
                .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 460)
        } detail: {
            if detailId != nil {
                detail()
            } else {
                placeholder
            }
        }
        .toolbar(removing: .sidebarToggle)
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
