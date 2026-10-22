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

    @State private var draft: ComposeFlow.Draft
    @State private var attachments: [OutgoingAttachment] = []
    @State private var isSending = false
    @State private var error: String?
    /// Why the last send failed, when it did. Drives whether the failure
    /// row offers a retry: some failures cannot be retried, and a retry
    /// button that cannot work is a lie about what the product can do.
    @State private var sendFailure: ComposeFlow.Failure?
    @State private var requestId = UUID().uuidString.lowercased()
    /// The pending draft write.
    ///
    /// Every keystroke used to JSON-encode the whole draft and write it to
    /// `UserDefaults` — on the main thread, once per key press, with a fresh
    /// `JSONEncoder` each time. The write is debounced now: one encode and
    /// one write per pause in typing.
    @State private var draftWriteTask: Task<Void, Never>?
    /// True briefly after each save lands — the "saved" tick. The sheet
    /// promises that the draft is kept, so it shows the proof.
    @State private var draftJustSaved = false
    @State private var draftSavedResetTask: Task<Void, Never>?
    /// Set once the message has been sent, so the teardown flush does not
    /// put the body the user just sent back into the draft slot.
    @State private var didSend = false
    /// Set when the user chose to throw the draft away.
    @State private var didDiscard = false
    /// True once the user has written something in this session — the
    /// answer to "is there unfinished work here?".
    @State private var hasEdited = false
    /// The "this mail is not finished" prompt.
    @State private var showUnsavedAlert = false
    /// The file picker is open.
    @State private var isPickingFiles = false
    private let draftSlot: ComposeFlow.DraftSlot
    private let api = APIClient.shared

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
        let slot = ComposeFlow.DraftSlot(key: key)
        self.draftSlot = slot
        var initial = slot.load() ?? ComposeFlow.Draft()
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
                Button { requestClose() } label: {
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
                TextField(l10n.newMessageToPlaceholder, text: $draft.to)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(l10n.newMessageToLabel)
                // The hint appears only once the field holds more than one
                // address: before that it is noise. It is about *this*
                // field — a mail to one person with three on Cc is not a
                // mail that needs commas here.
                if toAddresses.count > 1 {
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
                failureRow(error)
            }

            HStack(spacing: 10) {
                Text(l10n.shortcutSend).font(.caption).foregroundStyle(.secondary)
                // The same live indicator the reply composer uses. The sheet
                // promises the draft is kept, so it shows the proof rather
                // than a static sentence about it.
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .opacity(draftJustSaved ? 1 : 0)
                    Text(draftJustSaved ? l10n.draftSavedNow : l10n.draftSaved)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .animation(.easeOut(duration: 0.25), value: draftJustSaved)
                Spacer()
                // How many people the whole envelope reaches. It sits with
                // the send button rather than with the To label: it counts
                // To *and* Cc *and* Bcc, and a number next to a field it
                // does not describe is a number the user cannot trust.
                if recipientCount > 1 {
                    Text(l10n.newMessageTotalRecipients(count: recipientCount))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Button(l10n.closeComposer) { requestClose() }
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
                .disabled(isSending || !canSend)
                .help(canSend ? l10n.send : l10n.sendNeedsRecipient)
            }
        }
        .padding(20)
        .frame(width: 620)
        .onChange(of: draft) { _, newValue in
            hasEdited = true
            scheduleDraftWrite(newValue)
        }
        // The sheet is closing: whatever is on screen is what belongs in the
        // draft slot, and the debounced write may still be pending. Flushing
        // here is what keeps a draft typed in the last half second from
        // being lost.
        //
        // The flush only happens if the user wrote something: a sheet that
        // was opened and closed without a word must not leave a draft
        // behind for the next one to find.
        .onDisappear {
            draftWriteTask?.cancel()
            draftWriteTask = nil
            guard !didSend, !didDiscard else { return }
            guard hasEdited else { return }
            writeDraft(draft)
        }
        .fileImporter(
            isPresented: $isPickingFiles,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            handlePickedFiles(result)
        }
        // The prompt for a mail that is not finished. Closing keeps the
        // draft, so the question is never "are you sure you want to lose
        // it" — it is whether the draft should be kept or thrown away.
        .alert(l10n.unsavedMailTitle, isPresented: $showUnsavedAlert) {
            Button(l10n.keepWriting, role: .cancel) { }
            Button(l10n.discardDraft, role: .destructive) { discardAndClose() }
            Button(l10n.closeAndKeepDraft) { dismiss() }
        } message: {
            Text(l10n.unsavedMailMessage)
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
                    // The size of the whole set, because the server's limit
                    // is on the whole set.
                    Text(l10n.newMessageAttachmentTotalSize(size: totalAttachmentSize))
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

    /// The size of every attachment together, as a human-readable string.
    private var totalAttachmentSize: String {
        ByteCountFormatter.string(
            fromByteCount: Int64(ComposeFlow.Attachments.totalBytes(attachments)),
            countStyle: .file
        )
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
        Self.recipientCount(to: draft.to, cc: draft.cc, bcc: draft.bcc)
    }

    /// How many people the whole envelope reaches.
    ///
    /// To, Cc and Bcc together. The number belongs next to the send
    /// button — the button that reaches all of them — and not next to the
    /// To label, which counts only one of the three fields.
    static func recipientCount(to: String, cc: String, bcc: String) -> Int {
        AddressList.split(to).count + AddressList.split(cc).count + AddressList.split(bcc).count
    }

    /// Whether the mail has somebody to go to.
    ///
    /// The send button says so before the user presses it, rather than
    /// after: the user learns from the disabled button and its tooltip,
    /// not from a failed action.
    private var canSend: Bool {
        !toAddresses.isEmpty
    }

    // MARK: - Draft persistence

    /// Schedules the draft write, debounced.
    ///
    /// The task is cancelled and replaced on every keystroke, so a burst of
    /// typing produces one encode and one write — at the end of the burst —
    /// instead of one per key press.
    private func scheduleDraftWrite(_ value: ComposeFlow.Draft) {
        draftWriteTask?.cancel()
        draftWriteTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            writeDraft(value)
        }
    }

    /// Writes the draft to disk and confirms it.
    private func writeDraft(_ value: ComposeFlow.Draft) {
        draftSlot.save(value)
        // Flash the "saved" checkmark for 1.6 s after the write lands.
        draftSavedResetTask?.cancel()
        draftJustSaved = !value.isEmpty
        draftSavedResetTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_600))
            guard !Task.isCancelled else { return }
            draftJustSaved = false
        }
    }

    // MARK: - Leaving

    /// Closes the sheet — keeping the draft, or asking first.
    private func requestClose() {
        guard hasEdited else {
            dismiss()
            return
        }
        showUnsavedAlert = true
    }

    /// Throws the draft away and closes.
    private func discardAndClose() {
        didDiscard = true
        draftWriteTask?.cancel()
        draftWriteTask = nil
        draftSlot.clear()
        dismiss()
    }

    // MARK: - File picking

    /// Reads the picked files and turns them into attachments.
    ///
    /// A file that cannot be read, or that is empty or too big, is
    /// reported by name and skipped — the other files still go out,
    /// because refusing the whole batch for one bad file would be a worse
    /// answer than the user could act on.
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
                    // The server caps the *total* as well as each file.
                    guard ComposeFlow.Attachments.fits(
                        attachment.data.count,
                        alongside: attachments
                    ) else {
                        failures.append(l10n.newMessageAttachmentTotalTooLarge(name: name))
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

    // MARK: - Failures

    /// The failure line under the body: the cause, named, and a retry when
    /// retrying can work.
    private func failureRow(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if sendFailure?.canRetry == true {
                Button(l10n.retry) {
                    Task { await send() }
                }
                .buttonStyle(.link)
                .disabled(isSending)
            }
        }
    }

    /// The text for a failure, in the user's terms.
    private func message(for failure: ComposeFlow.Failure, error: Error) -> String {
        switch failure {
        case .authFailed: return l10n.sendFailedAuth
        case .notConfigured: return l10n.sendFailedNotConfigured
        case .messageGone: return l10n.sendFailedMessageGone
        case .accountMissing: return l10n.sendFailedAccountMissing
        case .malformedRecipient: return l10n.sendFailedMalformedRecipient
        case .malformedAttachment: return l10n.sendFailedMalformedAttachment
        case .forwardTooLarge: return l10n.sendFailedForwardTooLarge
        case .inFlight: return l10n.sendFailedInFlight
        case .rejected: return l10n.sendRejected
        case .transport: return l10n.sendFailedTransport
        case .unknown: return l10n.sendFailed + error.lagoonUIMessage
        }
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
        sendFailure = nil
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
            // The server's own answer decides. A 200 with `ok: false` is a
            // refusal wearing a success's clothes, and announcing "sent"
            // on it is a promise the user will not check.
            switch ComposeFlow.outcome(of: response) {
            case .rejected:
                sendFailure = .rejected
                error = l10n.sendRejected
            case .accepted(let providerMessageId):
                didSend = true
                // The pending write must not land after the send: it would put
                // the message the user just sent back into the draft slot, and the
                // next compose would start from the sent text.
                draftWriteTask?.cancel()
                draftWriteTask = nil
                draftSlot.clear()
                SoundEffects.send()
                onSent(providerMessageId)
                dismiss()
            }
        } catch {
            let failure = ComposeFlow.Failure.classify(error)
            sendFailure = failure
            self.error = message(for: failure, error: error)
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
