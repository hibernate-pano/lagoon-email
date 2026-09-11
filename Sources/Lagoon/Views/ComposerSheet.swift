import SwiftUI
import LagoonKit

/// Plain-text reply composer. To and Subject are read-only echoes of the
/// stored message: the server derives the envelope from its own row, so
/// editing them here could only lie to the user.
struct ComposerSheet: View {
    let remoteId: String
    let accountId: UUID
    let to: String
    let subject: String
    /// Called with the provider-assigned message id (nil when it reports none)
    /// after the server accepted the reply.
    let onSent: (String?) -> Void

    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss
    @State private var bodyText: String
    @State private var isSending = false
    @State private var error: String?
    private let api = APIClient()

    init(
        remoteId: String,
        accountId: UUID,
        to: String,
        subject: String,
        initialBody: String = "",
        onSent: @escaping (String?) -> Void
    ) {
        self.remoteId = remoteId
        self.accountId = accountId
        self.to = to
        self.subject = subject
        self.onSent = onSent
        _bodyText = State(initialValue: initialBody)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(l10n.replyTitle, systemImage: "arrowshape.turn.up.left").font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(l10n.replyTo).font(.caption).foregroundStyle(.secondary)
                Text(to).font(.callout).textSelection(.enabled)
                Text(subject).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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

            if let error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }

            HStack {
                Text(l10n.shortcutSend).font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button(l10n.cancel) { dismiss() }
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
                remoteId: remoteId, accountId: accountId, body: trimmed
            )
            onSent(response.providerMessageId)
            dismiss()
        } catch {
            // The typed body stays put so a retry is one click away.
            self.error = l10n.sendFailed + error.lagoonUIMessage
        }
        isSending = false
    }
}
