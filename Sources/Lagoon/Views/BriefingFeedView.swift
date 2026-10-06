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
    @State private var scrollProxy: ScrollViewProxy?
    @State private var selectedMessageId: String? = nil
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
    /// Stamped by every `refresh()` so a slow poll that started before the
    /// user archived a row cannot write the server's pre-archive snapshot
    /// back over the removal. Only the newest generation may commit.
    @State private var refreshGate = RefreshGate()
    /// False when another surface is showing (RootView keeps both alive).
    /// The poll loop sleeps instead of refreshing, and hidden shortcuts
    /// are disabled by the parent — keep-alive without traffic or hotkeys.
    var isVisible: Bool = true

    private let api = APIClient.shared
    private static let refreshInterval: Duration = .seconds(30)
    /// Fast cadence while the feed is empty (fresh connect, backfill still
    /// landing), bounded like the list view's fast poll.
    private static let emptyPollInterval: Duration = .seconds(3)
    private static let maxFastEmptyTicks = 20
    @Environment(\.l10n) private var l10n
    /// Backgrounded windows idle instead of polling — see `sleepForPoll`.
    @Environment(\.scenePhase) private var scenePhase

    /// Same gate as the detail toolbar. Unknown (directory not loaded yet, or a
    /// version-skewed row) reads as allowed: the server is the authority and
    /// answers 409 archive-unavailable when the folder really is missing.
    private var canArchive: Bool {
        directory.active?.capabilities.archiveFolder ?? true
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
                content
            }
            .onAppear { scrollProxy = proxy }
        }
        .background {
            groupJumpShortcuts
            keyboardNavigationShortcuts
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
        MessageSplitLayout(detailId: readerId) {
            sidebar
        } detail: {
            if let remoteId = readerId {
                destination(for: remoteId)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
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
                    self.selectedMessageId = remoteId
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
            // `selectedMessageId`, not on list order, so the list can stay live;
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
            .keyboardShortcut("0", modifiers: .command)
            .help(l10n.showRawListHelp)
            // Refresh is ⌥⌘R so it never collides with ⌘R = reply on the
            // open message. The modifiers are disjoint, so both bindings stay
            // live at once.
            refreshControl
                .keyboardShortcut("r", modifiers: [.command, .option])
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
        List(selection: $selectedMessageId) {
            ForEach(BriefingGroup.allCases) { group in
                let groupItems = items.filter { $0.group == group }
                if !groupItems.isEmpty {
                    Section {
                        if !collapsedGroups.contains(group) {
                            ForEach(groupItems) { item in
                            // No `NavigationLink`: the row is selected, not
                            // pushed. `List(selection:)` writes the tap into
                            // `selectedMessageId`, which drives the split view's
                            // reading pane. A link here would push inside the
                            // sidebar column's implicit stack and hide the list —
                            // the silent failure recorded in
                            // .memory/sheet-is-its-own-navigation-root.
                            BriefingRow(
                                item: item,
                                advice: adviceByRemoteId[item.message.remoteId],
                                showsSnippet: density.showsSnippet,
                                expandedAdviceId: $expandedAdviceId,
                                busyAdviceId: $busyAdviceId,
                                onOpenAdvice: { remoteId in
                                    Task { await reveal(remoteId) }
                                },
                                onDismissAdvice: { record in
                                    Task { await dismissAdvice(record) }
                                }
                            )
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
                                    Button(l10n.archived) { Task { await archiveAndUndo(item) } }
                                        .disabled(!canArchive)
                                    Button(item.group == .pinned ? l10n.unpin : l10n.pin) {
                                        togglePin(item: item)
                                    }
                                    Button(readVerbTitle(item.message, l10n: l10n)) {
                                        Task { await toggleRead(item) }
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
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: items.map(\.message.remoteId))
        .onDeleteCommand { if let id = selectedMessageId { Task { await archiveAndUndo(byId: id) } } }
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

        let current = selectedMessageId.flatMap { id in visible.firstIndex(where: { $0.message.remoteId == id }) } ?? 0

        let next: Int

        switch direction {

        case .up: next = max(0, current - 1)

        case .down: next = min(visible.count - 1, current + 1)

        case .left, .right: return

        @unknown default: return

        }

        let target = visible[next].message.remoteId

        selectedMessageId = target

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
            // No ↩ binding: selection already previews in the reading pane,
            // so an explicit "open" step has nothing left to do. (The cheatsheet
            // `open` row goes with it — a documented key bound nowhere is a
            // ghost the ShortcutSheet tests fail on.)
            // ⌘[ keeps Mail.app's "back" muscle memory, re-pointed at the one
            // thing it can still mean here: deselect, returning the reader pane
            // to its placeholder. No-op with nothing selected.
            Button(l10n.back) {
                selectedMessageId = nil
            }
            .keyboardShortcut("[", modifiers: .command)
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
    /// `selectedMessageId` is the list's own selection and can outlive the row:
    /// a poll that drops the selected message (archived from another client,
    /// or reclassified out of the window) would otherwise leave the pane
    /// rendering a detail view with no header — a blank reader that reads as a
    /// broken app. Guarding here retracts it to the placeholder instead, and is
    /// the split-layout twin of `MessageListView.previewId`.
    private var readerId: String? {
        guard let id = selectedMessageId,
              items.contains(where: { $0.message.remoteId == id })
        else { return nil }
        return id
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

                onAdvanceTo: { next in selectedMessageId = next },

                onDelete: { id in
                    dropItem(id)
                    selectedMessageId = nil
                },

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
        // Animate the section's height collapse so the rows below slide up
        // smoothly. Without `withAnimation` the section just snaps closed
        // and the rows beneath jump.
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            if collapsedGroups.contains(group) { collapsedGroups.remove(group) } else { collapsedGroups.insert(group) }
        }
    }



    private func setRead(remoteId: String, isRead: Bool) {

        guard let index = items.firstIndex(where: { $0.message.remoteId == remoteId }) else { return }

        let item = items[index]

        items[index] = BriefingItem(

            // `MessageHeader.withRead` copies every other field. The
            // hand-rolled constructor this replaced silently dropped
            // `isPinned` (and the RFC threading headers), so flipping the
            // read dot on a pinned mail un-pinned it locally.
            message: item.message.withRead(isRead),

            group: item.group, reasonCode: item.reasonCode

        )

    }



    /// The one way a row leaves the feed. Retiring the in-flight poll is
    /// not optional here: a poll that captured the feed before the archive
    /// lands afterwards and writes the row straight back.
    private func dropItem(_ remoteId: String) {

        refreshGate.invalidate()

        items.removeAll { $0.message.remoteId == remoteId }

    }

    private func handleArchived(id: String, isArchived: Bool) {

        dropItem(id)

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
                items.removeAll { $0.message.remoteId == item.message.remoteId }
            }
            undo.show(UndoItem(
                id: response.actionId,
                message: "\(l10n.unsubscribed) · \(response.publisher)",
                systemImage: "minus.circle",
                undoable: false
            ))
        } catch {
            errorBanner = ErrorBanner(
                severity: .error,
                title: l10n.unsubscribeFailedTitle,
                detail: error.lagoonUIMessage
            )
        }
    }



    private func archiveAndUndo(byId remoteId: String) async {
        invalidatePendingRefresh()
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

            // Wrap the removal in `withAnimation` so the row's
            // `.transition(.move(edge: .leading))` actually fires. Without
            // it the row snaps out of existence — the visual is "poof",
            // not "filed".
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                items.removeAll { $0.message.remoteId == remoteId }
            }
            // Soft metallic "Tink" complements the slide-out — a confirmatory
            // tick at low volume (see `SoundEffects`).
            SoundEffects.archive()

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

            items = response.items
            omittedCount = response.omittedCount
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
            selectedMessageId = remoteId
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
        for i in items.indices where !items[i].message.isRead {
            items[i] = items[i].withRead(true)
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
                    detail: firstError.lagoonUIMessage
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
    /// Whether the row shows its third line (reason or snippet).
    ///
    /// Driven by the shared density preference rather than hardcoded, so the
    /// feed and the raw list pack identically — they are two views of the same
    /// mailbox and a user who sets one dense expects the other to follow.
    let showsSnippet: Bool
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

    @Environment(\.l10n) private var l10n

    var body: some View {

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
