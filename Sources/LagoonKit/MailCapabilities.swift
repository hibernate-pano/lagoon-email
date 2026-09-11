import Foundation

/// Runtime-negotiated provider capabilities. IMAP discovers these after LOGIN
/// and LIST (163 has no MOVE, QQ may lack an \Archive folder), so they are
/// account data, not compile-time constants.
public struct MailCapabilities: Codable, Equatable, Sendable {
    public var archiveFolder: Bool
    public var idle: Bool
    public var move: Bool
    public var serverSnippet: Bool

    public static let unknown = MailCapabilities(
        archiveFolder: false, idle: false, move: false, serverSnippet: false
    )

    public init(archiveFolder: Bool, idle: Bool, move: Bool, serverSnippet: Bool) {
        self.archiveFolder = archiveFolder
        self.idle = idle
        self.move = move
        self.serverSnippet = serverSnippet
    }

    /// Tolerant decode: an empty `{}` (pre-008 rows) yields all-false, not a throw.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.archiveFolder = try c.decodeIfPresent(Bool.self, forKey: .archiveFolder) ?? false
        self.idle = try c.decodeIfPresent(Bool.self, forKey: .idle) ?? false
        self.move = try c.decodeIfPresent(Bool.self, forKey: .move) ?? false
        self.serverSnippet = try c.decodeIfPresent(Bool.self, forKey: .serverSnippet) ?? false
    }
}
