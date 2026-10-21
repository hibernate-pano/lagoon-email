import SwiftUI
import LagoonKit

/// Top-level surface for a connected account. Owns the account menu, the
/// global error banner (via `ErrorCenter.shared`), the AI action undo
/// controller, the language picker, and the sync-health "view details"
/// sheet. Surfaces global shortcuts and a usage indicator.
struct RootView: View {
    @EnvironmentObject private var accounts: AccountStore
    /// Backgrounded windows idle instead of polling — see `sleepForPoll`.
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var directory = DirectoryStore()
    @StateObject private var errorCenter = ErrorCenter.shared
    @StateObject private var undo = UndoController()
    /// The store's one-shot notices — today, "your drafts were deleted
    /// because they could not be encrypted".
    ///
    /// It sits beside the error center rather than inside it because a
    /// notice is not a failure: it is the store telling the user about
    /// something it did on their behalf, and it must be shown **once** and
    /// then acknowledged, which is a different lifecycle from a banner the
    /// user dismisses.
    @StateObject private var storeNotices = StoreNoticeCenter.shared
    /// The seam between the menu bar and this window.
    ///
    /// SwiftUI's `CommandMenu` lives on the `App`, and the `App` cannot
    /// reach a `WindowGroup`'s view state — so a menu command has to be
    /// *sent* somewhere and picked up here. The router is that seam; the
    /// window stays the single owner of what is on screen.
    @ObservedObject private var commandRouter = AppCommandRouter.shared
    @AppStorage(LanguagePreference.defaultsKey) private var languageTag = AppLanguage.zhHans.rawValue
    @State private var showSearch = false
    /// A search query handed in by a `lagoon://search?q=…` link.
    ///
    /// The sheet owns its own query field; this is the one-shot seed that
    /// tells it what to start with. It is cleared on the way in, so opening
    /// the panel by hand does not resurrect the last link's query.
    @State private var searchSeed: String?
    @State private var showUsage = false
    @State private var showActionHistory = false
    @State private var showAdvice = false
    /// The reminders the user set for themselves.
    ///
    /// A reminder that can be set but never seen is half a feature, so the
    /// list is reachable from the toolbar menu, the command palette and
    /// the app's own menu bar.
    @State private var showReminders = false
    @State private var showCompose = false
    @State private var showConnect = false
    @State private var showHealthDetail = false
    @State private var showCommandPalette = false
    @State private var showShortcuts = false
    @State private var showAISettings = false
    @State private var showAbout = false
    /// 发件人排行. Opened from the toolbar overflow and from the sidebar's
    /// 发件人 section.
    @State private var showSenderRanking = false
    /// The address a 聚合规则 was just created for, so the ranking panel can
    /// confirm it on the row it acted on.
    ///
    /// Lifted out of the panel because the rule is created by the stack
    /// editor, which lives in a different view tree — the panel could never
    /// hear about it on its own, which is why the 「已建立聚合」 label never
    /// appeared. The owner of both surfaces holds the fact and hands it down.
    @State private var filedSenderAddress: String?
    /// A sender handed *in* by the ranking panel, for the list to present.
    ///
    /// The mirror of `senderToFile`: the panel cannot open a sheet that belongs
    /// to a surface it does not own, so it hands the value over and the mounted
    /// list picks it up.
    @State private var senderFocusRequest: SenderFocus?
    /// Seeded by the "Reconnect" banner so the QQ form comes up pre-filled;
    /// "Add account" deliberately leaves it nil.
    @State private var connectPrefillEmail: String?
    /// User dismissed the current sync-health banner. Reset on the next
    /// `directory.refresh()` so a fresh poll is allowed to re-surface the
    /// banner if the underlying state is still bad.
    @State private var syncHealthDismissed = false
    /// Same contract for the load-error banner: the poll that fills
    /// `directory.loadError` is the only thing that can clear it, and the ✕
    /// has to work without waiting 30s for that poll.
    @State private var loadErrorDismissed = false
    /// …and for the AI-status banner, whose source is polled the same way.
    @State private var aiStatusDismissed = false
    private let api = APIClient.shared

    enum Surface: String, CaseIterable, Identifiable {
        case briefing
        /// The **inbox** — the raw message list. The name is historical: the
        /// surface was called 全部邮件 / "All messages" until the copy-honesty
        /// audit (P2-04) found that the server answers it with the inbox
        /// filter, sent mail excluded, so the old title promised a set the
        /// list never held.
        case allMessages
        var id: String { rawValue }
    }

    /// Where the sidebar sends the user. The single source of truth for "what
    /// am I looking at" — `surface` is now derived from it rather than tracked
    /// separately, which is what keeps a sidebar click and the ⌘0 toggle from
    /// ever disagreeing about which surface is showing.
    @State private var destination: SidebarDestination = .briefing
    /// Fixed-bucket tallies for the sidebar. Empty until the first load; the
    /// sidebar renders a row without a badge rather than a wrong "0".
    @State private var folderCounts: [String: Int] = [:]
    /// The user's own aggregation rules with their live counts.
    @State private var sidebarRules: [StackSummary] = []

    /// Moves to the next density, in the order comfortable → compact → dense.
    ///
    /// The cycle order runs widest-to-narrowest so a single ⌘K press always
    /// packs the list *more*, which is the direction a user reaching for this
    /// wants; the reverse is one more press. The preference is written through
    /// `ListDensityPreference` rather than a `@State` here, because the list and
    /// the feed each hold their own `@AppStorage` view of it and a third copy
    /// in RootView would be a fourth thing to keep in sync.
    private func cycleDensity() {
        let current = ListDensityPreference.current()
        let all = ListDensity.allCases
        guard let index = all.firstIndex(of: current) else { return }
        let next = all[(index + 1) % all.count]
        ListDensityPreference.set(next)
        errorCenter.report(.init(
            severity: .success,
            title: "\(l10n.densityTitle)：\(densityTitle(next))",
            autoDismissAfter: .seconds(2)
        ))
    }

    private func densityTitle(_ density: ListDensity) -> String {
        switch density {
        case .comfortable: return l10n.densityComfortable
        case .compact: return l10n.densityCompact
        case .dense: return l10n.densityDense
        }
    }

