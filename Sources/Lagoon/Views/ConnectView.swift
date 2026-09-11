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

    @State private var mode: Mode = .gmail
    @State private var qqEmail = ""
    @State private var qqAuthCode = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?

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

            Picker(l10n.connectPrompt, selection: $mode) {
                Text("Gmail").tag(Mode.gmail)
                Text(l10n.connectQQTab).tag(Mode.qq)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 280)
            .onChange(of: mode) { _, _ in errorMessage = nil }

            switch mode {
            case .gmail: gmailSection
            case .qq: qqSection
            }

            if let displayedError {
                Text(displayedError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
        .padding(40)
        .frame(minWidth: 460, minHeight: 320)
        // Polls while the view is visible; SwiftUI cancels the task on disappear.
        .task(id: connectAttempt) { await pollForConnection() }
    }

    @ViewBuilder
    private var gmailSection: some View {
        Button(l10n.connectGmail) {
            errorMessage = nil
            NSWorkspace.shared.open(api.oauthStartURL)
            connectAttempt += 1
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .disabled(isPolling && connectAttempt > 0)

        if isPolling && connectAttempt > 0 {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(l10n.waitingForApproval)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(l10n.afterApproval)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var qqSection: some View {
        Text(l10n.connectQQTitle)
            .font(.headline)
        TextField(l10n.qqEmailPlaceholder, text: $qqEmail)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 320)
        SecureField(l10n.qqAuthCodePlaceholder, text: $qqAuthCode)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 320)
        Button {
            Task { await connectQQ() }
        } label: {
            if isConnecting {
                ProgressView().controlSize(.small)
            } else {
                Text(l10n.qqConnectButton)
            }
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .disabled(isConnecting)
        Text(l10n.qqHelp)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: 360)
            .multilineTextAlignment(.leading)
    }

    private var displayedError: String? {
        errorMessage ?? accounts.loadError
    }

    /// QQ connect: the auth code goes to the server, which probes the mailbox
    /// before storing anything. 401/502/409 map to actionable text; the code
    /// itself is never echoed into the UI or logs.
    private func connectQQ() async {
        let email = qqEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !qqAuthCode.isEmpty else {
            errorMessage = l10n.qqMissingFields
            return
        }
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }
        do {
            let account = try await api.connectQQ(email: email, authCode: qqAuthCode)
            try accounts.set(accountId: account.id)
        } catch APIError.badStatus(let code, _) {
            switch code {
            case 401: errorMessage = l10n.qqAuthFailed
            case 502: errorMessage = l10n.qqUnreachable
            case 409: errorMessage = l10n.qqAccountExists
            default: errorMessage = l10n.connectFailed + L10n.current.httpStatus(code)
            }
        } catch {
            errorMessage = l10n.connectFailed + error.lagoonUIMessage
        }
    }

    /// M0 completion handshake for the Gmail dance: poll `GET /api/accounts`
    /// until the OAuth round-trip lands a row.
    private func pollForConnection() async {
        guard mode == .gmail else { return }
        isPolling = true
        errorMessage = nil
        defer { isPolling = false }

        let deadline = ContinuousClock.now + Self.pollTimeout
        while !Task.isCancelled {
            if ContinuousClock.now >= deadline {
                errorMessage = l10n.stillNotConnected
                return
            }

            do {
                let connected = try await api.fetchAccounts()
                if let first = connected.first {
                    // M0 is single-user local, so always take the first account.
                    do {
                        try accounts.set(accountId: first.id)
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
}
