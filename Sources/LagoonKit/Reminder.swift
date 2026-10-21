import Foundation

/// A reminder the user set for themselves.
///
/// ## Why this type exists
///
/// The AI could say "remind" — it is in the action vocabulary, the row
/// carries a bell icon, and the Chinese copy reads "建议提醒". But nothing
/// was ever stored, nothing was ever scheduled, and nothing ever
/// happened. The user saw a promise the product could not keep, and a
/// product that promises a reminder and does not deliver it teaches the
/// user to distrust every other suggestion.
///
/// So the promise is now backed by a thing: a row, a route, and a local
/// notification. And the due date is the user's own — never the model's.
/// The model may quote a date phrase from the mail ("10 月 8 日前"), but
/// the moment the user sets a reminder is the moment the user chose the
/// time, and the model's phrase is only the starting point.
public struct Reminder: Codable, Equatable, Sendable, Identifiable {
    public let id: Int64
    public let accountId: UUID
    /// The message this reminder is about. A reminder always points at a
    /// mail: a reminder to "reply to the contract" is about a mail, and a
    /// free-floating todo would be a different product.
    public let remoteId: String
    /// The subject of that mail, joined in by the server.
    ///
    /// A reminder list that showed only a time and an id would be a list
    /// the user has to decode — "10月8日 09:00 提醒" next to *what*? The
    /// subject is joined in the same query that reads the reminder, so the
    /// list costs one round trip and not one per row.
    public let subject: String?
    /// When the reminder fires.
    public let dueAt: Date
    /// The user's own note, if any.
    public let note: String?
    public let createdAt: Date
    /// When the user dismissed it, if they did.
    public let dismissedAt: Date?

    public init(
        id: Int64,
        accountId: UUID,
        remoteId: String,
        dueAt: Date,
        note: String? = nil,
        createdAt: Date,
        dismissedAt: Date? = nil,
        subject: String? = nil
    ) {
        self.id = id
        self.accountId = accountId
        self.remoteId = remoteId
        self.dueAt = dueAt
        self.note = note
        self.createdAt = createdAt
        self.dismissedAt = dismissedAt
        self.subject = subject
    }

    /// Whether this reminder is still waiting to fire.
    public var isActive: Bool { dismissedAt == nil }

    /// The same reminder, with the mail's subject filled in.
    ///
    /// The subject is joined in by the store rather than stored on the
    /// reminder row: it belongs to the mail, and a copy on the reminder
    /// would go stale the moment the mail is re-fetched.
    public func withSubject(_ subject: String?) -> Reminder {
        Reminder(
            id: id,
            accountId: accountId,
            remoteId: remoteId,
            dueAt: dueAt,
            note: note,
            createdAt: createdAt,
            dismissedAt: dismissedAt,
            subject: subject
        )
    }
}

/// `GET /api/reminders?accountId=` response.
public struct ReminderListResponse: Codable, Equatable, Sendable {
    public let reminders: [Reminder]
    public init(reminders: [Reminder]) { self.reminders = reminders }
}
