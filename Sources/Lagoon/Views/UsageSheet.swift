import SwiftUI
import LagoonKit

/// Monthly LLM cost panel (server: `GET /api/usage`).
struct UsageSheet: View {
    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss
    @State private var report: UsageReport?
    @State private var error: String?
    private let api = APIClient()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(l10n.budgetThisMonth, systemImage: "chart.bar").font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain)
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
            } else if let error {
                Text(error).foregroundStyle(.red)
            } else {
                ProgressView()
            }
        }
        .padding(24)
        .frame(width: 420)
        .task {
            do {
                report = try await api.fetchUsage()
            } catch let apiError {
                error = apiError.lagoonUIMessage
            }
        }
    }
}
