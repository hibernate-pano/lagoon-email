import SwiftUI
import LagoonKit

/// Default landing surface (spec §7.1): the classified Briefing Feed.
///
/// Each row carries context-aware action buttons (archive, pin, override)
/// and j/k navigation jumps between messages. ⌘Z surfaces the undo toast
/// via UndoController.
struct BriefingFeedView: View {
    @EnvironmentObject private var accounts: AccountStore
    @EnvironmentObject private var undo: UndoController
    @EnvironmentObject private var directory: DirectoryStore
    @State private var items: [BriefingItem] = []
    @State private var isLoading = false
    @State private var isMarkingAllRead = false
    @State private var errorBanner: ErrorBanner?
    @State private var collapsedGroups: Set<BriefingGroup> = Set(BriefingGroup.allCases.filter(\.collapsedByDefault))
    @State private var path: [String] = []
    @State private var scrollProxy: ScrollViewProxy?
    @State private var selectedGmailId: String? = nil

    private let api = APIClient()
    private static let refreshInterval: Duration = .seconds(30)
    @Environment(\.l10n) private var l10n

    /// Same gate as the detail toolbar. Unknown (directory not loaded yet, or a
    /// version-skewed row) reads as allowed: the server is the authority and
    /// answers 409 archive-unavailable when the folder really is missing.
    private var canArchive: Bool {
        directory.active?.capabilities.archiveFolder ?? true
    }

    var onShowAllMessages: () -> Void = {}

