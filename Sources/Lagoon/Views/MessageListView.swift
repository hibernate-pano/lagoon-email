import SwiftUI
import LagoonKit

/// Raw conversation list (spec §7.1) - the secondary surface reachable from
/// the Briefing Feed. Rows are conversations (会话归集, grouped by the
/// server's `thread_id`): a thread collapses to one count-badged row that
/// expands in place. Conversations are grouped by `DateBucket` (Today /
/// Yesterday / This week / ... / Earlier) so a 400-message inbox scans in
/// seconds; the row context menu opens the sender's full history.
struct MessageListView: View {
    @EnvironmentObject var accounts: AccountStore
    /// Injected by RootView, which also hosts the toast — so an undo raised
    /// on either surface is visible from this one.
    @EnvironmentObject private var undo: UndoController
    @State private var messages: [MessageHeader] = []
    @State private var isLoading = false
    @State private var errorBanner: ErrorBanner?
    @State private var path: [String] = []
    @State private var selection: Set<String> = []
    /// Thread rows the user expanded (会话归集). Collapsed by default so a
    /// 400-message inbox still scans as one row per conversation.
    @State private var expandedThreads: Set<String> = []
    /// Non-nil presents the sender's full mail history (发件人归集).
    @State private var senderFocus: SenderFocus?
    /// 聚合规则面板 + 右键创建入口。
    @State private var showStackList = false
    @State private var stackEditor: StackEditorRequest?
    /// 归集维度: conversations (thread + affinity), per-sender, or flat.
    /// Persisted — the lens the user picked should survive relaunch.
    @AppStorage("lagoon.grouping") private var groupingRaw = GroupingMode.conversation.rawValue
    @AppStorage("lagoon.unreadOnly") private var unreadOnly = false
    /// Guards the two things a local list mutation can break: a slow poll
    /// that started before the user archived a row writing the server's
    /// pre-archive snapshot back, and a refresh raised mid-poll vanishing.
    @State private var refreshGate = RefreshGate()

    enum GroupingMode: String, CaseIterable {
        case conversation
        case sender
        case date

        var mode: ConversationGrouper.Mode {
            self == .sender ? .sender : .thread
        }
    }

    private var groupingMode: GroupingMode {
        get { GroupingMode(rawValue: groupingRaw) ?? .conversation }
        nonmutating set { groupingRaw = newValue.rawValue }
    }

    /// `$`-prefix binding needs a property wrapper; a computed property
    /// provides its own explicit Binding instead.
    private var groupingBinding: Binding<GroupingMode> {
        Binding(get: { groupingMode }, set: { groupingMode = $0 })
    }
    /// False when another surface is showing (RootView keeps both alive).
    /// The poll loop sleeps instead of refreshing — keep-alive costs no
    /// traffic. Hidden shortcuts are disabled by the parent.
    var isVisible: Bool = true
    private let api = APIClient.shared

    /// Switches back to the Briefing Feed from the toolbar button.
    var onShowBriefing: () -> Void = {}

    private static let refreshInterval: Duration = .seconds(30)
    /// While the list is empty (fresh connect, backfill still landing) poll
    /// at this cadence for up to `maxFastEmptyTicks` ticks, then fall back to
    /// the 30s tracker so a genuinely empty mailbox doesn't hammer the API.
    private static let emptyPollInterval: Duration = .seconds(3)
    private static let maxFastEmptyTicks = 20

    @Environment(\.l10n) private var l10n
    /// Backgrounded windows idle instead of polling — see `sleepForPoll`.
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack(path: $path) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text(l10n.allMessages)
                        .font(.headline)
                    Picker(l10n.groupingLabel, selection: groupingBinding) {
                        Text(l10n.groupingConversation).tag(GroupingMode.conversation)
                        Text(l10n.groupingSender).tag(GroupingMode.sender)
                        Text(l10n.groupingDate).tag(GroupingMode.date)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .help(l10n.groupingHelp)
                    Spacer()
                    Button {
                        unreadOnly.toggle()
                    } label: {
                        Label(l10n.unreadOnly, systemImage: unreadOnly ? "envelope.badge.fill" : "envelope.badge")
                    }
                    .help(l10n.unreadOnlyHelp)
                    Button {
                        showStackList = true
                    } label: {
                        Label(l10n.stackListTitle, systemImage: "rectangle.stack")
                    }
                    .help(l10n.stackListTitle)
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
                    // Refresh is ⌥⌘R so it never collides with ⌘R = reply on the
                    // open message. No path.isEmpty guard needed: the modifiers
                    // are disjoint, so both bindings stay live in the same stack.
                    refreshControl
                        .keyboardShortcut("r", modifiers: [.command, .option])
                }
                .padding()