    /// Which surface the current destination belongs to.
    ///
    /// Only `.briefing` shows the feed; every other destination is a lens on
    /// the raw list. Deriving this is what stops "click 未读 while reading the
    /// Briefing" from being a silent no-op.
    private var surface: Surface {
        destination.showsBriefing ? .briefing : .allMessages
    }

    /// The user's own name for the rule the current destination points at.
    ///
    /// `nil` for every destination that is not a rule, and for a rule whose
    /// name has not loaded yet — the list's title then falls back to the
    /// rules header rather than a blank heading.
    ///
    /// The lookup is by id against the list `/api/stacks` already returned, so
    /// the sidebar row and the list heading are the *same* name: one source,
    /// one string. Reading it from anywhere else would be a second copy that
    /// could disagree with the sidebar the moment a rule is renamed.
    private var currentRuleName: String? {
        guard case .rule(let id) = destination else { return nil }
        return sidebarRules.first { $0.rule.id == id }?.rule.name
    }

    /// Moves to a surface, from ⌘0 or the toolbar picker.
    ///
    /// A function rather than a settable `surface` because the sidebar's
    /// destination is now the single source of truth — the surface is derived
    /// from it. Assigning the surface directly would let the two disagree, and
    /// the disagreement shows up as "I pressed ⌘0 and the same feed is still
    /// there".
    ///
    /// Leaving the feed keeps whichever lens the user had already chosen, so
    /// ⌘0 round-trips do not silently drop them back to the unfiltered list.
    private func go(to target: Surface) {
        switch target {
        case .briefing:
            destination = .briefing
        case .allMessages:
            destination = destination.showsBriefing ? .allMessages : destination
        }
    }

    /// Loads the sidebar's tallies and rules.
    ///
    /// Both are read-only, and both are allowed to fail quietly: a sidebar with
    /// no numbers is still a working navigation column, whereas a red banner
    /// over the mail for a decorative count would be a worse trade than the
    /// count. The rule list is separate because `/api/stacks` carries its own
    /// per-rule counts — one endpoint cannot answer for both without one of
    /// them being wrong.
    private func refreshSidebarData() async {
        guard let accountId = accounts.accountId else {
            folderCounts = [:]
            sidebarRules = []
            return
        }
        async let counts = api.fetchFolderCounts(accountId: accountId)
        async let stacks = api.fetchStacks(accountId: accountId)
        folderCounts = (try? await counts) ?? folderCounts
        sidebarRules = (try? await stacks.stacks) ?? sidebarRules
        // A rule the user deleted in another window must not leave the sidebar
        // pointing at a destination that no longer resolves. The fallback
        // used to be silent, which reads as "the app forgot what I clicked";
        // saying so turns the same event into an explanation.
        if case .rule(let id) = destination,
           !sidebarRules.contains(where: { $0.rule.id == id }) {
            destination = .allMessages
            errorCenter.report(.init(
                severity: .info,
                title: l10n.sidebarDestinationMissing,
                autoDismissAfter: .seconds(4)
            ))
        }
    }

    /// Re-reads everything the window shows, without asking the mail server
    /// for anything new.
    ///
    /// This is the ⌥⌘R verb: "show me what you already have". The two
    /// surfaces own their own lists and re-read them when this notification
    /// arrives, so there is one definition of "refresh" rather than one per
    /// surface.
    private func reloadFromServer() {
        NotificationCenter.default.post(name: .lagoonDidChangeData, object: nil)
        Task {
            await directory.refresh()
            await refreshSidebarData()
        }
    }

    /// Asks the server to pull from IMAP, then re-reads.
    ///
    /// This is the ⇧⌘N verb, and it is deliberately *not* the same as
    /// ⌥⌘R: one is a network round trip to the mail server and can take
    /// seconds, the other is a local re-read and returns in milliseconds.
    /// One key for both would make the fast one look broken.
    private func pullNewMail() {
        Task {
            do {
                try await api.requestSync()
            } catch {
                errorCenter.report(.init(
                    severity: .error,
                    title: l10n.syncFailed + error.lagoonUIMessage,
                    detail: l10n.syncFailedDetail,
                    actionLabel: l10n.retry,
                    action: { [self] in await self.retrySync() }
                ))
                return
            }
            reloadFromServer()
        }
    }

    /// Turns a command from the menu bar (or a `lagoon://` link) into the
    /// state change it implies.
    ///
    /// Every command lands on state this view already owns, so the menu bar
    /// and the toolbar cannot drift apart: there is one set of sheets, one
    /// surface, one density — and the menu is a second way of asking for
    /// them, not a second implementation of them.
    /// Opens the search panel, optionally with a query already in it.
    ///
    /// The seed is cleared on the way in unless this call supplies one. A
    /// `lagoon://search?q=…` link is a one-shot instruction; opening the
    /// panel by hand afterwards must start empty, or the last link's query
    /// silently comes back.
    private func openSearch(query: String? = nil) {
        searchSeed = query
        showSearch = true
    }

    private func handle(_ command: AppCommandRouter.Command) {
        switch command {
        case .newMessage:
            showCompose = true
        case .search(let query):
            openSearch(query: query)
        case .toggleSurface:
            go(to: surface == .briefing ? .allMessages : .briefing)
        case .refresh:
            reloadFromServer()
        case .getNewMail:
            pullNewMail()
        case .cycleDensity:
            cycleDensity()
        case .showShortcuts:
            showShortcuts = true
        case .showAbout:
            showAbout = true
        case .showUsage:
            showUsage = true
        case .showAdvice:
            showAdvice = true
        case .showReminders:
            showReminders = true
        case .showActionHistory:
            showActionHistory = true
        case .showSenderRanking:
            showSenderRanking = true
        case .showAISettings:
            showAISettings = true
        case .showCommandPalette:
            showCommandPalette = true
        case .showMessage(let remoteId):
            // The Briefing owns the reveal; RootView owns the surface, and
            // the message may not be in the list the user is looking at.
            go(to: .briefing)
            NotificationCenter.default.post(
                name: .lagoonRevealMessage,
                object: nil,
                userInfo: ["remoteId": remoteId]
            )
        case .showUnread:
            destination = .unread
        }
    }

