import SwiftUI
import LagoonKit

/// The data-handling disclosure.
///
/// ## Why this sheet exists
///
/// The About box said "your data stays on this Mac" and stopped there. For
/// an app that reads a person's whole inbox, that is the sentence that
/// matters most and the one the user is least able to check — so the sheet
/// spells out what it covers, and, just as importantly, **what it does not**:
/// the headers are readable in the database, the AI sends mail text to a
/// third party, and the key is in this machine's Keychain rather than
/// somewhere the mail never was.
///
/// A privacy page that only lists the good parts is marketing. This one
/// lists the parts that are not encrypted and names the one path on which
/// mail content leaves the machine.
struct PrivacySheet: View {
    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section(
                        l10n.privacyLocalTitle,
                        l10n.privacyLocalBody,
                        systemImage: "internaldrive"
                    )
                    section(
                        l10n.privacyEncryptedTitle,
                        l10n.privacyEncryptedBody,
                        systemImage: "lock.shield"
                    )
                    section(
                        l10n.privacyPlaintextTitle,
                        l10n.privacyPlaintextBody,
                        systemImage: "eye"
                    )
                    section(
                        l10n.privacyLeavingTitle,
                        l10n.privacyLeavingBody,
                        systemImage: "arrow.up.right.circle"
                    )
                    section(
                        l10n.privacyNeverTitle,
                        l10n.privacyNeverBody,
                        systemImage: "hand.raised"
                    )
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(
            width: LagoonSheetSize.standard.width,
            height: LagoonSheetSize.standard.height
        )
    }

    private var header: some View {
        HStack {
            Label(l10n.privacyTitle, systemImage: "hand.raised.square")
                .font(.headline)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(l10n.dismiss)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// One heading, one paragraph, one icon.
    ///
    /// The icon is decoration, not information: it repeats the heading's
    /// meaning for a reader who scans the sheet. Nothing here is conveyed
    /// by colour alone.
    private func section(_ title: String, _ body: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
            Text(body)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}
