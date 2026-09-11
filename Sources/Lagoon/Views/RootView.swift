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
    @State private var switchError: String?

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
        }
        .environment(\.l10n, l10n)
        .environmentObject(undo)
        .toolbar { toolbar }
        .sheet(isPresented: $showSearch) {
            SearchSheet()
        }
        .sheet(isPresented: $showUsage) {
            UsageSheet()
        }
        // Binding the environment store (not a throwaway one): UndoController
        // holds it weakly, so the real owner must be the one bound.
        .onAppear { undo.bind(accounts) }
        // The directory is the account list + health source; poll it while the
        // window is open (the server writes health from its sync loop).
        .task {
            while !Task.isCancelled {
                await directory.refresh()
                try? await Task.sleep(for: DirectoryStore.refreshInterval)
            }
        }
    }

    // MARK: - Sync health banner

    @ViewBuilder
    private var banner: some View {
        if let switchError {
            healthRow(
                text: switchError,
                color: .red,
                action: nil
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
                    action: nil
                )
            case .error:
                healthRow(
                    text: l10n.healthError + (active.syncHealth.lastError ?? l10n.unknownError),
                    color: .orange,
                    action: nil
                )
            case .ok:
                EmptyView()
            }
        }
    }

    private func healthRow(text: String, color: Color, action: (String, () -> Void)?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
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

    /// Switch account: persist the local id first (so the feed re-queries the
    /// new account) and then flip it server-side.
    private func switchTo(_ account: ConnectedAccount) async {
        do {
            try accounts.set(accountId: account.id)
            switchError = nil
            await directory.activate(account)
        } catch {
            switchError = l10n.saveAccountFailed + error.lagoonUIMessage
        }
    }

    /// "Add account" and "Reconnect" both return to the connect surface; the
    /// difference is only whether credentials still exist server-side.
    private func addAccount() {
        do {
            try accounts.clear()
        } catch {
            switchError = l10n.keychainError + error.lagoonUIMessage
        }
    }

    private func reconnect() {
        addAccount()
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
            Button { showUsage = true } label: {
                Label(l10n.budgetThisMonth, systemImage: "chart.bar")
            }
            .keyboardShortcut("b", modifiers: [.command])
            .help(l10n.budgetThisMonth)
        }
    }
}
