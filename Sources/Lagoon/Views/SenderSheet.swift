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
    @EnvironmentObject private var undo: UndoController
    @State private var messages: [MessageHeader] = []
    /// Total rows matching this sender, ignoring LIMIT. The bulk verbs hit
    /// *all* of them, so this number is what the buttons must promise.
    @State private var totalCount: Int?
    @State private var isLoading = true
    @State private var errorBanner: ErrorBanner?
    @State private var bulkInFlight = false
    @State private var path: [String] = []
    /// Which bulk verb is waiting for confirmation. A bulk action over every
    /// unread mail from a sender is exactly the kind of operation that needs
    /// one explicit tap between "I clicked the button" and "my mailbox moved".
    @State private var pendingConfirm: BulkVerb?
    /// Which bulk verb emptied the sheet, and how many rows it moved. The empty
    /// state then shows a success view instead of "no mail from this sender" —
    /// and it names the right destination, because a delete that reported
    /// "archived" would send the user looking in the archive cabinet for mail
    /// that is actually in the Trash.
    @State private var emptiedBy: EmptiedOutcome?

    private struct EmptiedOutcome {
        let verb: BulkVerb
        let count: Int
    }
    private let api = APIClient.shared
    /// 批量请求同时在途的上限。
    ///
    /// 和「全部邮件」页的 `MessageListView.bulkConcurrency` 是同一个数、同
    /// 一段理由。常量各自定义而不抽到共享类型里：三个界面只有数值相同，
    /// 没有别的关系，抽出去换来的只是多一处要同步改的间接层。
    ///
    /// 设上限的原因是两条界面之外的事实：每一个批量动词都是一次真实的
    /// 远程 IMAP 写请求，整个应用共用那条唯一的 IMAP 连接，而 30 秒一次
    /// 的轮询也排在它后面。发件人面板覆盖的是该发件人的**全部**历史邮件
    /// ——营销/通知类发件人积累几百上千封是常态。不限并发地全打出去，就是
    /// 把轮询堵在几百个写请求之后，界面看起来像卡死。
    ///
    /// 八个足够把管道填满，再多只是把队列排得更长：扇出是延迟受限，不是
    /// CPU 受限。
    private static let bulkConcurrency = 8

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: LagoonMetrics.spaceXS) {
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
                .padding(LagoonMetrics.spaceMD)
                Divider()
                if !messages.isEmpty {
                    bulkBar
                }
                if isLoading {
                    ProgressView().padding(LagoonMetrics.spaceXL)
                } else if messages.isEmpty, let outcome = emptiedBy {
                    emptiedView(outcome)
                } else if messages.isEmpty {
                    ContentUnavailableView {
                        Label(l10n.senderMailEmpty, systemImage: "envelope")
                    }
                } else {
                    List(messages) { m in
                        NavigationLink(value: m.remoteId) {
                            VStack(alignment: .leading, spacing: LagoonTypography.rowSpacing) {
                                HStack(alignment: .firstTextBaseline, spacing: LagoonMetrics.spaceSM) {
                                    UnreadMarker(isUnread: !m.isRead)
                                    Text(m.subject ?? l10n.noSubject)
                                        .font(LagoonTypography.rowSubject)
                                        .bold(!m.isRead)
                                        .lineLimit(LagoonTypography.rowSubjectLines)
                                    Spacer()
                                    Text(LagoonTypography.rowTimestamp(m.receivedAt))
                                        .font(LagoonTypography.rowTime)
                                        .foregroundStyle(.secondary)
                                }
                                if let snippet = m.snippet, !snippet.isEmpty {
                                    Text(snippet)
                                        .font(LagoonTypography.rowSnippet)
                                        // Tertiary, not secondary: on macOS
                                        // `.caption` and `.caption2` are the
                                        // same size, so the snippet's step
                                        // below the subject has to be a
                                        // colour step. Two greys that are
                                        // the same grey are not a
                                        // hierarchy.
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(LagoonTypography.rowSnippetLines)
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                    // The header already reports the true total ("312 封邮件"),
                    // so this row is not about counting — it is about saying that
                    // the *list* is a window. Without it the user reads 312 in
                    // the bar, scrolls to the end at 500, and concludes the sheet
                    // is broken rather than capped.
                    .safeAreaInset(edge: .bottom) {
                        if let truncationNotice {
                            Label(truncationNotice, systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, LagoonMetrics.spaceMD)
                                .padding(.vertical, LagoonMetrics.spaceSM)
                                .background(.bar)
                                .overlay(alignment: .top) { Divider() }
                                .accessibilityLabel(truncationNotice)
                        }
                    }
                }
            }
            .navigationDestination(for: String.self) { remoteId in
                MessageDetailView(
                    remoteId: remoteId,
                    accountId: accountId,
                    header: messages.first { $0.remoteId == remoteId },
                    initiallyPinned: messages.first { $0.remoteId == remoteId }?.isPinned ?? false,
                    siblings: messages.map {
                        MessageRef(accountId: accountId, remoteId: $0.remoteId)
                    },
                    onArchived: { id, _ in
                        messages.removeAll { $0.remoteId == id }
                    },
                    onAdvanceTo: { next in
                        path = next.map { [$0.remoteId] } ?? []
                    }
                )
                // Same reset contract as the other destinations: without this
                // the destination reuses the previous message's @State.
                .id(remoteId)
            }
        }
        .frame(
            width: LagoonSheetSize.wide.width,
            height: LagoonSheetSize.wide.height
        )
        .noticeBanner($errorBanner)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            // No client-side limit: the server owns the window, and this
            // sheet's bulk verbs operate over "every mail from this sender",
            // so a truncated list would make them quietly partial.
            let response = try await api.fetchMessages(
                accountId: accountId, sender: senderAddress
            )
            messages = response.messages
            totalCount = response.totalCount ?? response.messages.count
        } catch {
            errorBanner = ErrorBanner(
                severity: .error,
                title: l10n.loadFailed,
                detail: error.lagoonUIMessage,
                // A pure read that failed on the network: the same fetch can
                // simply be run again. Spec INV-4.
                actionLabel: l10n.retry,
                action: { [self] in await self.load() }
            )
        }
    }

    // MARK: - Bulk actions

    /// Scope note: mark-read fans out over every unread mail this sender has;
    /// archive fans out over every mail this sender has that is not already
    /// archived. Either set may be more than the 200 rows the list shows —
    /// the count row keeps the number honest.
    private var unreadIds: [String] {
        messages.filter { !$0.isRead }.map(\.remoteId)
    }

    private var archivableIds: [String] {
        messages.map(\.remoteId)
    }

    /// Non-nil when the server held more rows than the response carried.
    ///
    /// Distinct from the bulk bar's count on purpose: that one answers "how many
    /// does this sender have" (and is right), this one answers "how many am I
    /// about to see" — which is the number the bulk verbs actually act on.
    private var truncationNotice: String? {
        ListTruncationNotice.text(shown: messages.count, total: totalCount, l10n: l10n)
    }

    /// What the bulk verbs cover, when that is less than everything the
    /// sender has.
    ///
    /// The bar used to state the server's total — "312 封邮件" — while the
    /// buttons acted on the rows the response carried. The user was told
    /// 312 and operated on 200, and the only hint that the list was a
    /// window arrived at the *bottom* of the list, long after the action.
    ///
    /// The bar is where the user reads before pressing a button, so the
    /// scope belongs there.
    private var scopeNotice: String? {
        guard let totalCount, totalCount > messages.count else { return nil }
        return l10n.senderBulkScope(shown: messages.count, total: totalCount)
    }

    private var bulkBar: some View {
        HStack(spacing: LagoonMetrics.spaceMD) {
            // The number the buttons below act on — not the sender's whole
            // history. The two come apart the moment the server's window
            // is smaller than the sender's mailbox, and the bar is the
            // only place the user reads before pressing a button.
            Text(l10n.senderCount(messages.count))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let scopeNotice {
                Text(scopeNotice)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if bulkInFlight {
                ProgressView().controlSize(.small)
                Text(l10n.senderWorking).font(.caption).foregroundStyle(.secondary)
            } else {
                // Mark-read is only meaningful while unread mail exists, so it
                // hides when there is none. Archive is NOT gated on unread:
                // the natural flow is "mark all read, then archive all", and
                // hiding archive once the mail is read cut that flow in half —
                // the bug this fixed. It shows whenever there is anything to
                // archive.
                if !unreadIds.isEmpty {
                    Button(l10n.senderAllRead) { pendingConfirm = .markRead }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                if !archivableIds.isEmpty {
                    Button(l10n.senderAllArchive) { pendingConfirm = .archive }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                if !archivableIds.isEmpty {
                    Button(l10n.senderAllDelete, role: .destructive) {
                        pendingConfirm = .deleteAll
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, LagoonMetrics.spaceMD)
        .padding(.vertical, LagoonMetrics.spaceSM)
        .background(.quaternary.opacity(0.35))
        .confirmationDialog(
            // Every confirmation carries the count the verb will actually
            // move: the blast radius should be visible before the user
            // commits, and the delete path names the honest destination.
            pendingConfirm == .deleteAll
                ? l10n.senderAllDeleteConfirm(archivableIds.count)
                : (pendingConfirm == .archive
                    ? l10n.senderAllArchiveConfirm(archivableIds.count)
                    : l10n.senderAllReadConfirm(unreadIds.count)),
            isPresented: Binding(
                get: { pendingConfirm != nil },
                set: { if !$0 { pendingConfirm = nil } }
            ),
            titleVisibility: .visible
        ) {
            // The confirm button mirrors the verb being confirmed: destructive
            // for the delete path (red), plain for read/archive.
            Button(confirmTitle, role: confirmRole) {
                let verb = pendingConfirm
                pendingConfirm = nil
                Task { await run(verb) }
            }
            Button(l10n.cancel, role: .cancel) { pendingConfirm = nil }
        }
    }

    private var confirmTitle: String {
        switch pendingConfirm {
        case .markRead: l10n.senderAllRead
        case .archive: l10n.senderAllArchive
        case .deleteAll: l10n.senderAllDelete
        case nil: ""
        }
    }

    private var confirmRole: ButtonRole? {
        pendingConfirm == .deleteAll ? .destructive : nil
    }

    private enum BulkVerb {
        case markRead
        case archive
        case deleteAll
    }

    /// Fan-out over the existing per-message markRead route with
    /// `record: true`, so the whole batch joins the undo audit and one ⌘Z
    /// reverses it — the same contract the Briefing's ⇧⌘K already ships.
    private func run(_ verb: BulkVerb?) async {
        switch verb {
        case .markRead: await markAllRead()
        case .archive: await archiveAll()
        case .deleteAll: await deleteAll()
        case nil: break
        }
    }

    /// Delete via the single-message delete route: mail moves to the server's
    /// Trash, one undoable audit row per message. The fan-out mirrors
    /// markAllRead.
    ///
    /// There is no bulk-delete endpoint, so every message is its own request —
    /// and this sheet lists the sender's *entire* history, where a marketing
    /// or notification address routinely has hundreds, not dozens. Firing them
    /// all at once put that many writes in front of the single shared IMAP
    /// connection, with the 30s poll queued behind them; the window below
    /// bounds in-flight requests to `bulkConcurrency`, admitting one new one
    /// per completion — the same rule as `MessageListView.runBulk`.
    private func deleteAll() async {
        let ids = archivableIds
        guard !ids.isEmpty else { return }
        bulkInFlight = true
        defer { bulkInFlight = false }
        var deleted: [String] = []
        var actionIds: [Int64] = []
        var firstError: Error?
        let api = self.api
        let accountId = self.accountId
        await withTaskGroup(of: (String, Result<Int64?, Error>).self) { group in
            var next = 0
            // Fill the window first, then keep it full: one new task per
            // completion, so the number outstanding never exceeds the limit.
            while next < min(Self.bulkConcurrency, ids.count) {
                let id = ids[next]
                next += 1
                group.addTask {
                    await Self.deleteOne(api: api, remoteId: id, accountId: accountId)
                }
            }
            while let (id, outcome) = await group.next() {
                switch outcome {
                case .success(let actionId):
                    deleted.append(id)
                    if let actionId { actionIds.append(actionId) }
                case .failure(let error):
                    if firstError == nil { firstError = error }
                }
                guard next < ids.count else { continue }
                let id = ids[next]
                next += 1
                group.addTask {
                    await Self.deleteOne(api: api, remoteId: id, accountId: accountId)
                }
            }
        }
        if let firstError {
            errorBanner = ErrorBanner(
                severity: .warning,
                title: l10n.senderBulkPartial,
                // The reason *and* the state of the mail: a bare error string
                // ("网络连接失败") says what went wrong but not what the
                // failed rows are doing now, and the retry is only honest if
                // the user knows it will re-run over exactly those.
                detail: l10n.senderBulkPartialDetail(firstError.lagoonUIMessage),
                // Partial success is retryable, and the retry is real: the
                // rows that went through were removed from the list, so
                // re-running the same delete covers exactly the rows that
                // failed. Spec INV-4.
                actionLabel: l10n.retry,
                action: { [self] in await self.deleteAll() }
            )
        } else if errorBanner?.title == l10n.senderBulkPartial {
            // This run went through — the stale "some messages failed"
            // banner would otherwise keep asking for another click on a
            // batch that no longer exists.
            errorBanner = nil
        }
        let removed = Set(deleted)
        messages.removeAll { removed.contains($0.remoteId) }
        if messages.isEmpty, !deleted.isEmpty {
            emptiedBy = EmptiedOutcome(verb: .deleteAll, count: deleted.count)
        }
        if let first = actionIds.first {
            undo.show(UndoItem(
                id: first,
                message: l10n.senderAllDeleteDone(deleted.count),
                systemImage: "trash",
                extraIds: Array(actionIds.dropFirst())
            ))
        }
    }

    /// One delete, as its own failure domain.
    ///
    /// Split out of `deleteAll` so the bounded window has something to await
    /// that is the *same* request in both the fill and the top-up phase —
    /// the sweep is one task per message either way, only the scheduling
    /// changed. Returns the remoteId alongside the outcome so the caller can
    /// name which row failed without re-deriving it.
    private static func deleteOne(
        api: APIClient, remoteId: String, accountId: UUID
    ) async -> (String, Result<Int64?, Error>) {
        do {
            let response = try await api.deleteMessage(
                remoteId: remoteId, accountId: accountId
            )
            return (remoteId, .success(response.actionId))
        } catch {
            return (remoteId, .failure(error))
        }
    }

    /// The sheet after a full archive: success, the number, the undo window,
    /// and the way out.
    ///
    /// It is a `ContentUnavailableView` like every other empty state in the
    /// app, not a hand-rolled one. The hand-rolled version drew its symbol
    /// at a fixed 40pt — a size that does not move with the reader's text
    /// size, so the one state that reports success was the one that broke
    /// first under a large accessibility font.
    private func emptiedView(_ outcome: EmptiedOutcome) -> some View {
        let wasDelete = outcome.verb == .deleteAll
        return ContentUnavailableView {
            Label(
                wasDelete
                    ? l10n.senderAllDeletedEmptyTitle(outcome.count)
                    : l10n.senderAllArchivedEmptyTitle(outcome.count),
                systemImage: wasDelete ? "trash.circle" : "checkmark.circle"
            )
            // The success colour from the one severity scale, not a bare
            // `.green` beside it: two greens for one meaning is how a
            // palette starts to drift.
            .foregroundStyle(LagoonTheme.Severity.success.color)
        } description: {
            Text(
                wasDelete
                    ? l10n.senderAllDeletedEmptyDetail
                    : l10n.senderAllArchivedEmptyDetail
            )
        } actions: {
            Button(l10n.done) { dismiss() }
                .buttonStyle(.borderedProminent)
        }
    }

    private func markAllRead() async {
        let failed = await bulk { remoteId in
            _ = try await api.markRead(
                remoteId: remoteId, accountId: accountId, record: true
            )
        }
        // Optimistic flip after success; the list reloads from the server on
        // the next open, so this only needs to keep the rows consistent now.
        //
        // Only the rows the server actually accepted are flipped. A row that
        // failed stays unread in the list — which is what the banner's detail
        // promises (失败的邮件仍留在列表里) and what makes the banner's
        // retry real: the retry scopes itself to the rows that are still
        // unread, so it covers exactly the ones that failed.
        let failedSet = Set(failed)
        for i in messages.indices {
            guard !messages[i].isRead, !failedSet.contains(messages[i].remoteId) else { continue }
            messages[i] = messages[i].withRead(true)
        }
        if failed.isEmpty, errorBanner?.title == l10n.senderBulkPartial {
            // The retry went through — the stale "some messages failed"
            // banner would otherwise keep asking for another click on a
            // batch that no longer exists.
            errorBanner = nil
        }
    }

    /// Archive via the sweep route, which owns the flag-then-MOVE ordering
    /// that keeps reconcile from deleting a row mid-move, plus per-message
    /// audit rows for undo.
    private func archiveAll() async {
        // The whole sender, not just unread mail: "mark all read, then
        // archive all" is the natural flow, and gating on unread made the
        // second half a no-op right after the first.
        let ids = archivableIds
        guard !ids.isEmpty else { return }
        bulkInFlight = true
        defer { bulkInFlight = false }
        do {
            let response = try await api.archiveBulk(remoteIds: ids, accountId: accountId)
            let ok = response.items.filter(\.ok)
            if let truncated = response.truncatedCount, truncated > 0 {
                errorBanner = ErrorBanner(
                    severity: .warning,
                    title: l10n.senderBulkPartial,
                    // Not a bare count: the number says *how much* was left,
                    // the detail says *why* and *what to do* — the server caps
                    // one call, and the retry button right here is the way to
                    // continue with the rest.
                    detail: l10n.senderTruncatedDetail(truncated),
                    // The server's per-call cap stopped the batch short. The
                    // rows it did archive left the list, so re-running the
                    // same sweep covers the ones that are still there.
                    // Spec INV-4.
                    actionLabel: l10n.retry,
                    action: { [self] in await self.archiveAll() }
                )
            } else if errorBanner?.title == l10n.senderBulkPartial {
                // The retry went through — the stale partial banner would
                // otherwise keep asking for another click on a batch that
                // no longer exists.
                errorBanner = nil
            }
            if let first = ok.first, let actionId = first.actionId {
                undo.show(UndoItem(
                    id: actionId,
                    message: l10n.senderAllArchiveDone(ok.count),
                    systemImage: "tray.and.arrow.down",
                    extraIds: ok.dropFirst().compactMap(\.actionId)
                ))
            }
            let archived = Set(ok.map(\.remoteId))
            messages.removeAll { archived.contains($0.remoteId) }
            // A full archive leaves the sheet empty; the empty state below
            // names what happened instead of reading as "there was nothing".
            if messages.isEmpty {
                emptiedBy = EmptiedOutcome(verb: .archive, count: ok.count)
            }
        } catch {
            errorBanner = ErrorBanner(
                severity: .error,
                title: l10n.senderBulkPartial,
                detail: error.lagoonUIMessage,
                // The whole batch failed, so nothing moved: re-running the
                // same sweep is the whole fix. Spec INV-4.
                actionLabel: l10n.retry,
                action: { [self] in await self.archiveAll() }
            )
        }
    }

    /// Shared fan-out for the markRead path: per-item errors are captured so
    /// a partial batch is reported, and the actionIds feed the undo toast.
    ///
    /// Returns the ids that failed, so the caller can leave them alone. That
    /// is what makes the banner's retry real: the failed rows keep their
    /// unread state in the list, and the retry scopes itself to the rows that
    /// are still unread — so it covers exactly the ones that failed.
    ///
    /// Bounded on purpose, same rule and same number as
    /// `MessageListView.runBulk`: one task per unread message would put the
    /// sender's entire unread history on the wire at once, and the shared
    /// IMAP connection answers the 30s poll too. The window admits one new
    /// request per completion, so at most `bulkConcurrency` are outstanding.
    private func bulk(_ body: @escaping (String) async throws -> Void) async -> [String] {
        let ids = unreadIds
        guard !ids.isEmpty else { return [] }
        bulkInFlight = true
        defer { bulkInFlight = false }
        var failedIds: [String] = []
        var firstError: Error?
        await withTaskGroup(of: (String, Error?).self) { group in
            var next = 0
            // Fill the window first, then keep it full: one new task per
            // completion, so the number outstanding never exceeds the limit.
            while next < min(Self.bulkConcurrency, ids.count) {
                let id = ids[next]
                next += 1
                group.addTask {
                    do {
                        try await body(id)
                        return (id, nil)
                    } catch {
                        return (id, error)
                    }
                }
            }
            while let (id, result) = await group.next() {
                if let result {
                    failedIds.append(id)
                    if firstError == nil { firstError = result }
                }
                guard next < ids.count else { continue }
                let id = ids[next]
                next += 1
                group.addTask {
                    do {
                        try await body(id)
                        return (id, nil)
                    } catch {
                        return (id, error)
                    }
                }
            }
        }
        if let firstError {
            errorBanner = ErrorBanner(
                severity: .warning,
                title: l10n.senderBulkPartial,
                detail: l10n.senderBulkPartialDetail(firstError.lagoonUIMessage),
                // Partial success is retryable, and the retry is real: the
                // failed rows are still unread in the list, so re-running the
                // same mark-read covers exactly them. Spec INV-4.
                actionLabel: l10n.retry,
                action: { [self] in await self.markAllRead() }
            )
        }
        return failedIds
    }
}
