import SwiftUI
import AppKit

struct ConnectGmailView: View {
    @EnvironmentObject var accounts: AccountStore
    @State private var isPolling = false
    @State private var errorMessage: String?
    /// Bumped on every Connect click so `.task(id:)` restarts the poll loop
    /// with a fresh 3-minute deadline.
    @State private var connectAttempt = 0
    private let api = APIClient()

    @Environment(\.l10n) private var l10n
    private static let pollInterval: Duration = .seconds(2)
    private static let pollTimeout: Duration = .seconds(180)

    var body: some View {
        VStack(spacing: 16) {
            Text("Lagoon")
                .font(.largeTitle)
                .bold()
            Text(l10n.connectPrompt)
                .foregroundStyle(.secondary)
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

            if let displayedError {
                Text(displayedError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(40)
        .frame(minWidth: 420, minHeight: 260)
        // Polls while the view is visible; SwiftUI cancels the task on disappear.
        .task(id: connectAttempt) { await pollForConnection() }
    }

    private var displayedError: String? {
        errorMessage ?? accounts.loadError
    }

    /// M0 completion handshake: the app is a bare SwiftPM executable with no
    /// `Info.plist`, so it cannot register a URL scheme and the server cannot
    /// deep-link the new account back to it. Poll `GET /api/accounts` instead.
    private func pollForConnection() async {
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
                    // Multi-account selection arrives in M1.
                    do {
                        try accounts.set(accountId: first.id)
                        return
                    } catch {
                        errorMessage = l10n.saveAccountFailed + error.localizedDescription
                        return
                    }
                }
            } catch {
                errorMessage = l10n.checkConnectionFailed + error.localizedDescription
            }

            do {
                try await Task.sleep(for: Self.pollInterval)
            } catch {
                return // view disappeared / task cancelled
            }
        }
    }
}
