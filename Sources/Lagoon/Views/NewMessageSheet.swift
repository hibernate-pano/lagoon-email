import SwiftUI
import UniformTypeIdentifiers
import LagoonKit

/// Plain-text new-message composer. The server owns the From address and
/// validates the recipient; this sheet supplies only To, Subject and body.
///
/// ## What it can do
///
/// * **Several recipients.** The To field takes a comma-separated list, and
///   the sheet says so the moment there is more than one, because a mail
///   to three people looks identical to a mail to one until it is sent.
/// * **Cc and Bcc.** Cc is visible to everyone; Bcc is not, and the sheet
///   says *that* rather than leaving the user to work it out.
/// * **Attachments.** Files are read when they are picked, and their names
///   and sizes are listed above the body so the user can see what is going
///   out before they send it.
struct NewMessageSheet: View {
    let accountId: UUID
    let onSent: (String?) -> Void

    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss

    private struct Draft: Codable, Equatable {
        var to = ""
        var cc = ""
        var bcc = ""
        var subject = ""
        var body = ""
    }

    @State private var draft: Draft
    @State private var attachments: [OutgoingAttachment] = []
    @State private var isSending = false
    @State private var error: String?
    @State private var requestId = UUID().uuidString.lowercased()
    /// The pending draft write.
    ///
    /// Every keystroke used to JSON-encode the whole draft and write it to
    /// `UserDefaults` — on the main thread, once per key press, with a fresh
    /// `JSONEncoder` each time. The write is debounced now: one encode and
    /// one write per pause in typing.
    @State private var draftWriteTask: Task<Void, Never>?
    /// Set once the message has been sent, so the teardown flush does not
    /// put the body the user just sent back into the draft slot.
    @State private var didSend = false
    /// The file picker is open.
    @State private var isPickingFiles = false
    private let draftKey: String
    private let api = APIClient.shared
    /// One encoder for the sheet's lifetime. `JSONEncoder` is a class, and
    /// building a new one per keystroke allocated a fresh object to do the
    /// same work.
    private let draftEncoder = JSONEncoder()

