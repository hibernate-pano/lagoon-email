import SwiftUI
import LagoonKit

/// 发件人归集：all received mail from one sender, newest first, served by
/// `GET /api/messages?sender=<address>` (exact `from_address` match — the
/// full history, not just the loaded window). Hosts its own NavigationStack
/// so a tapped message opens inside the sheet (same contract as
/// `SearchSheet`: a `NavigationLink(value:)` needs a stack in scope).
struct SenderSheet: View {
    let accountId: UUID
    let senderAddress: String
    let senderName: String?

    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss
    @State private var messages: [MessageHeader] = []
    @State private var isLoading = true
    @State private var errorBanner: ErrorBanner?
    @State private var path: [String] = []
    private let api = APIClient()

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(senderName ?? senderAddress)
                            .font(.headline)
                            .lineLimit(1)
                        if senderName != nil {
                            Text(senderAddress)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Button(l10n.close) { dismiss() }
                }
                .padding(12)
                Divider()
                if isLoading {
                    ProgressView().padding(20)
                } else if messages.isEmpty {
                    Text(l10n.senderMailEmpty)
                        .foregroundStyle(.secondary)
                        .padding(20)
                } else {
                    List(messages) { m in
                        NavigationLink(value: m.remoteId) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(m.subject ?? l10n.noSubject)
                                        .font(.body)
                                        .bold(!m.isRead)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(m.receivedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                if let snippet = m.snippet, !snippet.isEmpty {
                                    Text(snippet)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .navigationDestination(for: String.self) { remoteId in
                MessageDetailView(
                    remoteId: remoteId,
                    accountId: accountId,
                    header: messages.first { $0.remoteId == remoteId },
                    initiallyPinned: false,
                    siblings: messages.map(\.remoteId),
                    onArchived: { id, _ in
                        messages.removeAll { $0.remoteId == id }
                    },
                    onAdvanceTo: { next in
                        path = next.map { [$0] } ?? []
                    }
                )
                // Same reset contract as the other destinations: without this
                // the destination reuses the previous message's @State.
                .id(remoteId)
            }
        }
        .frame(width: 640, height: 560)
        .noticeBanner($errorBanner)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await api.fetchMessages(
                accountId: accountId, limit: 200, sender: senderAddress
            )
            messages = response.messages
        } catch {
            errorBanner = ErrorBanner(severity: .error, title: l10n.loadFailed, detail: error.lagoonUIMessage)
        }
    }
}
