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
    /// The lookups the feed does on every redraw.
    ///
    /// The feed used to answer three questions by scanning the whole list:
    /// which items belong to a group, what the message behind a remote id is,
    /// and what the on-screen order is. On a 500-row feed that is several
    /// full passes *per body evaluation*, and the body re-runs on every
    /// hover, every selection change and every poll tick.
    ///
    /// Cached, and rebuilt only when the rows or the collapsed set change,
    /// so the cost is paid once per real change instead of once per redraw.
    @State private var index = FeedIndex()
    @State private var isLoading = false
    @State private var isMarkingAllRead = false
    @State private var errorBanner: ErrorBanner?
    @State private var collapsedGroups: Set<BriefingGroup> = Set(BriefingGroup.allCases.filter(\.collapsedByDefault))
    @State private var scrollProxy: ScrollViewProxy?
    /// 选中的邮件（remoteId 集合）。
    ///
    /// 集合而不是单个 id：简报要和「全部邮件」一样支持多选 + 批量操作。
    /// 一封一封归档 40 封就是 40 次远程 MOVE 往返，「10 分钟清零」这个承诺
    /// 在简报页兑现不了——而简报恰恰是用户打开得最多的那一页。
    @State private var selection: Set<String> = []
    /// 批量操作进行中。
    ///
    /// 每个动词都是一次远程往返（标已读/未读更是逐封一次），批量期间再点
    /// 一次会把同一批请求打两遍——对归档来说那是两倍的 MOVE，对删除来说
    /// 是同一封邮件被扔进废纸篓两次。
    @State private var isBulkBusy = false
    /// Pending suggestions keyed by the message they are about, so a row can
    /// render its own judgement without a lookup layer of its own.
    ///
    /// Loaded together with the feed rather than on demand: the whole point of
    /// putting advice on the row is that it is *already there* when the user
    /// arrives — a second round trip would flash the list without it.
    @State private var adviceByRemoteId: [String: AdviceRecord] = [:]
    /// Which suggestion is expanded. At most one, and it is a row-local concern
    /// that survives the feed re-sorting because it names a row id, not an index.
    @State private var expandedAdviceId: Int64?
    /// The suggestion whose dismissal is in flight, so only that row's button
    /// disables and a double-click cannot record two verdicts.
    @State private var busyAdviceId: Int64?
    /// The suggestion the user is turning into a reminder, and whether the
    /// reminder sheet is open.
    ///
    /// A `.remind` suggestion carries a deadline but sets nothing by
    /// itself. The user opens this sheet, picks the moment, and the
    /// reminder becomes real.
    @State private var reminderTarget: AdviceRecord?
    @State private var showReminderSheet = false
    /// The suggestion whose irreversible action is waiting for a yes.
    ///
    /// 「照做」 on an `.unsubscribe` suggestion sends a request to the
    /// publisher. That request cannot be taken back — the publisher has
    /// been told — so the tap opens a confirmation instead of firing
    /// immediately. The pending suggestion is held here so the dialog has
    /// something to act on when the user answers.
    @State private var pendingIrreversibleAccept: AdviceRecord?
    /// Row density, shared with the raw list through `UserDefaults`.
    @AppStorage(ListDensityPreference.key) private var densityRaw = ListDensity.compact.rawValue
    private var density: ListDensity {
        get { ListDensity(rawValue: densityRaw) ?? .compact }
        nonmutating set { densityRaw = newValue.rawValue }
    }
    /// Rows inside the 30-day window that did not fit under the server's cap.
    /// nil on the normal path; a non-nil value means the feed is a truncated
    /// view of the window and says so rather than looking complete.
    @State private var omittedCount: Int?
    /// How many messages are still waiting **outside** the feed's 30-day
    /// window.
    ///
    /// The window bounds the feed, but a mail does not stop needing a reply
    /// because it got old — so the server also carries the unread mail from
    /// before the window, and says how many there are in total. The rows
    /// themselves are already in the list (they land in "needs reply", where
    /// they belong); this number says how many are behind the ones on screen.
    @State private var backlogCount: Int?
    /// Stamped by every `refresh()` so a slow poll that started before the
    /// user archived a row cannot write the server's pre-archive snapshot
    /// back over the removal. Only the newest generation may commit.
    @State private var refreshGate = RefreshGate()
    /// The group editor, opened from a row's 「分组…」 menu.
    ///
    /// The Briefing is the product's front door, and grouping used to be
    /// reachable only from the raw list's row menu — so a user who never
    /// left the Briefing could never build a group, which is the one
    /// thing the Briefing is for.
    @State private var stackEditor: StackEditorRequest?
    /// False when another surface is showing (RootView keeps both alive).
    /// The poll loop sleeps instead of refreshing, and hidden shortcuts
    /// are disabled by the parent — keep-alive without traffic or hotkeys.
    var isVisible: Bool = true

    /// The window's shared column widths, handed down by `RootView`.
    ///
    /// Injected rather than created here so the navigation column beside this
    /// surface solves against the same numbers: one drag moves all three columns,
    /// and a surface switch does not reset the layout the user just set.
    let columnStore: ColumnWidthStore

    /// Whether the user has any groups of their own.
    ///
    /// Handed in by `RootView`, which already holds the rule list from
    /// `/api/stacks` for the sidebar. A second fetch here would be a second
    /// source for the same fact — and the two could disagree, which is how a
    /// note appears over a feed whose sidebar shows no groups.
    ///
    /// It gates the note that says who decides this feed's groups, so it
    /// lives next to the other RootView-injected dependency rather than
    /// down by the view that reads it.
    var hasUserGroups: Bool = false

    private let api = APIClient.shared
    private static let refreshInterval: Duration = .seconds(30)
    /// 批量标已读/未读时同时在途的请求数上限。
    ///
    /// 与「全部邮件」页的 `runBulk` 同一个数、同一段理由：每个动词都是
    /// 一次真实的远程写请求，而同一个服务器还要回答 30 秒一次的轮询和
    /// 别的界面的请求。八个足够把管道填满，再多只是把队列排得更长。
    private static let bulkConcurrency = 8
    /// Fast cadence while the feed is empty (fresh connect, backfill still
    /// landing), bounded like the list view's fast poll.
    private static let emptyPollInterval: Duration = .seconds(3)
    private static let maxFastEmptyTicks = 20
    @Environment(\.l10n) private var l10n
    /// Backgrounded windows idle instead of polling — see `sleepForPoll`.
    @Environment(\.scenePhase) private var scenePhase

    /// Same gate as the detail toolbar. Unknown (directory not loaded yet, or
    /// a version-skewed row) reads as allowed: the server is the authority and
    /// answers 409 archive-unavailable when the folder really is missing.
    private var canArchive: Bool {
        directory.active?.capabilities.allowsArchive ?? true
    }

    /// Whether 移到废纸篓 can be offered.
    ///
    /// Same reasoning as `canArchive`, applied to the trash role: an account
    /// whose server negotiated no trash folder cannot delete, and the server
    /// would answer 409. Unknown reads as allowed — the server is the
    /// authority, and a user locked out of delete by a cached guess has no
    /// way to appeal the guess.
    private var canDelete: Bool {
        directory.active?.capabilities.allowsDelete ?? true
    }

    var onShowAllMessages: () -> Void = {}

    /// Debug file log for the headless toolbar-crash repro — survives
    /// LaunchServices fd redirection, unlike stderr prints.
    ///
    /// DEBUG-only on purpose: it writes message remoteIds and window sizes,
    /// which is not something a shipping binary should put in a
    /// world-readable file just because the *call sites* are env-gated.
    /// The file also lives in the app's temporary directory with 0600
    /// permissions, and the write is off the main actor — a synchronous
    /// `FileHandle` round trip on the main thread is a stutter waiting
    /// for a slow disk.
    #if DEBUG
    static func debugLog(_ message: String) {
        let path = NSTemporaryDirectory() + "lagoon-debug.log"
        let line = (message + "\n").data(using: .utf8) ?? Data()
        debugLogQueue.async {
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(
                    atPath: path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                )
            }
            guard let handle = FileHandle(forWritingAtPath: path) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        }
    }

    private static let debugLogQueue = DispatchQueue(
        label: "dev.lagoon.debug-log",
        qos: .utility
    )
    #endif

    /// The left column: header bar plus the classified feed.
    ///
    /// Split out of `body` on purpose — the surface used to be one giant
    /// SwiftUI expression, and this project has already shipped an
    /// "unable to type-check in reasonable time" regression from adding a
    /// single parameter to a chain that large.
    private var sidebar: some View {
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
                groupsNote
                content
            }
            .onAppear { scrollProxy = proxy }
        }
        .background {
            groupJumpShortcuts
            keyboardNavigationShortcuts
        }
    }

    /// The note that says who decides these groups — and that the sidebar's
    /// own groups are not one of the inputs.
    ///
    /// ## Why it is here, and only here
    ///
    /// This is the surface where the confusion *happens*: the user opens the
    /// Briefing, sees 需要回复 / 可归档, and compares them with the group
    /// they built yesterday, which is sitting in the sidebar with a live
    /// count and a different set of mail. The note answers that comparison
    /// where it is made.
    ///
    /// It renders only when the user actually **has** groups. A user who has
    /// never made one is not confused by two mechanisms — they have not seen
    /// the second one — and a permanent line about 「我的分组」 would be a
    /// sentence about a feature they do not use, on the surface they use
    /// every day.
    ///
    /// The wording says *Lagoon* decides, not *the AI*: the heuristic
    /// classifier decides when no model is configured, and it decides for
    /// anything the model has not been asked about. "由 AI 判定" would be a
    /// promise the product does not keep.
    @ViewBuilder
    private var groupsNote: some View {
        if hasUserGroups {
            Text(l10n.briefingGroupsNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
        }
    }

    var body: some View {
        // Selection drives the reading pane; nothing is pushed any more. The
        // `NavigationStack(path:)` this replaced replaced the whole window with
        // the message, so triage meant committing to one row at a time and
        // pressing back to see the list again. The split keeps both on screen.
        //
        // `MessageSplitLayout` carries the `.toolbar(removing: .sidebarToggle)`
        // the split view would otherwise leak into the window toolbar, where
        // RootView's ZStack shows it twice (see that file's doc comment).
        MessageSplitLayout(store: columnStore, detailId: readerId, multiSelectionCount: multiSelectionCount) {
            sidebar
        } detail: {
            if let remoteId = readerId {
                destination(for: remoteId)
            }
        }
        .frame(minHeight: ColumnLayoutMetrics.windowMinimumHeight)
        // 批量操作条。和「全部邮件」页用同一个组件、挂在同一个位置（底部
        // 安全区），因为它们是同一个邮箱的两个视图——同一个动词、同一个
        // 快捷键、同一块地方，用户不该在两个界面之间重新学一遍。
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if bulkSelectionCount != nil {
                BulkActionBar(
                    count: bulkSelectionCount ?? 0,
                    onArchive: { archiveSelected() },
                    onDelete: { deleteSelected() },
                    onMarkRead: { markSelected(isRead: true) },
                    onMarkUnread: { markSelected(isRead: false) },
                    onClear: {
                        withAnimation(.snappy) {
                            selection.removeAll()
                        }
                    },
                    // 归档按钮的可用性和单行归档完全一致：服务器没有协商出
                    // 归档文件夹时，批量条不能提供一个服务器会拒绝的动词。
                    canArchive: canArchive,
                    canDelete: canDelete,
                    isBusy: isBulkBusy
                )
            }
        }
        .animation(.snappy, value: bulkSelectionCount)
        .onAppear {
            // Debug hook: LAGOON_OPEN_MESSAGE=<remoteId> opens a message at
            // launch by selecting it. In the split layout this just moves the
            // reader pane — there is no longer a push to seed, and the toolbar
            // swap the old torture mode chased no longer happens (see
            // .memory/lagoon-app-nscalendardate-toolbar-crash: the fix was to
            // take the detail actions off the window toolbar entirely).
            let seed = ProcessInfo.processInfo.environment["LAGOON_OPEN_MESSAGE"]
            #if DEBUG
            if seed != nil {
                BriefingFeedView.debugLog("onAppear seed=\(seed ?? "nil")")
            }
            #endif
            if let remoteId = seed, !remoteId.isEmpty {
                // Delayed so the first feed refresh has landed and the row
                // exists to select.
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    self.selection = [remoteId]
                    #if DEBUG
                    BriefingFeedView.debugLog("seeded selection \(remoteId)")
                    #endif
                }
            }
        }
        .task {
            await refresh()
            await poll()
        }
        .onReceive(NotificationCenter.default.publisher(for: .lagoonDidUndo)) { _ in
            Task { await refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lagoonDidChangeData)) { _ in
            Task { await refresh() }
        }
        .sheet(isPresented: $showReminderSheet) {
            if let target = reminderTarget {
                ReminderSheet(
                    accountId: accounts.accountId ?? UUID(),
                    remoteId: target.remoteId,
                    subject: target.advice.dueText,
                    dueText: target.advice.dueText
                ) { reminder in
                    // The confirmation names the time the user actually
                    // chose. It used to name `Date()` — the moment the
                    // sheet closed — so a reminder set for next Monday
                    // was confirmed as "remind me at 19:53 today". A
                    // confirmation that states the wrong time is worse
                    // than no confirmation, because the user believes it.
                    errorBanner = ErrorBanner(
                        severity: .success,
                        title: l10n.reminderTitle,
                        detail: l10n.reminderSetConfirmation(reminder.dueAt)
                    )
                }
            }
        }
        // The irreversible-action confirmation. A 「照做」 on an
        // unsubscribe suggestion lands here instead of firing, because the
        // request cannot be taken back once the publisher has it.
        .confirmationDialog(
            l10n.adviceAcceptConfirmTitle,
            isPresented: Binding(
                get: { pendingIrreversibleAccept != nil },
                set: { if !$0 { pendingIrreversibleAccept = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(l10n.adviceAcceptConfirmAction, role: .destructive) {
                Task { await confirmIrreversibleAccept() }
            }
            Button(l10n.adviceAcceptConfirmCancel, role: .cancel) {
                pendingIrreversibleAccept = nil
            }
        } message: {
            Text(l10n.adviceAcceptConfirmBody)
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
        // The advice panel asks the feed to reveal a message. The feed owns
        // its selection, so it does the revealing; the switch to the Briefing
        // surface belongs to RootView, which listens for the same notification.
        .onReceive(NotificationCenter.default.publisher(for: .lagoonRevealMessage)) { note in
            guard let remoteId = note.userInfo?["remoteId"] as? String else { return }
            // `reveal` refreshes first when the message is not in the current
            // snapshot, and `onReceive` hands us a synchronous closure.
            Task { await reveal(remoteId) }
        }
    }

    private func poll() async {
        var emptyTicks = 0
        while !Task.isCancelled {
            let fast = items.isEmpty && emptyTicks < Self.maxFastEmptyTicks
            emptyTicks = items.isEmpty ? emptyTicks + 1 : 0
            guard await sleepForPoll(
                fast ? Self.emptyPollInterval : Self.refreshInterval
            ) else { return }
            // The old `path.isEmpty` gate stopped the feed refreshing while a
            // message was pushed, so a poll could not reorder the list
            // underneath the reader. In the split layout the reader is keyed on
            // `selection`, not on list order, so the list can stay live;
            // `readerId` retracts the pane if a refresh drops the selected row.
            if shouldPoll(isVisible: isVisible, scenePhase: scenePhase) {
                await refresh()
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            Text(l10n.briefing)
                .font(.headline)
                // Same reason as the raw list's title: a surface heading that
                // wraps one glyph per line is noise, and the list surface proved
                // it happens under real width pressure. This row has a Spacer so
                // it is not currently squeezed, but the cost of `fixedSize` is
                // zero and the cost of the bug is a broken-looking toolbar.
                .fixedSize()
                .layoutPriority(1)
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
            // No ⌘0 here: the menu bar owns it (View → 切换主界面). A
            // surface-level ⌘0 *and* the menu's ⌘0 both fire on the same key
            // press, and the switch runs twice — which lands the user back
            // where they started.
            .help(l10n.showRawListHelp)
            // Refresh is ⌥⌘R so it never collides with ⌘R = reply on the
            // open message. The modifiers are disjoint, so both bindings stay
            // live at once.
            //
            // The shortcut itself lives on the menu bar's 邮件 → 刷新 item.
            // Two owners for one key is two answers for one key press:
            // whichever the system resolves to, the other is either dead
            // code that looks alive or a second refresh the user did not
            // ask for. The menu's version re-reads the list, the counts
            // and the account state, so the menu is where the key belongs.
            // Same reasoning as the ⌘0 above.
            refreshControl
        }
        .padding()
    }

    private var refreshControl: some View {
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
        .help(l10n.shortcutRefresh)
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
        List(selection: $selection) {
            ForEach(BriefingGroup.allCases) { group in
                let groupItems = index.byGroup[group] ?? []
                if !groupItems.isEmpty {
                    Section {
                        if !collapsedGroups.contains(group) {
                            ForEach(groupItems) { item in
                            // No `NavigationLink`: the row is selected, not
                            // pushed. `List(selection:)` writes the tap into
                            // `selection`, which drives the split view's
                            // reading pane. A link here would push inside the
                            // sidebar column's implicit stack and hide the list —
                            // the silent failure recorded in
                            // .memory/sheet-is-its-own-navigation-root.
                            BriefingRow(
                                item: item,
                                advice: adviceByRemoteId[item.message.remoteId],
                                density: density,
                                expandedAdviceId: $expandedAdviceId,
                                busyAdviceId: $busyAdviceId,
                                onOpenAdvice: { remoteId in
                                    Task { await reveal(remoteId) }
                                },
                                onDismissAdvice: { record in
                                    Task { await dismissAdvice(record) }
                                },
                                onSetReminder: { record in
                                    reminderTarget = record
                                    showReminderSheet = true
                                },
                                onAcceptAdvice: { record in
                                    Task { await acceptAdvice(record) }
                                }
                            )
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                // Leading swipe = archive (the destructive
                                // gesture Mail.app puts on the left).
                                Button { Task { await archiveAndUndo(item) } } label: {
                                    Label(l10n.archiveAction, systemImage: "tray.and.arrow.down")
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
                                // Slide the archived row off to the leading
                                // edge as it fades. Without `withAnimation`
                                // around the `items.removeAll` the transition
                                // never fires; the call sites below make sure
                                // every removal goes through this path.
                                .transition(.asymmetric(
                                    insertion: .opacity.combined(with: .move(edge: .trailing)),
                                    removal: .opacity.combined(with: .move(edge: .leading))
                                ))
                                // Mouse users have no swipe gesture; expose
                                // the same two verbs via right-click.
                                .contextMenu {
                                    Button(l10n.archiveAction) { Task { await archiveAndUndo(item) } }
                                        .disabled(!canArchive)
                                    Button(item.group == .pinned ? l10n.unpin : l10n.pin) {
                                        togglePin(item: item)
                                    }
                                    Button(readVerbTitle(item.message, l10n: l10n)) {
                                        Task { await toggleRead(item) }
                                    }
                                    // 「分组…」 — the same two rules the raw
                                    // list offers, so the Briefing is not a
                                    // place where you cannot organize mail.
                                    Menu(l10n.aggregateMenu) {
                                        Button(l10n.aggregateBySender) {
                                            openAggregateEditor(kind: .sender, for: item.message)
                                        }
                                        Button(l10n.aggregateByKeyword) {
                                            openAggregateEditor(kind: .keyword, for: item.message)
                                        }
                                    }
                                    if item.group == .subscriptionNoise {
                                        Divider()
                                        // 一键退订 lives with the noise rows:
                                        // messages carrying List-Unsubscribe
                                        // land in this group, and making the
                                        // user open the mail first defeats
                                        // "one-click". Terminal on the server.
                                        // It runs only because the user clicked
                                        // it — nothing here fires on its own.
                                        Button(l10n.unsubscribe, role: .destructive) {
                                            Task { await unsubscribeFrom(item) }
                                        }
                                    }
                                }
                            }
                        }
                    } header: {
                        groupHeader(group, count: groupItems.count)
                    }
                }
            }
            // Only present when the server truncated the window. Rendered as
            // a real row rather than an overlay so it scrolls with the feed
            // and cannot be mistaken for a transient toast — the user should
            // be able to find this statement again after dismissing it from
            // their attention.
            if let omittedCount {
                Section {
                    Label(l10n.briefingOmitted(omittedCount), systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(l10n.briefingOmitted(omittedCount))
                }
            }
            // Mail that is still waiting but is older than the feed's window.
            //
            // The rows themselves are already in the list — they land in
            // 「需要回复」, where they belong — so this line is not a list of
            // hidden mail. It is the *count*, because the rows are capped:
            // the feed carries the oldest fifty, and without a total the user
            // would see three old mails and conclude that three were all of
            // them.
            //
            // It is a real row rather than a toast, for the same reason the
            // omitted-count row is: the user has to be able to come back to
            // this statement after it has scrolled past.
            if let backlogCount, backlogCount > 0 {
                Section {
                    Label(l10n.briefingBacklog(backlogCount), systemImage: "clock.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(l10n.briefingBacklog(backlogCount))
                }
            }
        }
        .listStyle(.inset)
        // Shares the density preference with the raw list: they are two views
        // of one mailbox, and a user who packs one row wants the other packed
        // too. `compact` is the default there and here for the same reason.
        .listDensity(density)
        // Drive every list-row transition with the same easing curve so a
        // swipe-to-archive feels identical to a ⌫-to-archive. Spring with a
        // light damping reads as "the row slid into the tray" — closer to
        // Mail.app than the default easeInOut.
        //
        // The key is a revision counter, not the id array. The array was
        // rebuilt on every body evaluation — 500 pointer copies plus 500
        // string comparisons per redraw — to answer a yes/no question, and
        // the counter changes exactly when the set of rows on screen does,
        // which is the only thing the transition cares about.
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: index.revision)
        // ⌫ archives the selected row(s). With nothing selected it does
        // nothing — same rule as the raw list: the undo toast is a safety net,
        // not a licence to guess which mail the user meant.
        .onDeleteCommand { archiveSelected() }
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
                // Content transition on the count Text so a digit change
                // (3 → 2 after an archive) cross-fades instead of jumping.
                Text("\(count)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: Double(count)))
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
                    // Show a running count once the server has classified
                    // *anything* — a generic "syncing first time" leaves
                    // a 400-message mailbox waiting in silence. The count
                    // animates each refresh so the user sees the inbox
                    // filling up.
                    if items.isEmpty {
                        Text(l10n.syncingFirstTime)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(l10n.syncingFirstTimeCount(items.count))
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText(value: Double(items.count)))
                    }
                }
            } else {
                ContentUnavailableView {
                    Label(l10n.inboxZero, systemImage: "checkmark.seal")
                } description: {
                    Text(l10n.tapToSync)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }



    private var errorState: some View {
        ContentUnavailableView {
            Label(l10n.briefingUnavailable, systemImage: "exclamationmark.triangle")
        } description: {
            // The detail carries *what* went wrong; the title is a fixed
            // "简报加载失败：" string. Showing only the title left the panel
            // reading "简报加载失败：" with nothing after the colon — the
            // user was told the feed failed but not why.
            Text(errorBanner?.detail ?? errorBanner?.title ?? l10n.unknownError)
        } actions: {
            Button(l10n.retry) { Task { await refresh() } }
        }
    }



    // MARK: - Row index

    /// The one way the feed's rows change.
    ///
    /// Every mutation goes through here so the cached lookups can never
    /// disagree with the rows behind them. A second invalidation path (an
    /// `.onChange`, a version counter) is a path somebody eventually
    /// forgets, and a feed showing a row that is no longer there is exactly
    /// the kind of quiet lie this project keeps having to undo.
    private func setItems(_ updated: [BriefingItem]) {
        items = updated
        rebuildIndex()
    }

    /// The same, for an in-place change to the feed's rows.
    private func mutateItems(_ change: (inout [BriefingItem]) -> Void) {
        var updated = items
        change(&updated)
        setItems(updated)
    }

    /// Rebuilds the cached lookups of the feed.
    private func rebuildIndex() {
        var rebuilt = FeedIndex()
        // One pass to group the rows, instead of one scan per group: the
        // list renders five groups, so the old shape was five full passes
        // over the feed on every body evaluation.
        rebuilt.byGroup = Dictionary(grouping: items, by: \.group)
        rebuilt.byRemoteId = Dictionary(
            items.map { ($0.message.remoteId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        rebuilt.orderedIds = items.map(\.message.remoteId)
        rebuilt.visibleIds = items
            .filter { !collapsedGroups.contains($0.group) }
            .map(\.message.remoteId)
        // The animation key. A revision rather than the id array: the array
        // was rebuilt on every body evaluation to be compared. The revision
        // moves exactly when the *set* of rows changes — a read flip leaves
        // the set alone, and the old key did too, so the transitions behave
        // the same.
        rebuilt.revision = rebuilt.orderedIds == index.orderedIds
            ? index.revision
            : index.revision + 1
        index = rebuilt
    }

    /// The rows the user can reach, in feed order.
    ///
    /// A collapsed group is not reachable by j/k, so its rows are not in the
    /// walk. The order is the feed's own, not the rendered group order —
    /// the walk has always followed the feed.
    private var visibleIds: [String] { index.visibleIds }

    // MARK: - Selection / navigation



    /// j/k walk one row at a time.
    ///
    /// With nothing selected the walk starts at an end: "down" lands on the
    /// first row and "up" on the last. The old code computed the current
    /// position as `?? 0` and then moved *one more*, so the very first press
    /// of j skipped the first row and landed on the second — the feed and the
    /// raw list disagreed about what the first key press does, and the raw
    /// list's answer was the right one.
    ///
    /// The walk always lands on **one** row: a multi-selection replaced by
    /// whatever the key press pointed at. The alternative — keeping the old
    /// selection and adding the new one — would make j a "add to selection"
    /// gesture with no way to take a row back out, and the read pane would
    /// keep saying "已选 N 封" while the user is trying to walk the list.
    private func moveSelection(direction: MoveCommandDirection) {

        let tags = visibleIds

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

    /// One place owns "highlight this row and reveal it". The list's own
    /// selection does not reliably scroll the new selection into view, so the
    /// walk would move an invisible highlight off the bottom of the window.
    ///
    /// The selection is *replaced*, not extended: j/k is a cursor, and a
    /// cursor that accumulates would leave the read pane reporting a count
    /// the user never asked for.
    private func select(_ remoteId: String) {
        selection = [remoteId]
        withAnimation { scrollProxy?.scrollTo(remoteId, anchor: .center) }
    }



    private var groupJumpShortcuts: some View {

        VStack {

            ForEach(Array(BriefingGroup.allCases.enumerated()), id: \.element) { index, group in

                Button(l10n.groupTitle(group)) { jump(to: group) }

                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)

                    // `.background` is a sibling layer, so the `.disabled()`
                    // RootView applies to the surface never reaches here:
                    // without this gate the hidden Briefing still answered
                    // ⌘1–⌘5 on a feed the user cannot see.
                    .disabled(!isVisible)

            }

        }.frame(width: 0, height: 0).opacity(0).focusable(false).accessibilityHidden(true)

    }

    private var keyboardNavigationShortcuts: some View {
        VStack {
            Button(l10n.nextInGroup) { moveSelection(direction: .down) }
                .keyboardShortcut("j", modifiers: [])
                .disabled(!isVisible)
            Button(l10n.previousInGroup) { moveSelection(direction: .up) }
                .keyboardShortcut("k", modifiers: [])
                .disabled(!isVisible)
            // No ↩ binding: selection already previews in the reading pane,
            // so an explicit "open" step has nothing left to do. (The cheatsheet
            // `open` row goes with it — a documented key bound nowhere is a
            // ghost the ShortcutSheet tests fail on.)
            // ⌘[ keeps Mail.app's "back" muscle memory, re-pointed at the one
            // thing it can still mean here: deselect, returning the reader pane
            // to its placeholder. No-op with nothing selected.
            Button(l10n.back) {
                selection = []
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(!isVisible)
            // ⌘A 全选：**只选当前已加载的简报卡片**。
            //
            // 简报是服务端窗口（服务器一次最多回 500 条，超出的在
            // 「另有 N 封未纳入简报」那一行里说明），所以 ⌘A 不能等于
            // 「服务器上的全部」——那是「全部邮件」页第二段式全选才有的
            // 动作，简报页没有服务端窗口口径，不自己发明。
            //
            // 再按一次回到空选：⌘A 是「切换全选」，不是「升级范围」。
            Button(l10n.selectAll) {
                withAnimation(.snappy) {
                    selection = BriefingSelection.toggledAll(
                        selected: selection, loaded: loadedSelectionIds
                    )
                }
            }
            .keyboardShortcut("a", modifiers: .command)
            // `.background` 是兄弟图层，RootView 给整个界面加的 `.disabled()`
            // 到不了这里——没有这道门，隐藏的简报页仍然会响应 ⌘A，
            // 去改一个用户根本看不见的选择。
            .disabled(!isVisible)
            // ⌘⌫ 删除选中（移到服务器废纸篓），与 ⌫ = 归档对应。
            Button(l10n.moveToTrash) {
                deleteSelected()
            }
            .keyboardShortcut(.delete, modifiers: .command)
            // The shortcut is a verb too: it must be off for the same reason
            // the button is, or the user gets a 409 from a keystroke that
            // looked available.
            .disabled(!isVisible || !canDelete)
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



    /// The message the reading pane shows, or nil when the selection has gone
    /// stale.
    ///
    /// The selection is a *set* now, so this is the split-layout twin of
    /// `MessageListView.previewId`: exactly one selected row previews, and
    /// two or more preview nothing (the pane reports the count instead).
    ///
    /// The set can outlive the row: a poll that drops the selected message
    /// (archived from another client, or reclassified out of the window) would
    /// otherwise leave the pane rendering a detail view with no header — a
    /// blank reader that reads as a broken app. Guarding here retracts it to
    /// the placeholder instead.
    private var readerId: String? {
        BriefingSelection.readerId(selected: selection, valid: Set(items.map(\.message.remoteId)))
    }

    /// Non-nil when several rows are selected: the reading pane says how many
    /// instead of silently previewing one of them.
    ///
    /// The bulk verbs (⌫ / ⌘⌫) are about to act on every selected row, so
    /// showing one of them would describe the wrong scope — the classic shape
    /// of a bulk verb firing on mail the user never saw selected.
    private var multiSelectionCount: Int? {
        BriefingSelection.bulkCount(selected: selection)
    }

    // MARK: - Detail destination



    @ViewBuilder

    private func destination(for remoteId: String) -> some View {

        if let accountId = accounts.accountId {

            // The lookup the reader pane needs, answered from the cached
            // index instead of three scans of the feed. `visible` was
            // rebuilt from the whole list on every open of the pane.
            let item = index.byRemoteId[remoteId]

            let visible = visibleIds

            // The sibling list is addressed by `(accountId, remoteId)`, not
            // by the bare id: a `remoteId` is only unique *inside* one
            // mailbox (the provider falls back to `uid:<n>`, and IMAP UIDs
            // count per mailbox), so a list that could span mailboxes must
            // carry the pair. The feed's own selection stays on the bare id
            // — it only ever holds one mailbox's rows.
            let siblings = visible.contains(remoteId)
                ? visible.map { MessageRef(accountId: accountId, remoteId: $0) }
                : nil

            MessageDetailView(

                remoteId: remoteId,

                accountId: accountId,

                header: item?.message,

                initiallyPinned: item?.group == .pinned,

                initialGroup: item?.group,

                siblings: siblings,

                onArchived: { id, isArchived in

                    handleArchived(id: id, isArchived: isArchived)

                },

                onAdvanceTo: { next in selection = next.map { [$0.remoteId] } ?? [] },

                onDelete: { id in
                    dropItem(id)
                    selection = []
                },

                onReadStateChange: { id, isRead in

                    setRead(remoteId: id, isRead: isRead)

                },

                onPinnedChanged: { _ in

                    Task { await refresh() }

                },

                // The other surface's detail view is still mounted, so its
                // shortcuts would fire from a surface the user cannot see.
                isVisible: isVisible

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
        // Animate the section's height collapse so the rows below slide up
        // smoothly. Without `withAnimation` the section just snaps closed
        // and the rows beneath jump.
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            if collapsedGroups.contains(group) { collapsedGroups.remove(group) } else { collapsedGroups.insert(group) }
        }
        // The reachable rows changed with the collapsed set, so the cached
        // walk order has to follow — otherwise j/k would keep offering a row
        // the user can no longer see.
        rebuildIndex()
    }



    private func setRead(remoteId: String, isRead: Bool) {

        guard let position = items.firstIndex(where: { $0.message.remoteId == remoteId }) else { return }

        let item = items[position]

        mutateItems { rows in
            rows[position] = BriefingItem(

                // `MessageHeader.withRead` copies every other field. The
                // hand-rolled constructor this replaced silently dropped
                // `isPinned` (and the RFC threading headers), so flipping the
                // read dot on a pinned mail un-pinned it locally.
                message: item.message.withRead(isRead),

                group: item.group, reasonCode: item.reasonCode

            )
        }

    }



    /// The one way a row leaves the feed. Retiring the in-flight poll is
    /// not optional here: a poll that captured the feed before the archive
    /// lands afterwards and writes the row straight back.
    private func dropItem(_ remoteId: String) {

        refreshGate.invalidate()

        mutateItems { $0.removeAll { $0.message.remoteId == remoteId } }

    }

    private func handleArchived(id: String, isArchived: Bool) {

        dropItem(id)

        // The detail view archived the message — a user gesture like any
        // other. If the row carried a suggestion to archive it, the user
        // just agreed with the AI, and that agreement is the learning
        // signal. Best-effort, like every other acceptance write.
        Task { await recordAcceptedAdvice(remoteId: id, performed: .archive) }

    }



    /// 分组入口：sender 规则直接预填发件人；keyword 规则带主题建议词，
    /// 用户在编辑器里确认/修改后才落库。
    ///
    /// Mirrors the raw list's entry point exactly — two surfaces that
    /// offer the same rule with different prefills would train the user
    /// that one of them is broken.
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

    private func togglePin(item: BriefingItem) {

        guard let accountId = accounts.accountId else { return }

        let toPinned = item.group != .pinned

        Task {

            do {

                let actionId = try await api.setPinned(
                    remoteId: item.message.remoteId,
                    accountId: accountId,
                    pinned: toPinned
                )
                if let actionId {
                    undo.show(UndoItem(
                        id: actionId,
                        message: toPinned ? l10n.pinnedToast : l10n.unpinnedToast,
                        systemImage: "pin"
                    ))
                }

                await refresh()

            } catch {
                errorBanner = ErrorBanner(
                    severity: .error,
                    title: toPinned ? l10n.pinFailed : l10n.unpinFailed,
                    detail: toPinned ? l10n.pinFailedDetail : l10n.unpinFailedDetail,
                    actionLabel: l10n.retry,
                    action: { [self] in await self.togglePin(item: item) }
                )
            }

        }

    }



    /// Feed-level read/unread toggle (context menu). Same two-way wire
    /// as the list's `toggleRead`: optimistic flip, revert on failure.
    private func toggleRead(_ item: BriefingItem) async {
        guard let accountId = accounts.accountId else { return }
        let target = !item.message.isRead
        setRead(remoteId: item.message.remoteId, isRead: target)
        do {
            let actionId = try await api.markRead(
                remoteId: item.message.remoteId,
                accountId: accountId,
                isRead: target,
                record: true
            )
            if let actionId {
                undo.show(UndoItem(
                    id: actionId,
                    message: target ? l10n.markedAsReadToast : l10n.markedAsUnreadToast,
                    systemImage: "envelope.open"
                ))
            }
        } catch {
            setRead(remoteId: item.message.remoteId, isRead: !target)
            errorBanner = ErrorBanner(
                severity: .error,
                title: l10n.markReadFailedTitle,
                detail: l10n.markReadFailedDetail,
                actionLabel: l10n.retry,
                action: { [self] in await self.toggleRead(item) }
            )
        }
    }

    private func archiveAndUndo(_ item: BriefingItem) async {

        await archiveAndUndo(byId: item.message.remoteId)

    }

    /// One-click unsubscribe (一键退订) from the feed. The server resolves the
    /// List-Unsubscribe header / stored links / body scan, fires the request
    /// behind its SSRF guard, and archives the message on success — so the
    /// row leaves the feed the same way an archive row does. Terminal: the
    /// toast confirms without offering Undo.
    private func unsubscribeFrom(_ item: BriefingItem) async {
        guard let accountId = accounts.accountId else { return }
        invalidatePendingRefresh()
        do {
            let response = try await api.unsubscribeMessage(
                remoteId: item.message.remoteId,
                accountId: accountId
            )
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                mutateItems { $0.removeAll { $0.message.remoteId == item.message.remoteId } }
            }
            undo.show(UndoItem(
                id: response.actionId,
                message: "\(l10n.unsubscribed) · \(response.publisher)",
                systemImage: "minus.circle",
                undoable: false
            ))
            // The publisher has been told — that is irreversible — so the
            // only thing left to record is that the user agreed with the
            // suggestion. Best-effort, like every other acceptance write.
            await recordAcceptedAdvice(
                remoteId: item.message.remoteId, performed: .unsubscribe
            )
        } catch {
            // The request never completed, so nothing was unsubscribed and
            // the row is still here: the retry re-runs this same 退订.
            errorBanner = ErrorBanner(
                severity: .error,
                title: l10n.unsubscribeFailedTitle,
                detail: error.lagoonUIMessage,
                actionLabel: l10n.retry,
                action: { [self] in await self.unsubscribeFrom(item) }
            )
        }
    }



    private func archiveAndUndo(byId remoteId: String) async {
        invalidatePendingRefresh()
        guard canArchive else {
            errorBanner = ErrorBanner(
                severity: .error,
                title: l10n.archiveUnavailable,
                detail: l10n.archiveUnavailableDetail,
                // Retrying cannot fix this — the account negotiated no
                // archive-capable folder. Spec INV-5: a failure with no
                // retry gets a way out instead.
                helpURL: LagoonHelp.bannerMailto(
                    failure: l10n.archiveUnavailable,
                    detail: l10n.archiveUnavailableDetail,
                    l10n: l10n
                )
            )
            return
        }

        guard let accountId = accounts.accountId else { return }

        do {

            let response = try await api.archiveMessage(remoteId: remoteId, accountId: accountId)

            // Wrap the removal in `withAnimation` so the row's
            // `.transition(.move(edge: .leading))` actually fires. Without
            // it the row snaps out of existence — the visual is "poof",
            // not "filed".
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                mutateItems { $0.removeAll { $0.message.remoteId == remoteId } }
            }
            // Soft metallic "Tink" complements the slide-out — a confirmatory
            // tick at low volume (see `SoundEffects`).
            SoundEffects.archive()

            undo.show(UndoItem(
                id: response.actionId,
                message: l10n.archivedToast,
                systemImage: "tray.and.arrow.down"
            ))

            // The mail is filed; now record that the user *agreed* with the
            // suggestion, if this row carried one. Best-effort by design: the
            // archive already happened, so a failed preference write must not
            // fail it — but it is surfaced rather than swallowed.
            await recordAcceptedAdvice(remoteId: remoteId, performed: .archive)

        } catch APIError.badStatus(let code, _) where code == 409 {
            errorBanner = ErrorBanner(
                severity: .error,
                title: l10n.archiveUnavailable,
                detail: l10n.archiveUnavailableDetail,
                // The server refused for the same reason: no archive-capable
                // folder. Retrying cannot help, so the banner offers help.
                helpURL: LagoonHelp.bannerMailto(
                    failure: l10n.archiveUnavailable,
                    detail: l10n.archiveUnavailableDetail,
                    l10n: l10n
                )
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

    // MARK: - 批量操作（多选）

    /// 当前已加载、且在简报里的所有 remoteId。
    ///
    /// ⌘A 的第一阶段只选这里这些——**不是**「服务器上的全部」。
    ///
    /// 简报是服务端窗口：服务器一次最多回 500 条，超出的部分在
    /// 「另有 N 封未纳入简报」那一行里如实写着。简报页没有「服务器上的
    /// 全部」这个口径（服务端窗口还没做），所以这里也不自己发明一个：
    /// 用户看到的、能点得着的，就是全部。
    private var loadedSelectionIds: Set<String> {
        Set(items.map(\.message.remoteId))
    }

    /// 批量条该不该出现，以及它声称会作用到多少封。
    ///
    /// 两个以上才出现：单选时那一行自己的滑动操作和右键菜单已经给了全部
    /// 动词，一条只覆盖一行的批量条反而把列表挤窄了、什么也没多给。
    /// 阈值与「全部邮件」页一致（`BriefingSelection.bulkCount`）。
    private var bulkSelectionCount: Int? {
        BriefingSelection.bulkCount(selected: selection)
    }

    /// ⌫ / 批量条「归档选中」：把选中的邮件一次性归档。
    ///
    /// 走服务端的清扫接口（`/api/archive-bulk`），而不是逐封调用
    /// `/api/messages/{id}/archive`。理由有两个：
    ///
    /// 1. 40 封逐封归档是 40 次远程 MOVE 往返——「10 分钟清零」在简报页
    ///    就是兑现不了。
    /// 2. 清扫接口会**逐项回报**（每封的 ok / actionId），所以「哪几封成功
    ///    了、哪几封没动」是知道的，也才能只对成功的部分提供撤销。
    private func archiveSelected() {
        // 没有选中就什么都不做。撤销 toast 是安全网，不是替用户猜的许可：
        // 每一个改动都得是用户真的瞄准了的那一个。
        guard !selection.isEmpty else { return }
        // 一次清扫一个。第二轮点击会把同一批请求再打一遍。
        guard !isBulkBusy else { return }
        guard canArchive else {
            errorBanner = ErrorBanner(
                severity: .error,
                title: l10n.archiveUnavailable,
                detail: l10n.archiveUnavailableDetail,
                // 重试没用——这个账户压根没协商出可归档的文件夹。规范 INV-5：
                // 重试修不好的失败要给一条出路。
                helpURL: LagoonHelp.bannerMailto(
                    failure: l10n.archiveUnavailable,
                    detail: l10n.archiveUnavailableDetail,
                    l10n: l10n
                )
            )
            return
        }
        // 捕获当次的 id 集合。批量条一旦按下就清空选择，所以重试必须
        // 记得当次瞄准的是哪几封——重新读当前状态会打到别的邮件上。
        let ids = selection
        selection.removeAll()
        isBulkBusy = true
        Task { await archiveBulk(ids: ids) }
    }

    /// 批量归档的执行体。
    ///
    /// 重试走的是同一个方法，但**id 集合换成失败的那几封**——成功的已经
    /// 离开列表了，再跑一遍它们是无谓的第二次 MOVE；而「重试」这个词承诺
    /// 的是「把没做完的做完」。
    private func archiveBulk(ids: Set<String>) async {
        guard let accountId = accounts.accountId else { return }
        isBulkBusy = true
        defer { isBulkBusy = false }
        do {
            let response = try await api.archiveBulk(
                remoteIds: Array(ids), accountId: accountId
            )
            let ok = response.items.filter(\.ok)
            let failed = response.items.filter { !$0.ok }
            // 成功的先离开列表，失败的留着——这正是 banner 里承诺的
            // 「失败的邮件仍留在列表里」，也是「重试」按钮成立的前提。
            let archived = Set(ok.map(\.remoteId))
            invalidatePendingRefresh()
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                mutateItems { $0.removeAll { archived.contains($0.message.remoteId) } }
            }
            // 只对**成功**的那些提供撤销：失败的邮件根本没动，撤销它毫无意义。
            let actionIds = ok.compactMap(\.actionId)
            if let first = actionIds.first {
                undo.show(UndoItem(
                    id: first,
                    message: l10n.senderAllArchiveDone(ok.count),
                    systemImage: "tray.and.arrow.down",
                    extraIds: Array(actionIds.dropFirst())
                ))
            }
            SoundEffects.archive()
            // 部分失败要说清楚：哪几封成功了、哪几封没动、没动的为什么。
            if !failed.isEmpty {
                errorBanner = ErrorBanner(
                    severity: .warning,
                    title: l10n.senderBulkPartial,
                    // 失败原因 + 现在的状态。裸错误串（「网络连接失败」）说了
                    // 出了什么错，但没说失败的邮件现在在哪儿——而重试按钮
                    // 只在用户知道它会重跑哪些的时候才算诚实。
                    detail: l10n.senderBulkPartialDetail(bulkFailureReason(failed)),
                    // 重试是真的：成功的那些已经离开列表了，重跑剩下的那几封
                    // 覆盖到的正是失败的那几封。规范 INV-4。
                    actionLabel: l10n.retry,
                    action: { [self] in
                        await self.archiveBulk(ids: Set(failed.map(\.remoteId)))
                    }
                )
            } else if let truncated = response.truncatedCount, truncated > 0 {
                // 服务器一次最多处理 500 封，超出的没被尝试过。这一条必须
                // 说出来——「已归档 500 封」而用户以为全部搞定了，就是
                // 「看起来完成了、其实缺了一块」。
                errorBanner = ErrorBanner(
                    severity: .warning,
                    title: l10n.senderBulkPartial,
                    detail: l10n.senderTruncatedDetail(truncated),
                    actionLabel: l10n.retry,
                    action: { [self] in await self.archiveBulk(ids: ids) }
                )
            } else if errorBanner?.title == l10n.senderBulkPartial {
                // 这次全过了：上一轮的「部分失败」横幅否则会一直要求用户
                // 再点一次一个已经不存在的批次。
                errorBanner = nil
            }
        } catch APIError.badStatus(let code, _) where code == 409 {
            // 账户没有可归档的文件夹，服务器拒绝每一次归档。重试没有用，
            // 所以横幅给一条出路而不是一个没用的按钮。规范 INV-5。
            errorBanner = ErrorBanner(
                severity: .error,
                title: l10n.archiveUnavailable,
                detail: l10n.archiveUnavailableDetail,
                helpURL: LagoonHelp.bannerMailto(
                    failure: l10n.archiveUnavailable,
                    detail: l10n.archiveUnavailableDetail,
                    l10n: l10n
                )
            )
        } catch {
            errorBanner = ErrorBanner(
                severity: .error,
                title: l10n.archiveFailed,
                detail: error.lagoonUIMessage,
                // 整批没动，重跑同一批就是全部的修复。规范 INV-4。
                actionLabel: l10n.retry,
                action: { [self] in await self.archiveBulk(ids: ids) }
            )
        }
    }

    /// ⌘⌫ / 批量条「删除选中」：把选中的邮件移到服务器废纸篓。
    ///
    /// 走 `/api/delete-bulk` 的**显式 id 列表**形态——不是「服务器上的
    /// 全部」。简报页没有服务端窗口口径，所以只处理用户选中的那几封。
    private func deleteSelected() {
        guard !selection.isEmpty else { return }
        guard !isBulkBusy else { return }
        let ids = selection
        selection.removeAll()
        isBulkBusy = true
        Task { await deleteBulk(ids: ids) }
    }

    /// 批量删除的执行体。重试走的是同一个方法、同一批 id。
    private func deleteBulk(ids: Set<String>) async {
        guard let accountId = accounts.accountId else { return }
        isBulkBusy = true
        defer { isBulkBusy = false }
        do {
            let response = try await api.deleteBulk(
                DeleteBulkRequest(remoteIds: Array(ids)), accountId: accountId
            )
            let ok = response.items.filter(\.ok)
            let failed = response.items.filter { !$0.ok }
            let deleted = Set(ok.map(\.remoteId))
            invalidatePendingRefresh()
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                mutateItems { $0.removeAll { deleted.contains($0.message.remoteId) } }
            }
            let actionIds = ok.compactMap(\.actionId)
            if let first = actionIds.first {
                undo.show(UndoItem(
                    id: first,
                    message: l10n.bulkDeletedToast(ok.count),
                    systemImage: "trash",
                    extraIds: Array(actionIds.dropFirst())
                ))
            }
            if !failed.isEmpty {
                errorBanner = ErrorBanner(
                    severity: .warning,
                    title: l10n.senderBulkPartial,
                    detail: l10n.senderBulkPartialDetail(bulkFailureReason(failed)),
                    // 重试覆盖的是**失败的那几封**：成功的已经移进废纸篓了。
                    actionLabel: l10n.retry,
                    action: { [self] in
                        await self.deleteBulk(ids: Set(failed.map(\.remoteId)))
                    }
                )
            } else if let truncated = response.truncatedCount, truncated > 0 {
                errorBanner = ErrorBanner(
                    severity: .warning,
                    title: l10n.senderBulkPartial,
                    detail: l10n.senderTruncatedDetail(truncated),
                    actionLabel: l10n.retry,
                    action: { [self] in await self.deleteBulk(ids: ids) }
                )
            } else if errorBanner?.title == l10n.senderBulkPartial {
                errorBanner = nil
            }
        } catch {
            errorBanner = ErrorBanner(
                severity: .error,
                title: l10n.bulkDeleteFailed,
                detail: error.lagoonUIMessage,
                actionLabel: l10n.retry,
                action: { [self] in await self.deleteBulk(ids: ids) }
            )
        }
    }

    /// 批量条「标为已读 / 标为未读」。
    ///
    /// 已读状态是一次**远程写**（服务器上的 `\Seen`），所以不像本地筛选
    /// 那样可以「清掉选择就当没事发生」。每一封都有自己的请求、自己的失败：
    /// 默默丢掉八封里的一封，等于告诉用户八封全成功了。
    private func markSelected(isRead: Bool) {
        guard !selection.isEmpty else { return }
        guard !isBulkBusy else { return }
        let ids = selection
        selection.removeAll()
        isBulkBusy = true
        Task { await markBulk(ids: ids, isRead: isRead) }
    }

    /// 批量标已读/未读的执行体。逐封独立失败，重试重跑失败的那几封。
    ///
    /// 有并发上限（`bulkConcurrency`），和「全部邮件」页的 `runBulk` 一样：
    /// 每一个标已读都是一次真实的后端写请求，而同一个服务器还要回答 30 秒
    /// 一次的轮询和别的界面的请求——500 行同时打出去，就是把轮询堵在后面。
    private func markBulk(ids: Set<String>, isRead: Bool) async {
        guard let accountId = accounts.accountId else { return }
        isBulkBusy = true
        defer { isBulkBusy = false }
        var failed: [String] = []
        var firstError: Error?
        var actionIds: [Int64] = []
        var succeeded: [String] = []
        let targets = Array(ids)
        let api = self.api
        await withTaskGroup(of: (String, Result<Int64?, Error>).self) { group in
            var next = 0
            // 先把窗口填满，再保持满：一个完成放行一个。
            while next < min(Self.bulkConcurrency, targets.count) {
                let remoteId = targets[next]
                next += 1
                group.addTask { @MainActor in
                    await Self.markOne(
                        api: api, remoteId: remoteId, accountId: accountId, isRead: isRead
                    )
                }
            }
            while let (remoteId, outcome) = await group.next() {
                switch outcome {
                case .success(let actionId):
                    succeeded.append(remoteId)
                    if let actionId { actionIds.append(actionId) }
                case .failure(let error):
                    failed.append(remoteId)
                    if firstError == nil { firstError = error }
                }
                guard next < targets.count else { continue }
                let remoteId = targets[next]
                next += 1
                group.addTask { @MainActor in
                    await Self.markOne(
                        api: api, remoteId: remoteId, accountId: accountId, isRead: isRead
                    )
                }
            }
        }
        // One mutation for the whole batch: flipping the rows one at a time
        // would rebuild the cached lookups once per row — a quadratic sweep
        // over a 500-row feed for a change the user sees in one frame. The
        // same reason `markAllRead` does it this way.
        let succeededSet = Set(succeeded)
        if !succeededSet.isEmpty {
            mutateItems { rows in
                for i in rows.indices where succeededSet.contains(rows[i].message.remoteId) {
                    rows[i] = rows[i].withRead(isRead)
                }
            }
        }
        if let first = actionIds.first {
            undo.show(UndoItem(
                id: first,
                message: isRead
                    ? l10n.markedAllReadToast(actionIds.count)
                    : l10n.markedAsUnreadToast,
                systemImage: "envelope.open",
                extraIds: Array(actionIds.dropFirst())
            ))
        }
        if let firstError {
            // The retry closure is `@Sendable`, so it may not capture the
            // mutable `failed` array. The snapshot is the *same* set — the
            // rows that failed and are still on screen — and taking it here
            // is what makes "Retry covers exactly those" true rather than
            // merely intended.
            let failedIds = Set(failed)
            errorBanner = ErrorBanner(
                severity: .warning,
                title: l10n.markAllReadPartial,
                // 原因 + 状态 + 重试范围。失败的那些**没有**改状态，仍留在
                // 列表里，所以重跑失败的那几封覆盖到的正是它们。
                detail: l10n.senderBulkPartialDetail(firstError.lagoonUIMessage),
                actionLabel: l10n.retry,
                action: { [self] in
                    await self.markBulk(ids: failedIds, isRead: isRead)
                }
            )
        } else if errorBanner?.title == l10n.markAllReadPartial {
            errorBanner = nil
        }
    }

    /// 一次标已读/未读，一封一个结果。
    ///
    /// 失败不抛出去：抛出去就得在组外面逐个接，接不住的那一封就会被
    /// 悄悄吞掉——而「八封里有一封没标上」正是这个动词最需要说出口的事。
    ///
    /// 只发请求，不动本地状态：本地那一笔由调用方**一次性**写入，否则
    /// 每封一次 `mutateItems` 就是一次全量索引重建。
    @MainActor
    private static func markOne(
        api: APIClient, remoteId: String, accountId: UUID, isRead: Bool
    ) async -> (String, Result<Int64?, Error>) {
        do {
            // `record: true` 让服务器写下可撤销的审计行——批量标已读必须
            // 和单封一样能 ⌘Z 撤销。
            let actionId = try await api.markRead(
                remoteId: remoteId, accountId: accountId, isRead: isRead, record: true
            )
            return (remoteId, .success(actionId))
        } catch {
            return (remoteId, .failure(error))
        }
    }

    /// 把一批失败项的机器可读标签翻成一句人话。
    ///
    /// 服务器返回的是 `errorCode`（`unreachable`、`archive-unavailable` 之类），
    /// 直接显示给用户等于让人去猜内部标识。这里走 `SyncErrorReason` 的同一
    /// 套翻译——未知标签落到通用句子，而不是把原始标识漏到界面上。
    private func bulkFailureReason(_ failed: [ArchiveBulkItem]) -> String {
        guard let code = failed.compactMap(\.errorCode).first else {
            return l10n.reasonUnknown
        }
        return SyncErrorReason.sentence(for: code, l10n: l10n)
    }



    /// Retire any poll already in flight. Called by every local mutation of
    /// `items` (archive, unsubscribe, mark-all-read) so a response captured
    /// before that mutation cannot write the pre-mutation snapshot back over
    /// it — the row would visibly reappear.
    private func invalidatePendingRefresh() {
        refreshGate.invalidate()
    }

    /// Loads the pending suggestion queue and indexes it by message.
    ///
    /// Only `pending` rows are fetched: a dismissed suggestion must never come
    /// back (constitution §3 — that is what makes the queue trustworthy), and
    /// an accepted one has already been acted on. Only messages currently on
    /// screen are indexed, so the dictionary stays the size of the feed rather
    /// than the size of the mailbox.
    ///
    /// Failure is deliberately silent and non-fatal: no banner, no retry loop.
    /// The advice table is a derived convenience — losing it costs the user the
    /// suggestion, not any mail — and a red banner here would read as "your mail
    /// failed to load", which is both untrue and alarming.
    private func loadAdvice() async {
        guard let accountId = accounts.accountId else {
            adviceByRemoteId = [:]
            return
        }
        do {
            let records = try await api.fetchAdvice(accountId: accountId)
            let visible = Set(items.map(\.message.remoteId))
            adviceByRemoteId = Dictionary(
                uniqueKeysWithValues: records
                    .filter { visible.contains($0.remoteId) }
                    .map { ($0.remoteId, $0) }
            )
            // A row that disappeared must not keep the expanded body on screen.
            expandedAdviceId = expandedAdviceId.flatMap { id in
                adviceByRemoteId.values.contains { $0.id == id } ? id : nil
            }
        } catch {
            adviceByRemoteId = [:]
        }
    }

    /// Records a `dismissed` verdict for one suggestion.
    ///
    /// This is the *only* write the advice surface performs, and it writes the
    /// `advice` table only — no mailbox is touched, so it needs no undo entry
    /// (constitution §2 rule 6). The row drops its strip immediately on success
    /// because a dismissed suggestion must not be re-surfaced on the next poll.
    private func dismissAdvice(_ record: AdviceRecord) async {
        guard let accountId = accounts.accountId else { return }
        guard busyAdviceId == nil else { return }
        busyAdviceId = record.id
        defer { busyAdviceId = nil }
        do {
            _ = try await api.setAdviceDecision(
                id: record.id, decision: .dismissed, accountId: accountId
            )
            adviceByRemoteId.removeValue(forKey: record.remoteId)
            if expandedAdviceId == record.id { expandedAdviceId = nil }
        } catch {
            errorBanner = ErrorBanner(
                severity: .error,
                title: l10n.adviceDismissFailedTitle,
                detail: error.lagoonUIMessage,
                actionLabel: l10n.retry,
                action: { Task { await dismissAdvice(record) } }
            )
        }
    }

    /// Performs the action a suggestion advised, and records the acceptance.
    ///
    /// This is the whole learning loop in one place: the user's tap is the
    /// write trigger (constitution §2 rule 3), the action goes through the
    /// *same* user-triggered route the swipe gesture uses, and the fact that
    /// the user acted on the advice is what the server later reads back to
    /// sharpen the next suggestion.
    ///
    /// ## The two-stage shape
    ///
    /// An **irreversible** action (unsubscribe) does not fire on the tap.
    /// The tap parks the suggestion in `pendingIrreversibleAccept` and
    /// opens a confirmation that says what cannot be undone; the action
    /// runs only when the user answers yes. A reversible one (archive,
    /// delete — both are undoable through the trash) runs immediately,
    /// because a confirmation for something the user can take back is
    /// friction with no safety behind it.
    private func acceptAdvice(_ record: AdviceRecord) async {
        // The irreversible case stops here and waits for the answer.
        if record.advice.action.isIrreversible {
            pendingIrreversibleAccept = record
            return
        }
        await performAcceptedAdvice(record)
    }

    /// The second stage: the user answered the confirmation.
    private func confirmIrreversibleAccept() async {
        guard let record = pendingIrreversibleAccept else { return }
        pendingIrreversibleAccept = nil
        await performAcceptedAdvice(record)
    }

    /// Runs the advised action and records the acceptance.
    private func performAcceptedAdvice(_ record: AdviceRecord) async {
        guard let item = items.first(where: { $0.message.remoteId == record.remoteId })
        else { return }
        switch record.advice.action {
        case .archive:
            await archiveAndUndo(item)
        case .delete:
            await deleteOne(item)
        case .unsubscribe:
            await unsubscribeFrom(item)
        default:
            // Unreachable through the button (the row only offers the
            // mutating ones), but a silent no-op would be a lie if the
            // row's set and this switch ever drift apart.
            break
        }
    }

    /// Moves one message to the trash — the single-message form of the
    /// feed's bulk delete, on the same route.
    ///
    /// It used to have no single-message form at all, which is why a
    /// 「建议删除」 row's 「照做」 button was rendered and did nothing:
    /// the button set said ".delete is acceptable", and the executor had
    /// no case for it. A button that silently does nothing is worse than
    /// no button, because the user believes the mail is gone.
    private func deleteOne(_ item: BriefingItem) async {
        guard let accountId = accounts.accountId else { return }
        invalidatePendingRefresh()
        do {
            let response = try await api.deleteMessage(
                remoteId: item.message.remoteId, accountId: accountId
            )
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                mutateItems { $0.removeAll { $0.message.remoteId == item.message.remoteId } }
            }
            undo.show(UndoItem(
                id: response.actionId,
                message: l10n.deleted,
                systemImage: "trash"
            ))
            // The mail is in the trash. If it carried a suggestion to
            // delete it, the user just agreed with the AI. Best-effort,
            // like every other acceptance write: the delete already
            // happened.
            await recordAcceptedAdvice(
                remoteId: item.message.remoteId, performed: .delete
            )
        } catch {
            // The server never moved the row, so the row is still in the
            // list — the retry re-runs this same delete.
            errorBanner = ErrorBanner(
                severity: .error,
                title: l10n.deleteFailedTitle,
                detail: error.lagoonUIMessage,
                actionLabel: l10n.retry,
                action: { [self] in await self.deleteOne(item) }
            )
        }
    }

    /// Records that the user acted on the suggestion attached to a message.
    ///
    /// Called *after* the mail action succeeded, and deliberately never
    /// before it: the action is what the user asked for, and the verdict is
    /// only meaningful once the action actually happened. A failed verdict
    /// write does not undo the action — it surfaces a banner that says
    /// exactly that ("done, but not recorded"), because a preference that
    /// silently stops being written is how the learning loop looked before
    /// it existed.
    private func recordAcceptedAdvice(
        remoteId: String,
        performed: AdvisedAction
    ) async {
        guard let accountId = accounts.accountId else { return }
        let record = adviceByRemoteId[remoteId]
        let failure = await AdviceAcceptanceRecorder.record(
            advice: record,
            performedAction: performed,
            accountId: accountId,
            api: api
        )
        guard let failure else {
            // The row is leaving the feed anyway (it was archived or
            // unsubscribed), so the accepted verdict must not keep it in the
            // suggestion queue.
            adviceByRemoteId.removeValue(forKey: remoteId)
            return
        }
        errorBanner = ErrorBanner(
            severity: .warning,
            title: l10n.adviceAcceptFailedTitle,
            detail: failure.lagoonUIMessage
        )
    }

    private func refresh() async {
        guard let accountId = accounts.accountId else { return }

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

        do {

            let response = try await api.fetchBriefing(accountId: accountId)

            // A newer refresh started while this one was in flight; its
            // payload is at least as fresh, so committing this one would
            // resurrect rows the user has since archived or unsubscribed.
            guard generation == refreshGate.generation else { return }

            setItems(response.items)
            omittedCount = response.omittedCount
            backlogCount = response.backlogCount
            errorBanner = nil
            // Advice rides along with the feed but is a separate table, so a
            // failure here must not fail the refresh: the rows stay, they just
            // carry no suggestion. Loading it after committing the items keeps
            // that ordering explicit — the list is never blocked on the advice
            // queue, and a slow/absent LLM cannot delay the mail.
            await loadAdvice()
        } catch {
            guard generation == refreshGate.generation else { return }
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
    }

    /// Opens a message the advice panel pointed at.
    ///
    /// Refreshes first: the suggestion may be for mail that arrived after the
    /// last poll, and pushing a remoteId the current snapshot does not contain
    /// would navigate to a detail view with no header — a blank screen that
    /// reads as "the app is broken".
    ///
    /// A message that is still absent afterwards (archived, or filtered out of
    /// the feed entirely) is reported rather than silently ignored. This is the
    /// one place the feed cannot honour a request, and saying so beats a
    /// button that appears to do nothing.
    private func reveal(_ remoteId: String) async {
        if !items.contains(where: { $0.message.remoteId == remoteId }) {
            await refresh()
        }
        guard !isLoading else { return }
        guard items.contains(where: { $0.message.remoteId == remoteId }) else {
            errorBanner = ErrorBanner(
                severity: .warning,
                title: l10n.adviceMessageGoneTitle,
                detail: l10n.adviceMessageGoneDetail
            )
            return
        }
        withAnimation {
            selection = [remoteId]
        }
    }

    /// Mark every message in the current briefing as read. Runs the per-row
    /// markRead calls in parallel via a TaskGroup so a 50-message briefing
    /// takes ~3-5 round trips' worth of wall time rather than 50 in series.
    /// Optimistic local flip first so the UI updates before the server
    /// confirms; the first error surfaces in `errorBanner` and the next
    /// refresh pulls the server's view of truth back.
    private func markAllRead() async {
        invalidatePendingRefresh()
        guard let accountId = accounts.accountId else { return }
        guard !isMarkingAllRead, !items.isEmpty else { return }
        let unread = items.filter { !$0.message.isRead }
        guard !unread.isEmpty else { return }
        isMarkingAllRead = true
        defer { isMarkingAllRead = false }

        // Optimistic local update so the unread dots disappear immediately.
        // One mutation for the whole batch: flipping the rows one at a time
        // would rebuild the cached lookups once per row — a quadratic sweep
        // over a 500-row feed for a change the user sees in one frame.
        mutateItems { rows in
            for i in rows.indices where !rows[i].message.isRead {
                rows[i] = rows[i].withRead(true)
            }
        }

        // Each read is recorded with `record: true` so the whole batch can be
        // reversed by one ⌘Z. Before this, ⇧⌘K over an inbox was
        // irreversible: no audit rows, no toast, and the newest-action ⌘Z had
        // nothing of this operation to find. The ids are collected as they
        // come back so a partially-failed batch still offers to undo what did
        // land.
        await withTaskGroup(of: Result<Int64?, Error>.self) { group in
            for item in unread {
                group.addTask { [api] in
                    do {
                        let actionId = try await api.markRead(
                            remoteId: item.message.remoteId,
                            accountId: accountId,
                            record: true
                        )
                        return .success(actionId)
                    } catch {
                        return .failure(error)
                    }
                }
            }
            var actionIds: [Int64] = []
            var firstError: Error?
            for await result in group {
                switch result {
                case .success(let id):
                    if let id { actionIds.append(id) }
                case .failure(let error):
                    if firstError == nil { firstError = error }
                }
            }
            if let firstError {
                errorBanner = ErrorBanner(
                    severity: .warning,
                    title: l10n.markAllReadPartial,
                    detail: firstError.lagoonUIMessage,
                    // The retry is real: the messages that *did* land are
                    // read now, so re-running the sweep covers exactly the
                    // ones that failed. Spec INV-4.
                    actionLabel: l10n.retry,
                    action: { [self] in await self.markAllRead() }
                )
            }
            // Offer undo for whatever actually landed, newest first so a
            // single-action ⌘Z after this still reverses one of them.
            if let first = actionIds.first {
                undo.show(UndoItem(
                    id: first,
                    message: l10n.markedAllReadToast(actionIds.count),
                    systemImage: "envelope.open",
                    extraIds: Array(actionIds.dropFirst())
                ))
            }
        }
    }

}



private struct BriefingRow: View {

    let item: BriefingItem

    /// The AI's suggestion for this message, when one exists.
    ///
    /// Passed in rather than looked up inside the row: the feed owns the advice
    /// table (it loads it, refreshes it, records verdicts), so this view stays
    /// a pure renderer — it cannot fetch, and it cannot record a dismissal
    /// without going back through the feed.
    let advice: AdviceRecord?
    /// The shared density preference.
    ///
    /// The row used to receive a bare `showsSnippet` flag, which could express
    /// "hide the third line" but not the one-line layout dense mode promises —
    /// so the feed's dense silently rendered as compact (UX-04). Passing the
    /// density itself is what lets the row honour all three modes exactly like
    /// the raw list does.
    let density: ListDensity

    /// Whether the row shows its third line (reason or snippet).
    private var showsSnippet: Bool { density.showsSnippet }
    /// Which suggestion is expanded, across all rows.
    ///
    /// One id rather than a `Set`: two rows open at once is not a state the
    /// user can act on, and a per-row `@State` would leave the first row's
    /// body on screen when a second opens.
    @Binding var expandedAdviceId: Int64?
    /// The suggestion whose dismissal is in flight.
    @Binding var busyAdviceId: Int64?
    let onOpenAdvice: (String) -> Void
    let onDismissAdvice: (AdviceRecord) -> Void
    /// Set a reminder for the message this suggestion is about.
    ///
    /// A user gesture only: the suggestion says "remind", and the user
    /// picks the moment. The suggestion never schedules anything.
    let onSetReminder: (AdviceRecord) -> Void
    /// Perform the action the suggestion advised, and record it as accepted.
    ///
    /// The gesture is the user's; the row only carries it to the feed,
    /// which owns the mail actions and the advice table.
    let onAcceptAdvice: (AdviceRecord) -> Void

    @Environment(\.l10n) private var l10n

    /// The suggestions the row can actually *perform*.
    ///
    /// Only the three that change the mailbox, and only the ones the feed
    /// already has a user-triggered route for: archive, delete, unsubscribe.
    /// `.reply` and `.remind` open a composer or a sheet rather than mutate
    /// mail, and `.wait` / `.nothing` are not actions at all — so for those
    /// the strip offers no 「照做」 button rather than a dead one.
    static let acceptableActions: Set<AdvisedAction> = [.archive, .delete, .unsubscribe]

    var body: some View {
        if density == .dense {
            denseRow
        } else {
            regularRow
        }
    }

    /// The dense row: one line — unread dot, sender, subject, time — the same
    /// scan-line the raw list's dense mode renders, deliberately.
    ///
    /// Dense is the "hundreds of rows looking for one sender" mode, and it
    /// trades away the avatar, the reason/snippet *and the advice strip* to
    /// keep that promise: the strip is an extra line, and a row that sometimes
    /// wraps to two lines is not a dense row. compact and comfortable are
    /// untouched and still carry all of it.
    private var denseRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if !item.message.isRead {
                Circle()
                    .fill(.tint)
                    .frame(width: 6, height: 6)
            }
            Text(item.message.fromName ?? item.message.fromAddress)
                .font(.caption)
                .lineLimit(1)
                .frame(maxWidth: 110, alignment: .leading)
            Text(item.message.subject ?? l10n.noSubject)
                .font(.callout)
                .bold(!item.message.isRead)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(item.message.receivedAt.formatted(date: .omitted, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var regularRow: some View {

        VStack(alignment: .leading, spacing: 0) {

        HStack(alignment: .top, spacing: 10) {
            // Avatar — initials in a colour derived from the email hash.
            // Anchors the row visually so a long list of subscription
            // noise scans faster (eye lands on the circle, then the subject).
            SenderAvatar(
                email: item.message.fromAddress,
                displayName: item.message.fromName
            )

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

            if showsSnippet, let reason = l10n.reasonText(item.reasonCode) {

                Text(reason).font(.caption2).foregroundStyle(.secondary).lineLimit(2)

            } else if showsSnippet, let snippet = item.message.snippet {

                Text(snippet).font(.caption2).foregroundStyle(.secondary).lineLimit(2)

            }

            // The AI's judgement, on the row the user is already looking at.
            // Placed *after* the static reason so the two never compete for the
            // same visual weight: the deterministic "why this group" is a fact
            // about the mail, the suggestion is an opinion about what to do.
            //
            // Omitted when the message has no suggestion — and the strip itself
            // hides `.nothing`, so a row only grows when there is a judgement
            // worth reading.
            if let advice {
                RowAdviceStrip(
                    record: advice,
                    onOpen: { onOpenAdvice(advice.remoteId) },
                    onDismiss: { onDismissAdvice(advice) },
                    onSetReminder: advice.advice.action == .remind
                        ? { onSetReminder(advice) }
                        : nil,
                    onAccept: Self.acceptableActions.contains(advice.advice.action)
                        ? { onAcceptAdvice(advice) }
                        : nil,
                    isExpanded: Binding(
                        get: { expandedAdviceId == advice.id },
                        set: { expanded in
                            expandedAdviceId = expanded ? advice.id : nil
                        }
                    ),
                    isBusy: busyAdviceId == advice.id
                )
            }

            }
        }.padding(.vertical, 2)

        }

    }

}

// MARK: - Feed index

/// The Briefing's multi-select arithmetic.
///
/// ## Why this is a type and not three lines in the view
///
/// These rules are **silent**: get them wrong and nothing fails to compile —
/// the build stays green, the tests stay green, and the user just gets the
/// wrong behaviour. "⌘A twice returns to an empty selection" and "⌘A never
/// reaches past what is loaded" are the two claims the whole no-second-stage
/// design rests on, and neither of them can be checked by reading the view.
///
/// So the arithmetic lives here, in a pure type the view *calls*, and the
/// test drives these functions rather than a copy of them. A copy in the
/// test file would keep passing after the view changed — which is exactly
/// the guardrail-that-goes-blind failure this project keeps having to undo.
enum BriefingSelection {
    /// ⌘A: select everything loaded — or clear the selection when it already
    /// is everything loaded.
    ///
    /// The toggle is the whole point. Pressing ⌘A twice must land back on
    /// *no* selection, never on a wider blast radius: the most natural thing
    /// a user can do is press ⌘A, ⌘A, ⌫, and the answer to that sequence
    /// has to be "nothing happened".
    ///
    /// `loaded` is the window, never "everything on the server". The Briefing
    /// has no server-wide scope to offer, so the widest selection it can
    /// hand the user is the one they can see.
    static func toggledAll(selected: Set<String>, loaded: Set<String>) -> Set<String> {
        selected == loaded ? [] : loaded
    }

    /// The message the reading pane shows: exactly one selected row.
    ///
    /// Two or more preview nothing — the pane reports the count instead,
    /// because the bulk verbs are about to act on all of them and quietly
    /// showing one would describe the wrong scope.
    ///
    /// A selected row that has left the feed (archived from another client,
    /// or reclassified out of the window) previews nothing either: the pane
    /// would otherwise render a detail view with no header.
    static func readerId(selected: Set<String>, valid: Set<String>) -> String? {
        guard selected.count == 1, let only = selected.first else { return nil }
        guard valid.contains(only) else { return nil }
        return only
    }

    /// How many rows the bulk bar should claim to act on — nil when it
    /// should not appear at all.
    ///
    /// Two, not one: a single selected row already shows its own verbs (the
    /// swipe actions, the context menu), so a bar over one row would hide
    /// the list to offer nothing the row does not. Same threshold as the raw
    /// list — the two surfaces are two views of one mailbox.
    static func bulkCount(selected: Set<String>) -> Int? {
        selected.count > 1 ? selected.count : nil
    }
}

/// The cached lookups of the feed's rows.
///
/// One pass over the feed answers all of them: which rows belong to a
/// group, what the message behind a remote id is, and what the order of the
/// reachable rows is. The feed used to answer each of those with its own
/// scan, on every body evaluation.
struct FeedIndex {
    /// The rows of each group, in feed order.
    var byGroup: [BriefingGroup: [BriefingItem]] = [:]
    /// Every row by the id the rest of the app knows it by.
    var byRemoteId: [String: BriefingItem] = [:]
    /// Every row's id, in feed order.
    var orderedIds: [String] = []
    /// The ids the user can reach: the feed order minus the collapsed
    /// groups.
    var visibleIds: [String] = []
    /// Bumped whenever the *set* of rows changes.
    ///
    /// The animation key. It used to be the whole id array, which was
    /// rebuilt on every body evaluation — 500 pointer copies and 500 string
    /// comparisons per redraw — to answer a yes/no question.
    var revision: Int = 0
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
