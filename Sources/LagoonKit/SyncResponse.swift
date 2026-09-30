import Foundation

/// Response payload of GET /api/messages. Shared between server and client.
public struct SyncResponse: Codable, Equatable, Sendable {
    public let cursor: SyncCursor
    public let messages: [MessageHeader]
    /// Rows matching the request filter ignoring LIMIT. Nil on payloads
    /// encoded before the server started sending it.
    public let totalCount: Int?

    public init(cursor: SyncCursor, messages: [MessageHeader], totalCount: Int? = nil) {
        self.cursor = cursor
        self.messages = messages
        self.totalCount = totalCount
    }
}