import Foundation

/// Per-account sync cursor, persisted as `accounts.sync_state` (JSONB).
///
/// Gmail uses `historyId`; IMAP uses `uidValidity`/`lastUid`. `archiveFolder`
/// records the resolved remote archive mailbox name (IMAP only). The `sent*`
/// triple tracks the Sent folder scan that feeds cross-client reply detection
/// (V2 A2): Sent mail is never stored as rows, only its threading references
/// are harvested, so the cursor is all the state it needs.
public struct MailSyncState: Codable, Equatable, Sendable {
    public var historyId: String?
    public var uidValidity: Int64?
    public var lastUid: Int64?
    public var archiveFolder: String?
    public var sentUidValidity: Int64?
    public var sentLastUid: Int64?
    public var sentFolder: String?

    public init(
        historyId: String? = nil,
        uidValidity: Int64? = nil,
        lastUid: Int64? = nil,
        archiveFolder: String? = nil,
        sentUidValidity: Int64? = nil,
        sentLastUid: Int64? = nil,
        sentFolder: String? = nil
    ) {
        self.historyId = historyId
        self.uidValidity = uidValidity
        self.lastUid = lastUid
        self.archiveFolder = archiveFolder
        self.sentUidValidity = sentUidValidity
        self.sentLastUid = sentLastUid
        self.sentFolder = sentFolder
    }
}
