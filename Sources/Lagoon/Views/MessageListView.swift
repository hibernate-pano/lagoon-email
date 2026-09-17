import SwiftUI
import LagoonKit

/// Raw conversation list (spec §7.1) - the secondary surface reachable from
/// the Briefing Feed. Each row drills into the message body.
struct MessageListView: View {
    @EnvironmentObject var accounts: AccountStore
    @State private var messages: [MessageHeader] = []
    @State private var isLoading = false
    @State private var errorBanner: ErrorBanner?
    @State private var path: [String] = []
    private let api = APIClient()

    /// Switches back to the Briefing Feed from the toolbar button.
    var onShowBriefing: () -> Void = {}

    private static let refreshInterval: Duration = .seconds(30)

    @Environment(\.l10n) private var l10n

    var body: some View {
        NavigationStack(path: $path) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text(l10n.allMessages)
                        .font(.headline)
                    Spacer()
                    if isLoading {
                        ProgressView().controlSize(.small)
                    }
                    Button {
                        onShowBriefing()
                    } label: {
                        Label(l10n.briefing, systemImage: "rectangle.grid.2x2")
                    }
                    .keyboardShortcut("0", modifiers: .command)
                    .help(l10n.backToBriefingHelp)
                    Button(l10n.refresh) {
                        Task { await refresh() }
                    }
                    .disabled(isLoading)
                    .keyboardShortcut("r", modifiers: .command)
                    .help(l10n.shortcutRefresh)
                }
                .padding()

                if !messages.isEmpty {
                    List(messages) { m in
                        NavigationLink(value: m.remoteId) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.subject ?? l10n.noSubject)
                                    .font(.body)
                                    .bold(!m.isRead)
                                    .lineLimit(1)
                                HStack(spacing: 6) {
                                    Text(m.fromName ?? m.fromAddress)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(m.receivedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                if let snippet = m.snippet {
                                    Text(snippet)
                                        .font(.caption2)
                                        .lineLimit(2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .listStyle(.inset)
                } else if !isLoading && errorBanner == nil {
                    Text(l10n.noMessagesYet)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationDestination(for: String.self) { remoteId in
                destination(for: remoteId)
            }
        }
        .noticeBanner($errorBanner)
        .frame(minWidth: 720, minHeight: 480)
        // Initial load, then track the server's 30s poller while visible.
        // SwiftUI cancels the task when the view disappears.
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

    // MARK: - Navigation

    @ViewBuilder
    private func destination(for remoteId: String) -> some View {
        if let accountId = accounts.accountId {
            let header = messages.first { $0.remoteId == remoteId }
            MessageDetailView(
                remoteId: remoteId,
                accountId: accountId,
                header: header,
                // We don't render pin state in the raw list; the detail
                // still loads / toggles it via the server.
                initiallyPinned: false,
                siblings: messages.map(\.remoteId),
                onArchived: { id, _ in
                    messages.removeAll { $0.remoteId == id }
                },
                onAdvanceTo: { next in
                    path = next.map { [$0] } ?? []
                },
                onReadStateChange: { remoteId, isRead in
                    setRead(remoteId: remoteId, isRead: isRead)
                },
                onPinnedChanged: { _ in
                    Task { await refresh() }
                }
            )
            .id(remoteId)
        } else {
            ContentUnavailableView(
                l10n.notConnected,
                systemImage: "person.crop.circle.badge.exclamationmark",
                description: Text(l10n.connectToRead)
            )
        }
    }

    private func setRead(remoteId: String, isRead: Bool) {
        guard let index = messages.firstIndex(where: { $0.remoteId == remoteId }) else { return }
        let message = messages[index]
        messages[index] = MessageHeader(
            id: message.id,
            accountId: message.accountId,
            remoteId: message.remoteId,
            threadId: message.threadId,
            fromAddress: message.fromAddress,
            fromName: message.fromName,
            subject: message.subject,
            snippet: message.snippet,
            receivedAt: message.receivedAt,
            isRead: isRead,
            isArchived: message.isArchived
        )
    }

    // MARK: - Sync

    private func refresh() async {
        guard let id = accounts.accountId else { return }
        guard !isLoading else { return }
        isLoading = true
        errorBanner = nil
        do {
            let resp = try await api.fetchMessages(accountId: id)
            messages = resp.messages
            accounts.setLastSync(resp)
        } catch {
            errorBanner = ErrorBanner(
                severity: .error,
                title: l10n.syncFailed + error.lagoonUIMessage,
                actionLabel: l10n.retry,
                action: { [self] in await self.refresh() }
            )
        }
        isLoading = false
    }
}
