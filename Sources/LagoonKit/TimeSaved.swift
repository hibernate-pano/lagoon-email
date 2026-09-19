import Foundation

/// `GET /api/time-saved` payload (spec principle #3: quantified time saved).
///
/// The minutes are **declared estimates, not measurements** — the server
/// multiplies audited action counts by per-kind constants. The UI must say
/// so ("估算"), the same way the usage panel discloses an unenforceable
/// dollar cap.
public struct TimeSavedReport: Codable, Sendable, Equatable {
    public let today: TimeSavedWindow
    public let week: TimeSavedWindow

    public init(today: TimeSavedWindow, week: TimeSavedWindow) {
        self.today = today
        self.week = week
    }
}

/// One aggregation window (today / last 7 days).
public struct TimeSavedWindow: Codable, Sendable, Equatable {
    /// Sum of per-kind minute estimates for handled mail.
    public let minutesSaved: Double
    /// archive + unsubscribe + send: actions that finish triage on a message.
    /// Reads and pins do not count — they are not a triage endpoint.
    public let messagesHandled: Int
    /// Replies actually sent (idempotent retries collapse in the audit log).
    public let draftsSent: Int
    public let unsubscribed: Int
    /// Per-day breakdown for the week window (ascending by day). Empty for
    /// the today window.
    public let byDay: [TimeSavedDay]

    public init(
        minutesSaved: Double,
        messagesHandled: Int,
        draftsSent: Int,
        unsubscribed: Int,
        byDay: [TimeSavedDay] = []
    ) {
        self.minutesSaved = minutesSaved
        self.messagesHandled = messagesHandled
        self.draftsSent = draftsSent
        self.unsubscribed = unsubscribed
        self.byDay = byDay
    }

    /// True when nothing was handled in this window — the status bar hides
    /// instead of showing zeros (spec principle #4: sections hide when empty).
    public var isEmpty: Bool {
        messagesHandled == 0 && draftsSent == 0 && unsubscribed == 0
    }
}

public struct TimeSavedDay: Codable, Sendable, Equatable {
    /// Local midnight of the aggregated day.
    public let date: Date
    public let minutesSaved: Double
    public let messagesHandled: Int

    public init(date: Date, minutesSaved: Double, messagesHandled: Int) {
        self.date = date
        self.minutesSaved = minutesSaved
        self.messagesHandled = messagesHandled
    }
}