    /// - Parameters:
    ///   - prefillTo: Recipient to seed the To field with. Empty for a
    ///     blank compose; the forward flow leaves it empty on purpose so
    ///     the user must consciously pick who receives the forwarded mail.
    ///   - prefillSubject: Subject to seed. `nil` restores the persisted
    ///     draft's subject (the normal compose case).
    ///   - prefillBody: Body to seed (the quoted forward block). `nil`
    ///     restores the persisted draft's body.
    ///
    /// Prefills win over the persisted draft so opening Forward never
    /// shows a half-typed message from a previous compose session. The
    /// draft itself is left on disk — cancel and reopen "New message"
    /// and it comes back.
    init(
        accountId: UUID,
        prefillTo: String? = nil,
        prefillSubject: String? = nil,
        prefillBody: String? = nil,
        onSent: @escaping (String?) -> Void
    ) {
        self.accountId = accountId
        self.onSent = onSent
        let key = "lagoon.compose.\(accountId.uuidString)"
        self.draftKey = key
        let seeded: Draft
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode(Draft.self, from: data) {
            seeded = saved
        } else {
            seeded = Draft()
        }
        var initial = seeded
        if let prefillTo { initial.to = prefillTo }
        if let prefillSubject { initial.subject = prefillSubject }
        if let prefillBody { initial.body = prefillBody }
        _draft = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(l10n.newMessageTitle, systemImage: "square.and.pencil")
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
                HStack {
                    Text(l10n.newMessageToLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    // The count only appears when it is more than one, so a
                    // single-recipient mail looks exactly as it did before.
                    if recipientCount > 1 {
                        Text(l10n.newMessageRecipientsCount(count: recipientCount))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                TextField(l10n.newMessageToPlaceholder, text: $draft.to)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(l10n.newMessageToLabel)
                // The hint appears only once the field holds more than one
                // address: before that it is noise.
                if recipientCount > 1 {
                    Text(l10n.newMessageMultipleRecipientsHelp)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(l10n.newMessageCcLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(l10n.newMessageCcPlaceholder, text: $draft.cc)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(l10n.newMessageCcLabel)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(l10n.newMessageBccLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(l10n.newMessageBccPlaceholder, text: $draft.bcc)
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
                // No placeholder: the caption above already names the field, and
                // reusing the same string twice read as a glitch.
                TextField("", text: $draft.subject)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(l10n.newMessageSubjectLabel)
            }

            attachmentsSection

            TextEditor(text: $draft.body)
                .font(.body)
                .frame(minHeight: 240)
                .padding(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.quaternary)
                )
                .overlay(alignment: .topLeading) {
                    if draft.body.isEmpty {
                        Text(l10n.newMessageBodyPlaceholder)
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }

            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                Text(l10n.shortcutSend).font(.caption).foregroundStyle(.secondary)
                Text(l10n.draftSaved).font(.caption2).foregroundStyle(.secondary)
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
        .frame(width: 620)
        .onChange(of: draft) { _, newValue in
            scheduleDraftWrite(newValue)
        }
        // The sheet is closing: whatever is on screen is what belongs in the
        // draft slot, and the debounced write may still be pending. Flushing
        // here is what keeps a draft typed in the last half second from
        // being lost.
        .onDisappear {
            draftWriteTask?.cancel()
            draftWriteTask = nil
            guard !didSend else { return }
            writeDraft(draft)
        }
        .fileImporter(
            isPresented: $isPickingFiles,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            handlePickedFiles(result)
        }
    }

    // MARK: - Attachments

    /// The attachment list and the button that adds to it.
    ///
    /// The list is above the body, not below it: the user needs to see
    /// what is attached while they write, not after they have written.
    @ViewBuilder
    private var attachmentsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(l10n.newMessageAttachments)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !attachments.isEmpty {
                    Text(l10n.newMessageAttachmentCount(count: attachments.count))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    isPickingFiles = true
                } label: {
                    Label(l10n.newMessageAddAttachment, systemImage: "paperclip")
                        .font(.caption)
                }
                .buttonStyle(.link)
            }
            ForEach(attachments) { attachment in
                HStack(spacing: 6) {
                    Image(systemName: "doc")
                        .foregroundStyle(.secondary)
                    Text(attachment.filename)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(attachment.displaySize)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button {
                        removeAttachment(attachment)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(l10n.newMessageRemoveAttachment)
                }
                .font(.callout)
            }
        }
    }

    // MARK: - Recipients

    /// The addresses the To/Cc/Bcc fields hold, split the way RFC 5322
    /// splits them.
    ///
    /// `AddressList.split` — not a plain `split(separator: ",")` — because
    /// a comma inside a quoted display name (`"Zhang, Wei" <wei@x.com>`)
    /// is part of the name, and cutting there produced one address and one
    /// unusable fragment.
    private var toAddresses: [String] {
        AddressList.split(draft.to)
    }

    private var ccAddresses: [String] {
        AddressList.split(draft.cc)
    }

    private var bccAddresses: [String] {
        AddressList.split(draft.bcc)
    }

    /// Every recipient the mail goes to.
    private var recipientCount: Int {
        toAddresses.count + ccAddresses.count + bccAddresses.count
    }

    // MARK: - Draft persistence

    /// Schedules the draft write, debounced.
    ///
    /// The task is cancelled and replaced on every keystroke, so a burst of
    /// typing produces one encode and one write — at the end of the burst —
    /// instead of one per key press.
    private func scheduleDraftWrite(_ value: Draft) {
        draftWriteTask?.cancel()
        draftWriteTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            writeDraft(value)
        }
    }

    /// Writes the draft to disk.
    private func writeDraft(_ value: Draft) {
        if value.to.isEmpty, value.cc.isEmpty, value.bcc.isEmpty,
           value.subject.isEmpty, value.body.isEmpty {
            UserDefaults.standard.removeObject(forKey: draftKey)
        } else if let data = try? draftEncoder.encode(value) {
            UserDefaults.standard.set(data, forKey: draftKey)
        }
    }

    // MARK: - File picking

    /// Reads the picked files and turns them into attachments.
    ///
    /// A file that cannot be read, or that is empty or too big, is reported
    /// by name and skipped — the other files still go out, because refusing
    /// the whole batch for one bad file would be a worse answer than the
    /// user could act on.
    private func handlePickedFiles(_ result: Result<[URL], Error>) {
        switch result {
        case .failure:
            error = l10n.newMessageAttachmentReadFailed
        case .success(let urls):
            var failures: [String] = []
            for url in urls {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    let name = url.lastPathComponent
                    let attachment = OutgoingAttachment(
                        filename: name,
                        mimeType: Self.mimeType(for: url),
                        data: data
                    )
                    if attachment.data.isEmpty {
                        failures.append(l10n.newMessageAttachmentEmpty(name))
                        continue
                    }
                    guard attachment.isSendable else {
                        failures.append(l10n.newMessageAttachmentTooLarge(name))
                        continue
                    }
                    attachments.append(attachment)
                } catch {
                    failures.append(l10n.newMessageAttachmentReadFailed)
                }
            }
            error = failures.isEmpty ? nil : failures.joined(separator: "\n")
        }
    }

    /// The MIME type of a file, from its extension.
    ///
    /// Falls back to `application/octet-stream`, which every client reads
    /// as "an opaque file" — the right answer for a type we do not know,
    /// and better than a wrong type.
    static func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }

