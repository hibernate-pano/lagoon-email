import Foundation
import SwiftUI
import LagoonKit

/// Floating toast that announces "Lagoon just did X" with a Undo button.
/// Driven by an `UndoController` injected into the environment.
public struct UndoToast: View {
    @ObservedObject var controller: UndoController
    @Environment(\.l10n) private var l10n
    /// Whether the pointer is over the toast. The controller owns the
    /// countdown; the view is the only thing that knows where the pointer is.
    @State private var isHovering = false

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
                .onHover { hovering in
                    isHovering = hovering
                    controller.setHovering(hovering)
                }
                // A new toast inherits the pointer that is already sitting
                // over the old one. Without re-asserting the hover, the
                // fresh countdown would run out under the user's cursor.
                .onChange(of: controller.current?.id) { _, _ in
                    controller.setHovering(isHovering)
                }
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
    /// Extra ids to reverse in the same ⌘Z, for bulk operations.
    ///
    /// "Mark all as read" writes one audit row per message. Undoing only the
    /// newest would leave the other N-1 changes in place and read to the user
    /// as "undo did nothing", which is worse than offering no undo at all.
    /// When non-empty the controller posts to `undo-bulk` instead of the
    /// single-action route.
    public let extraIds: [Int64]

    public init(
        id: Int64,
        message: String,
        systemImage: String,
        undoable: Bool = true,
        extraIds: [Int64] = []
    ) {
        self.id = id
        self.message = message
        self.systemImage = systemImage
        self.undoable = undoable
        self.extraIds = extraIds
    }

    /// Every id this toast's Undo button reverses, `id` first.
    public var allIds: [Int64] { [id] + extraIds }
}

@MainActor
public final class UndoController: ObservableObject {
    @Published public private(set) var current: UndoItem?
    @Published public private(set) var errorMessage: String?
    /// Why the failure happened, in a second line.
    ///
    /// The banner's title says *what* failed; this says why, which is the
    /// half the user needs to decide what to do next. "没有可撤销的操作" is
    /// not a diagnosis — it is the same sentence in both cases where there
    /// is nothing to undo and where the undo itself was refused.
    @Published public private(set) var errorDetail: String?

