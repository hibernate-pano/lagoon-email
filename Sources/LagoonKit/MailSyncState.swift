import Foundation

/// Per-account sync cursor, persisted as `accounts.sync_state` (TEXT holding
/// `JSONEncoder` output).
///
/// IMAP uses `uidValidity`/`lastUid`. `archiveFolder` records the resolved
/// remote archive mailbox name. The `sent*` triple tracks the Sent folder scan
/// that feeds cross-client reply detection (V2 A2): Sent mail is never stored
/// as rows, only its threading references are harvested, so the cursor is all
/// the state it needs.
public struct MailSyncState: Codable, Equatable, Sendable {
    public var uidValidity: Int64?
    public var lastUid: Int64?
    public var archiveFolder: String?
    public var sentUidValidity: Int64?
    public var sentLastUid: Int64?
    public var sentFolder: String?
    /// The lowest UID the bounded history backfill covered; nil means it has
    /// not run to completion.
    ///
    /// This exists because `lastUid` alone cannot express "how far back we
    /// fetched". It is a high-water mark for *forward* sync, so a first round
    /// that covered only part of the mailbox still parks the cursor at the
    /// top — and every later round looks strictly above it, so the gap is
    /// never revisited and sync reports `ok` over a mailbox it has not read.
    ///
    /// A stored cursor with `lastUid != nil` and `historyFloorUid == nil` is
    /// therefore the signature of a truncated history, and the round refills
    /// it. Optional field in a JSON column: no migration, and an old row
    /// decodes as nil, which is exactly the meaning wanted here.
    public var historyFloorUid: Int64?

    public init(
        uidValidity: Int64? = nil,
        lastUid: Int64? = nil,
        archiveFolder: String? = nil,
        sentUidValidity: Int64? = nil,
        sentLastUid: Int64? = nil,
        sentFolder: String? = nil,
        historyFloorUid: Int64? = nil
    ) {
        self.uidValidity = uidValidity
        self.lastUid = lastUid
        self.archiveFolder = archiveFolder
        self.sentUidValidity = sentUidValidity
        self.sentLastUid = sentLastUid
        self.sentFolder = sentFolder
        self.historyFloorUid = historyFloorUid
    }
}