    private var language: AppLanguage { AppLanguage(rawValue: languageTag) ?? .zhHans }
    private var l10n: L10n { L10n(language: language) }

    // Extracted from `body`: the combined expression sits right at the
    // Swift type-checker's time limit, and any upstream change (e.g. a new
    // ConnectView parameter) tips it over into an unreasonable-time error.
    @ViewBuilder private var briefingSurface: some View {
        BriefingFeedView(
            isVisible: surface == .briefing,
            columnStore: columnStore,
            // The feed needs to know whether the user has groups of their
            // own, because that is what decides whether it shows the note
            // explaining that its five groups are decided by Lagoon and are
            // not affected by the sidebar's 「我的分组」. The rule list is
            // already loaded here for the sidebar, so the answer is a
            // property of state this view holds — not a second fetch that
            // could disagree with the sidebar's own count.
            hasUserGroups: !sidebarRules.isEmpty,
            onShowAllMessages: { go(to: .allMessages) }
        )
            .opacity(surface == .briefing ? 1 : 0)
            .disabled(surface != .briefing)
            .allowsHitTesting(surface == .briefing)
            .accessibilityHidden(surface != .briefing)
    }

    @ViewBuilder private var messagesSurface: some View {
        MessageListView(
            isVisible: surface == .allMessages,
            columnStore: columnStore,
            lens: MessageListView.Lens(destination),
            // The user's own name for the rule, so the list's heading says
            // 「工作」 rather than 「分组规则」. The list cannot look this up
            // itself — the rule list is this view's state, and a second copy
            // inside the list would be a second thing to keep in sync.
            ruleTitle: currentRuleName,
            onShowBriefing: { go(to: .briefing) },
            onClearLens: { destination = .allMessages },
            senderFocusRequest: $senderFocusRequest
        )
            .opacity(surface == .allMessages ? 1 : 0)
            .disabled(surface != .allMessages)
            .allowsHitTesting(surface == .allMessages)
            .accessibilityHidden(surface != .allMessages)
            // A lens change has to re-query: `未读` and a rule are server-side
            // filters, so re-filtering the rows already in memory would show a
            // list the server never sent. Keyed on the destination, which
            // changes whenever the sidebar selection changes.
            .id(destination)
    }

    // `body` used to be one giant SwiftUI expression that sat right at the
    // type-checker's time limit; adding a ConnectView parameter tipped it
    // over into "unable to type-check in reasonable time". The three computed
    // properties below keep each chain small enough to check quickly.
    /// The window's shared widths.
    ///
    /// A `@StateObject` on `RootView` rather than on either surface, so a surface
    /// switch cannot reset the layout the user just set, and so the sidebar and
    /// the list/reader pair solve as one system. See `ColumnWidthStore` for the
    /// one-authority rule this exists to keep.
    @StateObject private var columnStore = ColumnWidthStore()

    /// The window's columns, for a known content width.
    ///
    /// `GeometryReader` is the one honest source of the window's width, and it is
    /// read here rather than passed down: the three columns' widths are a function
    /// of the window, so the place that knows the window is the place that tells
    /// the store.
    ///
    /// The window's floor is stated here and not on either surface, because it
    /// depends on all three columns: `sum(min) + separators`. A per-surface
    /// minimum is what previously sat at 720 while the three columns needed 820,
    /// guaranteeing a breach on every narrow window
    /// (`docs/三栏宽度求解器-实测结论.md`, conclusion 2).
    @ViewBuilder
    private func windowColumns(width: CGFloat) -> some View {
        // The window's geometry is handed to the store here, in `body`, rather
        // than from `.onChange` or `.task` on this view.
        //
        // Both of those attach to the *HStack*, and a width that arrives before
        // the HStack has settled never reaches them: the first `width` they see
        // can be the placeholder 0 `GeometryReader` hands out before the window
        // is sized, and if the view does not rebuild afterwards, no real width
        // ever arrives. The symptom was a window whose columns laid out
        // correctly but whose separators reported 0pt — the store had solved,
        // but against a container it believed was empty.
        //
        // Reading it in `body` is the deterministic version: any change to
        // `width` re-runs this function, so the store is told before a single
        // `.frame(width:)` below reads its answer.
        let _ = columnStore.window(width: width, columns: visibleColumns)

        HStack(spacing: 0) {
            if visibleColumns.contains(.navigation) {
                NavigationColumnView(store: columnStore) {
                    Sidebar(
                        selection: $destination,
                        rules: sidebarRules,
                        counts: folderCounts
                    )
                }
                ColumnDivider(
                    column: .navigation,
                    invertedColumn: nil,
                    store: columnStore,
                )
                .frame(width: ColumnLayoutMetrics.dividerHitWidth)
            }
            twoColumnSurfaces
        }
        .frame(minWidth: minimumWindowWidth, minHeight: ColumnLayoutMetrics.windowMinimumHeight)
        .onAppear {
            // One write per settled drag, not one per frame. Wired here rather
            // than inside the store so `UserDefaults` stays behind an explicit
            // call, and a window nobody ever dragged in never writes.
            columnStore.installPersistence()
        }
    }

    /// The columns this window has. Two without a connected account — there is
    /// nothing to navigate — and three with one.
    ///
    /// Declared here rather than inferred inside the layout so the solve and the
    /// draw are provably about the same set.
    private var visibleColumns: [LagoonColumn] {
        accounts.accountId == nil ? [.list, .reader] : [.navigation, .list, .reader]
    }

    /// `sum(min) + separators` over the columns actually present — derived by
    /// the layout's one authority (`ColumnLayoutMetrics.minimumWindowWidth(for:)`)
    /// rather than re-spelled here. A second hand-written copy is exactly how
    /// this drifted before: the window enforced 822 while a stale static 832
    /// survived in tests (UX-11).
    private var minimumWindowWidth: CGFloat {
        CGFloat(ColumnLayoutMetrics.minimumWindowWidth(for: visibleColumns))
    }

