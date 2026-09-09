import SwiftUI
import LagoonKit

struct MessageListView: View {
    @EnvironmentObject var accounts: AccountStore
    @State private var messages: [MessageHeader] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    private let api = APIClient()

    /// Raw conversation list is a secondary view (spec §7.1); this returns to
    /// the Briefing Feed.
    var onShowBriefing: () -> Void = {}

    private static let refreshInterval: Duration = .seconds(30)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("All messages")
                    .font(.headline)
                Spacer()
                if isLoading {
                    ProgressView().controlSize(.small)
                }
                Button {
                    onShowBriefing()
                } label: {
                    Label("Briefing", systemImage: "rectangle.grid.1x2")
                }
                .keyboardShortcut("0", modifiers: .command)
                .help("Back to the Briefing Feed (⌘0)")
                Button("Refresh") {
                    Task { await refresh() }
                }
                .disabled(isLoading)
            }
            .padding()

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            if messages.isEmpty && !isLoading {
                Text("No messages yet — the server is still syncing.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(messages) { m in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.subject ?? "(no subject)")
                            .font(.body)
                            .bold(!m.isRead)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(m.fromName ?? m.fromAddress)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(m.receivedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        if let snippet = m.snippet {
                            Text(snippet)
                                .font(.caption2)
                                .lineLimit(2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        // Initial load, then track the server's 30s poller while visible.
        // SwiftUI cancels this task when the view disappears.
        .task {
            await refresh()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.refreshInterval)
                } catch {
                    return
                }
                await refresh()
            }
        }
    }

    private func refresh() async {
        guard let id = accounts.accountId else { return }
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            let resp = try await api.fetchMessages(accountId: id)
            messages = resp.messages
            accounts.setLastSync(resp)
        } catch {
            errorMessage = "Sync failed: \(error.localizedDescription). Is the server running?"
        }
        isLoading = false
    }
}
