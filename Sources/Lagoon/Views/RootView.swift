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
    @State private var surface: Surface = .briefing
    @AppStorage(LanguagePreference.defaultsKey) private var languageTag = AppLanguage.zhHans.rawValue
    @State private var showSearch = false
    @State private var showUsage = false
    @State private var showActionHistory = false
    @State private var showAdvice = false
    @State private var showCompose = false
    @State private var showConnect = false
    @State private var showHealthDetail = false
    @State private var showCommandPalette = false
    @State private var showShortcuts = false
    @State private var showAISettings = false
    @State private var showAbout = false
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
    /// The health state at the moment of the last `directory.refresh()`;
    /// any transition into `.ok` fires a transient "Sync recovered" banner.
    @State private var lastObservedHealth: SyncHealth.Status?
    private let api = APIClient.shared

    enum Surface: String, CaseIterable, Identifiable {
        case briefing
        case allMessages
        var id: String { rawValue }
    }

    private var language: AppLanguage { AppLanguage(rawValue: languageTag) ?? .zhHans }
    private var l10n: L10n { L10n(language: language) }

    // Extracted from `body`: the combined expression sits right at the
    // Swift type-checker's time limit, and any upstream change (e.g. a new
    // ConnectView parameter) tips it over into an unreasonable-time error.
    @ViewBuilder private var briefingSurface: some View {
        BriefingFeedView(isVisible: surface == .briefing, onShowAllMessages: { surface = .allMessages })
            .opacity(surface == .briefing ? 1 : 0)
            .disabled(surface != .briefing)
            .allowsHitTesting(surface == .briefing)
            .accessibilityHidden(surface != .briefing)
    }

    @ViewBuilder private var messagesSurface: some View {
        MessageListView(isVisible: surface == .allMessages, onShowBriefing: { surface = .briefing })
            .opacity(surface == .allMessages ? 1 : 0)
            .disabled(surface != .allMessages)
            .allowsHitTesting(surface == .allMessages)
            .accessibilityHidden(surface != .allMessages)
    }

    // `body` used to be one giant SwiftUI expression that sat right at the
    // type-checker's time limit; adding a ConnectView parameter tipped it
    // over into "unable to type-check in reasonable time". The three computed
    // properties below keep each chain small enough to check quickly.
    private var decorated: some View {
        VStack(spacing: 0) {
            if let banner = priorityBanner {
                NoticeBannerView(banner: banner, onDismiss: { dismissPriorityBanner(banner) })
            }
            // Both surfaces stay alive across switches (ZStack, not a Group
            // switch): scroll position, selection and navigation path survive
            // a ⌘0 round-trip. The hidden surface is inert (no hit testing,
            // no shortcuts, hidden from VoiceOver) and its poller sleeps via
            // `isVisible`, so keep-alive costs no traffic.
            ZStack {
                briefingSurface
                messagesSurface
            }
            .id(accounts.accountId)
        }
        // The global `ErrorCenter` banner — used for failures raised outside
        // the view layer (undo, polling errors, etc.) and for transient
        // confirmations like "Sent" / "Sync recovered".
        .noticeBanner($errorCenter.banner)
        .environment(\.l10n, l10n)
        .environmentObject(undo)
        // Views gate verbs (archive) on the active account's negotiated
        // capabilities, so the directory must be reachable from the feed.
        .environmentObject(directory)
        .toolbar { toolbar }
        // The undo toast lives at the RootView level so it is also visible on
        // the "All messages" surface, not just the Briefing Feed. The
        // time-saved status bar (spec principle #3) shares the bottom inset,
        // under the toast.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                UndoToast(controller: undo)
                TimeSavedBar()
            }
        }
    }

    private var sheetStack: some View {
        decorated
            .sheet(isPresented: $showSearch) {
                SearchSheet()
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
                AISettingsSheet(aiStatus: directory.aiStatus)
            }
            .sheet(isPresented: $showAbout) {
                AboutSheet()
            }
            // Both surfaces stay alive (the Briefing and the raw list are kept
            // mounted so their scroll position and poll loops survive a
            // switch), which means a message revealed from the advice panel
            // would be pushed onto a NavigationStack the user cannot see. The
            // switch has to happen here, where the surface lives.
            .onReceive(NotificationCenter.default.publisher(for: .lagoonRevealMessage)) { _ in
                surface = .briefing
            }
    }

    @ViewBuilder private var composeSheet: some View {
        if let accountId = accounts.accountId {
            NewMessageSheet(accountId: accountId) { _ in
                errorCenter.report(.init(
                    severity: .info,
                    title: l10n.sent,
                    autoDismissAfter: .seconds(4)
                ))
            }
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
            onSearch: { showSearch = true },
            onShowBriefing: { surface = .briefing },
            onShowAllMessages: { surface = .allMessages },
            onShowUsage: { showUsage = true },
            onShowActionHistory: { showActionHistory = true },
            onShowAdvice: { showAdvice = true },
            onShowShortcuts: { showShortcuts = true },
            onShowAISettings: { showAISettings = true },
            onRefresh: {
                Task { try? await api.requestSync(); await directory.refresh() }
            },
            onToggleSound: { SoundEffects.isEnabled.toggle() }
        )
    }

    var body: some View {
        sheetStack
        // Binding the environment store (not a throwaway one): UndoController
        // holds it weakly, so the real owner must be the one bound.
        .onAppear {
            undo.bind(accounts)
            lastObservedHealth = directory.active?.syncHealth.status
        }
        // The directory is the account list + health source; poll it while the
        // window is open (the server writes health from its sync loop).
        .task {
            // Immediate first pass. The directory is the only source of the
            // account list, sync health, AI status and load error, so sleeping
            // before the first refresh would leave the whole window empty for
            // 30s on every launch.
            await directory.refresh()
            while !Task.isCancelled {
                guard await sleepForPoll(DirectoryStore.refreshInterval) else { return }
                guard shouldPoll(isVisible: true, scenePhase: scenePhase) else { continue }
                await directory.refresh()
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
                    severity: .info,
                    title: l10n.syncRecovered,
                    autoDismissAfter: .seconds(4)
                ))
            }
            lastObservedHealth = new
        }
        .onChange(of: directory.loadError) { _, newError in
            guard let newError else { return }
            errorCenter.report(.init(
                severity: .error,
                title: newError,
                actionLabel: l10n.retry,
                action: { [weak directory = directory] in
                    await directory?.refresh()
                }
            ))
        }
        // The server owns the active account. Keep the Keychain mirror aligned
        // so the next launch opens the same mailbox.
        .onChange(of: directory.active?.id) { _, resolved in
            guard let resolved, accounts.accountId != resolved else { return }
            do {
                try accounts.set(accountId: resolved)
            } catch {
                errorCenter.report(.init(
                    severity: .error,
                    title: l10n.saveAccountFailed + error.lagoonUIMessage
                ))
            }
        }
        .background {
            Button(l10n.undoLastAction) { Task { await undo.undoLatest() } }
                .keyboardShortcut("z", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .focusable(false)
                .accessibilityHidden(true)
            // ⌘K — command palette, the power-user fast path
            Button(l10n.commandPalette) { showCommandPalette = true }
                .keyboardShortcut("k", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .focusable(false)
                .accessibilityHidden(true)
            // ⌘/ — keyboard shortcuts cheatsheet
            Button(l10n.commandPalette) { showShortcuts = true }
                .keyboardShortcut("/", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .focusable(false)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Priority banner chain

    /// First non-nil `ErrorBanner` wins. Four local sources (`undoError`,
    /// sync health, AI status, load error) race against each other; this
    /// keeps the highest-priority local banner visible above the global one.
    ///
    /// The global `errorCenter.banner` is deliberately absent: it is already
    /// rendered by the `.noticeBanner($errorCenter.banner)` modifier on the
    /// same stack, so returning it here drew the same banner twice.
    private var priorityBanner: ErrorBanner? {
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

    private var undoErrorBanner: ErrorBanner? {
        guard let text = undo.errorMessage else { return nil }
        return ErrorBanner(
            severity: .error,
            title: text,
            actionLabel: l10n.dismiss,
            action: { await undo.clearError() }
        )
    }

    private var loadErrorBanner: ErrorBanner? {
        // Mirror what the old RootView did: only show if the directory
        // poll actually failed. `directory.loadError` is set/cleared by
        // `DirectoryStore.refresh()` so a successful poll also clears this
        // banner for free; the ✕ clears it without waiting for that poll.
        guard !loadErrorDismissed, let lastError = directory.loadError else { return nil }
        return ErrorBanner(
            severity: .error,
            title: lastError,
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
        let lastError = active.syncHealth.lastError ?? l10n.unknownError
        switch active.syncHealth.status {
        case .needsReconnect:
            return ErrorBanner(
                severity: .error,
                title: l10n.healthNeedsReconnect,
                detail: l10n.healthReconnectDetail(lastError),
                actionLabel: l10n.reconnect,
                action: { [self] in await self.reconnect() }
            )
        case .degraded:
            return ErrorBanner(
                severity: .warning,
                title: l10n.healthDegradedDetail(lastError),
                actionLabel: l10n.retry,
                action: { [self] in await self.retrySync() }
            )
        case .error:
            return ErrorBanner(
                severity: .error,
                title: l10n.healthErrorDetail(lastError),
                actionLabel: l10n.retry,
                action: { [self] in await self.retrySync() }
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

    private func menuTitle(for account: ConnectedAccount) -> String {
        var base = "\(account.email) · \(l10n.providerName(account.provider))"
        if !account.isActive {
            return "\(base) · \(l10n.sleepingAccount)"
        }
        if account.unreadCount > 0 {
            base += " · \(l10n.unreadCount(account.unreadCount))"
        }
        guard account.syncHealth.status != .ok else { return base }
        if let lastError = account.syncHealth.lastError {
            return "\(base) · \(lastError)"
        }
        return "\(base) · \(l10n.healthStatusText(account.syncHealth.status))"
    }

    private func statusColor(for account: ConnectedAccount?) -> Color {
        guard let account, account.isActive else { return .gray }
        switch account.syncHealth.status {
        case .ok: return .green
        case .degraded, .error: return .yellow
        case .needsReconnect: return .red
        }
    }

    private func syncStatusLabel(for account: ConnectedAccount?) -> String {
        guard let account, account.isActive else { return l10n.syncStatusInactive }
        switch account.syncHealth.status {
        case .ok: return l10n.syncStatusOk
        case .degraded, .error: return l10n.syncStatusDegraded
        case .needsReconnect: return l10n.syncStatusNeedsReconnect
        }
    }

    // MARK: - Actions

    /// Switch the server's active sync owner, then mirror the choice locally.
    /// The UI does not move until the server confirms.
    private func switchTo(_ account: ConnectedAccount) async {
        errorCenter.dismiss()
        do {
            try await directory.activate(account)
            try accounts.set(accountId: account.id)
        } catch {
            errorCenter.report(.init(
                severity: .error,
                title: l10n.saveAccountFailed + error.lagoonUIMessage
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
            Picker(l10n.surface, selection: $surface) {
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
            .keyboardShortcut("n", modifiers: .command)
            .disabled(accounts.accountId == nil)
            .help(l10n.newMessageHelp)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { showSearch = true } label: {
                Label(l10n.search, systemImage: "magnifyingglass")
            }
            .keyboardShortcut("f", modifiers: .command)
            .help(l10n.shortcutSearch)
        }
        ToolbarItemGroup(placement: .automatic) {
            Menu {
                Button(l10n.budgetThisMonth) { Task { @MainActor in showUsage = true } }
                    .keyboardShortcut("b", modifiers: [.command])
                Button(l10n.aiSettingsTitle) { Task { @MainActor in showAISettings = true } }
                // First in the menu: the advice queue is the surface this app
                // exists for, and burying it under settings would hide the
                // product behind its own configuration.
                Button(l10n.adviceTitle) { Task { @MainActor in showAdvice = true } }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Button(l10n.actionHistory) { Task { @MainActor in showActionHistory = true } }
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
