import Foundation
import LagoonKit

public struct ArchiveResponse: Codable, Sendable, Equatable {
    public let ok: Bool
    public let remoteId: String
    public let remote: Bool
}

public struct UnsubscribeResponse: Codable, Sendable, Equatable {
    public let ok: Bool
    public let unsubscribed: Bool
    public let publisher: String
}

public struct ChooseDraftResponse: Codable, Sendable, Equatable {
    public let ok: Bool
    public let draftId: Int64
    public let chosen: Int
    public let gmailDraftId: String
}