    var body: some View {
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: 0) {
                    headerBar
                    // Only render the inline banner when the feed itself is
                    // already on screen: if `items` is empty the `errorState`
                    // (ContentUnavailableView) is already showing, and RootView
                    // covers sync-health concerns. Without this guard the
                    // briefing page would stack a banner on top of the
                    // empty-state copy.
                    if let errorBanner, !items.isEmpty {
                        NoticeBannerView(banner: errorBanner) { self.errorBanner = nil }
                    }
                    content
                }
                .onAppear { scrollProxy = proxy }
            }
            .navigationDestination(for: String.self) { remoteId in
                destination(for: remoteId)
            }
            .background {
                groupJumpShortcuts
                keyboardNavigationShortcuts
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .task {
            await refresh()
            await poll()
        }
        .onChange(of: path) { old, new in
            if !old.isEmpty, new.isEmpty {
                Task { await refresh() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lagoonDidUndo)) { _ in
            Task { await refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lagoonDidChangeData)) { _ in
            Task { await refresh() }
        }
    }

    private func poll() async {
        while !Task.isCancelled {
            do { try await Task.sleep(for: Self.refreshInterval) } catch { return }
            // Never reorder the feed underneath an open message. The next
            // refresh happens when the user returns to the feed.
            if path.isEmpty {
                await refresh()
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            Text(l10n.briefing).font(.headline)
            Spacer()
            Button {
                Task { await markAllRead() }
            } label: {
                if isMarkingAllRead {
                    ProgressView().controlSize(.small)
                } else {
                    Label(l10n.markAllRead, systemImage: "envelope.open")
                }
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            .disabled(isMarkingAllRead || items.isEmpty)
            .help(l10n.markAllReadHelp)
            Button { onShowAllMessages() } label: {
                Label(l10n.allMessages, systemImage: "list.bullet")
            }
            .keyboardShortcut("0", modifiers: .command)
            .help(l10n.showRawListHelp)
            Button {
                Task { await refresh() }
            } label: {
                if isLoading {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text(l10n.refresh)
                    }
                } else {
                    Label(l10n.refresh, systemImage: "arrow.clockwise")
                }
            }
            .disabled(isLoading)
            .keyboardShortcut("r", modifiers: .command)
            .help(l10n.shortcutRefresh)
        }
        .padding()
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if items.isEmpty {
            if isLoading { ProgressView(l10n.loadingBriefing).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if errorBanner != nil { errorState }
            else { emptyState }
        } else {
            feedList
        }
    }

    private var feedList: some View {
        List(selection: $selectedGmailId) {
            ForEach(BriefingGroup.allCases) { group in
                let groupItems = items.filter { $0.group == group }
                if !groupItems.isEmpty {
                    Section {
                        if !collapsedGroups.contains(group) {
                            ForEach(groupItems) { item in
                            NavigationLink(value: item.message.remoteId) {
                                BriefingRow(item: item)
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                // Leading swipe = archive (the destructive
                                // gesture Mail.app puts on the left).
                                Button { Task { await archiveAndUndo(item) } } label: {
                                    Label(l10n.archived, systemImage: "tray.and.arrow.down")
                                }
                                .tint(.orange)
                                .disabled(!canArchive)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                // Trailing swipe = pin/unpin (the quick
                                // triage gesture on the right).
                                Button { togglePin(item: item) } label: {
                                    Label(item.group == .pinned ? l10n.unpin : l10n.pin, systemImage: "pin")
                                }
                                .tint(.yellow)
                            }
                                // The row's ForEach id is a UUID but the list
                                // selection is `String?`; tag with the remoteId
                                // so highlight / j-k / Delete line up.
                                .tag(item.message.remoteId)
                                .id(item.message.remoteId)
                                // Mouse users have no swipe gesture; expose
                                // the same two verbs via right-click.
                                .contextMenu {
                                    Button(l10n.archived) { Task { await archiveAndUndo(item) } }
                                        .disabled(!canArchive)
                                    Button(item.group == .pinned ? l10n.unpin : l10n.pin) {
                                        togglePin(item: item)
                                    }
                                    // Whitelist autopilot is offered only on
                                    // subscription noise: auto-archiving a
                                    // sender that owes you replies would be
                                    // an accidental blacklist (spec 2026-09-19 §3).
                                    if item.group == .subscriptionNoise {
                                        Divider()
                                        Button(l10n.autoArchiveSenderMenuItem) {
                                            Task { await autoArchiveSender(item) }
                                        }
                                        .disabled(!canArchive)
                                    }
                                }
                            }
                        }
                    } header: {
                        groupHeader(group, count: groupItems.count)
                    }
                }
            }
        }
        .listStyle(.inset)
        .onDeleteCommand { if let id = selectedGmailId { Task { await archiveAndUndo(byId: id) } } }
        .onMoveCommand { direction in
            moveSelection(direction: direction)
        }
    }

    private func groupHeader(_ group: BriefingGroup, count: Int) -> some View {
        Button { toggle(group) } label: {
            HStack(spacing: 8) {
                Image(systemName: collapsedGroups.contains(group) ? "chevron.right" : "chevron.down")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("\(group.emoji) \(l10n.groupTitle(group))").font(.headline)
                Spacer()
                Text("\(count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(collapsedGroups.contains(group)
            ? l10n.expandGroup(l10n.groupTitle(group))
            : l10n.collapseGroup(l10n.groupTitle(group)))
        .id(group)
    }



    private var emptyState: some View {
        Group {
            if directory.active?.syncHealth.lastSyncAt == nil {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(l10n.syncingFirstTime)
                        .foregroundStyle(.secondary)
                }
            } else {
                ContentUnavailableView {
                    Label(l10n.inboxZero, systemImage: "checkmark.seal")
                } description: {
                    Text(l10n.tapGmailToSync)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }



    private var errorState: some View {
        ContentUnavailableView {
            Label(l10n.briefingUnavailable, systemImage: "exclamationmark.triangle")
        } description: {
            Text(errorBanner?.title ?? l10n.unknownError)
        } actions: {
            Button(l10n.retry) { Task { await refresh() } }
        }
    }



    // MARK: - Selection / navigation



    private func moveSelection(direction: MoveCommandDirection) {

        guard !items.isEmpty else { return }

        let visible = items.filter { !collapsedGroups.contains($0.group) }

        guard !visible.isEmpty else { return }

        let current = selectedGmailId.flatMap { id in visible.firstIndex(where: { $0.message.remoteId == id }) } ?? 0

        let next: Int

        switch direction {

        case .up: next = max(0, current - 1)

        case .down: next = min(visible.count - 1, current + 1)

        case .left, .right: return

        @unknown default: return

        }

        let target = visible[next].message.remoteId

        selectedGmailId = target

        withAnimation { scrollProxy?.scrollTo(target, anchor: .center) }

    }



    private var groupJumpShortcuts: some View {

        VStack {

            ForEach(Array(BriefingGroup.allCases.enumerated()), id: \.element) { index, group in

                Button(l10n.groupTitle(group)) { jump(to: group) }

                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)

            }

        }.frame(width: 0, height: 0).opacity(0).focusable(false).accessibilityHidden(true)

    }

    private var keyboardNavigationShortcuts: some View {
        VStack {
            Button(l10n.nextInGroup) { moveSelection(direction: .down) }
                .keyboardShortcut("j", modifiers: [])
            Button(l10n.previousInGroup) { moveSelection(direction: .up) }
                .keyboardShortcut("k", modifiers: [])
            Button(l10n.openSelected) {
                if let selectedGmailId { path = [selectedGmailId] }
            }
            .keyboardShortcut(.return, modifiers: [])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .focusable(false)
        .accessibilityHidden(true)
    }



    private func jump(to group: BriefingGroup) {

        collapsedGroups.remove(group)

        withAnimation { scrollProxy?.scrollTo(group, anchor: .top) }

    }



    // MARK: - Detail destination



    @ViewBuilder

    private func destination(for remoteId: String) -> some View {

        if let accountId = accounts.accountId {

            let visible = items.filter { !collapsedGroups.contains($0.group) }.map { $0.message.remoteId }

            let siblings = visible.contains(remoteId) ? visible : nil

            MessageDetailView(

                remoteId: remoteId,

                accountId: accountId,

                header: items.first { $0.message.remoteId == remoteId }?.message,

                initiallyPinned: items.first { $0.message.remoteId == remoteId }?.group == .pinned,

                initialGroup: items.first { $0.message.remoteId == remoteId }?.group,

                siblings: siblings,

                onArchived: { id, isArchived in

                    handleArchived(id: id, isArchived: isArchived)

                },

                onAdvanceTo: { next in path = next.map { [$0] } ?? [] },

                onReadStateChange: { id, isRead in

                    setRead(remoteId: id, isRead: isRead)

                },

                onPinnedChanged: { _ in

                    Task { await refresh() }

                }

            )
            .id(remoteId)

        } else {

            ContentUnavailableView(

                l10n.notConnected, systemImage: "person.crop.circle.badge.exclamationmark",

                description: Text(l10n.connectToRead)

            )

        }

    }



    // MARK: - Actions



    private func toggle(_ group: BriefingGroup) {

        if collapsedGroups.contains(group) { collapsedGroups.remove(group) } else { collapsedGroups.insert(group) }

    }



    private func setRead(remoteId: String, isRead: Bool) {

        guard let index = items.firstIndex(where: { $0.message.remoteId == remoteId }) else { return }

        let item = items[index]

        items[index] = BriefingItem(

            message: withUpdatedRead(item.message, isRead: isRead),

            group: item.group, reasonCode: item.reasonCode

        )

    }



    private func withUpdatedRead(_ m: MessageHeader, isRead: Bool) -> MessageHeader {

        MessageHeader(

            id: m.id, accountId: m.accountId, remoteId: m.remoteId, threadId: m.threadId,

            fromAddress: m.fromAddress, fromName: m.fromName,

            subject: m.subject, snippet: m.snippet,

            receivedAt: m.receivedAt, isRead: isRead, isArchived: m.isArchived

        )

    }



    private func handleArchived(id: String, isArchived: Bool) {

        items.removeAll { $0.message.remoteId == id }

    }



    private func togglePin(item: BriefingItem) {

        guard let accountId = accounts.accountId else { return }

        let toPinned = item.group != .pinned

        Task {

            do {

                try await api.setPinned(
                    remoteId: item.message.remoteId,
                    accountId: accountId,
                    pinned: toPinned
                )

                await refresh()

            } catch {
                errorBanner = ErrorBanner(
                    severity: .error,
                    title: toPinned ? l10n.pinFailed : l10n.unpinFailed,
                    actionLabel: l10n.retry,
                    action: { [self] in await self.togglePin(item: item) }
                )
            }

        }

    }



    private func archiveAndUndo(_ item: BriefingItem) async {

        await archiveAndUndo(byId: item.message.remoteId)

    }

    /// Whitelist autopilot entry point (spec 2026-09-19 §3): create the rule
    /// AND archive the message in front of the user — one tap, both effects,
    /// both reversible (archive via ⌘Z, the rule via the rules sheet).
    private func autoArchiveSender(_ item: BriefingItem) async {
        guard canArchive else {
            errorBanner = ErrorBanner(severity: .error, title: l10n.archiveUnavailable)
            return
        }
        guard let accountId = accounts.accountId else { return }
        do {
            _ = try await api.addAutoArchiveRule(
                senderAddress: item.message.fromAddress,
                accountId: accountId
            )
        } catch {
            errorBanner = ErrorBanner(
                severity: .error,
                title: l10n.autoArchiveRuleFailed,
                detail: error.lagoonUIMessage
            )
            return
        }
        await archiveAndUndo(byId: item.message.remoteId)
    }



    private func archiveAndUndo(byId remoteId: String) async {

        guard canArchive else {
            errorBanner = ErrorBanner(
                severity: .error,
                title: l10n.archiveUnavailable
            )
            return
        }

        guard let accountId = accounts.accountId else { return }

        do {

            let response = try await api.archiveMessage(remoteId: remoteId, accountId: accountId)

            items.removeAll { $0.message.remoteId == remoteId }

            undo.show(UndoItem(
                id: response.actionId,
                message: l10n.archived,
                systemImage: "tray.and.arrow.down"
            ))

        } catch APIError.badStatus(let code, _) where code == 409 {
            errorBanner = ErrorBanner(
                severity: .error,
                title: l10n.archiveUnavailable
            )
        } catch {
            errorBanner = ErrorBanner(
                severity: .error,
                title: l10n.archiveFailed,
                detail: error.lagoonUIMessage,
                actionLabel: l10n.retry,
                action: { [self] in await self.archiveAndUndo(byId: remoteId) }
            )
        }
    }



    private func refresh() async {

        guard let accountId = accounts.accountId else { return }

        guard !isLoading else { return }

        isLoading = true

        do {

            let response = try await api.fetchBriefing(accountId: accountId)

            items = response.items
            errorBanner = nil
        } catch {
            // Spec §6.2: a `.timedOut` from the briefing endpoint (LLM
            // classification can be slow) gets its own copy; everything
            // else falls into the generic retry banner.
            if let urlError = error as? URLError, urlError.code == .timedOut {
                errorBanner = ErrorBanner(
                    severity: .warning,
                    title: l10n.briefingTimeoutTitle,
                    detail: l10n.briefingTimeoutDetail,
                    actionLabel: l10n.retry,
                    action: { [self] in await self.refresh() }
                )
            } else {
                errorBanner = ErrorBanner(
                    severity: .error,
                    title: l10n.briefingFailed,
                    detail: error.lagoonUIMessage,
                    actionLabel: l10n.retry,
                    action: { [self] in await self.refresh() }
                )
            }
        }

        isLoading = false

    }

    /// Mark every message in the current briefing as read. Runs the per-row
    /// markRead calls in parallel via a TaskGroup so a 50-message briefing
    /// takes ~3-5 round trips' worth of wall time rather than 50 in series.
    /// Optimistic local flip first so the UI updates before the server
    /// confirms; the first error surfaces in `errorBanner` and the next
    /// refresh pulls the server's view of truth back.
    private func markAllRead() async {
        guard let accountId = accounts.accountId else { return }
        guard !isMarkingAllRead, !items.isEmpty else { return }
        let unread = items.filter { !$0.message.isRead }
        guard !unread.isEmpty else { return }
        isMarkingAllRead = true
        defer { isMarkingAllRead = false }

        // Optimistic local update so the unread dots disappear immediately.
        for i in items.indices where !items[i].message.isRead {
            items[i] = items[i].withRead(true)
        }

        await withTaskGroup(of: Error?.self) { group in
            for item in unread {
                group.addTask { [api] in
                    do {
                        try await api.markRead(
                            remoteId: item.message.remoteId,
                            accountId: accountId
                        )
                        return nil
                    } catch {
                        return error
                    }
                }
            }
            if let firstError = await group.first(where: { $0 != nil }) ?? nil {
                errorBanner = ErrorBanner(
                    severity: .warning,
                    title: l10n.markAllReadPartial,
                    detail: firstError.lagoonUIMessage
                )
            }
        }
    }

}



private struct BriefingRow: View {

    let item: BriefingItem

    @Environment(\.l10n) private var l10n



    var body: some View {

        VStack(alignment: .leading, spacing: 4) {

            HStack(alignment: .firstTextBaseline, spacing: 8) {

                Text(item.message.subject ?? l10n.noSubject)

                    .font(.body).bold(!item.message.isRead).lineLimit(1)

                Spacer(minLength: 8)

                Text(item.message.receivedAt.formatted(date: .abbreviated, time: .shortened))

                    .font(.caption2).foregroundStyle(.secondary)

            }

            Text(item.message.fromName ?? item.message.fromAddress)

                .font(.caption).foregroundStyle(.secondary).lineLimit(1)

            if let reason = l10n.reasonText(item.reasonCode) {

                Text(reason).font(.caption2).foregroundStyle(.secondary).lineLimit(2)

            } else if let snippet = item.message.snippet {

                Text(snippet).font(.caption2).foregroundStyle(.secondary).lineLimit(2)

            }

        }.padding(.vertical, 2)

    }

}

// MARK: - Optimistic read-flip helpers

extension BriefingItem {
    /// Copy with a different read state. BriefingItem itself is a thin
    /// wrapper; the read bit lives on the underlying `MessageHeader`.
    func withRead(_ isRead: Bool) -> BriefingItem {
        BriefingItem(
            message: message.withRead(isRead),
            group: group,
            reasonCode: reasonCode
        )
    }
}

extension MessageHeader {
    fileprivate func withRead(_ isRead: Bool) -> MessageHeader {
        MessageHeader(
            id: id,
            accountId: accountId,
            remoteId: remoteId,
            threadId: threadId,
            fromAddress: fromAddress,
            fromName: fromName,
            subject: subject,
            snippet: snippet,
            receivedAt: receivedAt,
            isRead: isRead,
            isArchived: isArchived
        )
    }
}
