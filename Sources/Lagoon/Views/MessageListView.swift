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
    /// Injected by RootView. Read here for the account's negotiated
    /// capabilities — the bulk archive button must be disabled on exactly the
    /// same condition as the per-row one, or the bar offers a verb the server
    /// will refuse.
    @EnvironmentObject private var directory: DirectoryStore
    @State private var messages: [MessageHeader] = []
    /// Rows the filter matches on the server, ignoring the response cap.
    /// Non-nil only when the response carried it, so an older server keeps
    /// rendering the list rather than a wrong claim about its size.
    @State private var serverTotalCount: Int?
    @State private var isLoading = false
    @State private var errorBanner: ErrorBanner?
    @State private var selection: Set<String> = []
    /// 阶段二已选：用户点了「选择服务器上的全部 N 封」之后为 true。
    ///
    /// This is the whole of Gmail's two-stage select-all, and it exists because
    /// the list is a **window**. Stage one selects what is loaded; stage two
    /// says "and the rest". Collapsing them into one "全选" would make a bulk
    /// delete quietly act on 3,000 messages when the user could see 50 — the
    /// single most destructive ambiguity a mail client can have.
    @State private var selectedAllOnServer = false
    /// 批量操作进行中。Bulk verbs are one remote round trip per message, so a
    /// second click mid-sweep would double-fire them.
    @State private var isBulkBusy = false
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
    /// Row density, shared by both mail surfaces through `UserDefaults` so the
    /// Briefing feed and the raw list cannot end up at different densities —
    /// they are two views of one mailbox.
    @AppStorage(ListDensityPreference.key) private var densityRaw = ListDensity.compact.rawValue
    /// 待确认的彻底删除。Non-nil while the confirmation alert is up.
    ///
    /// Held as the message rather than a Bool so the alert can *name* what it
    /// is about to destroy — a generic "are you sure?" on an irreversible
    /// action is a rubber stamp, and this is the one action in the product with
    /// no undo behind it.
    @State private var pendingPurge: MessageHeader?
    /// 清空废纸篓的确认。Separate from `pendingPurge` because the copy differs:
    /// one names a subject, the other names a count and a total size claim.
    @State private var confirmEmptyTrash = false
    @State private var isEmptyingTrash = false
    /// In-flight 彻底删除, so a second click cannot fire two purges for one row.
    @State private var isPurging = false
    /// 已发送 could not reach the server; the rows on screen may be out of date
    /// (R1). Kept apart from `errorBanner` because it is **not** an error the
    /// user needs to act on — it is context for what they are reading.
    @State private var isSentStale = false
    /// 空状态的三件套：图标 / 标题 / 补充说明。
    ///
    /// Split out so the title and the hint can disagree productively — most
    /// surfaces here have something useful to say beyond "nothing here", and a
    /// single shared string cannot.
    private var emptyStateIcon: String {
        switch lens {
        case .some(.sent): return "paperplane"
        case .some(.archived): return "archivebox"
        case .some(.deleted): return "trash"
        case .some(.pinned): return "pin"
        case .some(.unread): return "envelope"
        case .some(.rule): return "label"
        case .some(.all), .none: return "tray"
        }
    }

    private var emptyStateTitle: String {
        switch lens {
        case .some(.sent): return l10n.sentEmpty
        default: return l10n.noMessagesYet
        }
    }

    /// Nil where a hint would only be noise — an empty inbox needs no
    /// explanation, an empty 已发送 does.
    private var emptyStateHint: String? {
        switch lens {
        case .some(.sent): return l10n.sentEmptyHint
        default: return nil
        }
    }

    /// 工具栏标题，跟随当前透镜。
    ///
    /// Was hardcoded to 「全部邮件」 for every lens, which is why 废纸篓 and
    /// 档案柜 looked identical in the one place the user looks to confirm
    /// where they are. Same class of lie as the old `case .deleted: self =
    /// .all` — the surface said one thing and the content said another.
    private var surfaceTitle: String {
        Self.surfaceTitle(for: lens, l10n: l10n)
    }

    /// The lens → toolbar-title mapping, as a pure function.
    ///
    /// Extracted so `SentSurfaceUITests` can assert against the *real* mapping
    /// rather than a reimplementation of it. The previous version of that test
    /// only compared four `L10n` constants against each other, which stayed
    /// green even if this switch collapsed every case back to `allMessages` —
    /// i.e. it could not have caught the bug it was written for.
    static func surfaceTitle(for lens: Lens?, l10n: L10n) -> String {
        switch lens {
        case .some(.sent): return l10n.sidebarSent
        case .some(.archived): return l10n.stackArchivedRow
        case .some(.deleted): return l10n.sidebarDeleted
        case .some(.rule): return l10n.stackRulesHeader
        case .some(.unread): return l10n.sidebarUnread
        case .some(.pinned): return l10n.sidebarPinned
        case .some(.all), .none: return l10n.allMessages
        }
    }

    /// The row the pointer is resting on, and how long it has been there.
    ///
    /// Hover state lives here rather than on each row because the *delay*
    /// matters: an instant preview would strobe while the pointer crosses the
    /// list on its way somewhere else, and a card that appears on every row
    /// passed over is noise. Only a deliberate rest opens it.
    @State private var hoveredRemoteId: String?
    @State private var hoverTask: Task<Void, Never>?
    /// Guards the two things a local list mutation can break: a slow poll
    /// that started before the user archived a row writing the server's
    /// pre-archive snapshot back, and a refresh raised mid-poll vanishing.
    @State private var refreshGate = RefreshGate()
    /// Captured by the `ScrollViewReader` in `body` so the j/k walk can
    /// reveal the row it just highlighted.
    @State private var scrollProxy: ScrollViewProxy?

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

    private var density: ListDensity {
        get { ListDensity(rawValue: densityRaw) ?? .compact }
        nonmutating set { densityRaw = newValue.rawValue }
    }

    private func densityTitle(_ option: ListDensity) -> String {
        switch option {
        case .comfortable: return l10n.densityComfortable
        case .compact: return l10n.densityCompact
        case .dense: return l10n.densityDense
        }
    }

    /// Opens the hover card for a row after a deliberate rest.
    ///
    /// The task is cancelled on every exit and on every move to a different
    /// row, so sliding the pointer across the list never leaves a trail of
    /// stale cards behind it.
    private func hover(_ remoteId: String?) {
        hoverTask?.cancel()
        guard let remoteId else {
            hoveredRemoteId = nil
            return
        }
        // No card while a multi-selection is live: the bar has already told the
        // user what their next click will act on, and a card following the
        // pointer during a range selection is pure noise.
        guard selection.count <= 1 else { return }
        hoveredRemoteId = nil
        hoverTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            hoveredRemoteId = remoteId
        }
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

    /// Which slice of the mailbox the sidebar is pointing at.
    ///
    /// A value rather than three booleans because the destinations overlap and
    /// one of them needs an argument the others don't have (a rule id) — three
    /// independent flags could express "unread AND archived AND rule X", which
    /// is not a place anyone can navigate to.
    enum Lens: Equatable {
        case all
        case unread
        case pinned
        case archived
        /// 已发送 (R1). Its own case because it is fetched from a *different*
        /// route (`/api/sent`) — the inbox poll cannot answer it, because the
        /// sync loop only ever SELECTs the INBOX.
        case sent
        case deleted
        case rule(UUID)

        init(_ destination: SidebarDestination) {
            switch destination {
            case .allMessages, .briefing: self = .all
            case .unread: self = .unread
            case .pinned: self = .pinned
            case .archived: self = .archived
            case .sent: self = .sent
            // The Trash gets a real lens. It used to map to `.all`, which meant
            // clicking 废纸篓 in the sidebar showed the inbox — a button that
            // lies about where it takes you, which is worse than having none.
            case .deleted: self = .deleted
            case .rule(let id): self = .rule(id)
            }
        }

        /// Whether this lens lists trashed mail, which changes what the verbs
        /// mean: there is no "archive" for something already in the trash, and
        /// "delete" there means something irreversible-adjacent instead.
        var isTrash: Bool { self == .deleted }

        /// Whether this lens is served by `/api/sent` rather than the inbox
        /// poll. One predicate, because getting it wrong is silent: the inbox
        /// route would answer 200 with an empty list and 已发送 would look
        /// permanently empty.
        var needsSentRoute: Bool { self == .sent }
    }

    /// The sidebar's destination, applied as a filter.
    ///
    /// Held by the parent so the sidebar and this list cannot disagree; this
    /// view only reads it. `nil` before the account connects.
    var lens: Lens?

    /// The rule id this lens selects, if any.
    private var ruleId: UUID? {
        if case .rule(let id) = lens { return id }
        return nil
    }

    /// The unread-only cut, which the lens owns when it says `.unread`.
    ///
    /// The sidebar and the in-list filter chip are the same control seen from
    /// two places: picking 未读 in the sidebar must light the chip, and
    /// unchecking the chip must not leave the sidebar claiming a filter the
    /// list is no longer applying.
    private var unreadOnlyEffective: Bool {
        switch lens {
        case .some(.unread): return true
        case .some(.pinned), .some(.archived), .some(.sent), .some(.deleted),
            .some(.rule), .some(.all):
            return false
        case nil: return unreadOnly
        }
    }

    /// Switches back to the Briefing Feed from the toolbar button.
    var onShowBriefing: () -> Void = {}

    /// Leaves a sidebar-owned filter (currently: 未读) and returns to the
    /// unfiltered list.
    ///
    /// Separate from `onShowBriefing` on purpose — leaving the lens must not
    /// also swap the surface, or clearing a filter would throw the user out of
    /// the list they are working in.
    var onClearLens: () -> Void = {}

    /// A sender handed in from outside (the 发件人排行 panel) to present.
    ///
    /// A *binding*, because the list has to write `nil` back to mark the
    /// request consumed — otherwise the sheet reopens on the next redraw. A
    /// one-shot value the receiver cannot clear is a value that fires forever.
    @Binding var senderFocusRequest: SenderFocus?
    /// A sender handed in from outside to file into a 聚合规则.
    @Binding var senderToFile: SenderSummary?

    private static let refreshInterval: Duration = .seconds(30)
    /// While the list is empty (fresh connect, backfill still landing) poll
    /// at this cadence for up to `maxFastEmptyTicks` ticks, then fall back to
    /// the 30s tracker so a genuinely empty mailbox doesn't hammer the API.
    private static let emptyPollInterval: Duration = .seconds(3)
    private static let maxFastEmptyTicks = 20

    @Environment(\.l10n) private var l10n
    /// Backgrounded windows idle instead of polling — see `sleepForPoll`.
    @Environment(\.scenePhase) private var scenePhase

    /// The left column: filter bar plus the grouped list.
    ///
    /// Split out of `body` on purpose — the surface used to be one giant
    /// SwiftUI expression, and this project has already shipped a
    /// "unable to type-check in reasonable time" regression from adding one
    /// parameter to a chain that size.
    private var sidebar: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text(surfaceTitle)
                        .font(.headline)
                        // Never compress, never wrap. This row is a toolbar, and
                        // a heading that wraps to one glyph per line ("全/部/
                        // 邮/件") turns the surface into a column of noise that
                        // pushes everything else off-screen. `fixedSize` is the
                        // fix: the title keeps its intrinsic width and the row
                        // drops a lower-priority control instead.
                        .fixedSize()
                        .layoutPriority(1)
                    Picker(l10n.groupingLabel, selection: groupingBinding) {
                        Text(l10n.groupingConversation).tag(GroupingMode.conversation)
                        Text(l10n.groupingSender).tag(GroupingMode.sender)
                        Text(l10n.groupingDate).tag(GroupingMode.date)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .help(l10n.groupingHelp)
                    // Below the title in priority: the grouping picker and the
                    // two icon buttons are the ones a user reaches for while
                    // triaging, so they keep their space when the column is
                    // narrow. The title above outranks all of them, and the
                    // density menu below outranks none.
                    .layoutPriority(0)
                    Spacer()
                    Button {
                        // With the sidebar driving 未读, the chip reflects that
                        // lens instead of toggling a second flag — otherwise
                        // unchecking it would silently do nothing and the row
                        // would stay filtered.
                        if lens != nil {
                            onClearLens()
                        } else {
                            unreadOnly.toggle()
                        }
                    } label: {
                        Label(l10n.unreadOnly, systemImage: unreadOnlyEffective
                            ? "envelope.badge.fill" : "envelope.badge")
                    }
                    .help(l10n.unreadOnlyHelp)
                    Button {
                        showStackList = true
                    } label: {
                        Label(l10n.stackListTitle, systemImage: "rectangle.stack")
                    }
                    .help(l10n.stackListTitle)
                    // 清空废纸篓 lives on the toolbar row *only while the Trash
                    // is open* — Gmail/Outlook both put it at the top of the
                    // trash list rather than on every message, because it is an
                    // operation on the folder, not on a row. It is also the only
                    // control added for the trash lens, which keeps that lens's
                    // toolbar from crowding the width budget the title needs.
                    if lens?.isTrash == true {
                        if isEmptyingTrash {
                            ProgressView().controlSize(.small)
                        } else {
                            Button {
                                confirmEmptyTrash = true
                            } label: {
                                Label(l10n.emptyTrash, systemImage: "trash")
                            }
                            .disabled(messages.isEmpty)
                            .help(l10n.emptyTrashTitle)
                        }
                    }
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
                    // open message. The modifiers are disjoint, so both bindings
                    // stay live at once.
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
                                                onDelete: { Task { await delete(conversation.newest) } },
                                                onTogglePin: { Task { await togglePin(conversation.newest) } },
                                                lens: lens ?? .all,
                                                onRestore: { Task { await restoreFromTrash(conversation.newest) } },
                                                onUnarchive: { Task { await unarchive(conversation.newest) } },
                                                onPurge: { pendingPurge = conversation.newest }
                                            ))
                                            .onHover { inside in
                                                hover(inside ? conversation.newest.remoteId : nil)
                                            }
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
                        // A real row at the end, mirroring the Briefing Feed's
                        // `omittedCount`: it scrolls with the list, so the
                        // statement stays findable instead of being a toast the
                        // user dismisses and can never read again.
                        if let truncated {
                            Section {
                                Label(truncated, systemImage: "info.circle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel(truncated)
                            }
                        }
                    }
                    .listStyle(.inset)
                    // Density is applied as an environment value on the list so
                    // every row resizes together, including section headers and
                    // the empty state — setting a per-row height would leave the
                    // synthesized rows at the old size.
                    .listDensity(density)
                    .overlay(alignment: .bottomTrailing) { hoverCard }
                    // ⌫ archives the highlighted row(s). Backspace is the
                    // gesture every mail client uses; .delete is the SwiftUI
                    // name for it.
                    .onDeleteCommand {
                        archiveSelected()
                    }
                    // j/k move the highlight, ↩ opens it — the same trio the
                    // Briefing Feed has had all along. Without them the muscle
                    // memory built on the primary surface dies on the one
                    // surface you go to for historical mail.
                    .onMoveCommand { direction in
                        moveSelection(direction: direction)
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
                    // Lens-aware empty state. One generic 「还没有邮件」 for
                    // every surface is a small lie in each of them: in 废纸篓
                    // it says mail is missing when nothing was ever deleted,
                    // and in 已发送 it gives no hint that what lands here is
                    // whatever you sent from *any* client.
                    //
                    // The title is `.headline` rather than `.body` because an
                    // empty surface is a dead end, and a dead end deserves to
                    // look like one.
                    VStack(spacing: 6) {
                        Image(systemName: emptyStateIcon)
                            .font(.system(size: 28))
                            .foregroundStyle(.tertiary)
                        Text(emptyStateTitle)
                            .font(.headline)
                        if let emptyStateHint {
                            Text(emptyStateHint)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(24)
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
            // 已发送 的「可能不是最新」提示。Inline above the list rather than
            // as a banner, because it is not an error — it is a caveat about
            // what the user is reading, and it disappears on its own once the
            // next successful refresh lands.
            .safeAreaInset(edge: .top, spacing: 0) {
                if isSentStale {
                    Label(l10n.sentStale, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(.bar)
                        .overlay(alignment: .bottom) { Divider() }
                }
            }
            .onAppear { scrollProxy = proxy }
        }
    }

    var body: some View {
        // Selection drives the reading pane; nothing is pushed any more. The
        // old `NavigationStack(path:)` replaced the whole window with the
        // message, which is what made triage feel like a horizontal bar of
        // subjects you had to commit to one at a time.
        MessageSplitLayout(
            detailId: previewId,
            multiSelectionCount: multiSelectionCount
        ) {
            sidebar
        } detail: {
            if let previewId {
                destination(for: previewId)
            }
        }
        .noticeBanner($errorBanner)
        .frame(minWidth: 720, minHeight: 480)
        // 彻底删除 confirmation. `.alert` rather than a sheet, deliberately:
        // a sheet reads as a settings panel and gets dismissed reflexively,
        // whereas an alert has to be answered. It is the only irreversible
        // action in the product, so it gets the only blocking prompt.
        //
        // The message names the subject rather than saying "this message", so
        // the user can catch a mis-click on the wrong row — the failure this
        // prompt exists to prevent is not "did they mean to", it is "did they
        // click the right one".
        .alert(
            l10n.purgeForeverTitle,
            isPresented: Binding(
                get: { pendingPurge != nil },
                set: { if !$0 { pendingPurge = nil } }
            ),
            presenting: pendingPurge
        ) { message in
            Button(l10n.purgeForever, role: .destructive) {
                Task { await purge(message) }
            }
            Button(l10n.cancel, role: .cancel) { pendingPurge = nil }
        } message: { message in
            Text(l10n.purgeForeverConfirm(message.subject ?? l10n.noSubject))
        }
        .alert(
            l10n.emptyTrashTitle,
            isPresented: $confirmEmptyTrash
        ) {
            Button(l10n.emptyTrash, role: .destructive) {
                Task { await emptyTrashNow() }
            }
            Button(l10n.cancel, role: .cancel) { confirmEmptyTrash = false }
        } message: {
            // The count comes from the server's own total, not from
            // `messages.count`, so the number in the prompt is the number of
            // messages that will actually be erased — including the ones this
            // session never loaded.
            Text(l10n.emptyTrashConfirm(serverTotalCount ?? messages.count))
        }
        // The bulk bar lives in a bottom inset rather than the toolbar: the
        // toolbar already overflows into "»" on a narrow window (see the note in
        // `RootView.toolbar`), and these verbs belong next to the rows they
        // apply to anyway.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if bulkSelectionCount != nil {
                BulkActionBar(
                    count: bulkTargetCount,
                    onArchive: { archiveSelected() },
                    onDelete: { deleteSelected() },
                    onMarkRead: { markSelected(isRead: true) },
                    onMarkUnread: { markSelected(isRead: false) },
                    onClear: {
                        withAnimation(.snappy) {
                            selection.removeAll()
                            selectedAllOnServer = false
                        }
                    },
                    canArchive: canArchive,
                    // Stage two, inline above the verbs. It has to be a *link*
                    // carrying the real total, not a menu item: the user is
                    // deciding how much of their mailbox to put at risk, and
                    // "全部 3,142 封" is information, not an action label.
                    onSelectAllOnServer: offersSelectAllOnServer
                        ? { selectAllOnServer() } : nil,
                    allOnServerSelected: selectedAllOnServer,
                    // Shown whenever the selection reaches past what is loaded,
                    // because the user is about to act on mail they cannot see.
                    selectionReachesUnloaded: selectedAllOnServer,
                    isBusy: isBulkBusy
                )
            }
        }
        .animation(.snappy, value: bulkSelectionCount)
        .background {
            // ⌘A selects **what is loaded** — and only that.
            //
            // This is the load-bearing decision of the two-stage design. If ⌘A
            // meant "everything on the server", the most natural thing a user
            // could do — press ⌘A, ⌫ — would silently trash a mailbox they
            // could only see 50 rows of, with no confirmation in between. So ⌘A
            // is the *first* stage, and reaching the rest takes the explicit link
            // in the bulk bar, which states the real number before it is taken.
            Button(l10n.selectAll) {
                withAnimation(.snappy) {
                    selection = Set(messages.map(\.remoteId))
                    // Deliberately does NOT set `selectedAllOnServer`. Pressing
                    // ⌘A again therefore returns to stage one rather than
                    // escalating to a wider blast radius.
                    selectedAllOnServer = false
                }
            }
            .keyboardShortcut("a", modifiers: .command)
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
            // Zero-width buttons, mirroring BriefingFeedView's
            // `keyboardNavigationShortcuts`: the shortcut is the only
            // affordance, so it must be reachable from anywhere in the stack.
            Button(l10n.shortcutJ) { moveSelection(direction: .down) }
                .keyboardShortcut("j", modifiers: [])
                .frame(width: 0, height: 0)
                .opacity(0)
                .focusable(false)
                .accessibilityHidden(true)
            Button(l10n.shortcutK) { moveSelection(direction: .up) }
                .keyboardShortcut("k", modifiers: [])
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
        // Adopt (and immediately clear) the values the ranking panel hands in.
        // Clearing inside the same change is what makes them one-shot: without
        // it the sheet would reopen on every unrelated redraw.
        .onChange(of: senderFocusRequest) { _, request in
            guard let request else { return }
            senderFocus = request
            senderFocusRequest = nil
        }
        .onChange(of: senderToFile) { _, sender in
            guard let sender else { return }
            fileSender(sender)
            senderToFile = nil
        }
    }

    // MARK: - Navigation

    /// Which message the reading pane shows.
    ///
    /// Single selection previews that message. A multi-selection previews
    /// nothing and reports its count instead: ⌫/⌘⌫ are about to act on every
    /// highlighted row, so quietly showing one of them would describe the
    /// wrong scope — the classic shape of a bulk verb firing on mail the user
    /// never saw selected.
    private var previewId: String? {
        guard selection.count == 1, let only = selection.first else { return nil }
        // A row that has left the list (archived, deleted, or gone from a
        // refresh) must not leave the pane rendering a message with no header.
        guard messages.contains(where: { $0.remoteId == only }) else { return nil }
        return only
    }

    /// Nil unless two or more rows are highlighted; drives the pane's
    /// multi-selection placeholder.
    private var multiSelectionCount: Int? {
        selection.count > 1 ? selection.count : nil
    }

    /// 本次批量操作会作用到多少封邮件。
    ///
    /// Two different numbers depending on the stage, and **both are honest**:
    ///
    /// * stage one — the loaded rows the user can see and verify
    /// * stage two — the server's own total, which is what will actually be
    ///   touched
    ///
    /// Reporting the loaded count during stage two would understate the blast
    /// radius of a bulk delete by two orders of magnitude on a real mailbox.
    private var bulkTargetCount: Int {
        selectedAllOnServer ? (serverTotalCount ?? messages.count) : selection.count
    }

    /// 「选择服务器上的全部 N 封」是否应该出现。
    ///
    /// Only when the two counts actually differ. When everything is loaded there
    /// is no second stage to offer, and a link that says "select all 50" when
    /// 50 are already selected is noise.
    private var offersSelectAllOnServer: Bool {
        guard !selectedAllOnServer, let total = serverTotalCount else { return false }
        return total > messages.count
    }

    /// The lens as the server-side filter vocabulary understands it.
    ///
    /// Expressed as a `LensScope` rather than passed as ids, because stage two
    /// is a *query* — the ids for the unloaded rows do not exist on this side.
    private var lensScope: DeleteBulkRequest.LensScope {
        // Rounded-trip through the sidebar destination rather than switching on
        // the lens here: `LensScope.init(_:)` is the one place that knows which
        // lenses are folders and which are filters over the inbox, and a second
        // switch would be a second opinion that could disagree with it.
        guard let lens, let destination = SidebarDestination(lens) else { return .inbox }
        return DeleteBulkRequest.LensScope(destination)
    }

    /// How many rows the bulk bar should claim to act on.
    ///
    /// Two, not one: a single highlighted row already shows its own verbs in the
    /// reader pane and its swipe actions, and a bar over one row would hide the
    /// list to offer nothing the row does not.
    private var bulkSelectionCount: Int? {
        selection.count > 1 ? selection.count : nil
    }

    /// Same gate the per-row archive button uses, so the bar can never offer a
    /// verb the server would answer 409 to.
    private var canArchive: Bool {
        directory.active?.capabilities.archiveFolder ?? true
    }

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
                // Screen order, not storage order: "archive & next" should
                // land on the row underneath the one the user just filed, which
                // is what the grouped lenses put there — not whatever happens
                // to be next in `messages`.
                siblings: visibleRowTags,
                onArchived: { id, _ in dropRow(id) },
                onAdvanceTo: { next in
                    // nil means "that was the last one": clear the selection so
                    // the pane returns to its placeholder rather than holding a
                    // message that is no longer in the list.
                    selection = next.map { [$0] } ?? []
                },
                onDelete: { id in
                    dropRow(id)
                    selection = []
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

    /// The detail view's archive/delete callback. Delegates so the
    /// removal invariants live in exactly one place.
    private func dropRow(_ remoteId: String) {
        removeRows(matching: remoteId)
    }

    /// The only way rows leave the list locally, and the only place that
    /// invariant has to hold:
    ///
    /// * **Retire the in-flight poll.** A poll that captured the list *before*
    ///   this removal commits afterwards and writes the row straight back —
    ///   and because the detail view auto-advances, the user is then looking at
    ///   the next mail while the archived one reappears behind them. Every
    ///   caller used to remember this on its own; owning it here is what makes
    ///   it impossible to forget. `ListMutationRetiresRefreshTests` pins it.
    /// * **Move `serverTotalCount` with the list.** It is the same filter's row
    ///   count without the cap, so leaving a stale total behind turns a healthy
    ///   list into one claiming it is truncated. The next poll rewrites both
    ///   from one response and an undo refreshes, so this only has to hold for
    ///   the interval in between.
    private func removeRows(matching remoteId: String) {
        let removed = messages.filter { $0.remoteId == remoteId }.count
        guard removed > 0 else { return }
        invalidatePendingRefresh()
        messages.removeAll { $0.remoteId == remoteId }
        if let total = serverTotalCount {
            serverTotalCount = max(0, total - removed)
        }
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
            // 已发送 answers from `/api/sent`, not the inbox poll. The branch is
            // here rather than inside `APIClient` because the two responses are
            // different shapes and because the Sent call is markedly slower —
            // it opens a second IMAP session — so the caller may want to know
            // which one it is looking at.
            if lens?.needsSentRoute == true {
                let sent = try await api.fetchSent(accountId: id)
                guard generation == refreshGate.generation else { return }
                messages = sent.messages
                serverTotalCount = sent.effectiveTotal
                // Surfaced, not swallowed: a stale list that says nothing about
                // being stale is how a user reads old mail as current.
                isSentStale = sent.staleReason != nil
                // No `accounts.setLastSync` here: that call exists to advance
                // the unread cursor from the inbox payload, and a Sent payload
                // carries no cursor. Advancing it from here would mark unread
                // mail as seen without the inbox ever being read.
                errorBanner = nil
                return
            }
            let resp = try await api.fetchMessages(
                accountId: id,
                archived: lens == .archived,
                deleted: lens?.isTrash == true,
                stackId: ruleId
            )
            // A newer refresh started while this one was in flight; its
            // payload is at least as fresh, so committing this one would
            // resurrect rows the user has since archived or deleted.
            guard generation == refreshGate.generation else { return }
            messages = resp.messages
            serverTotalCount = resp.totalCount
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
        // No `NavigationLink`: the row is selected, not pushed. Selection is
        // what drives the reading pane (`previewId`), and `RowChrome` supplies
        // the `.tag` that `List(selection:)` matches on. A link here would
        // push inside the split view's sidebar column and quietly hide the
        // list — the silent failure shape recorded in
        // .memory/sheet-is-its-own-navigation-root.
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
            if density == .dense {
                    // Dense mode keeps the unread dot, sender, subject and time
                    // on one line — the minimum a human needs to decide "is
                    // this who I am looking for". The snippet is the first
                    // thing to go: it is the line that helps least when the
                    // answer is already visible in the sender.
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if !m.isRead {
                            Circle()
                                .fill(.tint)
                                .frame(width: 6, height: 6)
                        }
                        Text(m.fromName ?? m.fromAddress)
                            .font(.caption)
                            .lineLimit(1)
                            .frame(maxWidth: 110, alignment: .leading)
                        Text(m.subject ?? l10n.noSubject)
                            .font(.callout)
                            .bold(!m.isRead)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(m.receivedAt.formatted(date: .omitted, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
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
                        if density.showsSnippet, let snippet = m.snippet {
                            Text(snippet)
                                .font(.caption2)
                                .lineLimit(2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
        }
        .padding(.vertical, 2)
        // The whole row is the click target. Without this only the text
        // glyphs were hit-testable, so the padding around a short subject
        // line did nothing.
        .contentShape(Rectangle())
    }

    // MARK: - Conversation grouping (会话归集)

    private struct ConversationSection: Identifiable {
        let bucket: DateBucket
        let conversations: [Conversation]
        var id: DateBucket { bucket }
    }

    /// Non-nil when the server held more rows than the response could carry.
    ///
    /// Measured against `messages`, never `displayMessages`: the unread-only
    /// filter is a client-side cut of the same payload, so comparing the total
    /// against it would claim truncation on a list that simply hid some rows.
    private var truncated: String? {
        guard let total = serverTotalCount, total > messages.count else { return nil }
        return l10n.listTruncated(messages.count, total)
    }

    /// Rows the current lens shows: the unread-only filter is the first cut.
    ///
    /// Reads `unreadOnlyEffective`, not the stored flag, so the sidebar's 未读
    /// destination and this filter are one control rather than two that can
    /// disagree.
    private var displayMessages: [MessageHeader] {
        unreadOnlyEffective ? messages.filter { !$0.isRead } : messages
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
                onDelete: { Task { await delete(newest) } },
                onTogglePin: { Task { await togglePin(newest) } },
                lens: lens ?? .all,
                onRestore: { Task { await restoreFromTrash(newest) } },
                onUnarchive: { Task { await unarchive(newest) } },
                onPurge: { pendingPurge = newest }
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
                            onDelete: { Task { await delete(m) } },
                            onTogglePin: { Task { await togglePin(m) } },
                            lens: lens ?? .all,
                            onRestore: { Task { await restoreFromTrash(m) } },
                            onUnarchive: { Task { await unarchive(m) } },
                            onPurge: { pendingPurge = m }
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
                removeRows(matching: m.remoteId)
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
        // No `prefix(1)` fallback: with nothing highlighted, ⌫ used to
        // silently archive the first message in the list. The undo toast is a
        // safety net, not a licence to guess — every mutation has to be one
        // the user actually aimed at.
        guard !selection.isEmpty else { return }
        let ids = selection
        let targets = messages.filter { ids.contains($0.remoteId) }
        selection.removeAll()
        for m in targets {
            Task { await archive(m) }
        }
    }

    /// The verbs behind the bulk bar's mark-read buttons.
    ///
    /// Read state is a **remote write** (`\Seen` on the IMAP server), so unlike
    /// a local filter it cannot be waved away by clearing the selection. Each
    /// message therefore gets its own request and its own failure, and a row
    /// that failed stays in the list with the error surfaced rather than
    /// vanishing — silently dropping one of eight would tell the user all eight
    /// succeeded.
    private func markSelected(isRead: Bool) {
        guard !selection.isEmpty else { return }
        let ids = selection
        let targets = messages.filter { ids.contains($0.remoteId) }
        selection.removeAll()
        for m in targets {
            Task {
                do {
                    _ = try await api.markRead(
                        remoteId: m.remoteId, accountId: m.accountId, isRead: isRead
                    )
                    setRead(remoteId: m.remoteId, isRead: isRead)
                } catch {
                    errorBanner = ErrorBanner(
                        severity: .error,
                        title: l10n.markReadFailedTitle,
                        detail: error.lagoonUIMessage
                    )
                }
            }
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

    /// Pin/unpin a row, optimistically with revert — the same shape as
    /// `toggleRead`, for the same reason: both write remotely and both are
    /// undoable, so the user gets the undo toast either way.
    private func togglePin(_ m: MessageHeader) async {
        let target = !m.isPinned
        invalidatePendingRefresh()
        applyPin(m, target)
        do {
            let actionId = try await api.setPinned(
                remoteId: m.remoteId, accountId: m.accountId, pinned: target
            )
            if let actionId {
                undo.show(UndoItem(
                    id: actionId,
                    message: target ? l10n.pinnedToast : l10n.unpinnedToast,
                    systemImage: target ? "pin.fill" : "pin.slash"
                ))
            }
        } catch {
            applyPin(m, m.isPinned)
        }
    }

    private func applyPin(_ m: MessageHeader, _ pinned: Bool) {
        guard let index = messages.firstIndex(where: { $0.remoteId == m.remoteId }) else { return }
        messages[index] = messages[index].withPinned(pinned)
    }

    /// 取消归档：把邮件移回收件箱，并从当前（档案柜）列表里移除。
    ///
    /// The row leaves the list because the user just took it *out* of the place
    /// the list is showing — keeping it would mean the 档案柜 still displays a
    /// message that is now in the inbox, and the next poll would remove it
    /// anyway, making the row flicker.
    private func unarchive(_ m: MessageHeader) async {
        invalidatePendingRefresh()
        let remoteId = m.remoteId
        removeRow(id: remoteId)
        do {
            let response = try await api.unarchiveMessage(
                remoteId: remoteId, accountId: m.accountId
            )
            let actionId = response.actionId
            undo.show(UndoItem(
                id: actionId,
                message: l10n.movedToInboxToast,
                systemImage: "tray"
            ))
        } catch {
            // Put the row back: the remote MOVE failed, so the message is still
            // archived and the list must keep saying so.
            insertBack(m)
            errorBanner = ErrorBanner(
                severity: .error,
                title: l10n.unarchiveFailedTitle,
                detail: error.lagoonUIMessage,
                actionLabel: l10n.retry,
                action: { Task { await unarchive(m) } }
            )
        }
    }

    /// 从废纸篓恢复。与取消归档同一套：先移出列表，失败则放回去。
    private func restoreFromTrash(_ m: MessageHeader) async {
        invalidatePendingRefresh()
        let remoteId = m.remoteId
        removeRow(id: remoteId)
        do {
            let response = try await api.restoreMessage(
                remoteId: remoteId, accountId: m.accountId
            )
            let actionId = response.actionId
            undo.show(UndoItem(
                id: actionId,
                message: l10n.restoredToast,
                systemImage: "arrow.uturn.backward"
            ))
        } catch {
            insertBack(m)
            errorBanner = ErrorBanner(
                severity: .error,
                title: l10n.restoreFailedTitle,
                detail: error.lagoonUIMessage,
                actionLabel: l10n.retry,
                action: { Task { await restoreFromTrash(m) } }
            )
        }
    }

    /// The one way a row leaves the list, so `serverTotalCount` moves with it.
    ///
    /// Without this, unarchiving or restoring one message leaves the total
    /// where it was and the truncation notice keeps claiming the list is capped
    /// when it no longer is — the same class of bug the 档案柜 notice was added
    /// to fix, in the other direction.
    private func removeRow(id remoteId: String) {
        // Retires the in-flight poll here rather than at the call sites: every
        // caller does need it, and `RefreshGateTests` requires the invalidation
        // to be adjacent to the mutation it protects. Doing it inside the one
        // helper is also the only way it cannot be forgotten by the next caller.
        invalidatePendingRefresh()
        let removed = messages.filter { $0.remoteId == remoteId }.count
        guard removed > 0 else { return }
        messages.removeAll { $0.remoteId == remoteId }
        selection.remove(remoteId)
        if let total = serverTotalCount {
            serverTotalCount = max(0, total - removed)
        }
    }

    /// 彻底删除 one message, after the confirmation alert.
    ///
    /// No undo toast afterwards, and that asymmetry with every other verb in
    /// this file is the point: showing one here would be a lie about what the
    /// user can get back.
    private func purge(_ m: MessageHeader) async {
        pendingPurge = nil
        isPurging = true
        defer { isPurging = false }
        let remoteId = m.remoteId
        do {
            _ = try await api.permanentlyDelete(
                remoteId: remoteId, accountId: m.accountId
            )
            // Removed only after the server confirms. On failure the row stays
            // put, because it *is* still there — a permanent delete that failed
            // must not look like it succeeded.
            removeRow(id: remoteId)
            ErrorCenter.shared.report(.init(
                severity: .info,
                title: l10n.purgeForever,
                autoDismissAfter: .seconds(3)
            ))
        } catch {
            errorBanner = ErrorBanner(
                severity: .error,
                title: l10n.purgeFailedTitle,
                detail: error.lagoonUIMessage
            )
        }
    }

    /// 清空废纸篓, after the confirmation alert.
    private func emptyTrashNow() async {
        guard let accountId = accounts.accountId else { return }
        confirmEmptyTrash = false
        isEmptyingTrash = true
        defer { isEmptyingTrash = false }
        do {
            let response = try await api.emptyTrash(accountId: accountId)
            messages.removeAll()
            selection.removeAll()
            serverTotalCount = nil
            // The count is reported, not toasted away: "permanently deleted 12
            // messages" is the only receipt an irreversible action gets.
            ErrorCenter.shared.report(.init(
                severity: .info,
                title: l10n.emptyTrashDone(response.purged),
                autoDismissAfter: .seconds(4)
            ))
        } catch {
            errorBanner = ErrorBanner(
                severity: .error,
                title: l10n.purgeFailedTitle,
                detail: error.lagoonUIMessage
            )
        }
    }

    /// Puts a just-removed row back at its original position.
    ///
    /// Position, not append: the user is looking at a list and a row that jumps
    /// to the bottom reads as "a different mail reappeared".
    ///
    /// Retires the in-flight poll for the same reason `removeRow`'s callers do —
    /// this *is* a list mutation, and a poll that started before the failed
    /// restore would otherwise write the pre-restore snapshot back over it.
    /// `RefreshGateTests` asserts every direct mutation is preceded by an
    /// invalidate, and that guard is right: a restored row that silently
    /// disappears again on the next tick looks like the app losing mail.
    private func insertBack(_ m: MessageHeader) {
        invalidatePendingRefresh()
        guard !messages.contains(where: { $0.remoteId == m.remoteId }) else { return }
        // Position by received-at descending, which is the list's own order:
        // inserting at the old index would be wrong after earlier rows were
        // also removed, and appending would send the mail to the bottom of a
        // newest-first list.
        let newer = messages.filter { $0.receivedAt > m.receivedAt }.count
        messages.insert(m, at: min(newer, messages.count))
        if let total = serverTotalCount { serverTotalCount = total + 1 }
    }

    /// 删除 = 移入服务器废纸篓（provider.trash），可 ⌘Z 撤销（restore）。
    /// 本地行为与归档一致：行立刻离开列表，toast 承接撤销入口。
    private func delete(_ m: MessageHeader) async {
        invalidatePendingRefresh()
        do {
            let response = try await api.deleteMessage(remoteId: m.remoteId, accountId: m.accountId)
            withAnimation(.snappy) {
                removeRows(matching: m.remoteId)
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
        // Same rule as `archiveSelected`: an empty selection does nothing.
        guard !selection.isEmpty else { return }
        // Stage two hands the whole job to the server in **one** request. The
        // per-message loop below is the stage-one path and is deliberately not
        // used here: firing 3,000 single deletes would take minutes and would
        // be impossible to cancel or report on.
        if selectedAllOnServer {
            Task { await deleteAllMatching() }
            return
        }
        let ids = selection
        let targets = messages.filter { ids.contains($0.remoteId) }
        selection.removeAll()
        for m in targets {
            Task { await delete(m) }
        }
    }

    /// 阶段二：删除筛选条件下的**全部**邮件，由服务端解析。
    ///
    /// The request carries the lens, not a list of ids, because the ids for the
    /// unloaded rows were never sent to this side. That is the whole reason this
    /// is a query rather than a longer array — and the reason the server
    /// resolves it through the same filter the list uses.
    private func deleteAllMatching() async {
        guard let accountId = accounts.accountId else { return }
        isBulkBusy = true
        defer { isBulkBusy = false }
        do {
            let response = try await api.deleteBulk(
                DeleteBulkRequest(allMatchingIn: lensScope), accountId: accountId
            )
            // Whatever came back as ok is gone; whatever came back as failed is
            // still here. Reporting the split is the point — a bulk bar that
            // says "done" while 30 of 200 failed teaches people to distrust it.
            let failedIds = Set(response.items.filter { !$0.ok }.map(\.remoteId))
            let succeeded = response.items.filter(\.ok).count
            // Invalidate *before* the mutation, not after: the guard in
            // `RefreshGateTests` requires the retirement to be adjacent to the
            // write it protects, and a poll that started before this sweep would
            // otherwise restore the pre-sweep list and bring every deleted row
            // back.
            invalidatePendingRefresh()
            withAnimation(.snappy) {
                messages.removeAll { !failedIds.contains($0.remoteId) }
            }
            selection.removeAll()
            selectedAllOnServer = false
            if let truncated = response.truncatedCount, truncated > 0 {
                ErrorCenter.shared.report(.init(
                    severity: .warning,
                    title: l10n.bulkDeleteTruncated(succeeded, truncated),
                    autoDismissAfter: .seconds(8)
                ))
            } else {
                ErrorCenter.shared.report(.init(
                    severity: .info,
                    title: l10n.bulkDeletedToast(succeeded),
                    autoDismissAfter: .seconds(4)
                ))
            }
        } catch {
            selection.removeAll()
            selectedAllOnServer = false
            errorBanner = ErrorBanner(
                severity: .error,
                title: l10n.loadFailed,
                detail: error.lagoonUIMessage
            )
        }
    }

    /// 阶段一 → 阶段二：把选择扩展到服务器上的全部。
    private func selectAllOnServer() {
        withAnimation(.snappy) {
            selection = Set(messages.map(\.remoteId))
            selectedAllOnServer = true
        }
    }

    /// The hover card, anchored bottom-trailing so it never covers the row the
    /// pointer is on.
    ///
    /// Rendered in the list's overlay rather than as a `.popover` on each row:
    /// one card, driven by one piece of state, instead of N anchors fighting
    /// over screen edges.
    @ViewBuilder
    private var hoverCard: some View {
        if let hoveredRemoteId,
           let message = messages.first(where: { $0.remoteId == hoveredRemoteId }) {
            RowHoverPreview(message: message, advice: nil)
                .padding(12)
                // No animation on the card itself: it appears only after the
                // deliberate rest, and fading it in would blur the text the
                // user is trying to read.
                .allowsHitTesting(false)
        }
    }

    /// Wraps a row so the pointer can rest on it.
    ///
    /// `allowsHitTesting(false)` on the *tracker* would break selection, so the
    /// tracker stays interactive; the card above is the part that ignores the
    /// mouse.
    private func hoverTracked<Content: View>(_ remoteId: String, @ViewBuilder content: () -> Content) -> some View {
        content()
            .onHover { inside in hover(inside ? remoteId : nil) }
    }

    // MARK: - Keyboard navigation

    /// The tag of every row on screen, in on-screen order. A collapsed
    /// conversation contributes only its newest message (that is the single
    /// row rendered, and `RowChrome` tags it with that id); an expanded one
    /// contributes the header plus each member, and the header shares the
    /// newest member's tag, so duplicates collapse here.
    private var visibleRowTags: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for section in groupedSections {
            for conversation in section.conversations {
                let isExpanded = conversation.messages.count > 1
                    && expandedThreads.contains(conversation.threadId)
                let ids = isExpanded
                    ? conversation.messages.map(\.remoteId)
                    : [conversation.newest.remoteId]
                for id in ids where seen.insert(id).inserted {
                    ordered.append(id)
                }
            }
        }
        return ordered
    }

    /// j/k walk one row at a time. `selection` is a Set because the list is
    /// multi-select, so the walk starts from the first selected row in
    /// screen order; with nothing selected the first press lands on the
    /// first (down) or last (up) row rather than skipping one.
    private func moveSelection(direction: MoveCommandDirection) {
        let tags = visibleRowTags
        guard !tags.isEmpty else { return }
        guard let current = tags.firstIndex(where: { selection.contains($0) }) else {
            select(tags[direction == .up ? tags.count - 1 : 0])
            return
        }
        switch direction {
        case .up: select(tags[max(0, current - 1)])
        case .down: select(tags[min(tags.count - 1, current + 1)])
        case .left, .right: return
        @unknown default: return
        }
    }

    /// One place owns "highlight this row and reveal it". `List` selection on
    /// macOS does not reliably scroll the new selection into view, so the
    /// walk would move an invisible highlight off the bottom of the window —
    /// which is exactly the silent-degradation shape this project keeps
    /// getting bitten by.
    private func select(_ remoteId: String) {
        selection = [remoteId]
        withAnimation { scrollProxy?.scrollTo(remoteId, anchor: .center) }
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

    /// Opens the sender-rule editor for one address, pre-filled.
    ///
    /// The seam between the 发件人排行 panel and the aggregation feature: the
    /// panel finds the sender worth filing, this turns that into a rule through
    /// the same editor a row's context menu uses. Neither invents a second way
    /// to create a rule, so both produce identical rules.
    func fileSender(_ sender: SenderSummary) {
        stackEditor = StackEditorRequest(
            kind: .sender,
            value: sender.address,
            name: sender.displayName ?? sender.address
        )
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
    /// Pin/unpin. The Briefing feed's menu has offered this all along; the raw
    /// list did not, so muscle memory built on the primary surface did not
    /// carry over. Same verb, same route, same undoable audit row.
    let onTogglePin: () -> Void
    /// Where this row currently lives. The menu is different in each place:
    /// a message in the Trash has no "archive", and a message in the 档案柜 has
    /// no reason to offer delete as the *primary* verb.
    let lens: MessageListView.Lens
    /// 恢复：废纸篓 → 收件箱.
    let onRestore: () -> Void
    /// 取消归档：档案柜 → 收件箱.
    let onUnarchive: () -> Void
    /// 彻底删除：不可撤销，调用方必须先弹确认.
    let onPurge: () -> Void
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
            // In the Trash the trailing swipe is *restore*, not archive. The
            // gesture a user reaches for is "get this out of the trash", and
            // swiping a trashed message into the archive would be nonsense.
            .swipeActions(edge: .trailing) {
                if lens.isTrash {
                    Button { onRestore() } label: {
                        Label(l10n.restoreFromTrash, systemImage: "arrow.uturn.backward")
                    }
                    .tint(.green)
                } else {
                    Button(role: .destructive) { onArchive() } label: {
                        Label(l10n.archived, systemImage: "tray.and.arrow.down")
                    }
                }
            }
    }

    private func chrome(_ content: Content) -> some View {
        content
            .tag(message.remoteId)
            // `scrollTo` resolves by `.id()`, not by `.tag()` — the j/k walk
            // needs this to bring the highlighted row on screen. BriefingFeedView
            // carries both for the same reason.
            .id(message.remoteId)
            .contextMenu {
                if lens.isTrash {
                    // The Trash menu is short on purpose: everything else in it
                    // is either already done (mark read) or nonsensical
                    // (archive something that is in the trash). Restore is the
                    // verb the user came here for, so it leads.
                    Button(l10n.restoreFromTrash) { onRestore() }
                    Divider()
                    // 彻底删除. Irreversible, and it is the only item on this
                    // menu that is — which is why it sits below a divider, uses
                    // the trash-slash icon, and opens a confirmation that names
                    // the message. A destructive-looking row is not enough when
                    // there is no undo behind it.
                    Button(l10n.purgeForever, role: .destructive) { onPurge() }
                } else if lens == .archived {
                    // 档案柜: the way back out is the first item, and delete
                    // stays available because "archive this by accident, then
                    // it turns out I do not want it at all" is a real path.
                    Button(l10n.unarchive) { onUnarchive() }
                    Button(readVerbTitle(message, l10n: l10n)) { onToggleRead() }
                    Button(message.isPinned ? l10n.unpin : l10n.pin) { onTogglePin() }
                    Divider()
                    Button(l10n.deleteContext, role: .destructive) { onDelete() }
                } else {
                    Button(readVerbTitle(message, l10n: l10n)) { onToggleRead() }
                    Button(message.isPinned ? l10n.unpin : l10n.pin) { onTogglePin() }
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
}

/// Identifiable wrapper so `.sheet(item:)` can present the sender view.
/// One sender's full mail history, presented by `SenderSheet`.
///
/// Internal rather than private because the 发件人排行 panel hands a sender to
/// the list from outside: the ranking knows *which* sender, and this is the
/// value the existing sheet already understands.
struct SenderFocus: Identifiable, Equatable {
    let address: String
    let name: String?
    init(from m: MessageHeader) {
        address = m.fromAddress
        name = m.fromName
    }
    init(from address: String, name: String?) {
        self.address = address
        self.name = name
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
