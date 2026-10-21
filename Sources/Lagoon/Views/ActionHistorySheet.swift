import SwiftUI
import LagoonKit

/// Persistent undo surface. The toast is intentionally brief; this sheet keeps
/// reversible actions discoverable for the server's full retention window.
///
/// ## One owner of the undo state
///
/// This panel used to post to the undo route itself. `UndoController` owns the
/// toast (`current`), so undoing here left a toast for a *different* action
/// standing at the bottom of the window: the user undid a three-minute-old
/// archive and the app still showed "已归档" with an Undo button. Both entry
/// points now go through the controller, and a successful undo from either
/// side posts `.lagoonDidUndo` — which this panel listens for, so an undo
/// fired from the toast removes the row here too.
///
/// ## The list is paged, and says so
///
/// The server returns at most a page (`GET /api/actions`), newest first. This
/// panel loads one page, offers "load older" while the server says there is
/// more, and states how many older entries exist. The rule is the one the
/// bulk sheets already follow: **a list that silently drops rows must say
/// so** — a panel that stops at the hundredth entry is indistinguishable from
/// a broken one.
struct ActionHistorySheet: View {
    @EnvironmentObject private var accounts: AccountStore
    /// The single owner of undo state, injected by `RootView`. The sheet is
    /// presented from `RootView.sheetStack`, which carries this environment.
    @EnvironmentObject private var undo: UndoController
    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss

    @State private var actions: [AIAction] = []
    @State private var isLoading = false
    /// A *next-page* load in flight, distinct from the first-page load: they
    /// draw different controls, and a spinner in the wrong one reads as "the
    /// refresh you pressed is still running".
    @State private var isLoadingMore = false
    @State private var errorBanner: ErrorBanner?
    @State private var undoingId: Int64?
    /// The server's count for the whole history, ignoring the page. nil
    /// means the server did not say — and unknown is *not* zero, so the
    /// panel withholds the number rather than inventing one.
    @State private var totalCount: Int?
    /// Whether an older page exists. Measured by the server; a nil here is
    /// an older server that cannot answer, and the panel then offers the
    /// button rather than assuming the end of the list.
    @State private var hasMore = false
    /// No account is connected, so there is no history to show. Distinct
    /// from "the history is empty" — the two need different copy and only
    /// one of them is the user's to fix.
    @State private var isDisconnected = false

    /// One page is what fits a 480pt sheet without scrolling for a while,
    /// and it is small enough that the first paint is never the slow part.
    private static let pageSize = 100