    private func removeAttachment(_ attachment: OutgoingAttachment) {
        attachments.removeAll { $0.id == attachment.id }
    }

    // MARK: - Send

    private func send() async {
        let to = draft.to.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = draft.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !to.isEmpty else {
            error = l10n.emptyRecipient
            return
        }
        guard !body.isEmpty else {
            error = l10n.emptyMessage
            return
        }
        // The same check the server makes, made here so the user hears about
        // a typo'd address before they have written the mail, not after.
        if let invalid = Self.firstInvalidAddress(in: toAddresses) {
            error = l10n.newMessageInvalidRecipient(address: invalid)
            return
        }
        if let invalid = Self.firstInvalidAddress(in: ccAddresses) {
            error = l10n.newMessageInvalidRecipient(address: invalid)
            return
        }
        if let invalid = Self.firstInvalidAddress(in: bccAddresses) {
            error = l10n.newMessageInvalidRecipient(address: invalid)
            return
        }

        isSending = true
        error = nil
        do {
            let response = try await api.sendNewMessage(
                to: to,
                subject: subject,
                body: body,
                accountId: accountId,
                requestId: requestId,
                cc: ccAddresses,
                bcc: bccAddresses,
                attachments: attachments
            )
            didSend = true
            // The pending write must not land after the send: it would put
            // the message the user just sent back into the draft slot, and
            // the next compose would start from the sent text.
            draftWriteTask?.cancel()
            draftWriteTask = nil
            UserDefaults.standard.removeObject(forKey: draftKey)
            SoundEffects.send()
            onSent(response.providerMessageId)
            dismiss()
        } catch {
            self.error = l10n.sendFailed + error.lagoonUIMessage
        }
        isSending = false
    }

    /// The first address in the list that is not a plain address.
    ///
    /// The rule is the server's: one ordinary address, no display name, no
    /// list, no line break. Duplicated here because the server's answer
    /// arrives as a bare `malformed-recipient` code, and "the address you
    /// typed is wrong" is a far better message than "send failed".
    static func firstInvalidAddress(in addresses: [String]) -> String? {
        for address in addresses {
            let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { continue }
            if value.count > 254 { return value }
            if value.contains(where: \.isWhitespace) { return value }
            let parts = value.split(separator: "@", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  !parts[0].isEmpty,
                  !parts[1].isEmpty,
                  parts[1].contains(".")
            else { return value }
        }
        return nil
    }
}
