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
    @State private var errorMessage: String?
    @State private var path: [String] = []
    private let api = APIClient()

    var body: some View {
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
            if let errorMessage {
                VStack(spacing: 8) {
                    Text(l10n.searchFailed + errorMessage)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                    Button(l10n.retry) { Task { await run() } }
                }
                .padding(20)
            } else if isLoading { ProgressView().padding(20) }
            else if results.isEmpty { Text(l10n.noResults).foregroundStyle(.secondary).padding(20) }
            else {
                List(results) { m in
                    NavigationLink(value: m.remoteId) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.subject ?? l10n.noSubject).bold(!m.isRead).lineLimit(1)
                            HStack {
                                Text(m.fromName ?? m.fromAddress).font(.caption).foregroundStyle(.secondary)
                                Text(m.receivedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 640, height: 480)
        .navigationDestination(for: String.self) { remoteId in
            if let accountId = accounts.accountId {
                NavigationStack {
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
                        }
                    )
                }
            }
        }
    }

    func run() async {
        guard let accountId = accounts.accountId, !query.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        do {
            results = try await api.search(query: query, accountId: accountId)
        } catch {
            results = []
            errorMessage = error.lagoonUIMessage
        }
        isLoading = false
    }
}
