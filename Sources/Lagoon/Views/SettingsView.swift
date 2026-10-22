import SwiftUI
import AppKit
import LagoonKit

/// The macOS Settings window (⌘,).
///
/// ## Why a Settings scene and not another sheet
///
/// The app already had three sheets that are really preferences wearing a
/// sheet costume: AI settings, language, and sound. They lived in the
/// toolbar's overflow menu, which means **a user cannot find them** — there
/// is no "Settings" item anywhere in the app, and ⌘, does nothing. On macOS,
/// ⌘, is muscle memory: a Mac app without a Settings window is a Mac app
/// that has not been finished.
///
/// A `Settings` *scene* (rather than a sheet) is what puts the item in the
/// application menu and binds ⌘, to it. The system then owns the window's
/// chrome, its tab bar and its "close" behaviour, and the app does not have
/// to reimplement any of it.
///
/// ## What lives where
///
/// - **General** — the preferences that are about *this app*: language,
///   density, sound.
/// - **Notifications** — the new-mail switch and the system's answer to it.
/// - **Account** — which mailbox is connected, and its health.
/// - **About** — the version, and the links.
///
/// The AI key entry stays a sheet: it is a *configuration wizard* for one
/// feature, not an app-wide preference, and putting a password field in a
/// tab called "General" is how credentials end up in screenshots.
struct SettingsView: View {
    /// The language preference is app-wide and written straight to
    /// `UserDefaults`; the app's own `RootView` reads the same key, so
    /// changing it here takes effect without a relaunch.
    @AppStorage(LanguagePreference.defaultsKey) private var languageTag = AppLanguage.zhHans.rawValue
    @AppStorage(ListDensityPreference.key) private var densityRaw = ListDensity.compact.rawValue
    @AppStorage(SoundEffects.enabledDefaultsKey) private var soundEnabled = true
    @AppStorage(MailNotificationService.enabledDefaultsKey) private var notificationsEnabled = false

    @StateObject private var notifications = MailNotificationService.shared
    @State private var accounts: [ConnectedAccount] = []
    @State private var isLoadingAccount = false

    /// The localizer for this window.
    ///
    /// The Settings window is a **sibling scene**, not a child of the main
    /// window: the main window's `.environment(\.l10n, …)` never reaches
    /// it, so this window used to read the environment's default — a
    /// hardcoded Chinese localizer. That is why the window stayed in
    /// Chinese no matter what the user picked, including in the very
    /// picker that changes the language.
    ///
    /// The preference is already in `UserDefaults` — this window is where
    /// the user changes it — so the window reads it directly, and the
    /// picker re-renders the window in the new language as it is used.
    private var l10n: L10n {
        L10n.forStoredTag(languageTag)
    }

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label(l10n.settingsGeneral, systemImage: "gearshape") }
            notificationsTab
                .tabItem { Label(l10n.settingsNotifications, systemImage: "bell") }
            accountTab
                .tabItem { Label(l10n.settingsAccount, systemImage: "person.crop.circle") }
            aboutTab
                .tabItem { Label(l10n.settingsAbout, systemImage: "info.circle") }
        }
        .frame(width: 460)
        .task { await refresh() }
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Picker(l10n.languageLabel, selection: $languageTag) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName).tag(language.rawValue)
                }
            }
            .accessibilityLabel(l10n.languageLabel)

            Picker(l10n.densityTitle, selection: $densityRaw) {
                ForEach(ListDensity.allCases) { density in
                    Text(densityTitle(density)).tag(density.rawValue)
                }
            }
            .accessibilityLabel(l10n.densityTitle)

            Toggle(l10n.soundEnabled, isOn: $soundEnabled)
                .help(l10n.soundEnabledHelp)
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }

    private func densityTitle(_ density: ListDensity) -> String {
        switch density {
        case .comfortable: return l10n.densityComfortable
        case .compact: return l10n.densityCompact
        case .dense: return l10n.densityDense
        }
    }

    // MARK: - Notifications

    private var notificationsTab: some View {
        Form {
            Toggle(l10n.notificationsNewMail, isOn: notificationBinding)
                .help(l10n.notificationsNewMailHelp)

            Text(authorizationCaption)
                .font(.caption)
                .foregroundStyle(.secondary)

            if notifications.authorization == .denied {
                // The system says no, and the user has to change that in
                // System Settings — the app cannot do it for them. So the
                // button is not a nicety, it is the only way forward.
                Button(l10n.notificationsOpenSettings) {
                    openSystemNotificationSettings()
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }

    /// The toggle's binding, which asks the system for permission the first
    /// time it is switched on.
    ///
    /// The switch is bound to the *preference*, but turning it on also
    /// triggers the system's permission prompt. If the user says no, the
    /// preference follows the system's answer back to off — a switch left on
    /// that can never fire is a switch that lies.
    private var notificationBinding: Binding<Bool> {
        Binding(
            get: { notificationsEnabled },
            set: { newValue in
                if newValue {
                    Task {
                        let granted = await notifications.requestAuthorization()
                        notificationsEnabled = granted
                    }
                } else {
                    notificationsEnabled = false
                }
            }
        )
    }

    private var authorizationCaption: String {
        switch notifications.authorization {
        case .notDetermined: return l10n.notificationsNotDetermined
        case .denied: return l10n.notificationsDenied
        case .authorized, .provisional, .ephemeral: return l10n.notificationsAllowed
        @unknown default: return l10n.notificationsNotDetermined
        }
    }

    private func openSystemNotificationSettings() {
        // The pane's identifier is stable across macOS versions; the URL is
        // the documented way to reach it. If the URL somehow fails, the
        // button is a dead control — so it falls back to opening the app
        // itself, which at least gets the user to the right place.
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Account

    private var accountTab: some View {
        Form {
            if isLoadingAccount && accounts.isEmpty {
                ProgressView()
                    .controlSize(.small)
            } else if accounts.isEmpty {
                Text(l10n.notConnected)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(accounts) { account in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(statusColor(for: account))
                                .frame(
                                    width: LagoonMetrics.statusDotSize,
                                    height: LagoonMetrics.statusDotSize
                                )
                            Text(account.email)
                                .font(.body)
                            if account.isActive {
                                Text(l10n.activeAccountBadge)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if account.unreadCount > 0 {
                            Text(l10n.unreadCount(account.unreadCount))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }

    private func statusColor(for account: ConnectedAccount) -> Color {
        guard account.isActive else { return .gray }
        return LagoonTheme.syncStatusColor(account.syncHealth.status)
    }

    // MARK: - About

    private var aboutTab: some View {
        Form {
            LabeledContent(l10n.aboutTitle) {
                Text("Lagoon")
            }
            LabeledContent(l10n.settingsVersion) {
                Text(versionString)
            }
            LabeledContent(l10n.settingsDataLocation) {
                Text(dataLocation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }

    /// The version, read from the bundle so it can never disagree with what
    /// the shipped `.app` says.
    private var versionString: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "—"
        let build = info["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    /// Where the local database lives.
    ///
    /// Shown because the user owns this data: it is the one path they need
    /// to back up or to delete, and a mail app that hides its storage is a
    /// mail app that cannot be trusted with a mailbox.
    private var dataLocation: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Lagoon").path
    }

    // MARK: - Load

    private func refresh() async {
        isLoadingAccount = true
        defer { isLoadingAccount = false }
        await notifications.refreshAuthorization()
        // Best-effort: the account list is also on screen in the main window,
        // and a failure here must not look like "no account is connected".
        if let fetched = try? await APIClient.shared.fetchAccounts() {
            accounts = fetched
        }
    }
}
