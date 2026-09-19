import Foundation
import Hummingbird
import Logging
import PostgresNIO
import LagoonKit

/// Declared per-action minute estimates for the time-saved report (spec
/// 2026-09-19 §1). These are honest constants, not measurements: the product
/// claims "time saved", so the numbers and their basis live in one reviewable
/// place and the UI discloses that they are estimates.
///
/// Basis (manual triage benchmarks, adjustable as usage data accumulates):
/// - archive 0.5 min — decide + file one message
/// - unsubscribe 2 min — find the link and confirm
/// - send 2 min — the draft flow versus writing a reply from scratch
///
/// Reads, pins and classification overrides are triage steps, not triage
/// endpoints, so they carry no minutes and no "handled" count.
enum TimeSavedEstimates {
    static let minutesPerAction: [AIActionKind: Double] = [
        .archive: 0.5,
        .unsubscribe: 2,
        .send: 2,
    ]

    static func isHandled(_ kind: AIActionKind) -> Bool {
        kind == .archive || kind == .unsubscribe || kind == .send
    }
}

/// GET /api/time-saved?accountId=… — quantified time saved (spec principle #3).
///
/// Pure aggregation over the append-only `ai_actions` audit log: no new
/// tables, no counters to drift. Actions undone later are excluded by the
/// store query, so the report reflects what actually stuck.
public enum TimeSavedRoutes {
    /// How far back the week window reaches (inclusive days, local calendar).
    static let weekLengthDays = 7

    public static func register(
        on router: Router<BasicRequestContext>,
        db: PostgresConnection,
        logger: Logger
    ) {
        router.get("api/time-saved") { request, _ -> Response in
            guard let accountId = RouteParams.accountId(from: request) else {
                return RouteJSON.error(.badRequest, "malformed-accountId")
            }
            let calendar = Calendar.current
            let now = Date()
            let todayStart = calendar.startOfDay(for: now)
            guard let weekStart = calendar.date(byAdding: .day, value: -(weekLengthDays - 1), to: todayStart) else {
                return RouteJSON.error(.internalServerError, "internal-error")
            }
            let events: [(kind: AIActionKind, createdAt: Date)]
            do {
                events = try await AIActionStore.timeSavedEvents(
                    accountId: accountId,
                    since: weekStart,
                    db: db
                )
            } catch {
                logger.error("time-saved query failed", metadata: [
                    "accountId": .string(accountId.uuidString),
                    "err": .string("\(error)")
                ])
                return RouteJSON.error(.internalServerError, "internal-error")
            }

            func window(since start: Date, withDays: Bool) -> TimeSavedWindow {
                var minutes = 0.0
                var handled = 0
                var sent = 0
                var unsubscribed = 0
                var byDay: [Date: (minutes: Double, handled: Int)] = [:]
                for event in events where event.createdAt >= start {
                    if let perAction = TimeSavedEstimates.minutesPerAction[event.kind] {
                        minutes += perAction
                    }
                    if TimeSavedEstimates.isHandled(event.kind) {
                        handled += 1
                    }
                    if event.kind == .send { sent += 1 }
                    if event.kind == .unsubscribe { unsubscribed += 1 }
                    if withDays {
                        let day = calendar.startOfDay(for: event.createdAt)
                        byDay[day, default: (0, 0)].minutes += TimeSavedEstimates.minutesPerAction[event.kind] ?? 0
                        if TimeSavedEstimates.isHandled(event.kind) {
                            byDay[day, default: (0, 0)].handled += 1
                        }
                    }
                }
                let days = byDay
                    .map { TimeSavedDay(date: $0.key, minutesSaved: $0.value.minutes, messagesHandled: $0.value.handled) }
                    .sorted { $0.date < $1.date }
                return TimeSavedWindow(
                    minutesSaved: (minutes * 10).rounded() / 10,
                    messagesHandled: handled,
                    draftsSent: sent,
                    unsubscribed: unsubscribed,
                    byDay: days
                )
            }

            return RouteJSON.response(TimeSavedReport(
                today: window(since: todayStart, withDays: false),
                week: window(since: weekStart, withDays: true)
            ))
        }
    }
}
