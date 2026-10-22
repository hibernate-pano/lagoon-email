import SwiftUI
import LagoonKit

/// Keyboard shortcuts cheatsheet — invoked via ⌘/ (or the "Shortcuts"
/// entry in the ⌘K palette). The list is intentionally hand-curated, not
/// auto-discovered: the right set to surface is "every shortcut a power
/// user needs to know about", not "every shortcut that happens to exist
/// in the code". This is a learning surface as much as a reference.
///
/// ## Why every row says where it works
///
/// A row that names a key without saying *where* it applies teaches a
/// gesture that silently does nothing in the wrong surface: the user reads
/// "⌫ 归档选中" on the Briefing, presses ⌫, and nothing happens — with no
/// explanation anywhere. The scope chip is not decoration; it is the
/// difference between a cheatsheet and a list of keys.
///
/// ## Why the ranges are exact
///
/// "⌘1–⌘9" was taught for years while only ⌘1–⌘5 were bound — the
/// group-jump binding is generated from `BriefingGroup.allCases`, and that
/// enum has five cases. A ghost key in a cheatsheet is worse than no
/// cheatsheet: the user presses it once, sees nothing, and stops trusting
/// the whole sheet.
struct ShortcutsSheet: View {
    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss

    /// Where a shortcut applies.
    ///
    /// An enum rather than a free string so the scope column is consistent
    /// and so a row cannot claim a scope that does not exist.
    enum Scope: String, CaseIterable, Sendable {
        /// Anywhere in the app.
        case global
        /// Only the Briefing surface.
        case briefing
        /// Either mail-list surface (Briefing or the inbox).
        case lists
        /// Only the inbox surface.
        case list
        /// Only while a message is open in the reader.
        case reader
        /// Only inside the compose window.
        case composer

        /// The scope's name, in the current language.
        ///
        /// Takes the localizer as an argument rather than reading the
        /// environment: `Scope` is a nested type, so it has no access to
        /// the view's `@Environment`.
        func label(_ l10n: L10n) -> String {
            switch self {
            case .global: return l10n.shortcutScopeGlobal
            case .briefing: return l10n.shortcutScopeBriefing
            case .lists: return l10n.shortcutScopeLists
            case .list: return l10n.shortcutScopeList
            case .reader: return l10n.shortcutScopeReader
            case .composer: return l10n.shortcutScopeComposer
            }
        }
    }

    /// A single shortcut entry. `keys` is rendered as the macOS-style
    /// symbols (⌘ ⇧ ⌥ ⌃) by the row builder.
    struct Entry: Identifiable {
        let id: String
        let keys: String
        let description: String
        /// Where the key works. Mandatory on purpose: a row without a scope
        /// is the UX-65 defect, and the compiler is the cheapest place to
        /// prevent it.
        let scope: Scope
    }

