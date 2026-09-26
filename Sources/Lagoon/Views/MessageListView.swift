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
    /// 归集维度: conversations (thread + affinity), per-sender, or flat.
    /// Persisted — the lens the user picked should survive relaunch.
    @AppStorage("lagoon.grouping") private var groupingRaw = GroupingMode.conversation.rawValue
    @AppStorage("lagoon.unreadOnly") private var unreadOnly = false

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
                                                onShowSender: { senderFocus = SenderFocus(from: conversation.newest) }
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
        }
        // Initial load, then track the server's 30s poller while visible.
        // The view stays alive across surface switches (RootView ZStack),
        // so an invisible surface must sleep instead of polling.
        .task {
            await refresh()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.refreshInterval)
                } catch {
                    return
                }
                if isVisible {
                    await refresh()
                }
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
                // Hidden side of RootView's ZStack: keep the detail mounted
                // but emit no window toolbar items (they would duplicate the
                // visible surface's cluster).
                surfaceVisible: isVisible,
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
                onShowSender: { senderFocus = SenderFocus(from: newest) }
            ))
            if isExpanded {
                ForEach(conversation.messages) { m in
                    messageRow(m)
                        .modifier(RowChrome(
                            message: m,
                            onArchive: { Task { await archive(m) } },
                            onToggleRead: { Task { await toggleRead(m) } },
                            onShowSender: { senderFocus = SenderFocus(from: m) }
                        ))
                        .padding(.leading, 14)
                }
            }
        }
    }

    // MARK: - Actions

    private func archive(_ m: MessageHeader) async {
        do {
            _ = try await api.archiveMessage(remoteId: m.remoteId, accountId: m.accountId)
            messages.removeAll { $0.remoteId == m.remoteId }
        } catch APIError.badStatus(_, _) where (try? archiveUnavailable()) == nil {
            // server answered 409 — the account can't archive; banner set below
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

    private func toggleRead(_ m: MessageHeader) async {
        // Optimistic toggle: flip the local state immediately, then write
        // through. If the server fails, revert.
        let original = m.isRead
        if let index = messages.firstIndex(where: { $0.remoteId == m.remoteId }) {
            messages[index] = m.withRead(!original)
        }
        do {
            try await api.markRead(remoteId: m.remoteId, accountId: m.accountId)
        } catch {
            if let index = messages.firstIndex(where: { $0.remoteId == m.remoteId }) {
                messages[index] = m.withRead(original)
            }
        }
    }

    private func archiveUnavailable() throws -> Void {
        // Discriminates the 409 path; the real mapping lives in
        // MessageDetailView. We surface a banner instead.
        throw APIError.badStatus(code: 409, bodySnippet: "archive-unavailable")
    }
}

// MARK: - Row chrome

/// Tag + triage gestures shared by every tappable row (single message or
/// expanded thread member). Also the 发件人归集 entry point.
private struct RowChrome: ViewModifier {
    let message: MessageHeader
    let onArchive: () -> Void
    let onToggleRead: () -> Void
    let onShowSender: () -> Void
    @Environment(\.l10n) private var l10n

    func body(content: Content) -> some View {
        content
            .tag(message.remoteId)
            .swipeActions(edge: .trailing) {
                // Trailing swipe = archive (Mail.app convention).
                Button(role: .destructive) { onArchive() } label: {
                    Label(l10n.archived, systemImage: "tray.and.arrow.down")
                }
            }
            .swipeActions(edge: .leading) {
                // Leading swipe = toggle read. Single gesture, no destructive
                // styling so the row snaps back without warning.
                Button { onToggleRead() } label: {
                    Label(
                        message.isRead ? l10n.markAsUnread : l10n.markAsRead,
                        systemImage: message.isRead ? "envelope.badge" : "envelope.open"
                    )
                }
                .tint(.blue)
            }
            .contextMenu {
                Button(message.isRead ? l10n.markAsUnread : l10n.markAsRead) { onToggleRead() }
                Button(l10n.archived) { onArchive() }
                Divider()
                Button(l10n.senderMailContext) { onShowSender() }
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

extension MessageHeader {
    /// Tap-to-toggle-read creates a copy with the read flag flipped. The
    /// stored struct is `Sendable` and value-typed, so this is the
    /// standard "copy with a field change" idiom.
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
