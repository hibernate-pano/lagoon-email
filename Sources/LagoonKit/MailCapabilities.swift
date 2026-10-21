import Foundation

/// Runtime-negotiated provider capabilities. IMAP discovers these after LOGIN
/// and LIST (163 has no MOVE, QQ may lack an \Archive folder), so they are
/// account data, not compile-time constants.
///
/// ## Why the newer fields are optional
///
/// `idle` / `move` / `serverSnippet` are plain `Bool`s: they have been part
/// of the record since it was introduced, so every stored account row already
/// carries a real answer for each of them, and no gate is built on them.
///
/// The roles that **gate a verb** — `archiveFolder`, the folder roles
/// (`trashFolder`, `sentFolder`) and `uidplus` — are `Bool?`, because a
/// gate has to tell "the server said no" apart from "nobody has asked yet".
/// `nil` means "not determined", and `false` means "determined: the server
/// does not have it". Collapsing those two states is a data-loss-shaped bug
/// in both directions: a row written before these fields existed decodes
/// with them absent, and a client that read "absent" as "no" switches the
/// verb off for every account that connected before the upgrade — with no
/// way for the user to get it back. That is exactly what happened to
/// `archiveFolder`, which stayed a plain `Bool` while the other roles moved
/// to three states: one store's account row carried the all-false default
/// (the row could not be found to negotiate, so nothing was ever written),
/// and every archive right through to `bulk archive` answered
/// `409 archive-unavailable` — a settled "no" the server had never given.
///
/// A `Bool?` encodes the three states exactly, and it costs nothing at the
/// wire: `nil` is omitted from the JSON, and an absent key decodes back to
/// `nil`.
public struct MailCapabilities: Codable, Equatable, Sendable {
    /// Whether the account has an archive target.
    ///
    /// `nil` is "not determined", and the gates read that as *allowed*
    /// (see `allowsArchive`): the server is the authority and answers
    /// `409 archive-unavailable` when the folder really is missing. A
    /// settled `false` — a real probe that could neither find nor create
    /// the folder — still closes the gate.
    public var archiveFolder: Bool?
    public var idle: Bool
    public var move: Bool
    public var serverSnippet: Bool

    /// Whether the server supports UIDPLUS (RFC 4315).
    ///
    /// This is the difference between "delete this mail" and "this server
    /// will not let me delete this mail". Without UIDPLUS, a permanent
    /// delete cannot be scoped to one message — `UID EXPUNGE` is the only
    /// way to remove exactly the message the user picked, and the server
    /// refuses rather than risk expunging another client's deletions.
    ///
    /// The client used to learn this only by clicking a button and getting
    /// a 409. A capability is exactly the thing that should be known
    /// *before* the click.
    public var uidplus: Bool?

    /// Whether the account has a Sent-role mailbox.
    ///
    /// The 「已发送」 surface reads that folder. A server with no Sent
    /// mailbox answers `sent-unavailable`, and the user finds out by
    /// opening an empty surface and being told it failed.
    public var sentFolder: Bool?

    /// Whether the account has a Trash-role mailbox.
    ///
    /// Delete moves mail to the server's trash. Without one, there is
    /// nowhere to put it — the server answers 409 `delete-unavailable`
    /// rather than inventing a folder, because inventing one would fake
    /// the delete semantics the whole undo story rests on.
    public var trashFolder: Bool?

    /// The archive folder's actual name, when the server has one.
    ///
    /// The capability says *whether* archiving works; this says *where* the
    /// mail goes, which is the question a user actually has when something
    /// looks wrong ("归档到哪儿了？"). The name is the server's own, not one
    /// Lagoon invented — QQ answers `Archive`, some servers answer `归档`.
    public var archiveFolderName: String?

    public static let unknown = MailCapabilities(
        archiveFolder: nil, idle: false, move: false, serverSnippet: false
    )

    public init(
        archiveFolder: Bool?,
        idle: Bool,
        move: Bool,
        serverSnippet: Bool,
        uidplus: Bool? = nil,
        sentFolder: Bool? = nil,
        trashFolder: Bool? = nil,
        archiveFolderName: String? = nil
    ) {
        self.archiveFolder = archiveFolder
        self.idle = idle
        self.move = move
        self.serverSnippet = serverSnippet
        self.uidplus = uidplus
        self.sentFolder = sentFolder
        self.trashFolder = trashFolder
        self.archiveFolderName = archiveFolderName
    }

    /// Tolerant decode: an empty `{}` (pre-008 rows) yields all-false, not a throw.
    ///
    /// The optionals decode as `nil` when the key is absent, which is the
    /// whole point — see the type's doc comment.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.archiveFolder = try c.decodeIfPresent(Bool.self, forKey: .archiveFolder)
        self.idle = try c.decodeIfPresent(Bool.self, forKey: .idle) ?? false
        self.move = try c.decodeIfPresent(Bool.self, forKey: .move) ?? false
        self.serverSnippet = try c.decodeIfPresent(Bool.self, forKey: .serverSnippet) ?? false
        self.uidplus = try c.decodeIfPresent(Bool.self, forKey: .uidplus)
        self.sentFolder = try c.decodeIfPresent(Bool.self, forKey: .sentFolder)
        self.trashFolder = try c.decodeIfPresent(Bool.self, forKey: .trashFolder)
        self.archiveFolderName = try c.decodeIfPresent(String.self, forKey: .archiveFolderName)
    }
}

extension MailCapabilities {
    /// Whether the delete verb can be offered at all.
    ///
    /// "Not determined" reads as *allowed*, on purpose. The server is the
    /// authority: it resolves the trash folder at request time and answers
    /// 409 `delete-unavailable` when the folder really is missing. A client
    /// that refused on a stale or absent answer would be stricter than the
    /// server — and a user locked out of delete by a cached guess cannot
    /// appeal the guess.
    public var allowsDelete: Bool { trashFolder != false }

    /// Whether 彻底删除 can be offered.
    ///
    /// A permanent delete is `UID EXPUNGE` on one message, so it needs
    /// UIDPLUS. Without it the server refuses rather than expunge another
    /// client's pending deletions, and there is no honest way to offer the
    /// verb.
    public var allowsPurge: Bool { uidplus != false }

    /// Whether the 已发送 surface can be offered.
    public var allowsSent: Bool { sentFolder != false }

    /// Whether the archive verb can be offered.
    ///
    /// "Not determined" reads as *allowed*, for the same reason the other
    /// roles do: the server is the authority and answers
    /// `409 archive-unavailable` when it really cannot archive. A settled
    /// `false` — a probe that could neither find nor create the folder —
    /// still closes the gate.
    ///
    /// This used to be `archiveFolder` directly, on the theory that a
    /// `false` was always a settled verdict. It was not: the row could hold
    /// the all-false default simply because nobody had ever negotiated, and
    /// then the client and the route both refused to archive — a "no" the
    /// server never said.
    public var allowsArchive: Bool { archiveFolder != false }
}
