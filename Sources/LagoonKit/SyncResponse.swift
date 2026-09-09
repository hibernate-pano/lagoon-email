import Foundation

/// Response payload of GET /api/messages. Shared between server and client.
public struct SyncResponse: Codable, Equatable, Sendable {
    public let cursor: SyncCursor
    public let messages: [MessageHeader]

    public init(cursor: SyncCursor, messages: [MessageHeader]) {
        self.cursor = cursor
        self.messages = messages
    }
}