    /// Internal rather than private so `CommandPaletteFilterTests` can pin
    /// the list's content. A hand-curated cheatsheet rots silently: nothing
    /// in the compiler notices a dropped row or a key that only exists in
    /// one language.
    var entries: [Entry] {
        [
            // Navigation
            // ⌘[ is Mail.app's "back" muscle memory, re-pointed at the one
            // thing it can mean on a mail-list surface: clear the
            // selection. The row used to describe it as 「返回上一级」 —
            // a gesture the list surfaces do not have, taught with the
            // certainty of a key that is bound everywhere.
            Entry(id: "back", keys: "⌘[", description: l10n.deselectHelp, scope: .lists),
            Entry(id: "briefing", keys: "⌘0", description: l10n.surfaceHelp, scope: .global),
            Entry(id: "groupJump", keys: "⌘1–⌘\(BriefingGroup.allCases.count)", description: l10n.shortcutGroupJump, scope: .briefing),
            Entry(id: "search", keys: "⌘F", description: l10n.shortcutSearch, scope: .global),
            Entry(id: "palette", keys: "⌘K", description: l10n.commandPalette, scope: .global),
            Entry(id: "shortcuts", keys: "⌘/", description: l10n.keyboardShortcuts, scope: .global),
            Entry(id: "budget", keys: "⌘B", description: l10n.shortcutBudget, scope: .global),
            Entry(id: "advice", keys: "⇧⌘A", description: l10n.shortcutAdvice, scope: .global),
            // ⇧⌘N is the *server* round trip (ask IMAP for new mail); ⌥⌘R
            // below is the local one (re-read what is already fetched). Two
            // different verbs, so two different keys — a user who only knows
            // one of them still gets new mail, and the other is a shortcut to
            // a re-render.
            Entry(id: "getNewMail", keys: "⇧⌘N", description: l10n.menuGetNewMail, scope: .global),

            // Briefing feed
            Entry(id: "next", keys: "J", description: l10n.shortcutJ, scope: .lists),
            Entry(id: "prev", keys: "K", description: l10n.shortcutK, scope: .lists),
            Entry(id: "markAllRead", keys: "⇧⌘K", description: l10n.markAllReadHelp, scope: .briefing),

            // Compose / actions
            Entry(id: "new", keys: "⌘N", description: l10n.newMessageHelp, scope: .global),
            Entry(id: "reply", keys: "⌘R", description: l10n.replyHelp, scope: .reader),
            Entry(id: "replyAll", keys: "⇧⌘R", description: l10n.replyAllHelp, scope: .reader),
            Entry(id: "forward", keys: "⇧⌘F", description: l10n.forwardHelp, scope: .reader),
            // The row names the surface, not just the key: "⌘↩" on its
            // own is a gesture the reader cannot perform, and a cheatsheet
            // that teaches it there teaches a key that does nothing.
            Entry(id: "send", keys: "⌘↩", description: l10n.shortcutSendScope, scope: .composer),
            // ⇧⌘P, not ⌘P: on macOS ⌘P is print, and a mail client that
            // hijacks it silently changes the message's state when the user
            // meant to print it.
            Entry(id: "pin", keys: "⇧⌘P", description: l10n.pinHelp, scope: .reader),
            Entry(id: "summarize", keys: "⌘D", description: l10n.shortcutSummarize, scope: .reader),
            Entry(id: "draft", keys: "⇧⌘D", description: l10n.shortcutDraft, scope: .reader),
            Entry(id: "archiveNext", keys: "⌘E", description: l10n.shortcutArchiveNext, scope: .reader),

            // List-surface gestures. Bound via `onDeleteCommand`, not
            // `keyboardShortcut`, so they are invisible to a grep of the
            // latter — which is exactly how they went undocumented.
            Entry(id: "selectAll", keys: "⌘A", description: l10n.shortcutSelectAll, scope: .list),
            Entry(id: "archiveSelected", keys: "⌫", description: l10n.shortcutArchiveSelected, scope: .lists),
            Entry(id: "deleteSelected", keys: "⌘⌫", description: l10n.shortcutDeleteSelected, scope: .list),

            // Global
            Entry(id: "undo", keys: "⌘Z", description: l10n.shortcutZ, scope: .global),
            Entry(id: "refresh", keys: "⌥⌘R", description: l10n.shortcutRefresh, scope: .global),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(l10n.keyboardShortcuts).font(.headline)
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
                    Text(Self.body(of: entry.description))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    // The scope chip: a quiet badge that says where the key
                    // works. `.global` rows carry no chip — "everywhere" is
                    // the default and a chip on every row would be noise.
                    if entry.scope != .global {
                        Text(entry.scope.label(l10n))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary.opacity(0.4), in: Capsule())
                    }
                }
                .padding(.vertical, 2)
            }
            .listStyle(.inset)
        }
        .frame(
            width: LagoonSheetSize.wide.width,
            height: LagoonSheetSize.wide.height
        )
    }

    /// The description with the key stripped out.
    ///
    /// The L10n strings carry their key so they can double as button
    /// tooltips ("⌘F = 搜索"). In the cheatsheet the key already has its own
    /// column, so leaving it in the text reads as a stutter. Two shapes
    /// exist in the strings: a leading "KEY = " and a trailing "（KEY）".
    ///
    /// The trailing form is only stripped when it actually contains a key
    /// symbol — "全选已加载的邮件（不包含未加载的）" is a *qualification*,
    /// not a key, and dropping it would remove the one thing that tells the
    /// user how dangerous ⌘A is.
    static func body(of description: String) -> String {
        if let range = description.range(of: " = ") {
            let head = description[..<range.lowerBound]
            if !head.isEmpty, !head.contains(" ") {
                return String(description[range.upperBound...])
            }
        }
        if let open = description.range(of: "（"),
           let close = description.range(of: "）", range: open.upperBound..<description.endIndex),
           close.upperBound == description.endIndex {
            let inner = description[open.upperBound..<close.lowerBound]
            if inner.contains(where: { "⌘⇧⌥⌃".contains($0) }) {
                return String(description[..<open.lowerBound])
            }
        }
        return description
    }
}