    private let api = APIClient.shared

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
            } else if isDisconnected {
                ContentUnavailableView(
                    l10n.notConnected,
                    systemImage: "envelope.badge",
                    description: Text(l10n.notConnectedHint)
                )
            } else if actions.isEmpty {
                ContentUnavailableView(
                    l10n.emptyActionHistory,
                    systemImage: "clock.arrow.circlepath",
                    description: Text(l10n.emptyActionHistoryHint)
                )
            } else {
                List {
                    ForEach(actions) { action in
                        row(action)
                    }
                    footer
                }
            }
        }
        .noticeBanner($errorBanner)
        .frame(
            width: LagoonSheetSize.standard.width,
            height: LagoonSheetSize.standard.height
        )
        .task { await load() }
        // An undo fired from the toast must retire its row here too. Without
        // this the panel keeps offering Undo for an action that is already
        // reversed, and the server answers 409 — the panel showing a control
        // that cannot work is the same disagreement as the toast, mirrored.
        .onReceive(NotificationCenter.default.publisher(for: .lagoonDidUndo)) { note in
            guard let ids = note.object as? [Int64], !ids.isEmpty else {
                // A post with no ids says only "some undo happened".
                // Re-reading is the honest response: this panel cannot know
                // which row changed.
                Task { await load() }
                return
            }
            actions.removeAll { ids.contains($0.id) }
            // The count is left alone, and that is not an oversight.
            //
            // An undo does not remove a row from the history — the server
            // records an *undo* row for it, so the history still says what
            // Lagoon did. The action it reverses stops being listed (the
            // server's predicate drops an action that has been undone) and
            // the undo row takes its place: one out, one in. The total is
            // therefore unchanged, and decrementing it here would make the
            // footer claim fewer older entries than exist.
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(_ action: AIAction) -> some View {
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
                Button { Task { await undoRow(action) } } label: {
                    if undoingId == action.id {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(l10n.undo)
                    }
                }
                .disabled(undoingId != nil)
            } else if isExpired(action) {
                // Time closed the window; the kind was reversible.
                Text(l10n.actionExpired)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(l10n.notUndoable)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    /// The end of the list, where the panel either offers the next page or
    /// states — once, and quietly — that the older entries are the ones
    /// nearest their expiry.
    @ViewBuilder
    private var footer: some View {
        if hasMore {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button {
                        Task { await loadMore() }
                    } label: {
                        if isLoadingMore {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(l10n.actionHistoryLoadMoreOlder)
                        }
                    }
                    .disabled(isLoadingMore)
                    Spacer()
                    if let remaining = remainingCount, remaining > 0 {
                        Text(l10n.actionHistoryRemaining(remaining))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(l10n.actionHistoryOlderNearExpiry)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        }
    }

    /// Older entries the panel has not loaded, when that number is knowable.
    ///
    /// Returns nil rather than a guess when the server did not report a
    /// total: a made-up "还有 N 条" is worse than no number, because the user
    /// would act on it.
    private var remainingCount: Int? {
        guard let totalCount else { return nil }
        return max(0, totalCount - actions.count)
    }

    // MARK: - Loading

    private func canUndo(_ action: AIAction) -> Bool {
        guard action.kind.isUndoable else { return false }
        return !isExpired(action)
    }

    private func isExpired(_ action: AIAction) -> Bool {
        guard let expiresAt = action.expiresAt else { return false }
        return expiresAt <= Date()
    }

    /// Replaces the list with the newest page.
    ///
    /// Used by the refresh button and by first appearance. It deliberately
    /// resets the cursor: a refresh means "show me the current head of the
    /// history", and appending a fresh first page onto an old second page
    /// would interleave two snapshots.
    private func load() async {
        guard let accountId = accounts.accountId else {
            // Silently returning here made the panel claim there was nothing
            // to undo — a statement about the user's mailbox that was never
            // actually asked for.
            isDisconnected = true
            isLoading = false
            return
        }
        isDisconnected = false
        isLoading = true
        errorBanner = nil
        do {
            let page = try await api.fetchActionPage(
                accountId: accountId,
                since: Date().addingTimeInterval(-30 * 24 * 60 * 60),
                before: nil,
                limit: Self.pageSize
            )
            actions = page.actions
            totalCount = page.totalCount
            // An older server sends neither field. `?? true` would claim more
            // exists; `?? false` would claim it does not. The button is the
            // safer of the two: pressing it either loads the next page or
            // ends the list, and it is the panel that stops silently that
            // this whole change is about.
            hasMore = page.hasMore ?? true
        } catch {
            errorBanner = makeError(
                title: l10n.actionHistoryLoadFailed,
                detail: l10n.actionHistoryLoadFailedHint,
                retry: { [self] in await self.load() }
            )
        }
        isLoading = false
    }

    /// Appends the page after the last row currently held.
    ///
    /// Keyset, not offset: the cursor is the last row's id, so an action
    /// written while the panel was open cannot shift the next page and make
    /// the list skip a row.
    private func loadMore() async {
        // `hasMore` is the only precondition: the footer that calls this is
        // already gated on it, and the total may be unknown on an older
        // server while the button is still the right control.
        guard hasMore, let accountId = accounts.accountId, let last = actions.last else { return }
        guard !isLoadingMore else { return }
        isLoadingMore = true
        do {
            let page = try await api.fetchActionPage(
                accountId: accountId,
                since: Date().addingTimeInterval(-30 * 24 * 60 * 60),
                before: last.id,
                limit: Self.pageSize
            )
            // Append only rows not already held. A row can arrive twice if
            // the cursor's row was removed between pages; showing it twice
            // would make the count in the footer disagree with the list.
            let known = Set(actions.map(\.id))
            actions.append(contentsOf: page.actions.filter { !known.contains($0.id) })
            if let serverTotal = page.totalCount {
                totalCount = serverTotal
            }
            hasMore = page.hasMore ?? (page.actions.count >= Self.pageSize)
        } catch {
            errorBanner = makeError(
                title: l10n.actionHistoryLoadMoreFailed,
                detail: l10n.actionHistoryLoadFailedHint,
                retry: { [self] in await self.loadMore() }
            )
        }
        isLoadingMore = false
    }

    // MARK: - Undo

    /// Undo one row, through the controller that owns the toast.
    ///
    /// The row leaves the list only after the server says it worked. A row
    /// that vanished optimistically and came back on failure would flicker
    /// the list under the user's pointer, and an optimistic removal that the
    /// server refused is the panel misreporting the mailbox — the one thing
    /// this panel is for.
    private func undoRow(_ action: AIAction) async {
        undoingId = action.id
        errorBanner = nil
        let result = await undo.undo(actionId: action.id)
        switch result {
        case .undone:
            // `undo(actionId:)` posted `.lagoonDidUndo`, which the receiver
            // above turns into the row removal — one code path for both
            // entry points, so they cannot disagree about what removal means.
            break
        case .failed(let message, let detail):
            errorBanner = makeError(
                title: message,
                detail: detail,
                retry: { [self] in await self.undoRow(action) }
            )
        }
        undoingId = nil
    }

    private func makeError(
        title: String,
        detail: String?,
        retry: @escaping @Sendable () async -> Void
    ) -> ErrorBanner {
        ErrorBanner(
            severity: .error,
            title: title,
            detail: detail,
            actionLabel: l10n.retry,
            action: retry
        )
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
        // 彻底删除 gets its own icon, not a variant of the trash can. In a
        // history list the two rows sit next to each other, and a user must be
        // able to tell at a glance which one is the irreversible one.
        case .purge: "trash.slash"
        }
    }
}
