import Foundation

/// Per-account sync cursor, persisted as `accounts.sync_state` (JSONB).
///
/// Gmail uses `historyId`; IMAP uses `uidValidity`/`lastUid`. `archiveFolder`
/// records the resolved remote archive mailbox name (IMAP only).
public struct MailSyncState: Codable, Equatable, Sendable {
    public var historyId: String?
    public var uidValidity: Int64?
    public var lastUid: Int64?
    public var archiveFolder: String?

    public init(
        historyId: String? = nil,
        uidValidity: Int64? = nil,
        lastUid: Int64? = nil,
        archiveFolder: String? = nil
    ) {
        self.historyId = historyId
        self.uidValidity = uidValidity
        self.lastUid = lastUid
        self.archiveFolder = archiveFolder
    }
}
