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
    @State private var errorMessage: String?
    @State private var undoingId: Int64?

    private let api = APIClient()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(l10n.actionHistory, systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Spacer()
                Button(l10n.refresh) { Task { await load() } }
                    .disabled(isLoading)
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            Divider()

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .padding()
            } else if isLoading, actions.isEmpty {
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
                            Button(l10n.undo) { Task { await undo(action) } }
                                .disabled(undoingId != nil)
                        } else {
                            Text(l10n.notUndoable)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
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
        errorMessage = nil
        do {
            actions = try await api.fetchActions(
                accountId: accountId,
                since: Date().addingTimeInterval(-30 * 24 * 60 * 60)
            )
        } catch {
            errorMessage = l10n.undoFailed + error.lagoonUIMessage
        }
        isLoading = false
    }

    private func undo(_ action: AIAction) async {
        guard let accountId = accounts.accountId else { return }
        undoingId = action.id
        errorMessage = nil
        do {
            try await api.undoAction(id: action.id, accountId: accountId)
            actions.removeAll { $0.id == action.id }
            NotificationCenter.default.post(name: .lagoonDidUndo, object: nil)
        } catch {
            errorMessage = l10n.undoFailed + error.lagoonUIMessage
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
        }
    }
}
