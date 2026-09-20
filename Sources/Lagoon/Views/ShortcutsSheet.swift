import SwiftUI
import LagoonKit

/// Keyboard shortcuts cheatsheet — invoked via ⌘/ (or the "Shortcuts"
/// entry in the ⌘K palette). The list is intentionally hand-curated, not
/// auto-discovered: the right set to surface is "every shortcut a power
/// user needs to know about", not "every shortcut that happens to exist
/// in the code". This is a learning surface as much as a reference.
struct ShortcutsSheet: View {
    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss

    /// A single shortcut entry. `keys` is rendered as the macOS-style
    /// symbols (⌘ ⇧ ⌥ ⌃) by the row builder.
    struct Entry: Identifiable {
        let id: String
        let keys: String
        let description: String
    }

    private var entries: [Entry] {
        [
            // Navigation
            Entry(id: "back", keys: "⌘[", description: l10n.backHelp),
            Entry(id: "briefing", keys: "⌘0", description: l10n.surfaceHelp),
            Entry(id: "search", keys: "⌘F", description: l10n.shortcutSearch),
            Entry(id: "palette", keys: "⌘K", description: l10n.commandPalette),
            Entry(id: "shortcuts", keys: "⌘/", description: l10n.shortcutHelp),

            // Briefing feed
            Entry(id: "next", keys: "J", description: l10n.shortcutJ),
            Entry(id: "prev", keys: "K", description: l10n.shortcutK),
            Entry(id: "open", keys: "↩", description: l10n.openSelected),
            Entry(id: "markAllRead", keys: "⇧⌘K", description: l10n.markAllReadHelp),

            // Compose / actions
            Entry(id: "new", keys: "⌘N", description: l10n.newMessageHelp),
            Entry(id: "reply", keys: "⌘R", description: l10n.replyHelp),
            Entry(id: "replyAll", keys: "⇧⌘R", description: l10n.replyAllHelp),
            Entry(id: "forward", keys: "⇧⌘F", description: l10n.forwardHelp),
            Entry(id: "send", keys: "⌘↩", description: l10n.shortcutSend),
            Entry(id: "pin", keys: "⌘P", description: l10n.pinHelp),
            Entry(id: "summarize", keys: "⌘D", description: l10n.shortcutSummarize),
            Entry(id: "draft", keys: "⇧⌘D", description: l10n.shortcutDraft),
            Entry(id: "archiveNext", keys: "⌘E", description: l10n.shortcutArchiveNext),

            // Global
            Entry(id: "undo", keys: "⌘Z", description: l10n.shortcutZ),
            Entry(id: "refresh", keys: "⌘R", description: l10n.shortcutRefresh),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(l10n.shortcutHelp).font(.headline)
                Spacer()
                Button(l10n.done) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            List(entries) { entry in
                HStack(spacing: 16) {
                    Text(entry.keys)
                        .font(.callout.monospaced())
                        .foregroundStyle(.primary)
                        .frame(minWidth: 88, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                    Text(entry.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 2)
            }
            .listStyle(.inset)
        }
        .frame(width: 560, height: 480)
    }
}