import SwiftUI
import LagoonKit

/// Top-level surface for a connected account. Owns the account menu, the sync
/// health banner, the AI action undo controller and the language picker.
/// Surfaces global shortcuts and a usage indicator.
struct RootView: View {
    @EnvironmentObject private var accounts: AccountStore
    @StateObject private var directory = DirectoryStore()
    @State private var surface: Surface = .briefing
    @AppStorage(LanguagePreference.defaultsKey) private var languageTag = AppLanguage.zhHans.rawValue
    @StateObject private var undo = UndoController()
    @State private var showSearch = false
    @State private var showUsage = false
    @State private var showActionHistory = false
    @State private var showCompose = false
    @State private var showConnect = false
    /// Seeded by the "Reconnect" banner so the QQ form comes up pre-filled;
    /// "Add account" deliberately leaves it nil.
    @State private var connectPrefillEmail: String?
    @State private var switchError: String?
    @State private var recoveredNotice: String?
    @State private var composeNotice: String?
    @State private var composeNoticeDismiss: Task<Void, Never>?
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
            banner
            Group {
                switch surface {
                case .briefing:
                    BriefingFeedView(onShowAllMessages: { surface = .allMessages })
                case .allMessages:
                    MessageListView(onShowBriefing: { surface = .briefing })
                }
            }
            .id(accounts.accountId)
        }
        .environment(\.l10n, l10n)
        .environmentObject(undo)
        // Views gate verbs (archive) on the active account's negotiated
        // capabilities, so the directory must be reachable from the feed.
        .environmentObject(directory)
        .toolbar { toolbar }
        .sheet(isPresented: $showSearch) {
            SearchSheet()
        }
        .sheet(isPresented: $showUsage) {
            UsageSheet()
        }
        .sheet(isPresented: $showActionHistory) {
            ActionHistorySheet()
        }
        .sheet(isPresented: $showCompose) {
            if let accountId = accounts.accountId {
                NewMessageSheet(accountId: accountId) { _ in
                    showComposeNotice()
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
        // Binding the environment store (not a throwaway one): UndoController
        // holds it weakly, so the real owner must be the one bound.
        .onAppear { undo.bind(accounts) }
        // The directory is the account list + health source; poll it while the
        // window is open (the server writes health from its sync loop).
        .task {
            while !Task.isCancelled {
                await directory.refresh()
                do {
                    try await Task.sleep(for: DirectoryStore.refreshInterval)
                } catch {
                    return
                }
            }
        }
        .onChange(of: directory.active?.syncHealth.status) { old, new in
            guard let old, old != .ok, new == .ok else { return }
            recoveredNotice = l10n.syncRecovered
            Task {
                try? await Task.sleep(for: .seconds(4))
                recoveredNotice = nil
            }
        }
        .onChange(of: directory.active?.id) { _, activeId in
            do {
                if let activeId {
                    if accounts.accountId != activeId {
                        try accounts.set(accountId: activeId)
                    }
                } else if accounts.accountId != nil {
                    try accounts.clear()
                }
            } catch {
                switchError = l10n.saveAccountFailed + error.lagoonUIMessage
            }
        }
        .background {
            Button(l10n.undoLastAction) { Task { await undo.undoLatest() } }
                .keyboardShortcut("z", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Sync health banner

    @ViewBuilder
    private var banner: some View {
        if let undoError = undo.errorMessage {
            healthRow(
                text: undoError,
                color: .red,
                action: (l10n.dismiss, { undo.clearError() })
            )
        } else if let recoveredNotice {
            healthRow(
                text: recoveredNotice,
                color: .green,
                systemImage: "checkmark.circle.fill",
                action: nil
            )
        } else if let switchError {
            healthRow(
                text: switchError,
                color: .red,
                action: nil
            )
        } else if let composeNotice {
            healthRow(
                text: composeNotice,
                color: .green,
                systemImage: "paperplane.fill",
                action: nil
            )
        } else if let loadError = directory.loadError {
            healthRow(
                text: loadError,
                color: .red,
                action: (l10n.retry, { Task { await directory.refresh() } })
            )
        } else if let active = directory.active, active.syncHealth.status != .ok {
            switch active.syncHealth.status {
            case .needsReconnect:
                healthRow(
                    text: l10n.healthNeedsReconnect,
                    color: .red,
                    action: (l10n.reconnect, { reconnect() })
                )
            case .degraded:
                healthRow(
                    text: l10n.healthDegraded + (active.syncHealth.lastError ?? l10n.unknownError),
                    color: .orange,
                    action: (l10n.retry, { Task { await retrySync() } })
                )
            case .error:
                healthRow(
                    text: l10n.healthError + (active.syncHealth.lastError ?? l10n.unknownError),
                    color: .orange,
                    action: (l10n.retry, { Task { await retrySync() } })
                )
            case .ok:
                EmptyView()
            }
        }
    }

    private func healthRow(
        text: String,
        color: Color,
        systemImage: String = "exclamationmark.triangle.fill",
        action: (String, () -> Void)?
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
            Text(text)
                .font(.caption)
            Spacer()
            if let action {
                Button(action.0) { action.1() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(color.opacity(0.12))
    }

    // MARK: - Account menu

    @ViewBuilder
    private var accountMenu: some View {
        Menu {
            ForEach(directory.accounts) { account in
                Button {
                    Task { await switchTo(account) }
                } label: {
                    Text(menuTitle(for: account))
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
                    .fill(statusColor(directory.active?.syncHealth.status))
                    .frame(width: 8, height: 8)
                Text(directory.active?.email ?? l10n.accountsMenuHelp)
            }
        }
        .help(l10n.accountsMenuHelp)
    }

    private func menuTitle(for account: ConnectedAccount) -> String {
        let base = "\(account.email) · \(l10n.providerName(account.provider))"
        guard account.syncHealth.status != .ok else { return base }
        if let lastError = account.syncHealth.lastError {
            return "\(base) · \(lastError)"
        }
        return "\(base) · \(l10n.healthStatusText(account.syncHealth.status))"
    }

    private func statusColor(_ status: SyncHealth.Status?) -> Color {
        switch status {
        case .ok, .none: return .green
        case .degraded, .error: return .yellow
        case .needsReconnect: return .red
        }
    }

    /// Switch account: make the server's active row authoritative first, then
    /// persist the same id locally. If Keychain fails, roll the server back.
    private func switchTo(_ account: ConnectedAccount) async {
        let previous = directory.accounts.first { $0.id == accounts.accountId }
        do {
            switchError = nil
            try await directory.activate(account)
            try accounts.set(accountId: account.id)
        } catch {
            if let previous, accounts.accountId != account.id {
                try? await directory.activate(previous)
            }
            switchError = l10n.saveAccountFailed + error.lagoonUIMessage
        }
    }

    private func retrySync() async {
        do {
            try await api.requestSync()
            await directory.refresh()
        } catch {
            switchError = l10n.syncFailed + error.lagoonUIMessage
        }
    }

    private func showComposeNotice() {
        composeNoticeDismiss?.cancel()
        composeNotice = l10n.sent
        composeNoticeDismiss = Task {
            do {
                try await Task.sleep(for: .seconds(4))
            } catch {
                return
            }
            composeNotice = nil
        }
    }

    /// "Add account" and "Reconnect" both open the connect sheet. The stored
    /// account id is deliberately left in place: clearing it here would unmount
    /// RootView before the user submits any credentials and strand them with no
    /// way back. The sheet's Cancel (shown while an account id exists) is the
    /// exit, and the success paths call `accounts.set(accountId:)` themselves.
    private func addAccount() {
        switchError = nil
        connectPrefillEmail = nil
        showConnect = true
    }

    private func reconnect() {
        switchError = nil
        // Only QQ re-auth is an in-app form; Gmail reconnect goes through the
        // browser OAuth dance, so leaving the default Gmail tab is correct.
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
            .help(l10n.surfaceHelp)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { showCompose = true } label: {
                Label(l10n.newMessage, systemImage: "square.and.pencil")
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(accounts.accountId == nil)
            .help(l10n.newMessageHelp)
        }
        ToolbarItem(placement: .primaryAction) {
            Picker(l10n.languageLabel, selection: $languageTag) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName).tag(language.rawValue)
                }
            }
            .pickerStyle(.menu)
        }
        ToolbarItemGroup(placement: .automatic) {
            Button { showSearch = true } label: {
                Label(l10n.search, systemImage: "magnifyingglass")
            }
            .keyboardShortcut("f", modifiers: .command)
            .help(l10n.shortcutSearch)
            Menu {
                Button(l10n.budgetThisMonth) { showUsage = true }
                    .keyboardShortcut("b", modifiers: [.command])
                Button(l10n.actionHistory) { showActionHistory = true }
            } label: {
                Label(l10n.moreActions, systemImage: "ellipsis.circle")
            }
            .help(l10n.moreActions)
        }
    }
}
