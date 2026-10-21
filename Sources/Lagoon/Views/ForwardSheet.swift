import SwiftUI
import LagoonKit

/// Forward a message to someone else.
///
/// ## Why this sheet is not the new-message sheet
///
/// The old forward reused `NewMessageSheet` and pre-filled it with the
/// original's body wrapped in `>` characters. That produced a *quoted*
/// forward: the recipient got a wall of plain text, the original's
/// formatting was gone, its attachments were gone, and its headers were
/// gone.
///
/// RFC 5322 §3.6.4 has a better answer. A forwarded message travels as a
/// `message/rfc822` part — the original message itself, bytes and all.
/// The recipient's client renders it as it was and offers the original's
/// attachments as the original's attachments.
///
/// The original's bytes live on the server, so this sheet cannot build
/// the forward itself: it names the message and the server wraps it. What
/// the sheet owns is the part that *is* the user's: who gets it, what
/// note goes on top, and the subject.
///
/// ## What the sheet says
///
/// The sheet tells the user that the original travels **as the original**,
/// with its attachments — because the previous behaviour (a quoted block)
/// looked like a forward and quietly was not one.
struct ForwardSheet: View {
    let accountId: UUID
    let remoteId: String
    /// The original's subject, for the "Fwd:" line and the file name the
    /// recipient sees.
    let originalSubject: String?
    /// Called after the forward goes out, with the provider's message id.
    let onSent: (String?) -> Void

    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss

    @State private var to = ""
    @State private var cc = ""
    @State private var bcc = ""
    @State private var subject = ""
    @State private var note = ""
    @State private var isSending = false
    @State private var error: String?
    @State private var requestId = UUID().uuidString.lowercased()

    private let api = APIClient.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(l10n.forward, systemImage: "arrowshape.turn.up.right")
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

            VStack(alignment: .leading, spacing: 4) {
                Text(l10n.newMessageToLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(l10n.newMessageToPlaceholder, text: $to)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(l10n.newMessageToLabel)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(l10n.newMessageCcLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(l10n.newMessageCcPlaceholder, text: $cc)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(l10n.newMessageCcLabel)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(l10n.newMessageBccLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(l10n.newMessageBccPlaceholder, text: $bcc)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(l10n.newMessageBccLabel)
                Text(l10n.newMessageBccHelp)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(l10n.newMessageSubjectLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("", text: $subject)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(l10n.newMessageSubjectLabel)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(l10n.forwardNoteLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $note)
                    .font(.body)
                    .frame(minHeight: 100)
                    .padding(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.quaternary)
                    )
                    .overlay(alignment: .topLeading) {
                        if note.isEmpty {
                            Text(l10n.forwardNotePlaceholder)
                                .font(.body)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 12)
                                .allowsHitTesting(false)
                        }
                    }
            }

            // What the recipient will actually get. The previous forward
            // looked like a forward and was not one, and the user had no
            // way to tell — so the sheet says what happens to the original.
            Label(l10n.forwardKeepsOriginal, systemImage: "envelope.badge")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                Text(l10n.shortcutSend).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(l10n.cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await send() }
                } label: {
                    if isSending {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(l10n.sending)
                        }
                    } else {
                        Text(l10n.send)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(isSending)
            }
        }
        .padding(20)
        .frame(width: LagoonSheetSize.composer.width)
        .onAppear {
            // The subject is seeded, not required: the server derives
            // "Fwd: <original>" when the field is empty, and the user can
            // still change it.
            if subject.isEmpty {
                subject = Self.forwardSubject(originalSubject)
            }
        }
    }

    /// The seeded subject: "Fwd:" once, the original's subject kept.
    static func forwardSubject(_ original: String?) -> String {
        let base = (original ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if base.lowercased().hasPrefix("fwd:") { return base }
        return base.isEmpty ? "Fwd:" : "Fwd: \(base)"
    }

    // MARK: - Send

    private var toAddresses: [String] {
        AddressList.split(to)
    }

    private var ccAddresses: [String] {
        AddressList.split(cc)
    }

    private var bccAddresses: [String] {
        AddressList.split(bcc)
    }

    private func send() async {
        let recipients = toAddresses
        guard !recipients.isEmpty else {
            error = l10n.emptyRecipient
            return
        }
        // The same check the server makes, made here so the user hears about
        // a typo'd address before they press send.
        if let invalid = NewMessageSheet.firstInvalidAddress(in: recipients) {
            error = l10n.newMessageInvalidRecipient(address: invalid)
            return
        }
        if let invalid = NewMessageSheet.firstInvalidAddress(in: ccAddresses) {
            error = l10n.newMessageInvalidRecipient(address: invalid)
            return
        }
        if let invalid = NewMessageSheet.firstInvalidAddress(in: bccAddresses) {
            error = l10n.newMessageInvalidRecipient(address: invalid)
            return
        }

        isSending = true
        error = nil
        do {
            let response = try await api.forwardMessage(
                remoteId: remoteId,
                to: recipients,
                body: note,
                subject: subject.trimmingCharacters(in: .whitespacesAndNewlines),
                accountId: accountId,
                requestId: requestId,
                cc: ccAddresses,
                bcc: bccAddresses
            )
            SoundEffects.send()
            onSent(response.providerMessageId)
            dismiss()
        } catch {
            self.error = l10n.sendFailed + error.lagoonUIMessage
        }
        isSending = false
    }
}
