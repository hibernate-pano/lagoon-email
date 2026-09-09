import SwiftUI
import LagoonKit

struct MessageListView: View {
    @EnvironmentObject var accounts: AccountStore
    @State private var messages: [MessageHeader] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    private let api = APIClient()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Briefing (M0 stub)")
                    .font(.headline)
                Spacer()
                if isLoading {
                    ProgressView().controlSize(.small)
                }
                Button("Refresh") {
                    Task { await refresh() }
                }
            }
            .padding()

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

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
                        Text(m.receivedAt, style: .date)
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
        .frame(minWidth: 720, minHeight: 480)
        .task { await refresh() }
    }

    private func refresh() async {
        guard let id = accounts.accountId else { return }
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