import SwiftUI
import LagoonKit

/// First-run surface: connect a QQ Mailbox with an address + authorization code.
///
/// The form is the only entry point (the app is a bare SwiftPM executable with
/// no `Info.plist` and registers no URL scheme, so a browser OAuth round-trip
/// has nowhere to land). The server probes the mailbox before storing anything.
struct ConnectView: View {
    @EnvironmentObject var accounts: AccountStore
    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss

    /// RootView presents this as a sheet (connect/reconnect while accounts
    /// exist) — there `dismiss()` closes the sheet. As the WindowGroup root
    /// (onboarding, no account yet) `dismiss()` would close the ENTIRE
    /// window and leave the app running windowless; LagoonApp's switch on
    /// `accounts.accountId` swaps the content to RootView instead.
    var presentedAsSheet: Bool = false

    @State private var qqEmail = ""
    @State private var qqAuthCode = ""
    @State private var showAuthCode = false
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

    /// Pre-filled by RootView's "Reconnect" banner.
    private let prefillEmail: String?

    init(prefillEmail: String? = nil, presentedAsSheet: Bool = false) {
        self.prefillEmail = prefillEmail
        self.presentedAsSheet = presentedAsSheet
        _qqEmail = State(initialValue: prefillEmail ?? "")
    }

    private let api = APIClient()

    var body: some View {
        VStack(spacing: 16) {
            Text("Lagoon")
                .font(.largeTitle)
                .bold()
            Text(l10n.connectPrompt)
                .foregroundStyle(.secondary)

            qqSection

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
                    if presentedAsSheet { dismiss() }
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(40)
        .frame(minWidth: 460, maxWidth: 460, minHeight: 380)
        // Editing either field invalidates whatever the last attempt said.
        // This used to be the segmented-control's `onChange`; with a single
        // provider there is no tab switch left to hang it on.
        .onChange(of: qqEmail) { _, _ in clearFailureState() }
        .onChange(of: qqAuthCode) { _, _ in clearFailureState() }
        .onAppear {
            focusedField = qqEmail.isEmpty ? .email : .authCode
        }
        // A sheet can be closed while the probe is still in flight; without
        // this the request keeps running and can adopt an account the user
        // backed out of.
        .onDisappear { connectTask?.cancel() }
    }

    private func clearFailureState() {
        errorMessage = nil
        accountExistsEmail = nil
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
            HStack(spacing: 6) {
                Group {
                    if showAuthCode {
                        TextField(l10n.qqAuthCodePlaceholder, text: $qqAuthCode)
                    } else {
                        SecureField(l10n.qqAuthCodePlaceholder, text: $qqAuthCode)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .authCode)
                Button {
                    showAuthCode.toggle()
                } label: {
                    Label(
                        showAuthCode ? l10n.hideAuthCode : l10n.showAuthCode,
                        systemImage: showAuthCode ? "eye.slash" : "eye"
                    )
                    .labelStyle(.iconOnly)
                }
                .help(showAuthCode ? l10n.hideAuthCode : l10n.showAuthCode)
            }
            Text(l10n.qqAuthCodeHelp)
                .font(.caption2)
                .foregroundStyle(.tertiary)
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
            if presentedAsSheet { dismiss() }
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

    /// The 409 action: select the already-connected server row as the single
    /// active account. If the row is not listed, the neutral prompt stays up.
    private func useExistingAccount(email: String) async {
        do {
            let rows = try await api.fetchAccounts()
            if Task.isCancelled { return }
            guard let row = rows.first(where: { $0.provider == .qq && $0.email == email }) else {
                return
            }
            try await api.activateAccount(id: row.id)
            try accounts.set(accountId: row.id)
            if presentedAsSheet { dismiss() }
        } catch let urlError as URLError where urlError.code == .cancelled {
            return
        } catch is CancellationError {
            return
        } catch {
            errorMessage = l10n.checkConnectionFailed + error.lagoonUIMessage
            accountExistsEmail = nil
        }
    }
}
