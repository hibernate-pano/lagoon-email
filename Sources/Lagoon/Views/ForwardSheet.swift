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

    @State private var draft: ComposeFlow.Draft
    /// The draft as the sheet settled on it.
    ///
    /// What the user changed since then is what "unfinished work" means.
    /// The subject is seeded when the sheet opens, and a seeded value is
    /// not something the user wrote.
    @State private var settled: ComposeFlow.Draft
    /// True when the composer brought back a draft from an earlier
    /// session.
    @State private var restoredDraft = false
    /// True while the sheet is putting its own default subject into the
    /// field.
    ///
    /// The seed is the sheet's own doing, not the user's, so it must not
    /// be written into the draft slot: a slot that holds nothing but the
    /// default subject would come back as "your last draft was
    /// restored".
    @State private var isSeeding = false
    @State private var isSending = false
    @State private var error: String?
    /// Why the last send failed, when it did. Drives whether the failure
    /// row offers a retry.
    @State private var sendFailure: ComposeFlow.Failure?
    @State private var requestId = UUID().uuidString.lowercased()
    /// The pending draft write, debounced.
    @State private var draftWriteTask: Task<Void, Never>?
    /// True briefly after each save lands.
    @State private var draftJustSaved = false
    @State private var draftSavedResetTask: Task<Void, Never>?
    /// Set once the forward went out, so the teardown flush does not put
    /// the note back into the draft slot.
    @State private var didSend = false
    /// Set when the user chose to throw the draft away.
    @State private var didDiscard = false
    /// The "this mail is not finished" prompt.
    @State private var showUnsavedAlert = false

    private let draftSlot: ComposeFlow.DraftSlot
    private let api = APIClient.shared

    init(
        accountId: UUID,
        remoteId: String,
        originalSubject: String? = nil,
        onSent: @escaping (String?) -> Void
    ) {
        self.accountId = accountId
        self.remoteId = remoteId
        self.originalSubject = originalSubject
        self.onSent = onSent
        let key = "lagoon.forward.\(accountId.uuidString).\(remoteId)"
        let slot = ComposeFlow.DraftSlot(key: key)
        self.draftSlot = slot
        let saved = slot.load()
        let initial = saved ?? ComposeFlow.Draft()
        _draft = State(initialValue: initial)
        _settled = State(initialValue: initial)
        _restoredDraft = State(initialValue: saved != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(l10n.forward, systemImage: "arrowshape.turn.up.right")
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
                // The subject is seeded, not required: the server derives
                // "Fwd: <original>" when the field is empty, and the user can
                // still change it.
                TextField(subjectPlaceholder, text: $draft.subject)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(l10n.newMessageSubjectLabel)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(l10n.forwardNoteLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $draft.body)
                    .font(.body)
                    .frame(minHeight: 100)
                    .padding(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.quaternary)
                    )
                    .overlay(alignment: .topLeading) {
                        if draft.body.isEmpty {
                            Text(l10n.forwardNotePlaceholder)
                                .font(.body)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 12)
                                .allowsHitTesting(false)
                        }
                    }
            }

            if restoredDraft {
                Label(l10n.draftRestored, systemImage: "arrow.counterclockwise")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // What the recipient will actually get. The previous forward
            // looked like a forward and was not one, and the user had no
            // way to tell — so the sheet says what happens to the original.
            //
            // The sentence asks for an emphasis with `**`, and a plain
            // `Text` shows the asterisks; rendering it as Markdown makes
            // the emphasis real.
            Label {
                Text(Self.emphasis(l10n.forwardKeepsOriginal))
            } icon: {
                Image(systemName: "envelope.badge")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)

            if let error {
                failureRow(error)
            }

            HStack(spacing: 10) {
                Text(l10n.shortcutSend).font(.caption).foregroundStyle(.secondary)
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
                .disabled(isSending || !canSend)
                .help(canSend ? l10n.send : l10n.sendNeedsRecipient)
            }
        }
        .padding(20)
        .frame(width: LagoonSheetSize.composer.width)
        .onAppear {
            // The subject is seeded, not required: the server derives
            // "Fwd: <original>" when the field is empty, and the user can
            // still change it.
            if draft.subject.isEmpty, !restoredDraft, let original = knownOriginalSubject {
                isSeeding = true
                draft.subject = Self.forwardSubject(original)
            }
            // The sheet has settled now: whatever the user changes from
            // here on is work they did.
            settled = draft
        }
        .onChange(of: draft) { _, newValue in
            // The seed is the sheet's own default, not something the user
            // wrote, and it does not belong in the draft slot.
            if isSeeding {
                isSeeding = false
                return
            }
            scheduleDraftWrite(newValue)
        }
        // The sheet is closing: whatever is on screen is what belongs in
        // the draft slot, and the debounced write may still be pending.
        //
        // The flush only happens if the user wrote something. The sheet's
        // own default subject is not a draft, and a slot holding nothing
        // but the default would come back as "your last draft was
        // restored".
        .onDisappear {
            draftWriteTask?.cancel()
            draftWriteTask = nil
            guard !didSend, !didDiscard else { return }
            guard hasEdited else { return }
            writeDraft(draft)
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

    /// The original's subject, or nil when the client does not really know it.
    ///
    /// The reader hands over its *display* subject, which falls back to the
    /// "（无主题）" placeholder when the message has none. That placeholder
    /// is not a subject: seeding it would put "Fwd: （无主题）" on the
    /// wire and call it the user's mail.
    private var knownOriginalSubject: String? {
        Self.knownSubject(originalSubject, noSubject: l10n.noSubject)
    }

    /// The original's subject, or nil when the client does not really know it.
    ///
    /// The reader hands over its *display* subject, which falls back to the
    /// "（无主题）" placeholder when the message has none. That placeholder
    /// is not a subject: seeding it would put "Fwd: （无主题）" on the
    /// wire and call it the user's mail.
    static func knownSubject(_ original: String?, noSubject: String) -> String? {
        guard let original else { return nil }
        let trimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != noSubject else { return nil }
        return trimmed
    }

    /// What the subject field says when it is empty.
    ///
    /// When the client knows the original's subject, the field is seeded
    /// with it and needs no hint. When it does not, the hint names what
    /// will happen instead — the server derives the subject from its own
    /// copy of the original.
    private var subjectPlaceholder: String {
        knownOriginalSubject == nil ? l10n.forwardSubjectDefault : ""
    }

    /// Whether the user wrote their own subject.
    ///
    /// A subject the user did not write is not sent: the server derives
    /// "Fwd: <original>" from the row it already has, which is the
    /// authoritative copy. The client only holds the reader's display
    /// subject, and that one can be a placeholder.
    private var subjectWasEdited: Bool {
        draft.subject != settled.subject
    }

    /// Whether the forward has somebody to go to.
    private var canSend: Bool {
        !toAddresses.isEmpty
    }

    /// Whether the user has written anything since the sheet settled.
    private var hasEdited: Bool {
        draft != settled
    }

    /// The seeded subject: "Fwd:" once, the original's subject kept.
    static func forwardSubject(_ original: String?) -> String {
        let base = (original ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if base.lowercased().hasPrefix("fwd:") { return base }
        return base.isEmpty ? "Fwd:" : "Fwd: \(base)"
    }

    /// The sentence about the original, with its emphasis rendered.
    ///
    /// The line reads "the original travels **as the original**". A plain
    /// `Text` does not read `**` as anything, so the user saw the
    /// asterisks — the emphasis the sentence was written for did not
    /// happen, and the markers drew the eye instead.
    static func emphasis(_ raw: String) -> AttributedString {
        (try? AttributedString(markdown: raw)) ?? AttributedString(raw)
    }

    // MARK: - Draft persistence

    /// Schedules the draft write, debounced.
    private func scheduleDraftWrite(_ value: ComposeFlow.Draft) {
        draftWriteTask?.cancel()
        draftWriteTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            writeDraft(value)
        }
    }

    /// Writes the draft to disk and confirms it.
    ///
    /// The note is the only part of a forward that cannot be rebuilt from
    /// the server: the original travels as itself, and the words the user
    /// wrote on top of it exist nowhere else. So the note is kept the way
    /// the other two composers keep their drafts.
    private func writeDraft(_ value: ComposeFlow.Draft) {
        draftSlot.save(value)
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

    // MARK: - Send

    private var toAddresses: [String] {
        AddressList.split(draft.to)
    }

    private var ccAddresses: [String] {
        AddressList.split(draft.cc)
    }

    private var bccAddresses: [String] {
        AddressList.split(draft.bcc)
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
        sendFailure = nil
        do {
            let response = try await api.forwardMessage(
                remoteId: remoteId,
                to: recipients,
                body: draft.body,
                subject: subjectWasEdited
                    ? draft.subject.trimmingCharacters(in: .whitespacesAndNewlines)
                    : nil,
                accountId: accountId,
                requestId: requestId,
                cc: ccAddresses,
                bcc: bccAddresses
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

    // MARK: - Failures

    /// The failure line under the note: the cause, named, and a retry when
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
}
