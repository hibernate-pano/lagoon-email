import Foundation

/// How far a 「改分组」 override reaches.
///
/// ## Why this type exists
///
/// The override used to have exactly one meaning, and the UI did not say so:
/// the user changed the group on **one** mail, the server stored a
/// preference keyed by that mail, and the briefing resolved it **by sender**
/// — so every mail from that sender moved too. The interface said "change
/// group"; the product did "change group for this sender". That gap is a
/// trust bug, not a wording nit: the user acts on one mail and something
/// broader happens.
///
/// So the scope is now part of the request rather than an accident of the
/// storage:
/// * `.message` — this mail only.
/// * `.sender` — every mail from this sender.
///
/// ## Why it is a plain string on the wire
///
/// The value travels through JSON (client → server) and through a SQLite
/// column, and it is parsed in both places. A `String` raw value with one
/// case per scope keeps the two encodings identical by construction — there
/// is no mapping table to drift — and an unknown value degrades to the
/// **narrower** scope on the server (see the route), because a scope the
/// server does not understand must never be the broad one.
public enum OverrideScope: String, Codable, Sendable, CaseIterable {
    /// Applies to every mail from one sender. This is what the override
    /// always meant before the scope existed.
    case sender
    /// Applies to this mail only.
    case message
}
