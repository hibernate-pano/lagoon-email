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
    /// True once the mail has been moved to the server's Trash. Deleted mail
    /// leaves every list, the unread count and search; the message itself
    /// lives in the server's Trash folder until restore or server-side expiry.
    public let isDeleted: Bool
    /// True when the user pinned this mail. Pins live in their own server
    /// table, so every list route has to join them in — without this the
    /// client had no way to know, and the detail view's pin button showed
    /// "置顶" for a mail that was already pinned.
    public let isPinned: Bool
    /// 这封邮件是**我发出的**（位于服务器 Sent 文件夹）。R1。
    public let isSent: Bool
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
        isDeleted: Bool = false,
        isPinned: Bool = false,
        isSent: Bool = false,
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
        self.isDeleted = isDeleted
        self.isPinned = isPinned
        self.isSent = isSent
        self.messageIdHeader = messageIdHeader
        self.inReplyTo = inReplyTo
        self.references = references
    }

    /// Rows written before migration 019 have no `is_deleted` key; tolerate
    /// their absence instead of failing the whole sync response.
    private enum CodingKeys: String, CodingKey {
        case id, accountId, remoteId, threadId
        case fromAddress, fromName, subject, snippet, receivedAt
        case isRead, isArchived, isDeleted, isPinned
        case messageIdHeader, inReplyTo, references
        // camelCase like every other key here. This one was briefly `is_sent`
        // — snake_case, matching the *database* column rather than the wire
        // format — and the mismatch was invisible: `decodeIfPresent` returned
        // nil, the property fell back to `false`, and every sent message
        // decoded as "not sent". No error, no warning, just a flag that was
        // always wrong. The wire format for this type is camelCase throughout
        // and the database column name has no say in it.
        case isSent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        accountId = try c.decode(UUID.self, forKey: .accountId)
        remoteId = try c.decode(String.self, forKey: .remoteId)
        threadId = try c.decode(String.self, forKey: .threadId)
        fromAddress = try c.decode(String.self, forKey: .fromAddress)
        fromName = try c.decodeIfPresent(String.self, forKey: .fromName)
        subject = try c.decodeIfPresent(String.self, forKey: .subject)
        snippet = try c.decodeIfPresent(String.self, forKey: .snippet)
        receivedAt = try c.decode(Date.self, forKey: .receivedAt)
        isRead = try c.decode(Bool.self, forKey: .isRead)
        isArchived = try c.decode(Bool.self, forKey: .isArchived)
        isDeleted = try c.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        // Absent on every row written before R1, so default rather than require.
        isSent = try c.decodeIfPresent(Bool.self, forKey: .isSent) ?? false
        messageIdHeader = try c.decodeIfPresent(String.self, forKey: .messageIdHeader)
        inReplyTo = try c.decodeIfPresent(String.self, forKey: .inReplyTo)
        references = try c.decodeIfPresent(String.self, forKey: .references)
    }

    public func withRead(_ read: Bool) -> MessageHeader {
        MessageHeader(
            id: id, accountId: accountId, remoteId: remoteId, threadId: threadId,
            fromAddress: fromAddress, fromName: fromName, subject: subject, snippet: snippet,
            receivedAt: receivedAt, isRead: read, isArchived: isArchived, isDeleted: isDeleted,
            isPinned: isPinned,
            isSent: isSent,
            messageIdHeader: messageIdHeader, inReplyTo: inReplyTo, references: references
        )
    }

    /// Copy with a new pin state.
    ///
    /// Separate from `withRead` rather than a parameterised copy: pins are a
    /// *user* flag on the message row, while read state also changes from the
    /// sync loop and the dwell timer. Two named helpers keep each call site
    /// honest about which one it means.
    public func withPinned(_ pinned: Bool) -> MessageHeader {
        MessageHeader(
            id: id, accountId: accountId, remoteId: remoteId, threadId: threadId,
            fromAddress: fromAddress, fromName: fromName, subject: subject, snippet: snippet,
            receivedAt: receivedAt, isRead: isRead, isArchived: isArchived, isDeleted: isDeleted,
            isPinned: pinned,
            isSent: isSent,
            messageIdHeader: messageIdHeader, inReplyTo: inReplyTo, references: references
        )
    }
}
