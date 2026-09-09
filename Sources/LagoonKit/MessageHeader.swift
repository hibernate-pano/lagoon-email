import Foundation

public struct MessageHeader: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let accountId: UUID
    public let gmailId: String
    public let threadId: String
    public let fromAddress: String
    public let fromName: String?
    public let subject: String?
    public let snippet: String?
    public let receivedAt: Date
    public let isRead: Bool
    public let isArchived: Bool

    public init(
        id: UUID,
        accountId: UUID,
        gmailId: String,
        threadId: String,
        fromAddress: String,
        fromName: String?,
        subject: String?,
        snippet: String?,
        receivedAt: Date,
        isRead: Bool,
        isArchived: Bool
    ) {
        self.id = id
        self.accountId = accountId
        self.gmailId = gmailId
        self.threadId = threadId
        self.fromAddress = fromAddress
        self.fromName = fromName
        self.subject = subject
        self.snippet = snippet
        self.receivedAt = receivedAt
        self.isRead = isRead
        self.isArchived = isArchived
    }
}