import Foundation
import LagoonKit

public struct ArchiveResponse: Codable, Sendable, Equatable {
    public let ok: Bool
    public let remoteId: String
    public let remote: Bool
    public let actionId: Int64
}

public struct UnsubscribeResponse: Codable, Sendable, Equatable {
    public let ok: Bool
    public let unsubscribed: Bool
    public let publisher: String
    public let actionId: Int64
}

public struct ChooseDraftResponse: Codable, Sendable, Equatable {
    public let ok: Bool
    public let draftId: Int64
    public let chosen: Int
}

public struct SendResponse: Codable, Sendable, Equatable {
    public let ok: Bool
    /// Server-side Message-ID reported by the SMTP send path.
    public let providerMessageId: String?
}