    private let api: APIClient
    private weak var accounts: AccountStore?
    private var dismissTask: Task<Void, Never>?
    /// When the current toast is scheduled to disappear. `nil` while the
    /// countdown is paused.
    private var dismissDeadline: Date?
    /// Seconds still to run when the countdown was paused.
    private var remainingSeconds: TimeInterval = 0

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
        remainingSeconds = seconds
        scheduleDismiss(after: seconds)
    }

    private func scheduleDismiss(after seconds: TimeInterval) {
        dismissDeadline = Date().addingTimeInterval(seconds)
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.current = nil
                self?.dismissDeadline = nil
            }
        }
    }

    /// Hovering the toast stops the countdown.
    ///
    /// Six seconds is a generous window for someone who is *not* looking —
    /// the point of the timeout is that the toast does not permanently occupy
    /// the bottom of the window. But the user who is reading the message, or
    /// who has noticed the toast and is reaching for Undo, is exactly the
    /// user the timeout is aimed at. Taking the Undo button away mid-reach
    /// is the worst possible moment to do it, so the clock waits.
    public func setHovering(_ hovering: Bool) {
        if hovering {
            pauseAutoDismiss()
        } else {
            resumeAutoDismiss()
        }
    }

    private func pauseAutoDismiss() {
        guard let deadline = dismissDeadline else { return }
        dismissTask?.cancel()
        remainingSeconds = max(0, deadline.timeIntervalSinceNow)
        dismissDeadline = nil
    }

    /// Stops the countdown for good — the toast is going away on purpose
    /// (undo, dismiss, replaced), not because time ran out.
    private func cancelScheduledDismiss() {
        dismissTask?.cancel()
        dismissDeadline = nil
        remainingSeconds = 0
    }

    private func resumeAutoDismiss() {
        guard dismissDeadline == nil, current != nil, remainingSeconds > 0 else { return }
        scheduleDismiss(after: remainingSeconds)
    }

    public func dismiss() {
        dismissTask?.cancel()
        dismissDeadline = nil
        remainingSeconds = 0
        current = nil
    }

    public func clearError() {
        errorMessage = nil
        errorDetail = nil
    }

    /// Undo the most recent action by id. The action record on the server
    /// holds the inverse (archive → INBOX back, mark-read → unread, etc.).
    public func undo() async {
        guard let item = current, let accounts, let accountId = accounts.accountId else { return }
        current = nil
        cancelScheduledDismiss()
        if item.extraIds.isEmpty {
            await perform(actionId: item.id, accountId: accountId)
        } else {
            await performBulk(actionIds: item.allIds, accountId: accountId)
        }
    }

    /// The outcome of one undo, for the surface that asked for it.
    ///
    /// A failure is returned **and** left unrecorded in `errorMessage`. That
    /// is deliberate: `RootView` renders `errorMessage` with a "重试" button
    /// wired to `undoLatest()`, which means "undo whatever the newest
    /// reversible action is". Retrying a *specific* old action from the
    /// history panel is a different operation, and a retry button that
    /// silently undoes something else is the worst kind of wrong. So the
    /// panel shows its own failure, next to its own retry, and the toast's
    /// error channel keeps meaning what it has always meant.
    public enum UndoResult: Sendable, Equatable {
        case undone
        case failed(message: String, detail: String?)
    }

    /// Undo one named action, from the history panel.
    ///
    /// ## Why this exists at all
    ///
    /// The panel used to call `api.undoAction` directly. `UndoController`
    /// owns `current` — the toast — so a panel undo left the toast standing:
    /// the user undid a three-minute-old archive and the bottom of the
    /// window still said "已归档" with an Undo button for a *different*
    /// action. Two undo entry points, two states, one product.
    ///
    /// Routing through here makes this the single owner. Undoing anything
    /// retires the toast, because the toast is a statement about "the last
    /// thing that happened" and after this call that statement is about
    /// something else.
    ///
    /// The row's granularity is one action. A row in the panel *is* one
    /// audit entry, so clicking its Undo reverses that entry — not the batch
    /// it belonged to. That is what the row says, and a list where one row
    /// silently reverses fifty is a list that lies about its own unit.
    @discardableResult
    public func undo(actionId: Int64) async -> UndoResult {
        guard let accounts, let accountId = accounts.accountId else {
            return .failed(message: L10n.current.undoFailed, detail: L10n.current.undoNoAccount)
        }
        // Before the await, like `undo()`: a second tap during the round trip
        // must not find a toast to fire against.
        dismiss()
        do {
            try await api.undoAction(id: actionId, accountId: accountId)
            // A stale failure from an earlier attempt must not outlive a
            // success — that is the same two-surfaces-disagree failure this
            // method exists to remove, one layer up.
            clearError()
            NotificationCenter.default.post(name: .lagoonDidUndo, object: [actionId])
            return .undone
        } catch {
            return .failed(
                message: L10n.current.undoFailed + error.lagoonUIMessage,
                detail: L10n.current.undoFailedDetail
            )
        }
    }

    /// Undo the newest still-reversible action, even after the toast expires.
    public func undoLatest() async {
        guard let accounts, let accountId = accounts.accountId else { return }
        // Prefer the live toast. ⌘Z is bound to this method, but when a toast
        // is showing it IS the last action — and for a bulk operation the toast
        // carries the whole set of ids. Falling through to the server's
        // newest-single lookup here would make ⇧⌘K's toast undo one message
        // when ⌘Z was pressed and all of them when the toast button was
        // pressed: the same toast, two different results. Routing through
        // `undo()` keeps both entry points identical (and honours extraIds).
        if let item = current, item.undoable {
            await undo()
            return
        }
        do {
            let actions = try await api.fetchActions(
                accountId: accountId,
                since: Date().addingTimeInterval(-30 * 24 * 60 * 60)
            )
            // The newest action, **and everything that happened with it**.
            //
            // A bulk operation writes one audit row per message, and those
            // rows share a timestamp. The old code took `actions.first` — a
            // single row — so ⌘Z after the toast had faded undid exactly ONE
            // of the fifty messages the user had archived, and the other
            // forty-nine stayed archived with no way back. The user pressed
            // "undo" once and one message came back: worse than not undoing
            // at all, because it *looked* like it worked.
            //
            // The batch is found by clustering: every undoable action
            // created within two seconds of the newest one belongs to the
            // same operation. Two seconds is wide enough to cover a
            // round-trip of fifty remote writes on a slow connection and
            // narrow enough that two separate operations a moment apart are
            // not merged into one.
            let undoable = actions.filter {
                $0.kind.isUndoable && ($0.expiresAt.map { $0 > Date() } ?? true)
            }
            guard let newest = undoable.first else {
                errorMessage = L10n.current.nothingToUndo
                // The detail has to say *why*: the same sentence covers
                // "there was never anything to undo" and "the undo record
                // expired 31 days ago", and the user cannot tell which
                // from the title alone.
                errorDetail = L10n.current.undoEmptyHint
                return
            }
            let batch = Self.batch(containing: newest, in: undoable)
            current = nil
            cancelScheduledDismiss()
            if batch.count == 1 {
                await perform(actionId: newest.id, accountId: accountId)
            } else {
                await performBulk(actionIds: batch, accountId: accountId)
            }
        } catch {
            errorMessage = L10n.current.undoFailed + error.lagoonUIMessage
            errorDetail = L10n.current.undoFailedDetail
        }
    }

    private func perform(actionId: Int64, accountId: UUID) async {
        do {
            try await api.undoAction(id: actionId, accountId: accountId)
            errorMessage = nil
            errorDetail = nil
            // The id travels with the notification so a surface that holds
            // rows can retire exactly the row that was reversed. A bare
            // "something was undone" forces every listener to re-fetch,
            // which loses the panel's loaded pages and, on a failure of
            // that re-fetch, makes it look as though the undo did nothing.
            NotificationCenter.default.post(name: .lagoonDidUndo, object: [actionId])
        } catch {
            errorMessage = L10n.current.undoFailed + error.lagoonUIMessage
            errorDetail = L10n.current.undoFailedDetail
        }
    }

    /// The ids of one operation.
    ///
    /// A bulk operation writes one audit row per message, and those rows are
    /// written within a second or two of each other. So: everything created
    /// within two seconds of `newest` is the same operation.
    ///
    /// Two seconds is a judgement, and it is worth stating why: it is wide
    /// enough to cover fifty remote writes on a slow connection, and narrow
    /// enough that two operations a moment apart do not get merged into one
    /// — a merged pair would undo an action the user never asked to undo.
    ///
    /// The rows are returned in the order the server gave them (newest
    /// first), because the undo endpoint takes ids and does not care about
    /// order, but a stable order makes the request reproducible.
    static func batch(
        containing newest: AIAction,
        in actions: [AIAction]
    ) -> [Int64] {
        let window: TimeInterval = 2
        let cutoff = newest.createdAt.addingTimeInterval(-window)
        return actions
            .filter { $0.createdAt >= cutoff }
            .map(\.id)
    }

    /// Reverses a whole bulk operation in one call and reports how many
    /// inverses actually ran.
    ///
    /// A partial result is reported honestly rather than as success: the
    /// server runs each inverse independently (one may already be spent, one
    /// remote write may fail), and telling the user "undone" when 3 of 50
    /// reversed would be a lie in the one place the product promises to be
    /// trustworthy about state.
    private func performBulk(actionIds: [Int64], accountId: UUID) async {        do {
            let response = try await api.undoBulk(actionIds: actionIds, accountId: accountId)
            if response.undone == actionIds.count {
                errorMessage = nil
                errorDetail = nil
            } else {
                errorMessage = L10n.current.undoPartial(response.undone, actionIds.count)
                errorDetail = L10n.current.undoPartialDetail
            }
            // Only the rows that actually reversed. A partial result that
            // told the panel to drop all fifty ids would remove rows that
            // are still undoable — and the list would then be missing
            // entries the server would happily accept a second tap on.
            let reversed = response.items.filter(\.ok).map(\.actionId)
            NotificationCenter.default.post(
                name: .lagoonDidUndo,
                object: reversed.isEmpty ? nil : reversed
            )
        } catch {
            errorMessage = L10n.current.undoFailed + error.lagoonUIMessage
            errorDetail = L10n.current.undoFailedDetail
        }
    }
}

public extension Notification.Name {
    /// Posted after a successful undo. Views refresh in response.
    static let lagoonDidUndo = Notification.Name("lagoon.didUndo")
    /// Posted when a non-undo action changes feed grouping or local state.
    static let lagoonDidChangeData = Notification.Name("lagoon.didChangeData")
    /// Carries a message remoteId when a surface outside the Briefing asks it
    /// to reveal one — the advice panel's "open message" button. The feed owns
    /// its navigation state, so this is how a sibling surface reaches it
    /// without that state having to become shared.
    static let lagoonRevealMessage = Notification.Name("lagoon.revealMessage")
}
