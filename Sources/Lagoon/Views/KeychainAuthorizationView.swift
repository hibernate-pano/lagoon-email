import SwiftUI
import AppKit

/// The screen shown when the Keychain has the account but this build is
/// not allowed to read it.
///
/// ## Why this screen exists at all
///
/// The reported defect was a hang: the app sat on 「服务器启动中」 forever
/// with no window the user could act from and no explanation. The cause was
/// environmental — macOS wanted the user to confirm a Keychain read and
/// raised the confirmation from a background agent with **no window**, so
/// the read never returned.
///
/// Two things have to be true for the user to be able to get themselves
/// out of that:
///
/// 1. **The app must not be waiting on the read.** The server binds its
///    port first and the secret is resolved around it, so the app is up
///    and answering even while the Keychain is stuck.
/// 2. **The app must say what is wrong and offer a next step.** This
///    screen is that step: it names the Keychain, says the data is safe,
///    and gives two buttons — open Keychain Access, and try again.
///
/// ## Why the account is not offered for re-connect
///
/// The stored account id is *there*; the app simply cannot read it right
/// now. Showing the connect form would tell the user their account is
/// gone, and connecting again would write a second account over the
/// first one. So this screen deliberately does not offer to connect.
struct KeychainAuthorizationView: View {
    @Environment(\.l10n) private var l10n

    /// Runs the account read again.
    let onRetry: () -> Void

    /// Where Keychain Access lives.
    ///
    /// `open -a` by name is the version that survives the app being
    /// moved between macOS releases: the bundle identifier is stable, and
    /// the path is not.
    private static let keychainAccessApp = "Keychain Access.app"

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.trianglebadge.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text(l10n.keychainAuthorizationTitle)
                .font(.headline)

            Text(l10n.keychainAuthorizationDetail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            HStack(spacing: 12) {
                Button(l10n.keychainOpenAccess) { openKeychainAccess() }
                    .buttonStyle(.borderedProminent)
                Button(l10n.retry) { onRetry() }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Opens Keychain Access, brought to the front.
    ///
    /// `NSWorkspace.openApplication` is used rather than `open` in a
    /// `Process`, because it activates the app: the user is being sent
    /// somewhere to do a thing, and an app that opens behind the one they
    /// are reading is a worse instruction than no instruction at all.
    private func openKeychainAccess() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: "/System/Library/CoreServices/Applications/\(Self.keychainAccessApp)"),
            configuration: configuration
        ) { _, _ in }
    }
}
