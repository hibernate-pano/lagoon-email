import SwiftUI
import LagoonKit

/// Persistent undo surface. The toast is intentionally brief; this sheet keeps
/// reversible actions discoverable for the server's full retention window.
struct ActionHistorySheet: View {
    @EnvironmentObject private var accounts: AccountStore
    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss

    @State private var actions: [AIAction] = []
    @State private var isLoading = false
    @State private var errorBanner: ErrorBanner?
    @State private var undoingId: Int64?

    private let api = APIClient()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(l10n.actionHistory, systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Spacer()
                HStack(spacing: 6) {
                    Button(l10n.refresh) { Task { await load() } }
                        .disabled(isLoading)
                    if isLoading {
                        ProgressView().controlSize(.small)
                    }
                }
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(l10n.dismiss)
            }
            .padding(16)

            Divider()

            if isLoading, actions.isEmpty {
                ProgressView().padding(30)
            } else if actions.isEmpty {
                Text(l10n.nothingToUndo)
                    .foregroundStyle(.secondary)
                    .padding(30)
            } else {
                List(actions) { action in
                    HStack(spacing: 12) {
                        Image(systemName: icon(for: action.kind))
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(l10n.actionTitle(action.kind))
                            Text(action.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if canUndo(action) {
                            Button { Task { await undo(action) } } label: {
                                if undoingId == action.id {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text(l10n.undo)
                                }
                            }
                            .disabled(undoingId != nil)
                        } else {
                            Text(l10n.notUndoable)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .noticeBanner($errorBanner)
        .frame(width: 560, height: 460)
        .task { await load() }
    }

    private func canUndo(_ action: AIAction) -> Bool {
        guard action.kind.isUndoable else { return false }
        return action.expiresAt.map { $0 > Date() } ?? true
    }

    private func load() async {
        guard let accountId = accounts.accountId else { return }
        isLoading = true
        errorBanner = nil
        do {
            actions = try await api.fetchActions(
                accountId: accountId,
                since: Date().addingTimeInterval(-30 * 24 * 60 * 60)
            )
        } catch {
            errorBanner = ErrorBanner(
                severity: .error,
                title: l10n.undoFailedTitle,
                detail: l10n.undoFailedDetail,
                actionLabel: l10n.retry,
                action: { [self] in await self.load() }
            )
        }
        isLoading = false
    }

    private func undo(_ action: AIAction) async {
        guard let accountId = accounts.accountId else { return }
        undoingId = action.id
        errorBanner = nil
        do {
            try await api.undoAction(id: action.id, accountId: accountId)
            actions.removeAll { $0.id == action.id }
            NotificationCenter.default.post(name: .lagoonDidUndo, object: nil)
        } catch {
            errorBanner = ErrorBanner(
                severity: .error,
                title: l10n.undoFailedTitle,
                detail: l10n.undoFailedDetail,
                actionLabel: l10n.retry,
                action: { [self] in await self.undo(action) }
            )
        }
        undoingId = nil
    }

    private func icon(for kind: AIActionKind) -> String {
        switch kind {
        case .archive: "tray.and.arrow.down"
        case .markRead: "envelope.open"
        case .pin, .unpin: "pin"
        case .unsubscribe: "minus.circle"
        case .classifyOverride: "rectangle.3.group"
        case .draftCreate: "text.bubble"
        case .send: "paperplane"
        case .undo: "arrow.uturn.backward"
        case .delete: "trash"
        }
    }
}
