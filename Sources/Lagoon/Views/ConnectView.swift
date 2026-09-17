import SwiftUI
import AppKit
import LagoonKit

/// First-run surface: pick a provider and connect.
///
/// Gmail goes through the browser OAuth dance (the app is a bare SwiftPM
/// executable with no `Info.plist`, so it cannot register a URL scheme; the
/// server deep-links nothing and the view polls `GET /api/accounts` instead).
/// QQ Mail is an in-app form: address + authorization code, checked by the
/// server before it stores anything.
struct ConnectView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case gmail
        case qq
        var id: String { rawValue }
    }

    @EnvironmentObject var accounts: AccountStore
    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode = .qq
    @State private var qqEmail = ""
    @State private var qqAuthCode = ""
    @State private var isConnecting = false
    /// The in-flight QQ connect/adopt task, so Cancel and `.onDisappear` can
    /// actually stop the request instead of letting it complete after dismissal.
    @State private var connectTask: Task<Void, Never>?
    @State private var errorMessage: String?
    /// Non-nil after a 409 `account-exists`: render a neutral prompt plus a
    /// "use this account" action instead of a dead-end red error.
    @State private var accountExistsEmail: String?
    @FocusState private var focusedField: QQField?

    private enum QQField: Hashable {
        case email
        case authCode
    }

    /// Pre-filled by RootView's "Reconnect" banner; selecting the QQ tab and
    /// filling the address is the whole point of that entry path.
    private let prefillEmail: String?

    init(prefillEmail: String? = nil) {
        self.prefillEmail = prefillEmail
        _qqEmail = State(initialValue: prefillEmail ?? "")
        _mode = State(initialValue: .qq)
    }

    // Gmail polling state.
    @State private var isPolling = false
    /// Bumped on every Connect click so `.task(id:)` restarts the poll loop
    /// with a fresh 3-minute deadline.
    @State private var connectAttempt = 0

    private let api = APIClient()
    private static let pollInterval: Duration = .seconds(2)
    private static let pollTimeout: Duration = .seconds(180)

    var body: some View {
        VStack(spacing: 16) {
            Text("Lagoon")
                .font(.largeTitle)
                .bold()
            Text(l10n.connectPrompt)
                .foregroundStyle(.secondary)

            Picker(l10n.connectMethod, selection: $mode) {
                Text("Gmail").tag(Mode.gmail)
                Text(l10n.connectQQTab).tag(Mode.qq)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 280)
            .onChange(of: mode) { _, newMode in
                errorMessage = nil
                accountExistsEmail = nil
                if newMode == .qq {
                    focusedField = qqEmail.isEmpty ? .email : .authCode
                }
            }

            switch mode {
            case .gmail: gmailSection
            case .qq: qqSection
            }

            if let accountExistsEmail {
                VStack(spacing: 8) {
                    Text(l10n.qqAccountExists)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                    Button(l10n.useThisAccount) {
                        connectTask = Task { await useExistingAccount(email: accountExistsEmail) }
                    }
                }
            } else if let displayedError {
                Text(displayedError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            if accounts.accountId != nil {
                Button(l10n.cancel) {
                    connectTask?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(40)
        .frame(minWidth: 460, maxWidth: 460, minHeight: 420)
        // Polls while the view is visible; SwiftUI cancels the task on disappear.
        .task(id: connectAttempt) { await pollForConnection() }
        .onAppear {
            if mode == .qq {
                focusedField = qqEmail.isEmpty ? .email : .authCode
            }
        }
        // A sheet can be closed while the probe is still in flight; without
        // this the request keeps running and can adopt an account the user
        // backed out of.
        .onDisappear { connectTask?.cancel() }
    }

    @ViewBuilder
    private var gmailSection: some View {
        Button {
            errorMessage = nil
            NSWorkspace.shared.open(api.oauthStartURL)
            connectAttempt += 1
        } label: {
            HStack(spacing: 6) {
                if isPolling && connectAttempt > 0 {
                    ProgressView().controlSize(.small)
                }
                Text(l10n.connectGmail)
            }
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .disabled(isPolling && connectAttempt > 0)

        if isPolling && connectAttempt > 0 {
            // The button carries the spinner; a second one here just competes.
            Text(l10n.waitingForApproval)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text(l10n.afterApproval)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var qqSection: some View {
        Text(l10n.connectQQTitle)
            .font(.headline)
        VStack(alignment: .leading, spacing: 4) {
            Text(l10n.qqEmailPlaceholder)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(l10n.qqEmailPlaceholder, text: $qqEmail)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .email)
        }
        .frame(maxWidth: 320)
        VStack(alignment: .leading, spacing: 4) {
            Text(l10n.qqAuthCodePlaceholder)
                .font(.caption)
                .foregroundStyle(.secondary)
            SecureField(l10n.qqAuthCodePlaceholder, text: $qqAuthCode)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .authCode)
        }
        .frame(maxWidth: 320)
        Button {
            connectTask = Task { await connectQQ() }
        } label: {
            // Keep the label text alongside the spinner: replacing it wholesale
            // left VoiceOver announcing only "button".
            HStack(spacing: 6) {
                if isConnecting {
                    ProgressView().controlSize(.small)
                }
                Text(l10n.qqConnectButton)
            }
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .disabled(isConnecting)
        .keyboardShortcut(.defaultAction)
        .accessibilityLabel(l10n.qqConnectButton)
        Text(l10n.qqHelp)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 360)
            .multilineTextAlignment(.leading)
    }

    private var displayedError: String? {
        errorMessage ?? accounts.loadError
    }

    /// QQ connect: the auth code goes to the server, which probes the mailbox
    /// before storing anything. The server's `{"error":"…"}` envelope is
    /// preferred over the bare status; the code itself is never echoed into the
    /// UI or logs.
    private func connectQQ() async {
        let email = qqEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        // Browser "copy" often carries a trailing space/newline; an untrimmed
        // code fails auth and the old copy wrongly told the user to regenerate.
        let authCode = qqAuthCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !authCode.isEmpty else {
            errorMessage = l10n.qqMissingFields
            accountExistsEmail = nil
            focusedField = email.isEmpty ? .email : .authCode
            return
        }
        isConnecting = true
        errorMessage = nil
        accountExistsEmail = nil
        defer { isConnecting = false }
        do {
            let account = try await api.connectQQ(email: email, authCode: authCode)
            // The user may have cancelled while the probe was in flight; do not
            // adopt the account they backed out of.
            if Task.isCancelled { return }
            try accounts.set(accountId: account.id)
            dismiss()
        } catch let apiError as APIError {
            applyConnectFailure(apiError, email: email)
        } catch let urlError as URLError {
            switch urlError.code {
            case .cancelled:
                // User-initiated cancellation: no error copy at all.
                return
            case .timedOut:
                errorMessage = l10n.serverTimedOut
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet:
                errorMessage = l10n.serverUnreachable
            default:
                errorMessage = l10n.connectFailed + urlError.localizedDescription
            }
        } catch {
            errorMessage = l10n.connectFailed + error.lagoonUIMessage
        }
    }

    /// Maps the typed API failure to view state. The copy itself comes from the
    /// pure `failureCopy` helper so it can be unit-tested without a View.
    private func applyConnectFailure(_ error: APIError, email: String) {
        guard case .badStatus(let status, _) = error else {
            errorMessage = l10n.connectFailed + error.localizedDescription
            return
        }
        if let copy = Self.failureCopy(code: error.serverErrorCode, status: status) {
            errorMessage = copy
        } else {
            // nil means the server says the account already exists: offer the
            // neutral prompt + "use this account" action instead of a red error.
            errorMessage = nil
            accountExistsEmail = email
        }
    }

    /// Pure mapping from the server error code (preferred) or the bare HTTP
    /// status to user-facing copy. `nil` means `account-exists`, which the view
    /// renders as the neutral prompt. Unknown codes/statuses fall back to the
    /// generic message and never splice the server body into the copy.
    static func failureCopy(code: String?, status: Int) -> String? {
        switch code ?? statusFallbackCode(status) {
        case "account-exists":
            return nil
        case "imap-auth-failed":
            return L10n.current.qqAuthFailed
        case "imap-unreachable":
            return L10n.current.qqUnreachable
        case "provider-not-configured":
            return L10n.current.qqProviderNotConfigured
        case "internal-error":
            return L10n.current.qqInternalError
        case "missing-field":
            return L10n.current.qqMissingFields
        default:
            return L10n.current.connectFailed + L10n.current.httpStatus(status)
        }
    }

    /// Fallback when the body is not the small error envelope. The connect
    /// route only ever emits these codes for these statuses.
    private static func statusFallbackCode(_ status: Int) -> String {
        switch status {
        case 400: return "missing-field"
        case 401: return "imap-auth-failed"
        case 409: return "account-exists"
        case 500: return "internal-error"
        case 502: return "imap-unreachable"
        case 503: return "provider-not-configured"
        default: return ""
        }
    }

    /// The 409 action: adopt the already-connected server row for this mailbox
    /// as the local account. Activation is flipped server-side too, otherwise
    /// the feed (local accountId) and the toolbar/health banner (server
    /// is_active) can show two different accounts. If the row is not listed,
    /// the neutral prompt stays up and Cancel returns the user to the main screen.
    private func useExistingAccount(email: String) async {
        do {
            let rows = try await api.fetchAccounts()
            if Task.isCancelled { return }
            guard let row = rows.first(where: { $0.provider == .qq && $0.email == email }) else {
                return
            }
            // Activate server-side first: if this fails or the user cancels
            // mid-flight, the local id is still the old one, so the feed and
            // the toolbar's `directory.active` never disagree. (Keychain
            // failure after this point is the rarer half of the race.)
            try await api.activateAccount(id: row.id)
            if Task.isCancelled { return }
            try accounts.set(accountId: row.id)
            dismiss()
        } catch let urlError as URLError where urlError.code == .cancelled {
            return
        } catch is CancellationError {
            return
        } catch {
            errorMessage = l10n.checkConnectionFailed + error.lagoonUIMessage
            accountExistsEmail = nil
        }
    }

    /// M0 completion handshake for the Gmail dance: poll `GET /api/accounts`
    /// until the OAuth round-trip lands a row.
    private func pollForConnection() async {
        // connectAttempt starts at 0: opening the sheet must not kick off a
        // 3-minute Gmail poll (and the "waiting for browser approval" copy)
        // before the user has even clicked Connect.
        guard connectAttempt > 0 else { return }
        guard mode == .gmail else { return }
        isPolling = true
        errorMessage = nil
        defer { isPolling = false }

        // Snapshot at poll start: only a row that appears or recovers *after*
        // this moment counts as landed. Without the baseline the poll would
        // steal a pre-existing row within one cycle, bouncing "add account"
        // straight back to the feed before the form can be used.
        let baseline = (try? await api.fetchAccounts()) ?? []

        let deadline = ContinuousClock.now + Self.pollTimeout
        while !Task.isCancelled {
            if ContinuousClock.now >= deadline {
                errorMessage = l10n.stillNotConnected
                return
            }

            do {
                let connected = try await api.fetchAccounts()
                if let landed = Self.landedGmailAccount(current: connected, baseline: baseline) {
                    do {
                        try accounts.set(accountId: landed.id)
                        dismiss()
                        return
                    } catch {
                        errorMessage = l10n.saveAccountFailed + error.lagoonUIMessage
                        return
                    }
                }
            } catch {
                errorMessage = l10n.checkConnectionFailed + error.lagoonUIMessage
            }

            do {
                try await Task.sleep(for: Self.pollInterval)
            } catch {
                return // view disappeared / task cancelled
            }
        }
    }

    /// The account the Gmail OAuth round-trip just landed, if any: a gmail row
    /// that is new since the poll started (first connect), or a previously
    /// unhealthy gmail row that now reads `.ok` — the callback upserts
    /// credentials in place (same id) and ticks the sync engine, so recovery
    /// is visible within seconds. Rows that were healthy at baseline are never
    /// selected: the connect surface is reachable while accounts exist, and
    /// stealing one would yank the user out of the form.
    static func landedGmailAccount(
        current: [ConnectedAccount],
        baseline: [ConnectedAccount]
    ) -> ConnectedAccount? {
        let baselineById = Dictionary(
            baseline.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for account in current where account.provider == .gmail {
            guard let before = baselineById[account.id] else { return account }
            if before.syncHealth.status != .ok, account.syncHealth.status == .ok {
                return account
            }
        }
        return nil
    }
}
