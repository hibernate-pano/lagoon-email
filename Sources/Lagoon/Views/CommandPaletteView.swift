import SwiftUI
import LagoonKit

/// ⌘K command palette — fuzzy-find every action Lagoon exposes. Each entry
/// is a `Command` with title + shortcut + action; the user types to filter
/// and presses Return (or clicks) to run. The sheet closes after any
/// successful invocation so the user lands on the destination surface.
///
/// The palette is deliberately a separate view (not a menu inside the
/// toolbar) because a single-character text filter is faster than a menu
/// for the actions a power user wants to keep reachable. Mail.app doesn't
/// have one; Superhuman does; Linear / Things have it as the primary
/// navigation surface. We're closer to the latter.
struct CommandPaletteView: View {
    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss

    /// Callers wire these up so the palette can navigate the outer shell.
    let onNewMessage: () -> Void
    let onSearch: () -> Void
    /// ⌘0 toggles between the two surfaces — it is not "go to briefing"
    /// and not "go to all messages". One callback, one row, one key.
    let onToggleSurface: () -> Void
    let onShowUsage: () -> Void
    let onShowActionHistory: () -> Void
    let onShowAdvice: () -> Void
    /// The reminders the user set for themselves.
    let onShowReminders: () -> Void
    /// 发件人排行 — who writes the most, ranked.
    let onShowSenderRanking: () -> Void
    /// Advances to the next density and reports which one, so the palette row
    /// shows the action's result rather than just its name.
    let onCycleDensity: () -> Void
    let onShowShortcuts: () -> Void
    let onShowAISettings: () -> Void
    /// Re-read what is already fetched — a local round trip.
    let onRefresh: () -> Void
    /// Ask the server to pull from IMAP, then re-read. A different verb
    /// from `onRefresh`, with a different latency, so it gets its own row.
    let onGetNewMail: () -> Void
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
    ///
    /// Internal rather than private so `CommandPaletteFilterTests` can pin
    /// the list: a command dropped or duplicated by accident is invisible
    /// in the compiler and merely "feels less useful" to the user.
    var allCommands: [Command] {
        [
            Command(id: "new-message", title: l10n.newMessage, shortcut: "⌘N", systemImage: "square.and.pencil", action: { run(onNewMessage) }),
            Command(id: "search", title: l10n.search, shortcut: "⌘F", systemImage: "magnifyingglass", action: { run(onSearch) }),
            Command(id: "toggle-surface", title: l10n.toggleSurface, shortcut: "⌘0", systemImage: "rectangle.grid.2x2", action: { run(onToggleSurface) }),
            // Two refresh verbs, two rows, two keys. "刷新" re-reads what the
            // server already has (fast, local); "获取新邮件" asks the mail
            // server for more (slow, a network round trip). One row for both
            // would make the fast one look broken.
            Command(id: "refresh", title: l10n.refresh, shortcut: "⌥⌘R", systemImage: "arrow.clockwise", action: { run(onRefresh) }),
            Command(id: "get-new-mail", title: l10n.menuGetNewMail, shortcut: "⇧⌘N", systemImage: "tray.and.arrow.down", action: { run(onGetNewMail) }),
            Command(id: "usage", title: l10n.budgetThisMonth, shortcut: "⌘B", systemImage: "chart.bar", action: { run(onShowUsage) }),
            Command(id: "ai-settings", title: l10n.aiSettingsTitle, shortcut: nil, systemImage: "sparkles", action: { run(onShowAISettings) }),
            Command(id: "advice", title: l10n.adviceTitle, shortcut: "⇧⌘A", systemImage: "sparkles", action: { run(onShowAdvice) }),
            // Next to the advice queue, because the two are the two halves
            // of the same promise: the advice queue is what the AI suggests,
            // and this is what the *user* set. A user who reads the
            // suggestion "this needs a reply by Friday" and does nothing
            // must be able to find the reminder they set for it.
            Command(id: "reminders", title: l10n.reminderTitle, shortcut: nil, systemImage: "bell", action: { run(onShowReminders) }),
            Command(id: "senders", title: l10n.senderRankingTitle, shortcut: nil, systemImage: "person.2", action: { run(onShowSenderRanking) }),
            // Density lives here rather than in the list's own toolbar row: that
            // row was already at the point where the surface title wrapped to
            // one glyph per line, and the density control was the control that
            // pushed it over. The palette has room, and ⌘K is already the
            // power-user path for everything that does not fit on a bar.
            Command(id: "density", title: l10n.densityTitle, shortcut: nil, systemImage: "line.3.horizontal.decrease", action: { run(onCycleDensity) }),
            Command(id: "history", title: l10n.actionHistory, shortcut: nil, systemImage: "clock.arrow.circlepath", action: { run(onShowActionHistory) }),
            Command(id: "shortcuts", title: l10n.keyboardShortcuts, shortcut: "⌘/", systemImage: "questionmark.circle", action: { run(onShowShortcuts) }),
            Command(id: "sound", title: l10n.soundEnabled, shortcut: nil, systemImage: "speaker.wave.2", action: { run(onToggleSound) }),
        ]
    }

    /// Substring match, case-insensitive. The palette is small enough
    /// (12 commands) that we don't need a real fuzzy matcher — a prefix
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
        .frame(
            width: LagoonSheetSize.standard.width,
            height: LagoonSheetSize.standard.height
        )
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
        Group {
            if filtered.isEmpty {
                // Without this the list rendered as an empty rectangle: the
                // user typed something that matched nothing and got no
                // explanation at all.
                ContentUnavailableView(
                    l10n.noMatchingCommands,
                    systemImage: "magnifyingglass",
                    description: Text(l10n.noMatchingCommandsHint)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
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
                        // VoiceOver read the row as "magnifyingglass" — the
                        // SF Symbol's name — because the icon is the first
                        // element and the label never said what the row
                        // *does*. The row's name is the command; the symbol
                        // is decoration and is hidden from the reader.
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(command.title)
                        .accessibilityValue(command.shortcut ?? "")
                        .accessibilityAddTraits(.isButton)
                    }
                }
                .listStyle(.plain)
            }
        }
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
