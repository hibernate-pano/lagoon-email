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
    public let gmailDraftId: String
}

public struct SendResponse: Codable, Sendable, Equatable {
    public let ok: Bool
    /// Server-side Message-ID when the provider reports one (SMTP path always
    /// does; Gmail returns its own message id).
    public let providerMessageId: String?
}
