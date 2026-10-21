import SwiftUI
import LagoonKit

/// Sheet shown from the "View details" button on the health banner
/// (spec §4.5). Surfaces `lastSyncAt`, the full `lastError` (monospaced
/// for easy copying), and the negotiated capabilities so the user can
/// tell at a glance whether the server is missing MOVE / IDLE.
struct SyncHealthDetailSheet: View {
    let health: SyncHealth
    let capabilities: MailCapabilities

    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(l10n.healthStatusText(health.status), systemImage: statusIcon)
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

            Group {
                Text(l10n.lastSyncAt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let last = health.lastSyncAt {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(last, format: .relative(presentation: .named))
                            .font(.callout)
                        Text(last.formatted(date: .complete, time: .standard))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } else {
                    Text("—")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if let lastError = health.lastError, !lastError.isEmpty {
                Text(l10n.lastError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // The sentence first — this is the part the user can act on.
                Text(SyncErrorReason.sentence(for: lastError, l10n: l10n))
                    .font(.callout)
                // The raw label stays, but demoted to copyable diagnostics:
                // this is the string a bug report needs, and it is the string
                // the user must not have to decode.
                VStack(alignment: .leading, spacing: 4) {
                    Text(l10n.technicalDetails)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(lastError)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }

            Text(l10n.capabilities)
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                capabilityRow(label: l10n.idleSupported, on: capabilities.idle)
                capabilityRow(label: l10n.moveSupported, on: capabilities.move)
                capabilityRow(label: l10n.archiveSupported, on: capabilities.archiveFolder)
                capabilityRow(label: l10n.uidplusSupported, on: capabilities.uidplus)
                capabilityRow(label: l10n.sentFolderSupported, on: capabilities.sentFolder)
                capabilityRow(label: l10n.trashFolderSupported, on: capabilities.trashFolder)
                if let folder = capabilities.archiveFolderName {
                    Text("\(l10n.archiveFolderName): \(folder)")
                        .font(.callout)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 420, maxWidth: 480)
    }

    /// One capability row.
    ///
    /// Three states, not two: "yes", "no", and "not determined". The third
    /// is not a cosmetic distinction — it is the difference between "this
    /// server cannot do this" (a settled fact the user can act on) and
    /// "Lagoon has not asked yet" (which a red ✗ would misreport as the
    /// former, and send the user looking for a problem that is not there).
    private func capabilityRow(label: String, on: Bool?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: Self.icon(for: on))
                .foregroundStyle(Self.color(for: on))
            Text(label)
                .font(.callout)
                .foregroundStyle(on == false ? .secondary : .primary)
        }
    }

    private static func icon(for on: Bool?) -> String {
        switch on {
        case .some(true): "checkmark.circle.fill"
        case .some(false): "xmark.circle"
        case nil: "questionmark.circle"
        }
    }

    private static func color(for on: Bool?) -> Color {
        switch on {
        case .some(true): .green
        case .some(false): .secondary
        case nil: .secondary.opacity(0.6)
        }
    }

    private var statusIcon: String {
        switch health.status {
        case .ok: "checkmark.circle.fill"
        case .degraded: "exclamationmark.triangle.fill"
        case .needsReconnect: "key.slash"
        case .accountMissing: "questionmark.circle"
        case .error: "exclamationmark.octagon.fill"
        }
    }
}
