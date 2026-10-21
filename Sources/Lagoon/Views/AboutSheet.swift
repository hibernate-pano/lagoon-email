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

    /// The data-handling disclosure, presented as its own sheet.
    ///
    /// A sheet rather than a paragraph in this box: the disclosure is four
    /// paragraphs long, and burying it under a scroll view in a 360-point
    /// dialog is the same as not shipping it.
    @State private var showPrivacy = false

    /// The data-and-backup panel.
    ///
    /// The other half of the privacy promise: "your data stays on this Mac"
    /// is only half a promise, and the half it was missing was "and you can
    /// take it with you". Same reason it is a sheet — the export alone needs
    /// a scope picker, a progress line and a cancel button, none of which fit
    /// under a 360-point dialog.
    @State private var showBackup = false

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
                    NSWorkspace.shared.open(LagoonHelp.feedbackMailto)
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

                // "Your data stays on this Mac" is a claim the user cannot
                // check for themselves, so the claim and its exceptions are
                // one click away — including the parts that are *not*
                // encrypted.
                Button {
                    showPrivacy = true
                } label: {
                    Label(l10n.aboutPrivacy, systemImage: "hand.raised")
                }
                .buttonStyle(.link)

                // The other half of that promise. Until this existed the
                // product told the user their mail was theirs and then gave
                // them no way to take it: no export, no backup button, no
                // path to another mail client. 「数据与备份」 is where the
                // promise gets paid.
                Button {
                    showBackup = true
                } label: {
                    Label(l10n.backupSectionTitle, systemImage: "externaldrive")
                }
                .buttonStyle(.link)
            }

            Spacer(minLength: 0)

            Button(l10n.done) { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(
            width: LagoonSheetSize.compact.width,
            height: LagoonSheetSize.compact.height
        )
        .sheet(isPresented: $showPrivacy) {
            PrivacySheet()
        }
        .sheet(isPresented: $showBackup) {
            // `RootView` injects `DirectoryStore` for the whole app, and this
            // sheet is presented from inside it — so the export scope picker
            // reads the same account list every other surface does instead of
            // fetching its own copy.
            BackupSheet()
        }
    }
}