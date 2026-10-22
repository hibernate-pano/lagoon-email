import SwiftUI
import LagoonKit

/// First-run surface: connect a QQ Mailbox with an address + authorization code.
///
/// The form is the entry point. The app registers a `lagoon://` URL scheme
/// (see `Support/Info.plist`), but a *browser* OAuth round-trip still has
/// nowhere to land: QQ Mail's own sign-in needs a session this app cannot
/// have, so the authorization code is pasted in by hand. The server probes
/// the mailbox before storing anything.
struct ConnectView: View {
    @EnvironmentObject var accounts: AccountStore
    @Environment(\.dismiss) private var dismiss

    /// The language preference, read straight from `UserDefaults`.
    @AppStorage(LanguagePreference.defaultsKey) private var languageTag = AppLanguage.zhHans.rawValue

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
    /// True only while the user asked to stop: the Cancel button, or Escape.
    ///
    /// `onDisappear` fires for reasons that are NOT the user backing out — the
    /// sheet is also dismissed by the system (Return on the focused field,
    /// window close) and by the parent re-rendering its `showConnect` binding.
    /// Cancelling the task unconditionally there killed the request *before it
    /// ever reached the server*: the sheet disappeared, `.onDisappear`
    /// cancelled `connectTask`, and the database stayed untouched with no
    /// error copy anywhere — a silent no-op that looked exactly like "I
    /// clicked and nothing happened" (reported 2026-10-09).
    ///
    /// So: cancel only when the user asked for it. Any other dismissal lets
    /// the probe finish, and `connectQQ` already refuses to adopt the account
    /// when the task was genuinely cancelled.
    @State private var userCancelled = false
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

    private let api = APIClient.shared

    /// The localizer for this screen.
    ///
    /// The first run is a **sibling scene** of the main window, so the
    /// main window's `.environment(\.l10n, …)` never reaches it — every
    /// label on the onboarding form was Chinese whatever the user had
    /// chosen, including for a user who had already chosen English.
    /// The preference is in `UserDefaults` and this screen can change it,
    /// so the screen reads it directly.
    private var l10n: L10n {
        L10n.forStoredTag(languageTag)
    }

    /// QQ Mail's web interface — where the authorization code is generated.
    ///
    /// ## Why the root, and not the settings page
    ///
    /// The settings screen itself needs a signed-in session (`sid`), which
    /// this app does not have and cannot have: the user has to log in with
    /// their QQ password and a phone verification. Every deep link that
    /// skips the login bounces to the sign-in page, and every one that does
    /// not exists only for a signed-in session — so a link to it would be a
    /// link to a 404 for anyone not already in a browser session.
    ///
    /// `https://mail.qq.com` is the one URL that is *always* the right
    /// place: it signs the user in, and the numbered path in the step above
    /// says where to go from there. It was verified to resolve (200) and to
    /// serve QQ Mail's sign-in page.
    static let qqMailURL = URL(string: "https://mail.qq.com")!

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
                        userCancelled = false
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
                    userCancelled = true
                    connectTask?.cancel()
                    if presentedAsSheet { dismiss() }
                }
                .keyboardShortcut(.cancelAction)
            }

            // The language picker, on the one screen a new user cannot
            // leave without reading.
            //
            // The settings window is where the language normally lives,
            // and the settings window cannot be reached until an account
            // is connected. So the first run was the one screen where a
            // user who does not read the app's language had no way out —
            // every label was in a language they could not read, and the
            // only control that could change it was on a screen they
            // could not reach yet.
            HStack {
                Spacer()
                Picker(l10n.languageLabel, selection: $languageTag) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel(l10n.languageLabel)
            }
            .frame(maxWidth: 360)
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
        // Only when the user actually asked to stop — see `userCancelled`.
        // Cancelling unconditionally made every system-initiated dismissal a
        // silent abort: no request reached the server and no copy was shown.
        .onDisappear {
            if Self.shouldCancelConnectOnDisappear(
                isDisappearing: true,
                userCancelled: userCancelled
            ) {
                connectTask?.cancel()
            }
        }
    }

    private func clearFailureState() {
        errorMessage = nil
        accountExistsEmail = nil
    }

    /// Whether a disappearance of this view should cancel the in-flight
    /// connect request.
    ///
    /// Extracted as a pure function so the rule is unit-testable: the bug it
    /// fixes was invisible to every existing test because it lived in a
    /// `.onDisappear` closure, and the failure mode was a *silent* no-op —
    /// the request never left the process, so no assertion on server calls,
    /// database rows, or error copy could ever have caught it.
    ///
    /// `true` only for a user-initiated cancel. A sheet can also disappear
    /// because the system dismissed it (Return on the focused field, window
    /// close) or because the parent flipped `showConnect`; those must let the
    /// probe finish, and `connectQQ` already refuses to adopt the account when
    /// the task was genuinely cancelled.
    static func shouldCancelConnectOnDisappear(
        isDisappearing: Bool,
        userCancelled: Bool
    ) -> Bool {
        isDisappearing && userCancelled
    }

    @ViewBuilder
    private var qqSection: some View {
        Text(l10n.connectQQTitle)
            .font(.headline)
        authCodeStep
        formStep
    }

    /// 第 1 步 — where the authorization code comes from.
    ///
    /// ## Why this is a step and not a footnote
    ///
    /// Without the code the form cannot be completed at all, and the step
    /// itself fails in several ways (a phone verification, a 16-character
    /// code, a code that is not the password). It used to be two lines of
    /// `caption2`/`tertiary` grey text under the field, which made the only
    /// hard step in the whole onboarding the hardest one to read.
    ///
    /// So it is a labelled step, in normal type, with the path spelled out
    /// in the order the user walks it, and with a **button that takes them
    /// there**. A step that says where to go but makes the user go there by
    /// hand is still a hunt; the button removes the hunt and leaves the
    /// navigation (which only the user can do — it needs their password and
    /// their phone) to them.
    private var authCodeStep: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(l10n.qqAuthCodeStepTitle)
                .font(.headline)
            Text(l10n.qqAuthCodeHelp)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
            // `Link`, not a bare string: the path is a place the user has to
            // go, and a place you can go in one click is worth having. The
            // link opens QQ Mail's web interface in the default browser —
            // the settings page itself needs a signed-in session this app
            // does not have and cannot have, so the link opens the mailbox
            // and the numbered path above says where to go from there.
            Link(destination: Self.qqMailURL) {
                Label(l10n.qqAuthCodeOpenButton, systemImage: "arrow.up.forward.square")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(l10n.qqAuthCodeOpenHelp)
        }
        .frame(maxWidth: 360, alignment: .leading)
    }

    /// 第 2 步 — the form itself.
    private var formStep: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(l10n.qqFormStepTitle)
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
                // The field's own hint: what the value *is*, in one line.
                // Not a second copy of the path above — two copies of the
                // same step drift apart, and the user is left unsure which
                // one is current.
                Text(l10n.qqHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: 320)
            Button {
                // A previous cancel must not poison this attempt.
                userCancelled = false
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
        }
        .frame(maxWidth: 360, alignment: .leading)
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
            try await accounts.set(accountId: account.id)
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
            try await accounts.set(accountId: row.id)
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
