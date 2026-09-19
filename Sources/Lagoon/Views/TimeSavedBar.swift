import SwiftUI
import LagoonKit

/// The persistent status bar (spec §3 step 4: "Today Lagoon saved you 47
/// minutes and handled 132 messages"). Slim, at the window's bottom edge,
/// hidden entirely until something has been handled (principle #4: sections
/// hide when empty). Click opens the week's day-by-day detail.
struct TimeSavedBar: View {
    @EnvironmentObject private var accounts: AccountStore
    @Environment(\.l10n) private var l10n
    @StateObject private var store = TimeSavedStore()
    @State private var showWeek = false

    var body: some View {
        Group {
            if let report = visibleReport {
                bar(report)
            }
        }
        .task(id: accounts.accountId) {
            guard let accountId = accounts.accountId else {
                store.clear()
                return
            }
            while !Task.isCancelled {
                await store.refresh(accountId: accountId)
                do {
                    try await Task.sleep(for: TimeSavedStore.refreshInterval)
                } catch {
                    return
                }
            }
        }
    }

    /// The bar shows the week numbers once today is empty but the week is
    /// not — "you did nothing today" is honest, "there is nothing to show"
    /// after a used week is not.
    private var visibleReport: TimeSavedReport? {
        guard let report = store.report else { return nil }
        if report.today.isEmpty && report.week.isEmpty { return nil }
        return report
    }

    @ViewBuilder
    private func bar(_ report: TimeSavedReport) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "clock.badge.checkmark")
                    .foregroundStyle(.secondary)
                Text(summary(report))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture { showWeek = true }
            .popover(isPresented: $showWeek, arrowEdge: .bottom) {
                weekDetail(report)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    private func summary(_ report: TimeSavedReport) -> String {
        if !report.today.isEmpty {
            return l10n.timeSavedToday(
                minutes: Self.minutes(report.today.minutesSaved),
                handled: report.today.messagesHandled
            )
        }
        return l10n.timeSavedWeek(
            minutes: Self.minutes(report.week.minutesSaved),
            handled: report.week.messagesHandled
        )
    }

    private func weekDetail(_ report: TimeSavedReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(l10n.timeSavedWeekTitle)
                .font(.headline)
            ForEach(report.week.byDay, id: \.date) { day in
                Text(l10n.timeSavedWeekRow(
                    Self.dayFormatter.string(from: day.date),
                    minutes: Self.minutes(day.minutesSaved),
                    handled: day.messagesHandled
                ))
                .font(.caption)
            }
            Divider()
            Text(l10n.timeSavedEstimatedNote)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 240, alignment: .leading)
    }

    /// ≥ 10 minutes reads as a whole number; below that one decimal keeps the
    /// small numbers honest ("0.5 分钟" is a real archive).
    private static func minutes(_ value: Double) -> String {
        if value >= 10, value == value.rounded() {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}
