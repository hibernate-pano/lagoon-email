import SwiftUI
import LagoonKit

/// Top-level surface for a connected account. Owns the account menu, the
/// global error banner (via `ErrorCenter.shared`), the AI action undo
/// controller, the language picker, and the sync-health "view details"
/// sheet. Surfaces global shortcuts and a usage indicator.
struct RootView: View {
    @EnvironmentObject private var accounts: AccountStore
    @StateObject private var directory = DirectoryStore()
    @StateObject private var errorCenter = ErrorCenter.shared
    @StateObject private var undo = UndoController()
    @State private var surface: Surface = .briefing
    @AppStorage(LanguagePreference.defaultsKey) private var languageTag = AppLanguage.zhHans.rawValue
    @State private var showSearch = false
    @State private var showUsage = false
    @State private var showActionHistory = false
    @State private var showAutoArchiveRules = false
    @State private var showCompose = false
    @State private var showConnect = false
    @State private var showHealthDetail = false
    @State private var showCommandPalette = false
    @State private var showShortcuts = false
    @State private var showAbout = false
    /// Seeded by the "Reconnect" banner so the QQ form comes up pre-filled;
    /// "Add account" deliberately leaves it nil.
    @State private var connectPrefillEmail: String?
    /// User dismissed the current sync-health banner. Reset on the next
    /// `directory.refresh()` so a fresh poll is allowed to re-surface the
    /// banner if the underlying state is still bad.
    @State private var syncHealthDismissed = false
    /// The health state at the moment of the last `directory.refresh()`;
    /// any transition into `.ok` fires a transient "Sync recovered" banner.
    @State private var lastObservedHealth: SyncHealth.Status?
    private let api = APIClient()

    enum Surface: String, CaseIterable, Identifiable {
        case briefing
        case allMessages
        var id: String { rawValue }
    }

    private var language: AppLanguage { AppLanguage(rawValue: languageTag) ?? .zhHans }
    private var l10n: L10n { L10n(language: language) }

    var body: some View {
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
                BriefingFeedView(isVisible: surface == .briefing, onShowAllMessages: { surface = .allMessages })
                    .opacity(surface == .briefing ? 1 : 0)
                    .disabled(surface != .briefing)
                    .allowsHitTesting(surface == .briefing)
                    .accessibilityHidden(surface != .briefing)
                MessageListView(isVisible: surface == .allMessages, onShowBriefing: { surface = .briefing })
                    .opacity(surface == .allMessages ? 1 : 0)
                    .disabled(surface != .allMessages)
                    .allowsHitTesting(surface == .allMessages)
                    .accessibilityHidden(surface != .allMessages)
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
        .sheet(isPresented: $showSearch) {
            SearchSheet()
        }
        .sheet(isPresented: $showUsage) {
            UsageSheet()
        }
        .sheet(isPresented: $showActionHistory) {
            ActionHistorySheet()
        }
        .sheet(isPresented: $showAutoArchiveRules) {
            AutoArchiveRulesSheet()
        }
        .sheet(isPresented: $showCompose) {
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
        .sheet(isPresented: $showConnect, onDismiss: {
            // A successful connect/reconnect can clear the health banner; refresh
            // the directory immediately instead of waiting up to 30s.
            Task { await directory.refresh() }
        }) {
            ConnectView(prefillEmail: connectPrefillEmail)
        }
        .sheet(isPresented: $showHealthDetail) {
            if let active = directory.active {
                SyncHealthDetailSheet(
                    health: active.syncHealth,
                    capabilities: active.capabilities
                )
            }
        }
        // ⌘K is the power-user fast path; mirrors Things / Linear / Superhuman.
        .sheet(isPresented: $showCommandPalette) {
            CommandPaletteView(
                onNewMessage: { showCompose = true },
                onSearch: { showSearch = true },
                onShowBriefing: { surface = .briefing },
                onShowAllMessages: { surface = .allMessages },
                onShowUsage: { showUsage = true },
                onShowActionHistory: { showActionHistory = true },
                onShowAutoArchiveRules: { showAutoArchiveRules = true },
                onShowShortcuts: { showShortcuts = true },
                onRefresh: {
                    Task { try? await api.requestSync(); await directory.refresh() }
                },
                onToggleSound: { SoundEffects.isEnabled.toggle() }
            )
        }
        .sheet(isPresented: $showShortcuts) {
            ShortcutsSheet()
        }
        .sheet(isPresented: $showAbout) {
            AboutSheet()
        }
        // Binding the environment store (not a throwaway one): UndoController
        // holds it weakly, so the real owner must be the one bound.
        .onAppear {
            undo.bind(accounts)
            lastObservedHealth = directory.active?.syncHealth.status
        }
        // The directory is the account list + health source; poll it while the
        // window is open (the server writes health from its sync loop).
        .task {
            while !Task.isCancelled {
                await directory.refresh()
                syncHealthDismissed = false
                do {
                    try await Task.sleep(for: DirectoryStore.refreshInterval)
                } catch {
                    return
                }
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

    /// First non-nil `ErrorBanner` wins. Six local sources (`undoError`,
    /// sync health, load error) plus the global `errorCenter.banner` race
    /// against each other; this keeps the highest-priority local banner
    /// visible above the global one.
    private var priorityBanner: ErrorBanner? {
        if let banner = undoErrorBanner { return banner }
        if let banner = syncHealthBanner { return banner }
        if let banner = aiStatusBanner { return banner }
        if let banner = loadErrorBanner { return banner }
        return errorCenter.banner
    }

    private func dismissPriorityBanner(_ banner: ErrorBanner) {
        // The undo and sync-health sources own their own dismissal. The
        // global one dismisses through ErrorCenter. The load-error banner
        // is recomputed on the next directory poll, so dismissing is
        // implicitly "until next poll".
        if banner.id == undoErrorBanner?.id {
            undo.clearError()
        } else if banner.id == syncHealthBanner?.id {
            syncHealthDismissed = true
        } else if banner.id == loadErrorBanner?.id {
            syncHealthDismissed = true
        } else {
            errorCenter.dismiss()
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
        // banner for free.
        guard let lastError = directory.loadError else { return nil }
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
        guard let status = directory.aiStatus, status.configured else { return nil }
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
                    .frame(maxWidth: 180, alignment: .leading)
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
        // Only QQ re-auth is an in-app form; Gmail reconnect goes through
        // the browser OAuth dance, so leaving the default Gmail tab is
        // correct.
        let active = directory.active
        connectPrefillEmail = active?.provider == .qq ? active?.email : nil
        showConnect = true
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            accountMenu
        }
        ToolbarItem(placement: .navigation) {
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
                Button(l10n.actionHistory) { Task { @MainActor in showActionHistory = true } }
                Button(l10n.autoArchiveRulesTitle) { Task { @MainActor in showAutoArchiveRules = true } }
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
