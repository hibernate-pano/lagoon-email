import SwiftUI
import LagoonKit

/// Sheet for picking one of the AI-generated draft variants and optionally
/// pushing it to Gmail Drafts.
struct DraftPickerSheet: View {
    let draft: DraftReply
    let provider: MailProviderKind
    let onPick: (Int, Bool) -> Void

    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Int = 0
    @State private var pushToGmail: Bool

    init(
        draft: DraftReply,
        provider: MailProviderKind,
        onPick: @escaping (Int, Bool) -> Void
    ) {
        self.draft = draft
        self.provider = provider
        self.onPick = onPick
        _pushToGmail = State(initialValue: provider == .gmail)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(l10n.draftVariants, systemImage: "text.bubble").font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Picker(l10n.pickOne, selection: $selected) {
                ForEach(Array(draft.variants.enumerated()), id: \.offset) { index, _ in
                    Text("\(l10n.variant) \(index + 1)").tag(index)
                }
            }
            .pickerStyle(.segmented)
            Text(draft.variants.indices.contains(selected) ? draft.variants[selected] : "")
                .font(.body)
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            if provider == .gmail {
                Toggle(l10n.chooseAndSendToGmail, isOn: $pushToGmail)
                    .toggleStyle(.switch)
            }
            HStack {
                Spacer()
                if provider == .gmail {
                    Button(l10n.chooseOnly) {
                        onPick(selected, false)
                        dismiss()
                    }
                    Button(l10n.chooseAndSendToGmail) {
                        onPick(selected, true)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button(l10n.chooseOnly) {
                        onPick(selected, false)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
