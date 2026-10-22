import SwiftUI
import UniformTypeIdentifiers
import LagoonKit

/// Plain-text reply composer. To and Subject are read-only echoes of the
/// stored message: the server derives the envelope from its own row, so
/// editing them here could only lie to the user.
struct ComposerSheet: View {
    let remoteId: String
    let accountId: UUID
    let to: String
    /// Reply-all Cc recipients. Empty for a plain reply; shown as a
    /// read-only line so the user can see who else is on the thread
    /// without being able to silently drop them.
    let cc: [String]
    let subject: String
    let quotedText: String
    /// Called with the provider-assigned message id (nil when it reports none)
    /// after the server accepted the reply.
    let onSent: (String?) -> Void

    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss
    @State private var bodyText: String
    @State private var isSending = false
    @State private var error: String?
    /// Why the last send failed, when it did. Drives whether the failure
    /// row offers a retry: some failures cannot be retried, and a retry
    /// button that cannot work is a lie about what the product can do.
    @State private var sendFailure: ComposeFlow.Failure?
    /// True briefly after each save fires — drives the "Saved ✓"
    /// checkmark animation. Reset when the user types again so the
    /// indicator doesn't lie about freshness.
    @State private var draftJustSaved = false
    @State private var draftSavedResetTask: Task<Void, Never>?
    /// The pending draft write.
    ///
    /// Every keystroke used to write `UserDefaults` synchronously and to
    /// cancel-and-recreate the indicator's reset task: a hundred words cost
    /// a hundred writes and a hundred task cancellations, on the main
    /// thread, while the user was typing. The write is debounced now — one
    /// write per pause — and the "saved" tick is shown when the write
    /// actually lands, so the indicator cannot claim a save that has not
    /// happened.
    @State private var draftWriteTask: Task<Void, Never>?
    /// Set once the reply has been sent, so the teardown flush does not put
    /// the body the user just sent back into the draft slot.
    @State private var didSend = false
    /// Set when the user chose to throw the draft away, so the teardown
    /// flush does not put it back either.
    @State private var didDiscard = false
    /// True once the user has written something in this session.
    ///
    /// The body starts out holding the quoted original, so "is the field
    /// empty" is the wrong question — it would ask the user about work
    /// they never did. This asks the question they actually care about:
    /// did *I* write anything?
    @State private var hasEdited = false
    /// True when the composer brought back a draft from an earlier
    /// session, so the sheet can say so.
    @State private var restoredDraft = false
    /// The "this mail is not finished" prompt.
    @State private var showUnsavedAlert = false
    /// Stable across retries; changes only when the composer is created anew.
    ///
    /// The server treats the request id as an idempotency key, so a retry
    /// with the same id either replays the first attempt's answer or
    /// proceeds — it can never send the same mail twice.
    @State private var requestId = UUID().uuidString.lowercased()
    /// Files to send with the reply.
    ///
    /// "Reply with the edited spreadsheet" is the most common reason a
    /// person attaches a file at all, and the reply composer is where
    /// that happens. So attachments live here, not only in the new-message
    /// sheet.
    @State private var attachments: [OutgoingAttachment] = []
    /// The file picker is open.
    @State private var isPickingFiles = false
    private let draftSlot: ComposeFlow.DraftSlot
    private let api = APIClient.shared

    /// The `To:` line split into an array for the reply-all override.
    /// A plain reply passes a single-element array (the same address the
    /// server would have derived), so the send path is uniform.
    ///
    /// The split goes through `AddressList`, not `split(separator: ",")`:
    /// a comma is not always a separator — it can sit inside a quoted
    /// display name (`"Zhang, Wei" <wei@example.com>`) — and splitting on
    /// every comma turned one recipient into two, the second of which was
    /// not an address at all. The server parses the same line with the
    /// same parser, so the client and the server now agree on what the
    /// recipient list is.
    private var toRecipients: [String] {
        AddressList.bareAddresses(to)
    }

    /// How many people this reply reaches.
    private var recipientCount: Int {
        Self.recipientCount(to: to, cc: cc)
    }

    /// How many people this reply reaches.
    ///
    /// The To line and the Cc line together. A reply to forty people is
    /// a wall of addresses; the number is what makes it readable.
    static func recipientCount(to: String, cc: [String]) -> Int {
        AddressList.bareAddresses(to).count + cc.count
    }

