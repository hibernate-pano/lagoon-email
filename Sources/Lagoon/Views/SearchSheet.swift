import SwiftUI
import LagoonKit

/// Global search (server: `GET /api/search?q=...&accountId=...`).
struct SearchSheet: View {
    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var accounts: AccountStore
    @State private var query = ""
    @State private var results: [MessageHeader] = []
    @State private var isLoading = false
    @State private var errorBanner: ErrorBanner?
    @State private var path: [String] = []
    private let api = APIClient()

    var body: some View {
        // `NavigationLink(value:)` only pushes when a NavigationStack is in
        // scope; previously the stack lived *inside* the destination closure,
        // so tapping a result did nothing. Bind `path` here too.
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(l10n.searchPlaceholder, text: $query)
                        .textFieldStyle(.plain)
                        .onSubmit { Task { await run() } }
                    if !query.isEmpty {
                        Button { query = ""; results = [] } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Button(l10n.search) { Task { await run() } }
                        .disabled(query.isEmpty || isLoading)
                }
                .padding(12)
                Divider()
                if isLoading { ProgressView().padding(20) }
                else if results.isEmpty { Text(l10n.noResults).foregroundStyle(.secondary).padding(20) }
                else {
                    List(results) { m in
                        NavigationLink(value: m.remoteId) {
                            VStack(alignment: .leading, spacing: 3) {
                                highlightedText(
                                    m.subject ?? l10n.noSubject,
                                    term: query,
                                    bold: !m.isRead
                                )
                                .lineLimit(1)
                                HStack {
                                    highlightedText(
                                        m.fromName ?? m.fromAddress,
                                        term: query,
                                        font: .caption,
                                        color: .secondary
                                    )
                                    .lineLimit(1)
                                    Text(m.receivedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                if let snippet = m.snippet, !snippet.isEmpty {
                                    highlightedText(
                                        snippet,
                                        term: query,
                                        font: .caption2,
                                        color: .secondary
                                    )
                                    .lineLimit(2)
                                }
                            }
                        }
                    }
                }
            }
            .navigationDestination(for: String.self) { remoteId in
                if let accountId = accounts.accountId {
                    MessageDetailView(
                        remoteId: remoteId,
                        accountId: accountId,
                        header: results.first { $0.remoteId == remoteId },
                        initiallyPinned: false,
                        siblings: results.map(\.remoteId),
                        onArchived: { id, _ in
                            results.removeAll { $0.remoteId == id }
                        },
                        onAdvanceTo: { next in
                            path = next.map { [$0] } ?? []
                        },
                        onDelete: { id in
                            results.removeAll { $0.remoteId == id }
                            path = []
                        }
                    )
                    // Same reset contract as the BriefingFeed/MessageList
                    // entries: without this the destination reuses the
                    // previous message's @State (stale body, stale height).
                    .id(remoteId)
                }
            }
        }
        .noticeBanner($errorBanner)
        .frame(width: 640, height: 480)
        .background {
            Button(l10n.back) {
                if !path.isEmpty { path.removeLast() }
            }
            .keyboardShortcut("[", modifiers: .command)
            .help(l10n.backHelp)
            .frame(width: 0, height: 0)
            .opacity(0)
            .focusable(false)
            .accessibilityHidden(true)
        }
    }

    func run() async {
        guard let accountId = accounts.accountId, !query.isEmpty else { return }
        isLoading = true
        errorBanner = nil
        do {
            results = try await api.search(query: query, accountId: accountId)
        } catch {
            results = []
            errorBanner = ErrorBanner(
                severity: .error,
                title: l10n.searchFailedTitle,
                detail: l10n.searchFailedDetail,
                actionLabel: l10n.retry,
                action: { [self] in await self.run() }
            )
        }
        isLoading = false
    }

    /// Render `text` with every case-insensitive occurrence of `term`
    /// highlighted in a yellow rounded background. Used to mark the
    /// user's search hits inside a result row so they can see *why* a
    /// given message matched before they open it.
    ///
    /// Built as a single `AttributedString` so styling stays consistent
    /// across matched and unmatched segments; the `Text` returned here
    /// lets the caller chain `.lineLimit` / `.foregroundStyle` modifiers
    /// if needed.
    private func highlightedText(
        _ text: String,
        term: String,
        font: Font? = nil,
        bold: Bool = false,
        color: Color? = nil,
        lineLimit: Int? = nil
    ) -> Text {
        var attr = AttributedString(text)
        if let font { attr.font = font }
        if bold {
            // `attr.font` is an optional, and `Font.bold()` returns a Font.
            // The compact assignment form below avoids the
            // if-let-with-side-effect-in-ViewBuilder pitfall.
            attr.font = (attr.font ?? .body).bold()
        }
        if let color { attr.foregroundColor = color }

        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty,
           let range = attr.range(of: trimmed, options: .caseInsensitive) {
            attr[range].backgroundColor = .yellow.opacity(0.35)
        }
        return Text(attr)
    }
}
