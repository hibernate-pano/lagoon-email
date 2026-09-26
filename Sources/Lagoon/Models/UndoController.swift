import Foundation
import SwiftUI

/// Floating toast that announces "Lagoon just did X" with a Undo button.
/// Driven by an `UndoController` injected into the environment.
public struct UndoToast: View {
    @ObservedObject var controller: UndoController
    @Environment(\.l10n) private var l10n

    public init(controller: UndoController) {
        self.controller = controller
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let item = controller.current {
                HStack(spacing: 12) {
                    Image(systemName: item.systemImage)
                        .foregroundStyle(.white)
                    Text(item.message)
                        .font(.callout)
                        .foregroundStyle(.white)
                    Spacer(minLength: 8)
                    if item.undoable {
                        Button(l10n.undo) {
                            Task { await controller.undo() }
                        }
                        .foregroundStyle(.white)
                    }
                    Button {
                        controller.dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.tint, in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal)
                .padding(.bottom, 14)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: controller.current)
        .allowsHitTesting(controller.current != nil)
    }
}

public struct UndoItem: Equatable {
    public let id: Int64
    public let message: String
    public let systemImage: String
    /// Terminal actions (unsubscribe, send) have no inverse on the server
    /// (`ActionsRoutes.NotUndoable`), so their toast must not offer Undo —
    /// a button that always errors teaches the user to ignore the toast.
    public let undoable: Bool

    public init(id: Int64, message: String, systemImage: String, undoable: Bool = true) {
        self.id = id
        self.message = message
        self.systemImage = systemImage
        self.undoable = undoable
    }
}

@MainActor
public final class UndoController: ObservableObject {
    @Published public private(set) var current: UndoItem?
    @Published public private(set) var errorMessage: String?

    private let api: APIClient
    private weak var accounts: AccountStore?
    private var dismissTask: Task<Void, Never>?

    public init(api: APIClient = APIClient()) {
        self.api = api
    }

    public func bind(_ accounts: AccountStore) {
        self.accounts = accounts
    }

    /// Show a new undo toast; older toasts are replaced.
    public func show(_ item: UndoItem, autoDismissAfter seconds: TimeInterval = 6) {
        dismissTask?.cancel()
        errorMessage = nil
        current = item
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self else { return }
            await MainActor.run { [weak self] in
                self?.current = nil
            }
        }
    }

    public func dismiss() {
        dismissTask?.cancel()
        current = nil
    }

    public func clearError() {
        errorMessage = nil
    }

    /// Undo the most recent action by id. The action record on the server
    /// holds the inverse (archive → INBOX back, mark-read → unread, etc.).
    public func undo() async {
        guard let item = current, let accounts, let accountId = accounts.accountId else { return }
        current = nil
        dismissTask?.cancel()
        await perform(actionId: item.id, accountId: accountId)
    }

    /// Undo the newest still-reversible action, even after the toast expires.
    public func undoLatest() async {
        guard let accounts, let accountId = accounts.accountId else { return }
        do {
            let actions = try await api.fetchActions(
                accountId: accountId,
                since: Date().addingTimeInterval(-30 * 24 * 60 * 60)
            )
            guard let action = actions.first(where: {
                $0.kind.isUndoable && ($0.expiresAt.map { $0 > Date() } ?? true)
            }) else {
                errorMessage = L10n.current.nothingToUndo
                return
            }
            current = nil
            dismissTask?.cancel()
            await perform(actionId: action.id, accountId: accountId)
        } catch {
            errorMessage = L10n.current.undoFailed + error.lagoonUIMessage
        }
    }

    private func perform(actionId: Int64, accountId: UUID) async {
        do {
            try await api.undoAction(id: actionId, accountId: accountId)
            errorMessage = nil
            NotificationCenter.default.post(name: .lagoonDidUndo, object: nil)
        } catch {
            errorMessage = L10n.current.undoFailed + error.lagoonUIMessage
        }
    }
}

public extension Notification.Name {
    /// Posted after a successful undo. Views refresh in response.
    static let lagoonDidUndo = Notification.Name("lagoon.didUndo")
    /// Posted when a non-undo action changes feed grouping or local state.
    static let lagoonDidChangeData = Notification.Name("lagoon.didChangeData")
}
