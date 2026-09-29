import SwiftUI
import LagoonKit

/// Sheet for picking one of the AI-generated draft variants. The chosen
/// variant is sent over SMTP — IMAP has no server-side draft concept, so
/// there is nothing to push to.
struct DraftPickerSheet: View {
    let draft: DraftReply
    let onPick: (Int) -> Void

    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(l10n.draftVariants, systemImage: "text.bubble").font(.headline)
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
            if !draft.variants.isEmpty {
                Picker(l10n.pickOne, selection: $selected) {
                    ForEach(Array(draft.variants.enumerated()), id: \.offset) { index, _ in
                        Text("\(l10n.variant) \(index + 1)").tag(index)
                    }
                }
                .pickerStyle(.segmented)
            }
            ScrollView {
                Text(draft.variants.indices.contains(selected) ? draft.variants[selected] : "")
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
            .frame(minHeight: 120, maxHeight: 240)
            HStack {
                Spacer()
                Button(l10n.chooseAndSend) {
                    onPick(selected)
                    dismiss()
                }
                .lineLimit(1)
                .keyboardShortcut(.defaultAction)
                .disabled(draft.variants.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
