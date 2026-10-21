import Foundation

/// A one-shot notice the store raises to the user.
///
/// ## Why this exists
///
/// The store can reach a state the user cannot see: a migration that had to
/// **delete** rows because they could not be encrypted. The bodies case was
/// silent by design — a body is a cache, and the next sync fetches it again,
/// so nothing is lost and nothing has to be said.
///
/// A draft is the same kind of thing (the model can regenerate it) but the
/// *deletion* is an action the user did not ask for and cannot undo. A
/// product that quietly throws work away is a product the user stops
/// trusting, so the deletion is written down where it can be shown.
///
/// The notice is **stored**, not logged: the app may not be running when the
/// migration happens, and a line in a log file is not something the user
/// will ever read. It sits in the database until the client picks it up and
/// acknowledges it, so "your drafts were deleted" reaches the person whose
/// drafts they were — whenever that is.
public struct StoreNotice: Codable, Sendable, Equatable, Identifiable {
    /// The stable identity of the notice.
    ///
    /// It is a *stable* id rather than a random one, so the same condition
    /// raised twice does not become two rows, and so the client can decide
    /// it has already shown this one.
    public let id: String
    /// When the store raised it.
    public let createdAt: Date
    /// A machine-readable detail — the numbers a client needs to phrase the
    /// notice in the user's language. Never the content of what was lost.
    public let detail: String?

    public init(id: String, createdAt: Date, detail: String? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.detail = detail
    }

    /// The notice raised when cached drafts had to be dropped because the
    /// store could not be encrypted.
    ///
    /// The id is fixed so that the row is written at most once per install:
    /// the condition is "there was no key", which happens at most once.
    public static let draftsDroppedID = "drafts-dropped-no-key"
}

/// `GET /api/store-notices` response.
///
/// It lives here rather than next to the route because the **client** has to
/// decode it, and the client does not link the server module — the two
/// halves of the wire format have to be able to see each other.
public struct StoreNoticeListResponse: Codable, Sendable, Equatable {
    public let notices: [StoreNotice]

    public init(notices: [StoreNotice]) {
        self.notices = notices
    }
}
