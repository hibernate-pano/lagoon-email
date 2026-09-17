import SwiftUI
import LagoonKit

/// Monthly LLM cost panel (server: `GET /api/usage`).
struct UsageSheet: View {
    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss
    @State private var report: UsageReport?
    @State private var errorBanner: ErrorBanner?
    private let api = APIClient()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(l10n.budgetThisMonth, systemImage: "chart.bar").font(.headline)
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
            if let report {
                ProgressView(value: report.capUSD > 0 ? min(1.0, report.monthUSD / report.capUSD) : 0)
                HStack {
                    Text(String(format: "$%.4f", report.monthUSD)).font(.title2).bold()
                    Text(" / ").foregroundStyle(.secondary)
                    Text(report.capUSD > 0 ? String(format: "$%.2f", report.capUSD) : l10n.budgetDisabled).foregroundStyle(.secondary)
                }
                Text(l10n.usageCallCount(report.callCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if report.capUSD > 0, !report.costTrackingAvailable {
                    Text(l10n.costTrackingUnavailable)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(l10n.budgetThisMonth).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(24)
        .noticeBanner($errorBanner)
        .frame(minWidth: 420, maxWidth: 420, minHeight: 180)
        .task { await load() }
    }

    private func load() async {
        errorBanner = nil
        do {
            report = try await api.fetchUsage()
        } catch {
            errorBanner = ErrorBanner(
                severity: .error,
                title: error.lagoonUIMessage,
                actionLabel: l10n.retry,
                action: { [self] in await self.load() }
            )
        }
    }
}
