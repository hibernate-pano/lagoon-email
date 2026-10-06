import SwiftUI
import LagoonKit

/// The action bar that rises above the list when rows are highlighted.
///
/// ## Why this exists
///
/// Before this, a multi-selection showed a *count* and nothing else, so the
/// only way to act on five rows was the keyboard: ⌫ to archive, ⌘⌫ to delete.
/// That is a fine power-user path and a poor answer for everyone else — Foxmail,
/// QQ邮箱 and 网易邮箱大师 all surface the verbs when a selection exists.
///
/// ## Why it rises from the bottom rather than sitting in the toolbar
///
/// The toolbar is already carrying the account menu, the surface picker, two
/// primary actions and an overflow menu; the project's own comment in
/// `RootView.toolbar` notes that macOS silently overflows trailing toolbar
/// items into "»" when the row runs out of room. Adding five selection verbs
/// there would have made that overflow happen for real users. The bottom inset
/// is free — `RootView` already reserves it for the undo toast and the
/// time-saved bar — and it keeps the verbs next to the rows they apply to.
///
/// ## Every verb here is undoable
///
/// Archive and delete both go through the ordinary user-triggered routes and
/// land in the audit log, so ⌘Z reverses them. This bar adds no verb that acts
/// on mail without an undo (constitution §2 rules 3 and 6).
struct BulkActionBar: View {
    let count: Int
    let onArchive: () -> Void
    let onDelete: () -> Void
    let onMarkRead: () -> Void
    let onMarkUnread: () -> Void
    let onClear: () -> Void
    /// Archive is disabled when the server never negotiated an archive folder —
    /// the same gate the per-row button uses, so the bar cannot offer a verb
    /// the row would have refused.
    var canArchive: Bool = true
    /// 「选择服务器上的全部 N 封」— Gmail 式两段式全选的第二段。
    ///
    /// Nil when the list holds everything already, because then there is no
    /// second stage to cross and the link would be noise.
    var onSelectAllOnServer: (() -> Void)?
    /// 第二段已选中。Changes the count's meaning and shows the warning line.
    var allOnServerSelected: Bool = false
    /// 选中范围超出可见列表。Set exactly when `allOnServerSelected` is true;
    /// the user is about to act on mail they cannot see, and has to be told.
    var selectionReachesUnloaded: Bool = false
    /// 批量动词进行中。Every verb here is one remote round trip per message, so
    /// a second click mid-sweep would double-fire it.
    var isBusy: Bool = false

    @Environment(\.l10n) private var l10n

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Stage two's own line. It is a *link* rather than a button in the
            // verb row because it is not a verb — it is the answer to "does
            // 全选 mean everything?", and it has to carry the real number for
            // that answer to mean anything.
            if let onSelectAllOnServer {
                Button(action: onSelectAllOnServer) {
                    Text(l10n.selectAllOnServer(count))
                        .font(.callout)
                }
                .buttonStyle(.link)
                .disabled(isBusy)
            } else if allOnServerSelected {
                Label(l10n.allSelected(count), systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if selectionReachesUnloaded {
                // Says what is about to happen, not what already happened.
                Label(l10n.selectionReachesUnloaded, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 12) {
                Text(l10n.selectedCount(count))
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                    .accessibilityLabel(l10n.selectionCount)

                Divider().frame(height: 16)

                Button(action: onMarkRead) {
                    Label(l10n.markRead, systemImage: "envelope.open")
                }
                .help(l10n.markReadFailedTitle)

                Button(action: onMarkUnread) {
                    Label(l10n.markUnread, systemImage: "envelope")
                }
                .help(l10n.markUnread)

                Button(action: onArchive) {
                    Label(l10n.archiveSelectedTitle, systemImage: "archivebox")
                }
                .disabled(!canArchive)
                .help(canArchive ? l10n.archiveFailed : l10n.archiveUnavailable)

                Button(role: .destructive, action: onDelete) {
                    Label(l10n.deleteSelectedTitle, systemImage: "trash")
                }
                .help(l10n.deleteContext)

                Spacer(minLength: 0)

                Button(action: onClear) {
                    Label(l10n.clearSelection, systemImage: "xmark")
                }
                .help(l10n.clearSelection)
            }
            .buttonStyle(.borderless)
        }
        .disabled(isBusy)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        // Slides rather than appears: the bar is a response to the user's own
        // selection, so its arrival should point at the rows that caused it.
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}