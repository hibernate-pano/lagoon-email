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

    private static let pollInterval: Duration = .seconds(2)
    private static let pollTimeout: Duration = .seconds(180)

    var body: some View {
        VStack(spacing: 16) {
            Text("Lagoon")
                .font(.largeTitle)
                .bold()
            Text("Connect your Gmail to begin.")
                .foregroundStyle(.secondary)
            Button("Connect Gmail") {
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
                    Text("waiting for browser approval…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("After approving in the browser, return here.")
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
                errorMessage = "still not connected — try again"
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
                        errorMessage = "Could not save account: \(error.localizedDescription)"
                        return
                    }
                }
            } catch {
                errorMessage = "Could not check connection: \(error.localizedDescription)"
            }

            do {
                try await Task.sleep(for: Self.pollInterval)
            } catch {
                return // view disappeared / task cancelled
            }
        }
    }
}
