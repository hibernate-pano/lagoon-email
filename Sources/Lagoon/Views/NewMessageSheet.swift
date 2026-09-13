import SwiftUI

/// Plain-text new-message composer. The server owns the From address and
/// validates the recipient; this sheet supplies only To, Subject and body.
struct NewMessageSheet: View {
    let accountId: UUID
    let onSent: (String?) -> Void

    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss

    private struct Draft: Codable, Equatable {
        var to = ""
        var subject = ""
        var body = ""
    }

    @State private var draft: Draft
    @State private var isSending = false
    @State private var error: String?
    @State private var requestId = UUID().uuidString.lowercased()
    private let draftKey: String
    private let api = APIClient()

    init(accountId: UUID, onSent: @escaping (String?) -> Void) {
        self.accountId = accountId
        self.onSent = onSent
        let key = "lagoon.compose.\(accountId.uuidString)"
        self.draftKey = key
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode(Draft.self, from: data) {
            _draft = State(initialValue: saved)
        } else {
            _draft = State(initialValue: Draft())
        }
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
                }
                .buttonStyle(.plain)
            }

            TextField(l10n.newMessageToPlaceholder, text: $draft.to)
                .textFieldStyle(.roundedBorder)
            TextField(l10n.newMessageSubjectPlaceholder, text: $draft.subject)
                .textFieldStyle(.roundedBorder)

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
                Text(l10n.shortcutSend).font(.caption).foregroundStyle(.tertiary)
                Text(l10n.draftSaved).font(.caption2).foregroundStyle(.tertiary)
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
        .frame(width: 620)
        .onChange(of: draft) { _, newValue in
            if newValue.to.isEmpty, newValue.subject.isEmpty, newValue.body.isEmpty {
                UserDefaults.standard.removeObject(forKey: draftKey)
            } else if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: draftKey)
            }
        }
    }

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

        isSending = true
        error = nil
        do {
            let response = try await api.sendNewMessage(
                to: to,
                subject: subject,
                body: body,
                accountId: accountId,
                requestId: requestId
            )
            UserDefaults.standard.removeObject(forKey: draftKey)
            onSent(response.providerMessageId)
            dismiss()
        } catch {
            self.error = l10n.sendFailed + error.lagoonUIMessage
        }
        isSending = false
    }
}