    init(
        remoteId: String,
        accountId: UUID,
        to: String,
        cc: [String] = [],
        subject: String,
        initialBody: String = "",
        quotedText: String = "",
        onSent: @escaping (String?) -> Void
    ) {
        self.remoteId = remoteId
        self.accountId = accountId
        self.to = to
        self.cc = cc
        self.subject = subject
        self.quotedText = quotedText
        self.onSent = onSent
        let key = "lagoon.composer.\(accountId.uuidString).\(remoteId)"
        let slot = ComposeFlow.DraftSlot(key: key)
        self.draftSlot = slot
        let saved = slot.load()?.body ?? ""
        // When the user is replying, prepend the original message as a
        // quoted block so they have the context right where they type.
        // The standard "top-post" convention is `\n\n` separator + `> `
        // prefix; line wrapping keeps the quote from exploding sideways
        // on long lines.
        let prefill = Self.restoredBody(
            initialBody: initialBody,
            saved: saved,
            quotedText: quotedText
        )
        _bodyText = State(initialValue: prefill)
        _restoredDraft = State(
            initialValue: initialBody.isEmpty && Self.isUserDraft(saved: saved, quotedText: quotedText)
        )
    }

    /// True when the saved draft is something the user actually wrote.
    ///
    /// The body starts out holding the quoted original, and a slot that
    /// holds only the quote is not a draft — it is the prefill. Saying
    /// "your last draft was restored" about it would be a lie.
    static func isUserDraft(saved: String, quotedText: String) -> Bool {
        guard !saved.isEmpty else { return false }
        guard !quotedText.isEmpty else { return true }
        return saved != formatQuotedReply(quotedText)
    }

    /// What the body starts out holding.
    ///
    /// The order matters: the user's own writing comes before the quoted
    /// original. The quoted block used to win, which meant the draft slot
    /// was filled but never read — the reply a user typed was shadowed by
    /// the mail they were replying to, and "the draft saves automatically"
    /// was a promise the product could not keep.
    ///
    /// An explicitly chosen AI variant still wins over everything: the user
    /// picked it a moment ago.
    static func restoredBody(initialBody: String, saved: String, quotedText: String) -> String {
        if !initialBody.isEmpty { return initialBody }
        if !saved.isEmpty { return saved }
        if !quotedText.isEmpty { return Self.formatQuotedReply(quotedText) }
        return ""
    }

