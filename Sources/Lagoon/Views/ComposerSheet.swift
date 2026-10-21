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
    /// True briefly after each save fires — drives the "Draft saved ✓"
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
    /// Stable across retries; changes only when the composer is created anew.
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
    private let draftKey: String
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
        self.draftKey = key
        let saved = UserDefaults.standard.string(forKey: key) ?? ""
        // When the user is replying, prepend the original message as a
        // quoted block so they have the context right where they type.
        // The standard "top-post" convention is `\n\n` separator + `> `
        // prefix; line wrapping keeps the quote from exploding sideways
        // on long lines.
        let prefill: String
        if !initialBody.isEmpty {
            prefill = initialBody
        } else if !quotedText.isEmpty {
            prefill = Self.formatQuotedReply(quotedText)
        } else {
            prefill = saved
        }
        _bodyText = State(initialValue: prefill)
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
                Label(l10n.replyTitle, systemImage: "arrowshape.turn.up.left").font(.headline)
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
                Text(l10n.replyTo).font(.caption).foregroundStyle(.secondary)
                Text(to).font(.callout).textSelection(.enabled)
                if !cc.isEmpty {
                    Text(l10n.replyCc).font(.caption).foregroundStyle(.secondary)
                    Text(cc.joined(separator: ", "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text(subject).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
                    scheduleDraftWrite(newValue)
                }

            if let error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
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
                    Text(l10n.draftSaved)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .animation(.easeOut(duration: 0.25), value: draftJustSaved)
                Spacer()
                Button(l10n.closeComposer) { dismiss() }
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
        .onDisappear {
            draftWriteTask?.cancel()
            draftWriteTask = nil
            guard !didSend else { return }
            writeDraft(bodyText)
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
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: draftKey)
        } else {
            UserDefaults.standard.set(text, forKey: draftKey)
        }
        // Flash the "saved" checkmark for 1.6 s after the write lands. The
        // reset task is cancelled and replaced so a second write does not
        // leave the indicator stuck on.
        draftSavedResetTask?.cancel()
        draftJustSaved = !trimmed.isEmpty
        draftSavedResetTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_600))
            guard !Task.isCancelled else { return }
            draftJustSaved = false
        }
    }

    private func send() async {
        let trimmed = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            error = l10n.emptyReply
            return
        }
        isSending = true
        error = nil
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
            didSend = true
            // The pending write must not land after the send: it would put
            // the body the user just sent back into the draft slot, and the
            // next reply to the same message would start from the sent text.
            draftWriteTask?.cancel()
            draftWriteTask = nil
            UserDefaults.standard.removeObject(forKey: draftKey)
            // Subtle "Pop" confirms the send landed — the dismiss animation
            // is silent, this fills the gap between "send" and "sheet gone".
            SoundEffects.send()
            onSent(response.providerMessageId)
            dismiss()
        } catch {
            // The typed body stays put so a retry is one click away.
            self.error = l10n.sendFailed + error.lagoonUIMessage
        }
        isSending = false
    }
}