                if !messages.isEmpty {
                    List(selection: $selection) {
                        ForEach(groupedSections, id: \.bucket) { section in
                            Section {
                                ForEach(section.conversations) { conversation in
                                    if conversation.messages.count > 1 {
                                        conversationRow(conversation)
                                    } else {
                                        messageRow(conversation.newest)
                                            .modifier(RowChrome(
                                                message: conversation.newest,
                                                onArchive: { Task { await archive(conversation.newest) } },
                                                onToggleRead: { Task { await toggleRead(conversation.newest) } },
                                                onShowSender: { senderFocus = SenderFocus(from: conversation.newest) },
                                                onAggregateSender: { openAggregateEditor(kind: .sender, for: conversation.newest) },
                                                onAggregateKeyword: { openAggregateEditor(kind: .keyword, for: conversation.newest) },
                                                onDelete: { Task { await delete(conversation.newest) } }
                                            ))
                                    }
                                }
                            } header: {
                                Text(l10n.label(for: section.bucket))
                                    .font(.caption)
                                    .bold()
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 4)
                            }
                        }
                    }
                    .listStyle(.inset)
                    // ⌫ archives the highlighted row(s). Backspace is the
                    // gesture every mail client uses; .delete is the SwiftUI
                    // name for it.
                    .onDeleteCommand {
                        archiveSelected()
                    }
                    .sheet(item: $senderFocus) { focus in
                        if let accountId = accounts.accountId {
                            SenderSheet(
                                accountId: accountId,
                                senderAddress: focus.address,
                                senderName: focus.name
                            )
                        }
                    }
                    .sheet(item: $stackEditor) { request in
                        StackRuleEditorSheet(
                            initialKind: request.kind,
                            prefilledValue: request.value,
                            prefilledName: request.name
                        ) { _ in
                            Task { await refresh() }
                        }
                    }
                } else if !isLoading && errorBanner == nil {
                    Text(l10n.noMessagesYet)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // 聚合规则 is reachable from the toolbar button, which is
            // outside the `!messages.isEmpty` branch — so the sheet has to
            // live outside it too. It used to hang off the `List`, where an
            // empty inbox meant the button did nothing at all and the
            // feature was unreachable. The two sheets below it stay put:
            // every one of their setters is a row action, and a row cannot
            // exist without a list.
            .sheet(isPresented: $showStackList) {
                StackListSheet()
            }
            .navigationDestination(for: String.self) { remoteId in
                destination(for: remoteId)
            }
        }
        .noticeBanner($errorBanner)
        .frame(minWidth: 720, minHeight: 480)
        // ⌘[ pops the NavigationStack one level. Hidden so the
        // keyboard shortcut is the only UI affordance — mirrors Mail.app.
        .background {
            Button(l10n.back) {
                if !path.isEmpty { path.removeLast() }
            }
            .keyboardShortcut("[", modifiers: .command)
            .help(l10n.backHelp)
            .frame(width: 0, height: 0)
            .opacity(0)
            .focusable(false)
            .accessibilityHidden(true)
            // ⌘⌫ deletes the selected row(s) (moves to the server's Trash),
            // mirroring ⌫ = archive.
            Button(l10n.deleteContext) {
                deleteSelected()
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)
            .focusable(false)
            .accessibilityHidden(true)
        }
        // Initial load, then track the server's 30s poller while visible.
        // The view stays alive across surface switches (RootView ZStack),
        // so an invisible surface must sleep instead of polling.
        .task {
            await refresh()
            var emptyTicks = 0
            while !Task.isCancelled {
                let fast = messages.isEmpty && emptyTicks < Self.maxFastEmptyTicks
                emptyTicks = messages.isEmpty ? emptyTicks + 1 : 0
                guard await sleepForPoll(
                    fast ? Self.emptyPollInterval : Self.refreshInterval
                ) else { return }
                if shouldPoll(isVisible: isVisible, scenePhase: scenePhase) {
                    await refresh()
                }
            }
        }
        // ⌘Z (raised on either surface — the toast lives in RootView) restores
        // the row server-side. Without these the list would sit on its stale
        // snapshot until the next 30s tick.
        .onReceive(NotificationCenter.default.publisher(for: .lagoonDidUndo)) { _ in
            Task { await refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lagoonDidChangeData)) { _ in
            Task { await refresh() }
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
                // The list row knows its own pin state, so the detail view
                // starts on the truth. It used to be hardcoded false, which
                // showed "置顶" for a mail that was already pinned and made
                // the first tap a no-op (pinned=true over an existing pin).
                initiallyPinned: header?.isPinned ?? false,
                siblings: messages.map(\.remoteId),
                onArchived: { id, _ in dropRow(id) },
                onAdvanceTo: { next in
                    path = next.map { [$0] } ?? []
                },
                onDelete: { id in
                    dropRow(id)
                    path = []
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

    /// The one way a row leaves the list. Retiring the in-flight poll is
    /// not optional here: a poll that captured the list before the archive
    /// lands afterwards and writes the row straight back — and because the
    /// detail view auto-advances, the user is then looking at the next
    /// mail while the archived one reappears behind them.
    private func dropRow(_ remoteId: String) {
        refreshGate.invalidate()
        messages.removeAll { $0.remoteId == remoteId }
    }

    private var refreshControl: some View {
        Button(l10n.refresh) {
            Task { await refresh() }
        }
        .disabled(isLoading)
        .help(l10n.shortcutRefresh)
    }

    private func setRead(remoteId: String, isRead: Bool) {
        guard let index = messages.firstIndex(where: { $0.remoteId == remoteId }) else { return }
        invalidatePendingRefresh()
        // `MessageHeader.withRead` copies every other field. The
        // hand-rolled constructor this replaced silently dropped
        // `isPinned` (and the RFC threading headers), so clearing the unread
        // dot on a pinned mail un-pinned it locally.
        messages[index] = messages[index].withRead(isRead)
    }

    // MARK: - Sync

    /// Retire any poll already in flight. Called by every local mutation of
    /// `messages` (archive, delete, mark-read) so a response captured before
    /// that mutation cannot write the pre-mutation snapshot back over it.
    private func invalidatePendingRefresh() {
        refreshGate.invalidate()
    }

    private func refresh() async {
        guard let id = accounts.accountId else { return }
        // `claim` is nil while a refresh is in flight. It used to be a bare
        // `guard !isLoading else { return }`, which silently discarded the
        // request: a ⌘Z landing mid-poll left the user looking at a snapshot
        // taken before the undo until the next 30s tick. The gate remembers
        // it instead and `finish()` tells us to run again.
        guard let generation = refreshGate.claim() else { return }
        isLoading = true
        // `defer`, not a trailing assignment: the two generation guards below
        // return early, and without this a single superseded response would
        // pin `isLoading` true for the life of the view — every later refresh
        // blocked by the guard above, the refresh button stuck disabled.
        defer {
            isLoading = false
            if refreshGate.finish() {
                Task { await refresh() }
            }
        }
        errorBanner = nil
        do {
            let resp = try await api.fetchMessages(accountId: id)
            // A newer refresh started while this one was in flight; its
            // payload is at least as fresh, so committing this one would
            // resurrect rows the user has since archived or deleted.
            guard generation == refreshGate.generation else { return }
            messages = resp.messages
            accounts.setLastSync(resp)
        } catch {
            guard generation == refreshGate.generation else { return }
            errorBanner = ErrorBanner(
                severity: .error,
                title: l10n.syncFailed + error.lagoonUIMessage,
                actionLabel: l10n.retry,
                action: { [self] in await self.refresh() }
            )
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func messageRow(_ m: MessageHeader) -> some View {
        NavigationLink(value: m.remoteId) {
            HStack(alignment: .top, spacing: 8) {
                // Unread dot: a small accent so triaging at a glance is easy.
                if !m.isRead {
                    Circle()
                        .fill(.tint)
                        .frame(width: 7, height: 7)
                        .padding(.top, 7)
                        .accessibilityLabel(l10n.unreadDotLabel)
                } else {
                    Color.clear.frame(width: 7, height: 7)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(m.subject ?? l10n.noSubject)
                            .font(.body)
                            .bold(!m.isRead)
                            .lineLimit(1)
                        Spacer()
                        Text(m.receivedAt.formatted(date: .omitted, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(m.fromName ?? m.fromAddress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let snippet = m.snippet {
                        Text(snippet)
                            .font(.caption2)
                            .lineLimit(2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Conversation grouping (会话归集)

    private struct ConversationSection: Identifiable {
        let bucket: DateBucket
        let conversations: [Conversation]
        var id: DateBucket { bucket }
    }

    /// Rows the current lens shows: the unread-only filter is the first cut.
    private var displayMessages: [MessageHeader] {
        unreadOnly ? messages.filter { !$0.isRead } : messages
    }

    /// Threads first (by `thread_id` + same-sender/same-subject affinity, or
    /// pure per-sender, per the lens), then each thread lands in the date
    /// bucket of its newest message — so a thread spanning midnight stays
    /// one row instead of splitting in two. The `.date` lens flattens to
    /// singleton rows (the count==1 row path renders them exactly as before).
    private var groupedSections: [ConversationSection] {
        switch groupingMode {
        case .date:
            let groups = Dictionary(grouping: displayMessages) { $0.receivedAt.dateBucket }
            return DateBucket.allCases.compactMap { bucket in
                guard let items = groups[bucket], !items.isEmpty else { return nil }
                let conversations = items
                    .sorted { $0.receivedAt > $1.receivedAt }
                    .map { Conversation(threadId: $0.remoteId, messages: [$0]) }
                return ConversationSection(bucket: bucket, conversations: conversations)
            }
        case .conversation, .sender:
            let conversations = ConversationGrouper.group(displayMessages, mode: groupingMode.mode)
            let groups = Dictionary(grouping: conversations) { $0.newest.receivedAt.dateBucket }
            return DateBucket.allCases.compactMap { bucket in
                guard let items = groups[bucket], !items.isEmpty else { return nil }
                return ConversationSection(bucket: bucket, conversations: items)
            }
        }
    }

    /// Collapsed thread: one row per conversation with a count badge and
    /// disclosure chevron; tapping expands the member rows in place. Verbs
    /// on the collapsed row act on the newest message only — per-message
    /// actions live on the expanded members, so nothing bulk-fires unseen.
    private func conversationRow(_ conversation: Conversation) -> some View {
        let newest = conversation.newest
        let isExpanded = expandedThreads.contains(conversation.threadId)
        return VStack(spacing: 0) {
            Button {
                if isExpanded {
                    expandedThreads.remove(conversation.threadId)
                } else {
                    expandedThreads.insert(conversation.threadId)
                }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    if conversation.hasUnread {
                        Circle()
                            .fill(.tint)
                            .frame(width: 7, height: 7)
                            .padding(.top, 7)
                            .accessibilityLabel(l10n.unreadDotLabel)
                    } else {
                        Color.clear.frame(width: 7, height: 7)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(newest.subject ?? l10n.noSubject)
                                .font(.body)
                                .bold(conversation.hasUnread)
                                .lineLimit(1)
                            Spacer()
                            Text(l10n.threadCount(conversation.messages.count))
                                .font(.caption2)
                                .bold()
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(newest.fromName ?? newest.fromAddress)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if !isExpanded, let snippet = newest.snippet {
                            Text(snippet)
                                .font(.caption2)
                                .lineLimit(2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(l10n.threadRowLabel(conversation.messages.count))
            .modifier(RowChrome(
                message: newest,
                onArchive: { Task { await archive(newest) } },
                onToggleRead: { Task { await toggleRead(newest) } },
                onShowSender: { senderFocus = SenderFocus(from: newest) },
                onAggregateSender: { openAggregateEditor(kind: .sender, for: newest) },
                onAggregateKeyword: { openAggregateEditor(kind: .keyword, for: newest) },
                onDelete: { Task { await delete(newest) } }
            ))
            if isExpanded {
                ForEach(conversation.messages) { m in
                    messageRow(m)
                        .modifier(RowChrome(
                            message: m,
                            onArchive: { Task { await archive(m) } },
                            onToggleRead: { Task { await toggleRead(m) } },
                            onShowSender: { senderFocus = SenderFocus(from: m) },
                            onAggregateSender: { openAggregateEditor(kind: .sender, for: m) },
                            onAggregateKeyword: { openAggregateEditor(kind: .keyword, for: m) },
                            onDelete: { Task { await delete(m) } }
                        ))
                        .padding(.leading, 14)
                }
            }
        }
    }

    // MARK: - Actions

    private func archive(_ m: MessageHeader) async {
        // Any local mutation retires the in-flight poll. Without this the
        // generation counter only ever guards refresh-vs-refresh — which
        // `guard !isLoading` already serialises — so the real race stayed
        // open: a poll that captured the list *before* this archive lands
        // afterwards and writes the row straight back.
        invalidatePendingRefresh()
        do {
            let response = try await api.archiveMessage(remoteId: m.remoteId, accountId: m.accountId)
            withAnimation(.snappy) {
                messages.removeAll { $0.remoteId == m.remoteId }
            }
            SoundEffects.archive()
            undo.show(UndoItem(
                id: response.actionId,
                message: l10n.archived,
                systemImage: "tray.and.arrow.down"
            ))
        } catch APIError.badStatus(let code, _) where code == 409 {
            // The account negotiated no archive-capable folder, so the
            // server refuses every archive. Retrying cannot help — say so
            // instead of filing a generic failure.
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
                action: { [self] in await self.archive(m) }
            )
        }
    }

    /// Archive every message the user has selected (multi-select via ⌫
    /// or shift-click). Failures on individual rows surface a banner;
    /// successes are removed from the list silently to keep the gesture
    /// snappy.
    private func archiveSelected() {
        let ids = selection.isEmpty ? Set(messages.prefix(1).map(\.remoteId)) : selection
        let targets = messages.filter { ids.contains($0.remoteId) }
        selection.removeAll()
        for m in targets {
            Task { await archive(m) }
        }
    }

    /// Two-way read toggle. The server's `/read` route takes `isRead`
    /// and writes it both locally (direct UPDATE, bypassing the sync OR)
    /// and remotely (`\\Seen` add/remove), and `IMAPProvider.setRead`
    /// re-baselines `reportedRead` so the next sync round does not flip it
    /// back. Optimistic flip with revert on failure, same as before.
    private func toggleRead(_ m: MessageHeader) async {
        let target = !m.isRead
        invalidatePendingRefresh()
        if let index = messages.firstIndex(where: { $0.remoteId == m.remoteId }) {
            messages[index] = m.withRead(target)
        }
        do {
            let actionId = try await api.markRead(
                remoteId: m.remoteId, accountId: m.accountId, isRead: target, record: true
            )
            if let actionId {
                undo.show(UndoItem(
                    id: actionId,
                    message: target ? l10n.markedAsReadToast : l10n.markedAsUnreadToast,
                    systemImage: "envelope.open"
                ))
            }
        } catch {
            if let index = messages.firstIndex(where: { $0.remoteId == m.remoteId }) {
                messages[index] = m.withRead(m.isRead)
            }
        }
    }

    /// 删除 = 移入服务器废纸篓（provider.trash），可 ⌘Z 撤销（restore）。
    /// 本地行为与归档一致：行立刻离开列表，toast 承接撤销入口。
    private func delete(_ m: MessageHeader) async {
        invalidatePendingRefresh()
        do {
            let response = try await api.deleteMessage(remoteId: m.remoteId, accountId: m.accountId)
            withAnimation(.snappy) {
                messages.removeAll { $0.remoteId == m.remoteId }
            }
            undo.show(UndoItem(
                id: response.actionId,
                message: l10n.deleted,
                systemImage: "trash"
            ))
        } catch {
            errorBanner = ErrorBanner(
                severity: .error,
                title: l10n.deleteFailedTitle,
                detail: error.lagoonUIMessage
            )
        }
    }

    /// ⌘⌫ — delete the selected row(s), mirroring ⌫ = archive.
    private func deleteSelected() {
        let ids = selection.isEmpty ? Set(messages.prefix(1).map(\.remoteId)) : selection
        let targets = messages.filter { ids.contains($0.remoteId) }
        selection.removeAll()
        for m in targets {
            Task { await delete(m) }
        }
    }

    /// 聚合入口：sender 规则直接预填发件人；keyword 规则带主题建议词，
    /// 用户在编辑器里确认/修改后才落库。
    private func openAggregateEditor(kind: StackRule.Kind, for m: MessageHeader) {
        if kind == .sender {
            stackEditor = StackEditorRequest(
                kind: .sender, value: m.fromAddress, name: m.fromName ?? m.fromAddress
            )
        } else {
            let suggestion = SubjectNormalizer.suggestKeyword(in: m.subject) ?? ""
            stackEditor = StackEditorRequest(kind: .keyword, value: suggestion, name: suggestion)
        }
    }
}

// MARK: - Row chrome

/// Read/unread toggle label for a row. The wire is two-way since V1:
/// `/read?isRead=false` clears `\\Seen` remotely and writes FALSE locally,
/// so both directions are live controls.
func readVerbTitle(_ message: MessageHeader, l10n: L10n) -> String {
    message.isRead ? l10n.markAsUnread : l10n.markAsRead
}

/// Tag + triage gestures shared by every tappable row (single message or
/// expanded thread member). Also the 发件人归集 and 聚合 entry points.
private struct RowChrome: ViewModifier {
    let message: MessageHeader
    let onArchive: () -> Void
    let onToggleRead: () -> Void
    let onShowSender: () -> Void
    let onAggregateSender: () -> Void
    let onAggregateKeyword: () -> Void
    let onDelete: () -> Void
    @Environment(\.l10n) private var l10n

    @ViewBuilder
    func body(content: Content) -> some View {
        chrome(content)
            .swipeActions(edge: .leading) {
                // Leading swipe = read/unread toggle. Single gesture, no
                // destructive styling so the row snaps back without
                // warning.
                Button { onToggleRead() } label: {
                    Label(readVerbTitle(message, l10n: l10n), systemImage: "envelope.open")
                }
                .tint(.blue)
            }
    }

    private func chrome(_ content: Content) -> some View {
        content
            .tag(message.remoteId)
            .swipeActions(edge: .trailing) {
                // Trailing swipe = archive (Mail.app convention).
                Button(role: .destructive) { onArchive() } label: {
                    Label(l10n.archived, systemImage: "tray.and.arrow.down")
                }
            }
            .contextMenu {
                Button(readVerbTitle(message, l10n: l10n)) { onToggleRead() }
                Button(l10n.archived) { onArchive() }
                Divider()
                // 聚合: seed a persistent rule from this row — one tap for the
                // sender rule, the editor for a subject keyword.
                Menu(l10n.aggregateMenu) {
                    Button(l10n.aggregateBySender) { onAggregateSender() }
                    Button(l10n.aggregateByKeyword) { onAggregateKeyword() }
                }
                Button(l10n.senderMailContext) { onShowSender() }
                Divider()
                Button(l10n.deleteContext, role: .destructive) { onDelete() }
            }
    }
}

/// Identifiable wrapper so `.sheet(item:)` can present the sender view.
private struct SenderFocus: Identifiable {
    let address: String
    let name: String?
    init(from m: MessageHeader) {
        address = m.fromAddress
        name = m.fromName
    }
    var id: String { address }
}

// MARK: - DateBucket

/// Friendly grouping used by `MessageListView`. Order in `allCases` is the
/// display order (newest → oldest); `dateBucket` is computed from the
/// local calendar so a message at 23:59 today stays in `.today` and
/// doesn't flip to `.yesterday` until midnight.
public enum DateBucket: CaseIterable, Comparable, Sendable {
    case today
    case yesterday
    case thisWeek
    case thisMonth
    case earlier

    private var sortOrder: Int {
        switch self {
        case .today: 0
        case .yesterday: 1
        case .thisWeek: 2
        case .thisMonth: 3
        case .earlier: 4
        }
    }

    public static func < (lhs: DateBucket, rhs: DateBucket) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

extension Date {
    var dateBucket: DateBucket {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return .today }
        if calendar.isDateInYesterday(self) { return .yesterday }
        let now = Date()
        let days = calendar.dateComponents([.day], from: self, to: now).day ?? 0
        if days < 7 { return .thisWeek }
        if days < 30 { return .thisMonth }
        return .earlier
    }
}

