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

    init(
        remoteId: String,
        accountId: UUID,
        to: String,
        subject: String,
        initialBody: String = "",
        quotedText: String = "",
        onSent: @escaping (String?) -> Void
    ) {
        self.remoteId = remoteId
        self.accountId = accountId
        self.to = to
        self.subject = subject
        self.quotedText = quotedText
        self.onSent = onSent
        let key = "lagoon.composer.\(accountId.uuidString).\(remoteId)"
        self.draftKey = key
        let saved = UserDefaults.standard.string(forKey: key) ?? ""
        _bodyText = State(initialValue: initialBody.isEmpty ? saved : initialBody)
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
                requestId: requestId
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
