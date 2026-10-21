import SwiftUI
import LagoonKit

/// Monthly LLM cost panel (server: `GET /api/usage`).
struct UsageSheet: View {
    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss
    @State private var report: UsageReport?
    @State private var aiStatus: AIStatus?
    @State private var showAISettings = false
    @State private var errorBanner: ErrorBanner?
    /// The usage report never arrived. Without this the `else` branch below
    /// rendered the "loading" spinner forever: `load()` set `errorBanner` on
    /// failure but left `report` nil, so the panel showed a spinner *and* an
    /// error banner at the same time and never reached an error state.
    @State private var loadFailed = false
    private let api = APIClient.shared

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
                // "$0.1200 / $10.00" left the two numbers to be told apart by
                // the slash alone, and the big one came first — a reader
                // glancing at the panel could take the spend for the cap.
                // Labels cost one word and remove the guess.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(l10n.usageSpentLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(format: "$%.4f", report.monthUSD)).font(.title2).bold()
                    Text("/").foregroundStyle(.tertiary)
                    Text(l10n.usageCapLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                // Only when there is something to show. An empty list means
                // the server did not send a breakdown (an older server) or
                // no AI call has been made this month — and in both cases
                // rendering an empty table would read as "every account
                // spent nothing", a claim the data does not support. Two or
                // more accounts is the case this panel exists for: one
                // account's share is the number already above it.
                if report.accounts.count >= 2 {
                    byAccountSection(report)
                }
            Divider()
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        // The theme's scale, not a hard-coded green: the
                        // colour means "working" / "not working" everywhere
                        // else too, and the text beside it says the same
                        // thing — so the dot is never the only carrier.
                        .fill(
                            (aiStatus?.configured ?? false)
                                ? LagoonTheme.Severity.success.color
                                : LagoonTheme.Severity.warning.color
                        )
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text((aiStatus?.configured ?? false) ? l10n.aiSettingsConfigured : l10n.aiSettingsNotConfigured)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(l10n.aiSettingsTitle) { showAISettings = true }
                    .buttonStyle(.link)
            }
            } else if loadFailed {
                ContentUnavailableView(
                    l10n.emptyUsage,
                    systemImage: "chart.bar",
                    description: Text(l10n.emptyUsageHint)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .sheet(isPresented: $showAISettings, onDismiss: {
            // The monthly cap can change in the AI settings sheet, and the
            // cap is what this panel is about. A panel that keeps showing
            // the old cap after the user changed it is a number that lies.
            Task { await load() }
        }) {
            AISettingsSheet(
                aiStatus: aiStatus,
                // The dot in this panel has to follow the key: the sheet
                // just told the user the AI is live, and a panel still
                // saying "AI 未配置" two inches away would be the same
                // contradiction, in the same window.
                onApplied: { status in aiStatus = status }
            )
        }
    }

    /// The per-account split.
    ///
    /// The bar under each row is a share of **this month's spend**, not of
    /// the cap: the question "where is the money going?" is about the money
    /// that was already spent, and scaling by the cap would draw every row
    /// as a sliver on a month that has barely started.
    ///
    /// The sum of the rows can round to a hair less than the headline (each
    /// share is computed from integer micro-dollars), which is why they are
    /// not presented as a breakdown of the total with percentages: the row
    /// amount is exact, the bar is an illustration.
    private func byAccountSection(_ report: UsageReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(l10n.usageByAccount)
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(report.accounts, id: \.accountEmail) { share in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(share.accountEmail)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(String(format: "$%.4f", share.monthUSD))
                            .font(.callout)
                            .monospacedDigit()
                        Text(l10n.usageAccountCalls(share.callCount))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    ProgressView(value: shareFraction(share, in: report))
                        .controlSize(.small)
                }
                .accessibilityElement(children: .combine)
            }
            Text(l10n.usageByAccountHint)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// One row's bar: its share of the month's total, clamped to 0…1.
    ///
    /// Guarded against a zero total — a month whose calls all had no token
    /// rates records `cost_micro_usd = 0`, and dividing by that would be a
    /// NaN bar rather than an empty one.
    private func shareFraction(_ share: UsageAccountShare, in report: UsageReport) -> Double {
        guard report.monthUSD > 0 else { return 0 }
        return min(1.0, max(0, share.monthUSD / report.monthUSD))
    }

    private func load() async {
        errorBanner = nil
        loadFailed = false
        if let status = try? await api.fetchAIStatus() {
            aiStatus = status
        }
        do {
            report = try await api.fetchUsage()
        } catch {
            // The report stays nil, so the panel needs to know the failure is
            // terminal-for-now rather than "still loading".
            loadFailed = true
            errorBanner = ErrorBanner(
                severity: .error,
                title: l10n.loadFailed,
                detail: error.lagoonUIMessage,
                actionLabel: l10n.retry,
                action: { [self] in await self.load() }
            )
        }
    }
}
