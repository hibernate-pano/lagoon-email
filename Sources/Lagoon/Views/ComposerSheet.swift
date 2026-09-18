import SwiftUI
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
    /// Stable across retries; changes only when the composer is created anew.
    @State private var requestId = UUID().uuidString.lowercased()
    private let draftKey: String
    private let api = APIClient()

    /// The `To:` line split into an array for the reply-all override.
    /// A plain reply passes a single-element array (the same address the
    /// server would have derived), so the send path is uniform.
    private var toRecipients: [String] {
        to.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
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
                    Text(String(quotedText.prefix(3_000)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(.top, 6)
                } label: {
                    Text(l10n.originalMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

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
                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        UserDefaults.standard.removeObject(forKey: draftKey)
                    } else {
                        UserDefaults.standard.set(newValue, forKey: draftKey)
                    }
                }

            if let error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }

            HStack {
                Text(l10n.shortcutSend).font(.caption).foregroundStyle(.secondary)
                Text(l10n.draftSaved).font(.caption2).foregroundStyle(.secondary)
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
                cc: cc.isEmpty ? nil : cc
            )
            UserDefaults.standard.removeObject(forKey: draftKey)
            onSent(response.providerMessageId)
            dismiss()
        } catch {
            // The typed body stays put so a retry is one click away.
            self.error = l10n.sendFailed + error.lagoonUIMessage
        }
        isSending = false
    }
}
