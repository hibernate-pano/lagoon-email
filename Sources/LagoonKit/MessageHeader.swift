import Foundation

public struct MessageHeader: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let accountId: UUID
    public let remoteId: String
    public let threadId: String
    public let fromAddress: String
    public let fromName: String?
    public let subject: String?
    public let snippet: String?
    public let receivedAt: Date
    public let isRead: Bool
    public let isArchived: Bool
    /// RFC5322 Message-ID / In-Reply-To / References, captured so replies can
    /// thread correctly (IMAP has no threads API).
    public let messageIdHeader: String?
    public let inReplyTo: String?
    public let references: String?

    public init(
        id: UUID,
        accountId: UUID,
        remoteId: String,
        threadId: String,
        fromAddress: String,
        fromName: String?,
        subject: String?,
        snippet: String?,
        receivedAt: Date,
        isRead: Bool,
        isArchived: Bool,
        messageIdHeader: String? = nil,
        inReplyTo: String? = nil,
        references: String? = nil
    ) {
        self.id = id
        self.accountId = accountId
        self.remoteId = remoteId
        self.threadId = threadId
        self.fromAddress = fromAddress
        self.fromName = fromName
        self.subject = subject
        self.snippet = snippet
        self.receivedAt = receivedAt
        self.isRead = isRead
        self.isArchived = isArchived
        self.messageIdHeader = messageIdHeader
        self.inReplyTo = inReplyTo
        self.references = references
    }
}
