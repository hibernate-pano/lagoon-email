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
                Text(lastError)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }

            Text(l10n.capabilities)
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                capabilityRow(label: l10n.idleSupported, on: capabilities.idle)
                capabilityRow(label: l10n.moveSupported, on: capabilities.move)
                if let folder = archiveFolderName {
                    Text("\(l10n.archiveFolderName): \(folder)")
                        .font(.callout)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 420, maxWidth: 480)
    }

    private func capabilityRow(label: String, on: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: on ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(on ? .green : .secondary)
            Text(label)
                .font(.callout)
                .foregroundStyle(on ? .primary : .secondary)
        }
    }

    private var statusIcon: String {
        switch health.status {
        case .ok: "checkmark.circle.fill"
        case .degraded: "exclamationmark.triangle.fill"
        case .needsReconnect: "key.slash"
        case .error: "exclamationmark.octagon.fill"
        }
    }

    /// Capabilities include `archiveFolder: Bool` but not the folder
    /// name itself; the server doesn't surface it. Leave the row out
    /// rather than fabricate a name.
    private var archiveFolderName: String? {
        capabilities.archiveFolder ? "✓" : nil
    }
}
