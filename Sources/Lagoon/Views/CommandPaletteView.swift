import SwiftUI
import LagoonKit

/// ⌘K command palette — fuzzy-find every action Lagoon exposes. Each entry
/// is a `Command` with title + shortcut + action; the user types to filter
/// and presses Return (or clicks) to run. The sheet closes after any
/// successful invocation so the user lands on the destination surface.
///
/// The palette is deliberately a separate view (not a menu inside the
/// toolbar) because a single-character text filter is faster than a menu
/// for the 20+ actions a power user wants to keep reachable. Mail.app
/// doesn't have one; Superhuman does; Linear / Things have it as the
/// primary navigation surface. We're closer to the latter.
struct CommandPaletteView: View {
    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss

    /// Callers wire these up so the palette can navigate the outer shell.
    let onNewMessage: () -> Void
    let onSearch: () -> Void
    let onShowBriefing: () -> Void
    let onShowAllMessages: () -> Void
    let onShowUsage: () -> Void
    let onShowActionHistory: () -> Void
    let onShowAutoArchiveRules: () -> Void
    let onShowShortcuts: () -> Void
    let onRefresh: () -> Void
    let onToggleSound: () -> Void

    @State private var query = ""
    @State private var highlightedIndex = 0
    @FocusState private var queryFocused: Bool

    /// A single palette entry. `id` must be unique within the palette so
    /// ForEach diffing works on filter changes.
    struct Command: Identifiable {
        let id: String
        let title: String
        let shortcut: String?
        let systemImage: String
        let action: () -> Void
    }

    /// All commands the palette exposes. Ordered roughly by frequency of
    /// use so a single Return invokes the most likely target before the
    /// user types anything.
    private var allCommands: [Command] {
        [
            Command(id: "new-message", title: l10n.newMessage, shortcut: "⌘N", systemImage: "square.and.pencil", action: { run(onNewMessage) }),
            Command(id: "search", title: l10n.search, shortcut: "⌘F", systemImage: "magnifyingglass", action: { run(onSearch) }),
            Command(id: "show-briefing", title: l10n.briefing, shortcut: "⌘0", systemImage: "rectangle.grid.2x2", action: { run(onShowBriefing) }),
            Command(id: "show-all", title: l10n.allMessages, shortcut: "⌘0", systemImage: "list.bullet", action: { run(onShowAllMessages) }),
            Command(id: "refresh", title: l10n.refresh, shortcut: "⌘R", systemImage: "arrow.clockwise", action: { run(onRefresh) }),
            Command(id: "usage", title: l10n.budgetThisMonth, shortcut: "⌘B", systemImage: "chart.bar", action: { run(onShowUsage) }),
            Command(id: "history", title: l10n.actionHistory, shortcut: nil, systemImage: "clock.arrow.circlepath", action: { run(onShowActionHistory) }),
            Command(id: "rules", title: l10n.autoArchiveRulesTitle, shortcut: nil, systemImage: "list.bullet.indent", action: { run(onShowAutoArchiveRules) }),
            Command(id: "shortcuts", title: l10n.commandPalette, shortcut: "⌘/", systemImage: "questionmark.circle", action: { run(onShowShortcuts) }),
            Command(id: "sound", title: l10n.soundEnabled, shortcut: nil, systemImage: "speaker.wave.2", action: { run(onToggleSound) }),
        ]
    }

    /// Substring match, case-insensitive. The palette is small enough
    /// (10 commands) that we don't need a real fuzzy matcher — a prefix
    /// or substring hit is faster and predictable.
    private var filtered: [Command] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return allCommands }
        return allCommands.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    /// Closes the sheet and runs the action. `run` is called from the
    /// action closure rather than the `onSubmit` so we don't double-fire
    /// when the user clicks the highlighted row.
    private func run(_ action: () -> Void) {
        action()
        dismiss()
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            commandList
        }
        .frame(width: 520, height: 360)
        .onAppear { queryFocused = true }
        // Keep the highlight in range as the user types.
        .onChange(of: query) { _, _ in
            highlightedIndex = min(highlightedIndex, max(0, filtered.count - 1))
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(l10n.commandPalettePlaceholder, text: $query)
                .textFieldStyle(.plain)
                .focused($queryFocused)
                .onSubmit { invokeHighlighted() }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var commandList: some View {
        List(selection: $highlightedIndex) {
            ForEach(Array(filtered.enumerated()), id: \.element.id) { index, command in
                Button {
                    command.action()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: command.systemImage)
                            .frame(width: 22)
                            .foregroundStyle(.secondary)
                        Text(command.title)
                        Spacer()
                        if let shortcut = command.shortcut {
                            Text(shortcut)
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .tag(index)
            }
        }
        .listStyle(.plain)
        .onMoveCommand { direction in
            switch direction {
            case .down: moveHighlight(by: 1)
            case .up: moveHighlight(by: -1)
            case .left, .right: break
            @unknown default: break
            }
        }
    }

    private func invokeHighlighted() {
        guard filtered.indices.contains(highlightedIndex) else { return }
        filtered[highlightedIndex].action()
    }

    private func moveHighlight(by delta: Int) {
        guard !filtered.isEmpty else { return }
        let next = highlightedIndex + delta
        highlightedIndex = max(0, min(filtered.count - 1, next))
    }
}