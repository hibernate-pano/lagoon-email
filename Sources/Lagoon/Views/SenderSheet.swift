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
                if !messages.isEmpty {
                    bulkBar
                }
                if isLoading {
                    ProgressView().padding(20)
                } else if messages.isEmpty, let outcome = emptiedBy {
                    emptiedView(outcome)
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
                    initiallyPinned: messages.first { $0.remoteId == remoteId }?.isPinned ?? false,
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
            totalCount = response.totalCount ?? response.messages.count
        } catch {
            errorBanner = ErrorBanner(severity: .error, title: l10n.loadFailed, detail: error.lagoonUIMessage)
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

    private var bulkBar: some View {
        HStack(spacing: 10) {
            Text(l10n.senderCount(totalCount ?? messages.count))
                .font(.caption)
                .foregroundStyle(.secondary)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.35))
        .confirmationDialog(
            // The delete confirmation carries the live count: the blast radius
            // should be visible before the user commits, and Trash is the
            // honest destination name.
            pendingConfirm == .deleteAll
                ? l10n.senderAllDeleteConfirm(archivableIds.count)
                : (pendingConfirm == .archive
                    ? l10n.senderAllArchiveConfirm
                    : l10n.senderAllReadConfirm),
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
    /// markAllRead. There is no bulk-delete endpoint, but at the volumes a
    /// single sender accumulates (dozens, not thousands) the concurrent calls
    /// finish in seconds.
    private func deleteAll() async {
        let ids = archivableIds
        guard !ids.isEmpty else { return }
        bulkInFlight = true
        defer { bulkInFlight = false }
        var deleted: [String] = []
        var actionIds: [Int64] = []
        var firstError: Error?
        await withTaskGroup(of: (String, Result<Int64?, Error>)?.self) { group in
            for id in ids {
                group.addTask { [api, accountId] in
                    do {
                        let response = try await api.deleteMessage(
                            remoteId: id, accountId: accountId
                        )
                        return (id, .success(response.actionId))
                    } catch {
                        return (id, .failure(error))
                    }
                }
            }
            for await result in group {
                guard let (id, outcome) = result else { continue }
                switch outcome {
                case .success(let actionId):
                    deleted.append(id)
                    if let actionId { actionIds.append(actionId) }
                case .failure(let error):
                    if firstError == nil { firstError = error }
                }
            }
        }
        if let firstError {
            errorBanner = ErrorBanner(
                severity: .warning,
                title: l10n.senderBulkPartial,
                detail: firstError.lagoonUIMessage
            )
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

    /// The sheet after a full archive: success, the number, the undo window,
    /// and the way out. Centered like the empty state it replaces, but with
    /// the checkmark and tint that say "this worked".
    private func emptiedView(_ outcome: EmptiedOutcome) -> some View {
        let wasDelete = outcome.verb == .deleteAll
        return VStack(spacing: 12) {
            Image(systemName: wasDelete ? "trash.circle" : "checkmark.circle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.green)
            Text(
                wasDelete
                    ? l10n.senderAllDeletedEmptyTitle(outcome.count)
                    : l10n.senderAllArchivedEmptyTitle(outcome.count)
            )
                .font(.headline)
            Text(
                wasDelete
                    ? l10n.senderAllDeletedEmptyDetail
                    : l10n.senderAllArchivedEmptyDetail
            )
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(l10n.done) { dismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    private func markAllRead() async {
        await bulk { remoteId in
            _ = try await api.markRead(
                remoteId: remoteId, accountId: accountId, record: true
            )
        }
        // Optimistic flip after success; the list reloads from the server on
        // the next open, so this only needs to keep the rows consistent now.
        for i in messages.indices where !messages[i].isRead {
            messages[i] = messages[i].withRead(true)
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
                    detail: l10n.senderCount(truncated)
                )
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
                detail: error.lagoonUIMessage
            )
        }
    }

    /// Shared fan-out for the markRead path: per-item errors are captured so
    /// a partial batch is reported, and the actionIds feed the undo toast.
    private func bulk(_ body: @escaping (String) async throws -> Void) async {
        let ids = unreadIds
        guard !ids.isEmpty else { return }
        bulkInFlight = true
        defer { bulkInFlight = false }
        var failures = 0
        var firstError: Error?
        await withTaskGroup(of: Error?.self) { group in
            for id in ids {
                group.addTask {
                    do {
                        try await body(id)
                        return nil
                    } catch {
                        return error
                    }
                }
            }
            for await result in group {
                if let result {
                    failures += 1
                    if firstError == nil { firstError = result }
                }
            }
        }
        if let firstError {
            errorBanner = ErrorBanner(
                severity: .warning,
                title: l10n.senderBulkPartial,
                detail: firstError.lagoonUIMessage
            )
        } else if failures > 0 {
            errorBanner = ErrorBanner(severity: .warning, title: l10n.senderBulkPartial)
        }
    }
}