    private var decorated: some View {
        VStack(spacing: 0) {
            if let banner = priorityBanner {
                NoticeBannerView(banner: banner, onDismiss: { dismissPriorityBanner(banner) })
            }
            GeometryReader { proxy in
                windowColumns(width: proxy.size.width)
            }
        }
        // The global `ErrorCenter` banner — used for failures raised outside
        // the view layer (undo, polling errors, etc.) and for transient
        // confirmations like "Sent" / "Sync recovered".
        .noticeBanner($errorCenter.banner)
        // Removing an account is destructive, so it asks first — and the
        // prompt says the one thing a user would otherwise worry about: the
        // mail on the server is not touched.
        .alert(
            l10n.removeAccountConfirmTitle,
            isPresented: Binding(
                get: { accountPendingRemoval != nil },
                set: { if !$0 { accountPendingRemoval = nil } }
            )
        ) {
            Button(l10n.removeAccountConfirmButton, role: .destructive) {
                guard let account = accountPendingRemoval else { return }
                accountPendingRemoval = nil
                Task { await removeAccount(account) }
            }
            Button(l10n.cancel, role: .cancel) { accountPendingRemoval = nil }
        } message: {
            Text(l10n.removeAccountConfirmMessage)
        }
        // The offline state is a *state*, not a failure: the mail on screen
        // is real and complete, it is only not being updated. It gets its
        // own quiet strip rather than a slot in the banner, so a permanent
        // condition cannot permanently occupy the one-banner-at-a-time slot
        // and train the user to ignore it.
        .offlineStrip(NetworkMonitor.shared)
        .environment(\.l10n, l10n)
        .environmentObject(undo)
        // Views gate verbs (archive) on the active account's negotiated
        // capabilities, so the directory must be reachable from the feed.
        .environmentObject(directory)
        .toolbar { toolbar }
        // The undo toast lives at the RootView level so it is also visible on
        // the inbox surface, not just the Briefing Feed. The
        // time-saved status bar (spec principle #3) shares the bottom inset,
        // under the toast.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                UndoToast(controller: undo)
                TimeSavedBar()
            }
        }
    }

    /// The two surfaces and their keep-alive ZStack, unchanged.
    private var twoColumnSurfaces: some View {
        ZStack {
            briefingSurface
            messagesSurface
        }
        .id(accounts.accountId)
    }

    private var sheetStack: some View {
        decorated
            .sheet(isPresented: $showSearch) {
                SearchSheet(initialQuery: searchSeed)
            }
            .sheet(isPresented: $showUsage) {
                UsageSheet()
            }
            .sheet(isPresented: $showActionHistory) {
                ActionHistorySheet()
            }
            .sheet(isPresented: $showAdvice) {
                AdviceSheet()
            }
            .sheet(isPresented: $showReminders) {
                RemindersSheet()
            }
            .sheet(isPresented: $showCompose) {
                composeSheet
            }
            .sheet(isPresented: $showConnect, onDismiss: {
                // A successful connect/reconnect can clear the health banner; refresh
                // the directory immediately instead of waiting up to 30s.
                Task { await directory.refresh() }
            }) {
                ConnectView(prefillEmail: connectPrefillEmail, presentedAsSheet: true)
            }
            .sheet(isPresented: $showHealthDetail) {
                healthDetailSheet
            }
            .sheet(isPresented: $showCommandPalette) {
                commandPalette
            }
            .sheet(isPresented: $showShortcuts) {
                ShortcutsSheet()
            }
            .sheet(isPresented: $showAISettings) {
                AISettingsSheet(
                    aiStatus: directory.aiStatus,
                    onApplied: { status in directory.applyAIStatus(status) }
                )
            }
            .sheet(isPresented: $showAbout) {
                AboutSheet()
            }
            .sheet(isPresented: $showSenderRanking) {
                senderRankingSheet
            }
            // Both surfaces stay alive (the Briefing and the raw list are kept
            // mounted so their scroll position and poll loops survive a
            // switch), which means a message revealed from the advice panel
            // would be pushed onto a NavigationStack the user cannot see. The
            // switch has to happen here, where the surface lives.
            .onReceive(NotificationCenter.default.publisher(for: .lagoonRevealMessage)) { _ in
                go(to: .briefing)
            }
            // The sidebar's group list and its counts are a *second* source
            // (`/api/stacks`, `/api/folder-counts`), and nothing in this view
            // re-reads them when a write lands elsewhere. So a group renamed
            // in the group panel kept its old name in the sidebar, and the
            // badge kept the count the group had *before* the rename — which
            // is the "I renamed it and the app ignored me" failure, in the
            // one place the user looks for their groups.
            //
            // The surfaces already listen for this notification and re-read
            // their own lists; this is the same notification, used for the
            // one surface that had no listener.
            .onReceive(NotificationCenter.default.publisher(for: .lagoonDidChangeData)) { _ in
                Task { await refreshSidebarData() }
            }
    }

    @ViewBuilder private var composeSheet: some View {
        if let accountId = accounts.accountId {
            NewMessageSheet(accountId: accountId) { _ in
                errorCenter.report(.init(
                    severity: .success,
                    title: l10n.sent,
                    autoDismissAfter: .seconds(4)
                ))
            }
        }
    }

    /// The ranking panel, wired to the two flows it can hand a sender to.
    ///
    /// Both callbacks stop at this level rather than reaching into a surface:
    /// "file" raises a 聚合规则 for the sender and then tells the sidebar to
    /// learn about it, and "view mail" opens the existing `SenderSheet`. So
    /// the panel never has to know which surface is mounted, and neither
    /// surface grows a branch for it.
    @ViewBuilder
    private var senderRankingSheet: some View {
        if let accountId = accounts.accountId {
            SenderRankingSheet(
                accountId: accountId,
                // The confirmation the panel shows on the row it just acted
                // on. Owned here because the panel is a separate view
                // instance: the fact has to live with the owner of both
                // surfaces to be readable by the one that has to show it.
                filedAddress: $filedSenderAddress,
                onFileSender: { _ in
                    // The rule exists. The sidebar's 自定义聚合 section lists
                    // the user's rules, so it has to be told about the new
                    // one — the panel cannot refresh a store it does not own.
                    Task { await directory.refresh() }
                },
                onOpenSender: { sender in
                    senderFocusRequest = SenderFocus(
                        from: sender.address, name: sender.displayName
                    )
                }
            )
        }
    }

    @ViewBuilder private var healthDetailSheet: some View {
        if let active = directory.active {
            SyncHealthDetailSheet(
                health: active.syncHealth,
                capabilities: active.capabilities
            )
        }
    }

    private var commandPalette: some View {
        // ⌘K is the power-user fast path; mirrors Things / Linear / Superhuman.
        CommandPaletteView(
            onNewMessage: { showCompose = true },
            onSearch: { openSearch() },
            // ⌘0 is a toggle on both surfaces (BriefingFeedView:226 /
            // MessageListView:112), so the palette row must be a toggle too.
            // Two rows each claiming ⌘0 told the user "press ⌘0 to reach the
            // Briefing" — and pressing it there sent them the other way.
            onToggleSurface: {
                go(to: surface == .briefing ? .allMessages : .briefing)
            },
            onShowUsage: { showUsage = true },
            onShowActionHistory: { showActionHistory = true },
            onShowAdvice: { showAdvice = true },
            onShowReminders: { showReminders = true },
            onShowSenderRanking: { showSenderRanking = true },
            onCycleDensity: { cycleDensity() },
            onShowShortcuts: { showShortcuts = true },
            onShowAISettings: { showAISettings = true },
            // ⌥⌘R re-reads what is already here; ⇧⌘N goes to the mail server.
            // Both surfaces bind ⌥⌘R to their own local refresh, so the
            // palette has to mean the same thing by it — one key, one verb.
            onRefresh: { reloadFromServer() },
            onGetNewMail: { pullNewMail() },
            onToggleSound: { SoundEffects.isEnabled.toggle() }
        )
    }

    var body: some View {
        sheetStack
        // Binding the environment store (not a throwaway one): UndoController
        // holds it weakly, so the real owner must be the one bound.
        .onAppear {
            undo.bind(accounts)
        }
        // The menu bar's commands arrive here. Without this the menu bar is
        // a picture of a menu bar: the items render, the shortcuts are
        // advertised in the cheatsheet, and pressing one does nothing —
        // which is worse than not having the menu at all, because the user
        // concludes the app is broken rather than that it is unfinished.
        .onChange(of: commandRouter.pending) { _, _ in
            guard let command = commandRouter.take() else { return }
            handle(command)
        }
        // The directory is the account list + health source; poll it while the
        // window is open (the server writes health from its sync loop).
        .task {
            // Immediate first pass. The directory is the only source of the
            // account list, sync health, AI status and load error, so sleeping
            // before the first refresh would leave the whole window empty for
            // 30s on every launch.
            await directory.refresh()
            // The sidebar's counts and rules are a *second* source: they come
            // from `/api/folder-counts` and `/api/stacks`, not from the
            // account list. They used to be loaded by a separate
            // `.task(id: accountId)`, which the three-column rewrite (13551b2)
            // dropped while leaving `refreshSidebarData` behind — so every
            // count badge stayed empty and the 自定义聚合 section never
            // rendered, with no error to show for it. Loading them here keeps
            // them on the same cadence as everything else the window polls.
            await refreshSidebarData()
            // The store's own notices. Fetched on the same cadence as
            // everything else the window polls, and on the first pass — a
            // notice that waits 30 seconds to appear is a notice the user
            // has already stopped expecting.
            await storeNotices.refresh()
            while !Task.isCancelled {
                guard await sleepForPoll(DirectoryStore.refreshInterval) else { return }
                guard shouldPoll(isVisible: true, scenePhase: scenePhase) else { continue }
                await directory.refresh()
                await refreshSidebarData()
                await storeNotices.refresh()
                // A dismissal only lasts until the next poll: if the
                // underlying state is still bad, the banner comes back.
                syncHealthDismissed = false
                loadErrorDismissed = false
                aiStatusDismissed = false
            }
        }
        .onChange(of: directory.active?.syncHealth.status) { old, new in
            if let old, old != .ok, new == .ok {
                // Spec §4.4: "Sync recovered" is a transient confirmation,
                // not an error, so it goes through ErrorCenter with severity
                // .info and an auto-dismiss. The "Glass" chime is the
                // audio counterpart — distinct from "Tink"/"Pop" so the user
                // learns what each sound means after a few days.
                SoundEffects.syncRecovered()
                errorCenter.report(.init(
                    severity: .success,
                    title: l10n.syncRecovered,
                    autoDismissAfter: .seconds(4)
                ))
            }
        }
        // NOTE: `directory.loadError` is deliberately *not* mirrored into
        // `errorCenter` here. It used to be, and the same failure then
        // appeared twice — once as the local `loadErrorBanner` above the
        // content, once as the global banner below it — with two different
        // titles ("邮件列表加载失败" vs "检查连接失败：…") and two retry
        // buttons for one problem. Spec INV-6 says one banner at a time; the
        // local banner is the better of the two (proper title, a detail, a
        // retry), so it is the only one.
        .onChange(of: directory.loadError) { _, newError in
            guard newError != nil else { return }
            // A failure that appears *while* the user has dismissed the
            // banner is a new failure, not the old one — show it again.
            loadErrorDismissed = false
        }
        // The server owns the active account. Keep the Keychain mirror aligned
        // so the next launch opens the same mailbox.
        .onChange(of: directory.active?.id) { _, resolved in
            guard let resolved, accounts.accountId != resolved else { return }
            // The Keychain write runs off the main thread (see
            // `AccountStore.set`) — it can raise the system's authorization
            // dialog, and a modal dialog on the main thread freezes the UI.
            Task { [accounts] in
                await mirrorAccountToKeychain(resolved, accounts)
            }
        }
        .background {
            // ⌘Z — undo. This one is *not* in the menu bar: undo is bound to
            // the last action, and a menu item that is only sometimes
            // meaningful (there is nothing to undo half the time) belongs on
            // a key, not on a menu row.
            //
            // ⌘K and ⌘/ used to live here too, as zero-width hidden buttons.
            // They are now menu-bar items, and macOS gives the menu priority
            // for a key equivalent — so these copies were dead code that
            // looked alive. A hidden button that never fires is a trap for
            // whoever debugs it next.
            Button(l10n.undoLastAction) { Task { await undo.undoLatest() } }
                .keyboardShortcut("z", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .focusable(false)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Priority banner chain
    /// Write the active account to the keychain, reporting a failure the
    /// user can act on.
    ///
    /// A keychain write can fail for a reason that goes away on its own —
    /// the user dismissed the authorization prompt, the machine was locked
    /// mid-write — so this is a retryable failure, and the retry is the same
    /// write. Each failure re-reports the banner with the same button, so
    /// pressing it again always does the one thing that could help.
    private func mirrorAccountToKeychain(_ accountId: UUID, _ accounts: AccountStore) async {
        do {
            try await accounts.set(accountId: accountId)
        } catch {
            errorCenter.report(.init(
                severity: .error,
                title: l10n.saveAccountFailed + error.lagoonUIMessage,
                detail: l10n.saveAccountFailedDetail,
                actionLabel: l10n.retry,
                action: {
                    await mirrorAccountToKeychain(accountId, accounts)
                }
            ))
        }
    }


    /// First non-nil `ErrorBanner` wins. Four local sources (`undoError`,
    /// sync health, AI status, load error) race against each other; this
    /// keeps the highest-priority local banner visible above the global one.
    ///
    /// The global `errorCenter.banner` is deliberately absent: it is already
    /// rendered by the `.noticeBanner($errorCenter.banner)` modifier on the
    /// same stack, so returning it here drew the same banner twice.
    private var priorityBanner: ErrorBanner? {
        if let banner = storeNoticeBanner { return banner }
        if let banner = undoErrorBanner { return banner }
        if let banner = syncHealthBanner { return banner }
        if let banner = aiStatusBanner { return banner }
        return loadErrorBanner
    }

    private func dismissPriorityBanner(_ banner: ErrorBanner) {
        // `ErrorBanner` mints a fresh `UUID` in its own initializer, so every
        // re-read of a source below returns a *different* instance and `id`
        // can never match the one the body rendered. The title is the stable
        // identity: it is the server error text for undo/load and the copy
        // for sync health, so an unchanged title means the same banner.
        //
        // The global `errorCenter.banner` is absent by design — the
        // `.noticeBanner` modifier owns its own ✕. A banner that matches no
        // source here was drawn by that modifier, so there is nothing to
        // dismiss.
        //
        // Every branch is a polled source, so dismissing is implicitly "until
        // the next poll". The AI branch was missing entirely, which made the
        // ✕ a dead control: it renders with no `actionLabel`, so on the
        // circuit-open banner that ✕ was the *only* thing to click, and
        // `directory.aiStatus` keeps its last value when a poll fails, so it
        // never went away on its own either.
        if undoErrorBanner?.title == banner.title {
            undo.clearError()
        } else if syncHealthBanner?.title == banner.title {
            syncHealthDismissed = true
        } else if aiStatusBanner?.title == banner.title {
            aiStatusDismissed = true
        } else if loadErrorBanner?.title == banner.title {
            // This used to set `syncHealthDismissed`, which silenced the
            // *sync-health* banner and left the load error on screen.
            loadErrorDismissed = true
        }
    }

    /// The banner for a notice the store raised for the user.
    ///
    /// ## Why this is a warning and not an error
    ///
    /// Nothing is broken and nothing is at risk: the drafts that could not
    /// be encrypted were *removed*, so what is on disk is exactly what the
    /// product promises. What the user lost is their drafts, and the
    /// severity that says "look at this" without saying "something is
    /// wrong" is the warning.
    private var storeNoticeBanner: ErrorBanner? {
        guard let notice = storeNotices.current else { return nil }
        let count = notice.detail.flatMap { Int($0) }
        let detail = count.map { l10n.draftsDroppedDetail(count: $0) }
            ?? l10n.draftsDroppedDetailUnknownCount
        return ErrorBanner(
            severity: .warning,
            title: l10n.draftsDroppedTitle,
            detail: detail,
            actionLabel: l10n.dismiss,
            action: { await storeNotices.acknowledgeCurrent() }
        )
    }

    private var undoErrorBanner: ErrorBanner? {
        guard let text = undo.errorMessage else { return nil }
        return ErrorBanner(
            severity: .error,
            title: text,
            // The title says what failed; the detail says why. "没有可撤销的
            // 操作" is the same sentence whether there was nothing to undo
            // or the undo was refused, and the user cannot tell which.
            detail: undo.errorDetail,
            // "重试", not "关闭". The banner already has a ✕ that closes it,
            // so an action button that also closed it was a control that
            // duplicated the one next to it. An undo that failed can
            // usually be undone *again* — `undoLatest()` re-reads the
            // server's newest reversible action, so the retry is a real
            // second attempt rather than a dismissal in disguise.
            actionLabel: l10n.retry,
            action: { await undo.undoLatest() }
        )
    }

    private var loadErrorBanner: ErrorBanner? {
        // Mirror what the old RootView did: only show if the directory
        // poll actually failed. `directory.loadError` is set/cleared by
        // `DirectoryStore.refresh()` so a successful poll also clears this
        // banner for free; the ✕ clears it without waiting for that poll.
        guard !loadErrorDismissed, let lastError = directory.loadError else { return nil }
        // The title names the operation in the user's terms; the detail
        // carries the server's own words about why it failed.
        return ErrorBanner(
            severity: .error,
            title: l10n.listLoadFailed,
            detail: lastError,
            actionLabel: l10n.retry,
            action: { [weak directory = directory] in
                await directory?.refresh()
            }
        )
    }

    private var syncHealthBanner: ErrorBanner? {
        guard !syncHealthDismissed,
              let active = directory.active,
              active.syncHealth.status != .ok else { return nil }
        // The server stores a machine-readable label here ("auth-failed",
        // "not-configured"). It is translated before it reaches the user —
        // the raw label is a debugging artifact, and a headline that names
        // one cause plus a detail that names another is worse than useless.
        let reason = SyncErrorReason.sentence(for: active.syncHealth.lastError, l10n: l10n)
        switch active.syncHealth.status {
        case .needsReconnect:
            return ErrorBanner(
                severity: .error,
                title: l10n.healthNeedsReconnect,
                detail: reason,
                actionLabel: l10n.reconnect,
                action: { [self] in await self.reconnect() }
            )
        case .degraded:
            return ErrorBanner(
                severity: .warning,
                title: l10n.healthDegradedTitle,
                detail: reason,
                actionLabel: l10n.retry,
                action: { [self] in await self.retrySync() }
            )
        case .error:
            return ErrorBanner(
                severity: .error,
                title: l10n.healthErrorTitle,
                detail: reason,
                actionLabel: l10n.retry,
                action: { [self] in await self.retrySync() }
            )
        case .accountMissing:
            // The copy names the real problem, and the action is the one
            // thing that can actually repair it.
            //
            // It is **not** the old "enter your code again" dead end: that
            // told the user their code had expired, and the write then went
            // to a row the server could not address. The reconnect sheet
            // probes the mailbox first and, on success, writes against the
            // row found by `(provider, oauth_user)` — which is found even
            // when the id is not. So reconnecting rebuilds the account's
            // state instead of repeating the failed lookup.
            //
            // No banner may be a dead end (spec INV-4/INV-5), and this one
            // is not: the detail says what is wrong, the button says how to
            // fix it.
            return ErrorBanner(
                severity: .error,
                title: l10n.healthAccountMissing,
                detail: reason,
                actionLabel: l10n.reconnect,
                action: { [self] in reconnect() }
            )
        case .ok:
            return nil
        }
    }

    /// Global AI degraded banner (V2 C1): credit exhaustion needs a top-up,
    /// circuit-open recovers on its own. Retry re-polls the status; the
    /// credit flag itself clears on the next successful AI call after top-up.
    private var aiStatusBanner: ErrorBanner? {
        guard !aiStatusDismissed else { return nil }
        guard let status = directory.aiStatus else { return nil }
        if !status.configured {
            return ErrorBanner(
                severity: .info,
                title: l10n.aiNotConfiguredTitle,
                detail: l10n.aiNotConfiguredDetail,
                actionLabel: l10n.aiSettingsTitle,
                action: { [self] in await MainActor.run { self.showAISettings = true } }
            )
        }
        if status.creditExhausted {
            return ErrorBanner(
                severity: .warning,
                title: l10n.aiCreditTitle,
                detail: l10n.aiCreditDetail,
                actionLabel: l10n.retry,
                action: { [self] in await self.retrySync() }
            )
        }
        if status.circuitOpen {
            return ErrorBanner(
                severity: .info,
                title: l10n.aiCircuitTitle,
                detail: l10n.aiCircuitDetail
            )
        }
        return nil
    }

    // MARK: - Account menu

    @ViewBuilder
    private var accountMenu: some View {
        Menu {
            ForEach(directory.accounts) { account in
                Button {
                    Task { await switchTo(account) }
                } label: {
                    if account.isActive {
                        Label(menuTitle(for: account), systemImage: "checkmark")
                    } else {
                        Text(menuTitle(for: account))
                    }
                }
                .disabled(account.isActive)
                // 「移除这个账号」 — every account gets an exit.
                //
                // It used to be that a user who connected the wrong mailbox
                // could never remove it: the API route existed, the store
                // method existed, and nothing in the UI called either. The
                // only way out was to delete the whole database — which
                // throws away every account, not just the wrong one.
                //
                // The active account is offered too, but it is confirmed:
                // removing it promotes another account, and if it was the
                // last one the app lands on the connect screen. A menu item
                // that destroys the thing you are looking at deserves one
                // click of friction.
                Button(role: .destructive) {
                    accountPendingRemoval = account
                } label: {
                    Label(l10n.removeAccount, systemImage: "trash")
                }
            }
            if directory.accounts.isEmpty {
                Text(l10n.notConnected)
            }
            Divider()
            Button(l10n.addAccount) { addAccount() }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor(for: directory.active))
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(syncStatusLabel(for: directory.active))
                Text(directory.active?.email ?? l10n.accountsMenuHelp)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // Kept short on purpose. The email is decoration here —
                    // the menu itself lists every account in full — while the
                    // toolbar budget it consumes is real: macOS overflows
                    // trailing items into "»" silently when the row does not
                    // fit, so a long address costs the user a button.
                    .frame(maxWidth: 140, alignment: .leading)
            }
        }
        .help(l10n.accountsMenuHelp)
    }

    /// The account the user asked to remove, waiting for the confirmation.
    @State private var accountPendingRemoval: ConnectedAccount?

    /// Removes the confirmed account and reports the outcome.
    ///
    /// The removal itself is the server's job (`DELETE /api/accounts/:id`
    /// cascades the account's messages, pins and drafts); what this adds is
    /// the *report*. A removal that fails silently leaves the user staring
    /// at an account they just decided they did not want — so a failure is
    /// a banner with a retry, not a shrug.
    private func removeAccount(_ account: ConnectedAccount) async {
        do {
            try await directory.remove(account)
        } catch {
            errorCenter.report(.init(
                severity: .error,
                title: l10n.deleteAccountFailed + error.lagoonUIMessage,
                detail: l10n.removeAccountFailedDetail,
                actionLabel: l10n.retry,
                action: { [self] in await self.removeAccount(account) }
            ))
        }
    }

    private func menuTitle(for account: ConnectedAccount) -> String {
        var base = "\(account.email) · \(l10n.providerName(account.provider))"
        if !account.isActive {
            return "\(base) · \(l10n.sleepingAccount)"
        }
        if account.unreadCount > 0 {
            base += " · \(l10n.unreadCount(account.unreadCount))"
        }
        guard account.syncHealth.status != .ok else { return base }
        // The raw label never appears in the menu: it is a log token, and a
        // menu item is the last place that should ask the user to decode one.
        return "\(base) · \(l10n.healthStatusText(account.syncHealth.status))"
    }

    private func statusColor(for account: ConnectedAccount?) -> Color {
        guard let account, account.isActive else { return .gray }
        switch account.syncHealth.status {
        case .ok: return .green
        case .degraded, .error: return .yellow
        case .needsReconnect, .accountMissing: return .red
        }
    }

    private func syncStatusLabel(for account: ConnectedAccount?) -> String {
        guard let account, account.isActive else { return l10n.syncStatusInactive }
        switch account.syncHealth.status {
        case .ok: return l10n.syncStatusOk
        case .degraded, .error: return l10n.syncStatusDegraded
        case .needsReconnect: return l10n.syncStatusNeedsReconnect
        case .accountMissing: return l10n.syncStatusAccountMissing
        }
    }

    // MARK: - Actions

    /// Switch the server's active sync owner, then mirror the choice locally.
    /// The UI does not move until the server confirms.
    ///
    /// The two steps fail for different reasons and the user needs different
    /// answers for each — "the server refused" is a connection problem you
    /// retry, "the keychain write failed" is a local problem that costs you
    /// the choice next launch. One `catch` around both used to report
    /// "保存账号失败" for a server refusal, which sent the user hunting for a
    /// credential problem they did not have.
    private func switchTo(_ account: ConnectedAccount) async {
        errorCenter.dismiss()
        do {
            try await directory.activate(account)
        } catch {
            errorCenter.report(.init(
                severity: .error,
                title: l10n.activateAccountFailed + error.lagoonUIMessage,
                detail: l10n.activateAccountFailedDetail,
                actionLabel: l10n.retry,
                action: { [self] in await self.switchTo(account) }
            ))
            return
        }
        do {
            try await accounts.set(accountId: account.id)
        } catch {
            errorCenter.report(.init(
                severity: .error,
                title: l10n.saveAccountFailed + error.lagoonUIMessage,
                detail: l10n.saveAccountFailedDetail,
                actionLabel: l10n.retry,
                action: { [self] in await self.switchTo(account) }
            ))
        }
    }

    private func retrySync() async {
        do {
            try await api.requestSync()
            await directory.refresh()
        } catch {
            errorCenter.report(.init(
                severity: .error,
                title: l10n.syncFailed + error.lagoonUIMessage,
                detail: l10n.syncFailedDetail,
                actionLabel: l10n.retry,
                action: { [self] in await self.retrySync() }
            ))
        }
    }

    /// "Add account" and "Reconnect" both open the connect sheet. The
    /// stored account id is deliberately left in place: clearing it here
    /// would unmount RootView before the user submits any credentials
    /// and strand them with no way back. The sheet's Cancel (shown
    /// while an account id exists) is the exit, and the success paths
    /// call `accounts.set(accountId:)` themselves.
    private func addAccount() {
        errorCenter.dismiss()
        connectPrefillEmail = nil
        showConnect = true
    }

    private func reconnect() {
        errorCenter.dismiss()
        connectPrefillEmail = directory.active?.email
        showConnect = true
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // Deliberately NOT `.navigation`. On macOS that placement is where the
        // system puts the back/forward buttons for a pushed NavigationStack,
        // and this window has one: opening a message inserts a back button
        // into that exact region. Parking the account menu and the surface
        // picker there put three controls in one ~117pt slot, and the back
        // button — the one control the user cannot reach any other way — was
        // the one that lost. `.automatic` lets AppKit place these app-level
        // controls outside the navigation region, so the back button keeps
        // its own space.
        ToolbarItem(placement: .automatic) {
            accountMenu
        }
        ToolbarItem(placement: .automatic) {
            // Bound through `go(to:)` rather than to a stored surface: the
            // picker shows which *surface* is up, and writing the surface
            // directly is exactly the assignment that used to be able to
            // disagree with the sidebar's destination.
            Picker(l10n.surface, selection: Binding(
                get: { surface },
                set: { go(to: $0) }
            )) {
                ForEach(Surface.allCases) { item in
                    Text(item == .briefing ? l10n.briefing : l10n.allMessages).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .accessibilityLabel(l10n.surface)
            .help(l10n.surfaceHelp)
        }
        // Overflow order, most-protected first: compose and search are
        // primaryAction (last to disappear); the language picker lives in
        // the ⋯ menu because it is touched once per install, not per triage.
        ToolbarItem(placement: .primaryAction) {
            Button { showCompose = true } label: {
                Label(l10n.newMessage, systemImage: "square.and.pencil")
            }
            .disabled(accounts.accountId == nil)
            .help(l10n.newMessageHelp)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { openSearch() } label: {
                Label(l10n.search, systemImage: "magnifyingglass")
            }
            .help(l10n.shortcutSearch)
        }
        ToolbarItemGroup(placement: .automatic) {
            Menu {
                Button(l10n.budgetThisMonth) { Task { @MainActor in showUsage = true } }
                Button(l10n.aiSettingsTitle) { Task { @MainActor in showAISettings = true } }
                // First in the menu: the advice queue is the surface this app
                // exists for, and burying it under settings would hide the
                // product behind its own configuration.
                Button(l10n.adviceTitle) { Task { @MainActor in showAdvice = true } }
                // Right after the advice queue: the advice queue is what the
                // AI suggests, and this is what the user set. They belong
                // next to each other, and the reminder list has to be
                // reachable — a reminder you cannot find again is not a
                // reminder.
                Button(l10n.reminderTitle) { Task { @MainActor in showReminders = true } }
                Button(l10n.actionHistory) { Task { @MainActor in showActionHistory = true } }
                // 发件人排行: the one question a per-message classifier cannot
                // answer — who writes the most. Placed next to the advice queue
                // because both are "look before you act", not settings.
                Button(l10n.senderRankingTitle) { Task { @MainActor in showSenderRanking = true } }
                Divider()
                // The toggle reads the current value via `SoundEffects.isEnabled`.
                // Using `Toggle` (not a Button) makes the checkmark reflect the
                // live state and gives the user a clear off affordance.
                Toggle(l10n.soundEnabled, isOn: Binding(
                    get: { SoundEffects.isEnabled },
                    set: { SoundEffects.isEnabled = $0 }
                ))
                .help(l10n.soundEnabledHelp)
                Divider()
                Picker(l10n.languageLabel, selection: $languageTag) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language.rawValue)
                    }
                }
                .accessibilityLabel(l10n.languageLabel)
                Divider()
                Button(l10n.aboutTitle) { showAbout = true }
            } label: {
                Label(l10n.moreActions, systemImage: "ellipsis.circle")
            }
            .help(l10n.moreActions)
        }
    }
}