    /// Format the original message body as a quoted block. Top-post
    /// convention: blank line, then each line prefixed with `> ` and
    /// soft-wrapped at ~72 columns. Empty lines inside the quote are
    /// preserved as bare `>` so the block stays visually contiguous.
    static func formatQuotedReply(_ original: String) -> String {
        let wrap = 72
        let quoted = original
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let trimmed = String(line)
                if trimmed.isEmpty { return ">" }
                // Soft-wrap: chunk on whitespace, prefix every chunk.
                var pieces: [String] = []
                var current = ""
                for word in trimmed.split(separator: " ") {
                    if current.isEmpty {
                        current = String(word)
                    } else if current.count + 1 + word.count > wrap {
                        pieces.append(current)
                        current = String(word)
                    } else {
                        current += " " + word
                    }
                }
                if !current.isEmpty { pieces.append(current) }
                return pieces.map { "> \($0)" }.joined(separator: "\n")
            }
            .joined(separator: "\n")
        return "\n\n" + quoted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(l10n.replyRecipientsFixed, systemImage: "arrowshape.turn.up.left").font(.headline)
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
                HStack {
                    Text(l10n.replyTo).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    // The count belongs next to the people it counts. A
                    // reply to forty people is a wall of addresses; the
                    // number is what makes it readable.
                    if recipientCount > 1 {
                        Text(l10n.newMessageRecipientsCount(count: recipientCount))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(to).font(.callout).textSelection(.enabled)
                if !cc.isEmpty {
                    Text(l10n.replyCc).font(.caption).foregroundStyle(.secondary)
                    Text(cc.joined(separator: ", "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text(subject).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                // These fields cannot be edited, and the sheet used to
                // look like a form that had gone wrong. One line says why.
                Text(l10n.replyTitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if restoredDraft {
                Label(l10n.draftRestored, systemImage: "arrow.counterclockwise")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if !quotedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DisclosureGroup {
                    // ScrollView so a long original (typical of forwarded
                    // threads) doesn't push the composer off the sheet.
                    // The previous version truncated at 3000 chars which
                    // silently dropped the tail of any long reply chain.
                    ScrollView {
                        Text(quotedText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                    .frame(maxHeight: 200)
                } label: {
                    Text(l10n.originalMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            attachmentsSection

            TextEditor(text: $bodyText)
                .font(.body)
                .frame(minHeight: 220)
                .padding(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 6).stroke(.quaternary)
                )
                .overlay(alignment: .topLeading) {
                    if bodyText.isEmpty {
                        Text(l10n.replyBodyPlaceholder)
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }
                .onChange(of: bodyText) { _, newValue in
                    hasEdited = true
                    scheduleDraftWrite(newValue)
                }

            if let error {
                failureRow(error)
            }

            HStack(spacing: 10) {
                Text(l10n.shortcutSend).font(.caption).foregroundStyle(.secondary)
                // Live save indicator: a checkmark that fades in briefly
                // after each keystroke. Replaces the old static "Drafts
                // are auto-saved" caption, which read like a footnote
                // rather than a confirmation.
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
                .disabled(isSending)
            }
        }
        .padding(20)
        .frame(width: 560)
        // The sheet is closing: whatever is on screen is what belongs in the
        // draft slot, and the debounced write may still be pending. Flushing
        // here is what keeps a draft that was typed in the last half second
        // from being lost.
        //
        // The flush only happens if the user wrote something. The body
        // starts out holding the quoted original, and a slot full of
        // somebody else's mail is not a draft.
        .onDisappear {
            draftWriteTask?.cancel()
            draftWriteTask = nil
            guard !didSend, !didDiscard else { return }
            guard hasEdited else { return }
            writeDraft(bodyText)
        }
        .fileImporter(
            isPresented: $isPickingFiles,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            handlePickedFiles(result)
        }
        // The prompt for a mail that is not finished. Closing keeps the
        // draft — that is the promise the sheet makes — so the question is
        // never "are you sure you want to lose it". It is whether the user
        // wants to keep the draft or throw it away, and only the second
        // one is a decision worth interrupting for.
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
    /// Above the body, not below it: the user needs to see what is
    /// attached while they write, not after they have written.
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
                    // is on the whole set. A row of file sizes that each
                    // look fine is how four of them add up to a send that
                    // fails at the last moment.
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
                        attachments.removeAll { $0.id == attachment.id }
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

    /// Reads the picked files and turns them into attachments.
    ///
    /// A file that cannot be read, or that is empty or too big, is
    /// reported by name and skipped — the other files still go out.
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
                        mimeType: NewMessageSheet.mimeType(for: url),
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
                    // Checking only the file meant four 24 MB attachments
                    // all passed here and the send failed at the server
                    // with nothing to point at.
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

    /// Schedules the draft write, debounced.
    ///
    /// The task is cancelled and replaced on every keystroke, so a burst of
    /// typing produces one write — at the end of the burst — instead of one
    /// per key press.
    private func scheduleDraftWrite(_ text: String) {
        draftWriteTask?.cancel()
        draftWriteTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            writeDraft(text)
        }
    }

    /// Writes the draft to disk and confirms it.
    private func writeDraft(_ text: String) {
        var draft = ComposeFlow.Draft()
        draft.body = text
        draftSlot.save(draft)
        // Flash the "saved" checkmark for 1.6 s after the write lands. The
        // reset task is cancelled and replaced so a second write does not
        // leave the indicator stuck on.
        draftSavedResetTask?.cancel()
        draftJustSaved = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        draftSavedResetTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_600))
            guard !Task.isCancelled else { return }
            draftJustSaved = false
        }
    }

    // MARK: - Leaving

    /// Closes the sheet — keeping the draft, or asking first.
    ///
    /// The button, the ✕ and the Escape key all come through here, so
    /// there is one way to leave and one promise about what happens to
    /// the work.
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

    // MARK: - Failures

    /// The failure line under the body.
    ///
    /// The message names the cause, because "server returned HTTP 401"
    /// tells the user nothing they can act on. The retry button is only
    /// there when retrying can actually work.
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
        let trimmed = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            error = l10n.emptyReply
            return
        }
        isSending = true
        error = nil
        sendFailure = nil
        do {
            let response = try await api.sendReply(
                remoteId: remoteId,
                accountId: accountId,
                body: trimmed,
                requestId: requestId,
                to: toRecipients,
                cc: cc.isEmpty ? nil : cc,
                attachments: attachments
            )
            // The server's own answer decides. A 200 with `ok: false` is
            // a refusal wearing a success's clothes, and announcing "sent"
            // on it is a promise the user will not check.
            switch ComposeFlow.outcome(of: response) {
            case .rejected:
                sendFailure = .rejected
                error = l10n.sendRejected
            case .accepted(let providerMessageId):
                didSend = true
                // The pending write must not land after the send: it would put
                // the body the user just sent back into the draft slot, and the
                // next reply to the same message would start from the sent text.
                draftWriteTask?.cancel()
                draftWriteTask = nil
                draftSlot.clear()
                // Subtle "Pop" confirms the send landed — the dismiss animation
                // is silent, this fills the gap between "send" and "sheet gone".
                SoundEffects.send()
                onSent(providerMessageId)
                dismiss()
            }
        } catch {
            // The typed body stays put so a retry is one click away.
            let failure = ComposeFlow.Failure.classify(error)
            sendFailure = failure
            self.error = message(for: failure, error: error)
        }
        isSending = false
    }
}
