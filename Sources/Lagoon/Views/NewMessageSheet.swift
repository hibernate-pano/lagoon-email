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
                Text(l10n.newMessageToLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(l10n.newMessageToPlaceholder, text: $draft.to)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(l10n.newMessageToLabel)
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
            SoundEffects.send()
            onSent(response.providerMessageId)
            dismiss()
        } catch {
            self.error = l10n.sendFailed + error.lagoonUIMessage
        }
        isSending = false
    }
}
