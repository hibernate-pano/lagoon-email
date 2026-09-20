import SwiftUI
import AppKit

/// About dialog — standard macOS surface every shipped app exposes. The
/// macOS HIG treats the absence of an About item as an incompleteness
/// signal, so the sheet exists even though the project is small.
///
/// Surfaces:
/// - App name + version (read from `CFBundleShortVersionString` and
///   `CFBundleVersion` so it tracks whatever the build emits).
/// - One-line tagline summarising the product so a new user understands
///   what they're looking at without reading the README.
/// - A "Send feedback" mailto link + the project repo URL. Both are
///   opened with `NSWorkspace.shared.open` so the user's default
///   browser / mail client is used.
struct AboutSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.l10n) private var l10n

    /// Pulled from the bundle at view-build time. Both are guaranteed
    /// to be present because the build script copies Info.plist as-is
    /// from `Support/Info.plist` and that file defines both keys.
    private let versionString: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "0"
        let build = info["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }()

    var body: some View {
        VStack(spacing: 16) {
            // The app icon — at 96pt it's large enough to read on a
            // Retina display but small enough to leave room for the text.
            // `NSImage`'s `appIcon` looks the icon up in the bundle's
            // Resources/Lagoon.icns, so it picks up whatever design the
            // current build ships with.
            if let icon = NSImage(named: NSImage.applicationIconName) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
            } else {
                // Fallback so the dialog never shows an empty box if
                // the .icns isn't in the bundle (e.g. running via
                // `swift run` without going through build-app.sh).
                Image(systemName: "envelope.fill")
                    .resizable()
                    .frame(width: 96, height: 96)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 4) {
                Text("Lagoon")
                    .font(.title).bold()
                Text(l10n.aboutTagline)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(l10n.aboutVersion(versionString))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }

            Divider().padding(.vertical, 4)

            VStack(spacing: 6) {
                Button {
                    NSWorkspace.shared.open(URL(string: "mailto:feedback@lagoon.email")!)
                } label: {
                    Label(l10n.aboutFeedback, systemImage: "envelope")
                }
                .buttonStyle(.link)

                Button {
                    NSWorkspace.shared.open(URL(string: "https://lagoon.email")!)
                } label: {
                    Label(l10n.aboutWebsite, systemImage: "safari")
                }
                .buttonStyle(.link)
            }

            Spacer(minLength: 0)

            Button(l10n.done) { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 360, height: 360)
    }
}