import Foundation
import GRDB

/// The data-export engine: one consistent database snapshot, and one `.mbox`
/// of every locally-known message.
///
/// ## Why the snapshot is `VACUUM INTO ?` and not a file copy
///
/// The database is a WAL `DatabasePool`. In WAL mode a committed write can
/// still live in `lagoon.sqlite-wal` and not be in `lagoon.sqlite` yet, so a
/// plain `FileManager.copyItem` of the `.sqlite` file is **not** a backup: it
/// silently omits the newest mail and, worse, omits it without any error the
/// user can see. The user guide's old advice ("quit the app, copy this one
/// file, three files if you want to be safe") was three files with no
/// consistency guarantee at any moment.
///
/// `VACUUM INTO` asks SQLite for a transactionally consistent copy: it runs
/// against a read snapshot, so concurrent writes cannot tear it, and it writes
/// a **fresh database in `journal_mode=delete`** — a single file with no
/// `-wal`/`-shm` siblings. That is exactly the artifact a user can copy to a
/// USB stick or onto a new Mac.
///
/// ### Why not GRDB's `Database.backup(to:)`
///
/// It is also transactionally safe, and it was the first choice. It was
/// measured, not assumed: `backup(to:)` copies the source's page image
/// **including its journal mode**, so the destination is a WAL database. The
/// resulting file is consistent, but every later open of it creates
/// `-wal`/`-shm` next to it — so "back up = copy this one file" is only true
/// until the user opens the backup once. `VACUUM INTO` has no such tail: the
/// file it produces is a single file in `delete` mode, forever.
///
/// The path is **bound**, never interpolated: `scripts/ci-guardrails.sh`
/// rule 1 rejects SQL built with string interpolation, and a user file name
/// is untrusted text. `VACUUM INTO ?` accepts a bound parameter (verified
/// against SQLite 3.54 via the C API before this was written).
///
/// ## Why the export is one `.mbox`
///
/// `.mbox` is the format every mail client can import (Thunderbird, Outlook,
/// Apple Mail, mutt). A directory of `.eml` files is more robust for enormous
/// mailboxes but every one of those clients needs the mbox path for
/// "import my old mail", and one file is one thing for the user to move.
///
/// ## Threading
///
/// Both entry points are synchronous and blocking on purpose: they do real
/// disk and network work. Callers run them off the main actor — the UI stays
/// responsive and the progress callback drives the indicator.
public enum BackupService {
    /// A finished snapshot.
    public struct Snapshot: Sendable, Equatable {
        public let url: URL
        public let byteCount: Int
    }

    /// The outcome of an export.
    public struct ExportSummary: Sendable, Equatable {
        public let url: URL
        /// Messages written into the file.
        public let exported: Int
        /// Messages the provider could not supply. Counted, never hidden: a
        /// file that silently dropped a hundred mails is the quiet wrong
        /// answer this product refuses to give.
        public let skipped: Int
    }

    /// How many consecutive per-message failures mean "the provider is not
    /// answering" rather than "this one message is gone".
    ///
    /// Individual messages genuinely vanish (deleted from another client
    /// between the sync and the export), and aborting a 3,000-message export
    /// over one of them would be useless. But if the first several all fail,
    /// the export is not working at all, and continuing would write an
    /// almost-empty file and call it a success.
    static let consecutiveFailureLimit = 5

    // MARK: - Snapshot

    /// Take a consistent snapshot of the app's database into `destination`.
    ///
    /// The write is atomic from the user's point of view: the snapshot is
    /// built beside the destination and only moved into place once SQLite has
    /// finished and the file has been verified. A failure therefore never
    /// leaves the user holding a truncated `.sqlite` that looks like a
    /// backup — the worst possible outcome for a feature whose entire job is
    /// trust.
    public static func snapshotDatabase(to destination: URL) throws -> Snapshot {
        guard let database = LagoonDataPaths.databaseURL else {
            throw BackupError.databaseUnavailable
        }
        return try makeSnapshot(from: database, to: destination)
    }

    /// The testable core of `snapshotDatabase(to:)`.
    public static func makeSnapshot(from source: URL, to destination: URL) throws -> Snapshot {
        // The file has to be there before anything else: opening a missing
        // path would create an empty database and "successfully" snapshot
        // nothing, which is the one failure the user would never notice.
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw BackupError.databaseUnavailable
        }
        let directory = destination.deletingLastPathComponent()
        // The panel may hand back a path inside a folder the user just made.
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        // `VACUUM INTO` refuses to write over an existing file, and the
        // destination may already exist (NSSavePanel lets the user pick it
        // and confirms the overwrite). A sibling temp file solves both: the
        // old backup stays intact until the new one is complete.
        let staging = directory.appendingPathComponent(
            ".lagoon-snapshot-\(UUID().uuidString).sqlite"
        )
        defer { try? FileManager.default.removeItem(at: staging) }

        let connection = try openReadConnection(at: source)
        do {
            try connection.writeWithoutTransaction { db in
                // Bound, never interpolated — see the type comment.
                try db.execute(sql: "VACUUM INTO ?", arguments: [staging.path])
            }
        } catch {
            throw BackupError.snapshotFailed(reason: error.localizedDescription)
        }

        let size = (try? FileManager.default.attributesOfItem(
            atPath: staging.path
        )[.size] as? Int) ?? nil
        guard let size, size > 0 else {
            throw BackupError.snapshotFailed(reason: L10n.current.backupSnapshotEmpty)
        }
        try verifySnapshot(at: staging)
        try replaceItem(at: destination, with: staging)
        return Snapshot(url: destination, byteCount: size)
    }

    /// Opens the live database **without** taking a write lock on the app's
    /// own pool, and without ever creating a file.
    ///
    /// A read-only connection is the default because it cannot possibly
    /// modify the user's mail. The fallback exists for one real case: a
    /// read-only WAL connection needs the `-shm` file, and if the app's
    /// server has not opened the pool yet (or a previous run closed it
    /// cleanly and the shm is gone) SQLite answers `SQLITE_CANTOPEN`. The
    /// file demonstrably exists at that point — checked above — so opening it
    /// read-write without `CREATE` is safe and cannot invent a database.
    private static func openReadConnection(at source: URL) throws -> DatabaseQueue {
        var readOnly = Configuration()
        readOnly.readonly = true
        // Same policy the pool uses: wait for the writer rather than fail the
        // backup because a sync round happened to be committing.
        readOnly.busyMode = .timeout(10)
        do {
            return try DatabaseQueue(path: source.path, configuration: readOnly)
        } catch {
            var readWrite = Configuration()
            readWrite.busyMode = .timeout(10)
            do {
                return try DatabaseQueue(path: source.path, configuration: readWrite)
            } catch {
                throw BackupError.snapshotFailed(reason: error.localizedDescription)
            }
        }
    }

    /// Reads the snapshot back before handing it to the user.
    ///
    /// `VACUUM INTO` succeeding is already strong evidence, but "is this file
    /// actually a database" is the question the user will ask when they need
    /// it — and a backup that only fails at restore time has failed too late.
    /// `quick_check` walks the b-tree structure without the full-page cost of
    /// `integrity_check`.
    private static func verifySnapshot(at url: URL) throws {
        var readOnly = Configuration()
        readOnly.readonly = true
        let connection: DatabaseQueue
        do {
            connection = try DatabaseQueue(path: url.path, configuration: readOnly)
        } catch {
            throw BackupError.snapshotFailed(reason: error.localizedDescription)
        }
        let verdict: String?
        do {
            verdict = try connection.read { db in
                try String.fetchOne(db, sql: "PRAGMA quick_check")
            }
        } catch {
            throw BackupError.snapshotFailed(reason: error.localizedDescription)
        }
        guard verdict == "ok" else {
            throw BackupError.snapshotFailed(
                reason: verdict ?? L10n.current.backupSnapshotEmpty
            )
        }
    }

    /// Moves `staging` onto `destination`, replacing what is there.
    private static func replaceItem(at destination: URL, with staging: URL) throws {
        let manager = FileManager.default
        do {
            if manager.fileExists(atPath: destination.path) {
                _ = try manager.replaceItemAt(destination, withItemAt: staging)
            } else {
                try manager.moveItem(at: staging, to: destination)
            }
        } catch {
            throw BackupError.snapshotFailed(reason: error.localizedDescription)
        }
    }

    // MARK: - mbox export

    /// One message to write into the mbox.
    ///
    /// `accountId` travels with the item because a `remoteId` is only unique
    /// **within** an account — the same Message-ID really can exist in two
    /// mailboxes the user connected — so the fetch step has to be told which
    /// mailbox to ask. Carrying it on the item keeps that pairing impossible
    /// to get wrong.
    public struct ExportItem: Sendable, Equatable {
        public let remoteId: String
        public let fromAddress: String
        public let receivedAt: Date
        public let accountId: UUID

        public init(
            remoteId: String,
            fromAddress: String,
            receivedAt: Date,
            accountId: UUID
        ) {
            self.remoteId = remoteId
            self.fromAddress = fromAddress
            self.receivedAt = receivedAt
            self.accountId = accountId
        }
    }

    /// Writes every item into one `.mbox` at `destination`.
    ///
    /// - Parameters:
    ///   - items: oldest first — the order the server returns.
    ///   - fetch: returns the raw RFC 5322 bytes for one message. Throwing
    ///     here is how a vanished message is reported.
    ///   - progress: called after each message with how many are done.
    ///
    /// Cancellation is cooperative: the task checks between messages, closes
    /// the file and reports how far it got. A cancelled export leaves a real
    /// (partial) file and says so, because pretending it succeeded would be
    /// the same lie as a silent `catch`.
    public static func writeMbox(
        items: [ExportItem],
        to destination: URL,
        fetch: (ExportItem) async throws -> Data,
        progress: (Int, Int) -> Void
    ) async throws -> ExportSummary {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        // Same staging discipline as the snapshot: nothing lands on the
        // user's chosen path until the export has actually finished. A
        // cancelled or failed run must not destroy a previous good export.
        let staging = directory.appendingPathComponent(
            ".lagoon-export-\(UUID().uuidString).mbox"
        )
        guard FileManager.default.createFile(atPath: staging.path, contents: nil) else {
            throw BackupError.exportFailed(reason: L10n.current.backupExportWriteFailed)
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw BackupError.exportFailed(reason: error.localizedDescription)
        }

        var exported = 0
        var skipped = 0
        var consecutiveFailures = 0
        do {
            for (index, item) in items.enumerated() {
                try Task.checkCancellation()
                do {
                    let raw = try await fetch(item)
                    try handle.write(contentsOf: Self.mboxEntry(raw, from: item))
                    exported += 1
                    consecutiveFailures = 0
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // A per-message failure is counted and the export keeps
                    // going — one mail deleted from another client must not
                    // cost the user the other 2,999. But a run where every
                    // message fails is not an export, and reporting "0
                    // exported" as a success would be worse than an error.
                    skipped += 1
                    consecutiveFailures += 1
                    if consecutiveFailures >= Self.consecutiveFailureLimit && exported == 0 {
                        throw error
                    }
                }
                progress(index + 1, items.count)
            }
        } catch is CancellationError {
            try? handle.close()
            try? FileManager.default.removeItem(at: staging)
            throw BackupError.exportCancelled(exported: exported)
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: staging)
            throw BackupError.exportFailed(reason: error.localizedDescription)
        }
        do {
            try handle.close()
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw BackupError.exportFailed(reason: error.localizedDescription)
        }
        do {
            try replaceItem(at: destination, with: staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw BackupError.exportFailed(reason: error.localizedDescription)
        }
        return ExportSummary(url: destination, exported: exported, skipped: skipped)
    }

    /// One mbox entry: the `From ` separator, the message, and the blank line
    /// that ends it.
    ///
    /// The separator is the format's actual framing — a line beginning with
    /// `From ` and no colon, which is why any body line that starts the same
    /// way must be escaped (see `mboxQuoted`).
    public static func mboxEntry(_ raw: Data, from item: ExportItem) -> Data {
        var out = Data()
        out.append(contentsOf: Array("From \(item.fromAddress) \(mboxDate(item.receivedAt))\n".utf8))
        out.append(mboxQuoted(raw))
        // A missing trailing newline would glue the next separator onto this
        // message's last line and corrupt the boundary; a second one is the
        // blank line the format expects between messages.
        if out.last != 0x0A { out.append(0x0A) }
        out.append(0x0A)
        return out
    }

    /// mboxrd quoting: prefix one `>` to any line that already reads like a
    /// `From ` separator, however many `>`s it starts with.
    ///
    /// Without this, a message whose body contains a line `From the desk of…`
    /// would be split in two on import. mboxrd (the variant Thunderbird,
    /// Apple Mail and mutt all write) adds one `>` to the longest run, and
    /// readers strip exactly one — so the original text survives a round trip.
    ///
    /// Bytes, not `String`: message bodies are not guaranteed to be valid
    /// UTF-8, and decoding them "helpfully" with replacement characters would
    /// corrupt the file. The escape is purely structural.
    public static func mboxQuoted(_ raw: Data) -> Data {
        let gt = UInt8(ascii: ">")
        let from = Array("From ".utf8)
        var out = Data()
        out.reserveCapacity(raw.count + 64)
        var atLineStart = true
        var index = raw.startIndex
        while index < raw.endIndex {
            if atLineStart {
                // Count the existing `>` run, then ask whether `From `
                // follows it.
                var scan = index
                while scan < raw.endIndex, raw[scan] == gt {
                    scan = raw.index(after: scan)
                }
                if matchesFrom(from, in: raw, at: scan) {
                    out.append(gt)
                }
                atLineStart = false
            }
            let byte = raw[index]
            out.append(byte)
            if byte == 0x0A { atLineStart = true }
            index = raw.index(after: index)
        }
        return out
    }

    private static func matchesFrom(_ needle: [UInt8], in data: Data, at start: Data.Index) -> Bool {
        var cursor = start
        for byte in needle {
            guard cursor < data.endIndex, data[cursor] == byte else { return false }
            cursor = data.index(after: cursor)
        }
        return true
    }

    /// The separator's date in the fixed, locale-free form the format
    /// specifies (`Wed Jan  1 00:00:00 2025`).
    ///
    /// A `DateFormatter` with the user's locale would emit a month name the
    /// importing client may not parse, and `asctime` is what every mbox
    /// reader expects. POSIX locale is set explicitly for the same reason.
    public static func mboxDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.string(from: date)
    }

    // MARK: - File names

    /// A subject or an address is untrusted text; a path component is not
    /// where it may land.
    ///
    /// `/` and `:` are the two that change meaning on macOS (a separator and
    /// the legacy HFS separator), and a leading `.` hides the file. The
    /// server's `rawMessageFilename` sanitizes for the same reason on the way
    /// out of the HTTP route; this is the client-side twin for names the app
    /// suggests itself.
    public static func sanitizedFileNameComponent(_ raw: String) -> String {
        let banned = Set("/\\:\0")
        let cleaned = raw.map { banned.contains($0) ? "-" : $0 }
        let trimmed = String(cleaned)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let capped = String(trimmed.prefix(80))
        return capped.isEmpty ? "Lagoon" : capped
    }

    /// `Lagoon-备份-2026-10-20.sqlite`
    public static func defaultSnapshotName(date: Date) -> String {
        "Lagoon-\(L10n.current.backupFileNamePrefix)-\(dayStamp(date)).sqlite"
    }

    /// `Lagoon-邮箱地址-2026-10-20.mbox` for one account, or
    /// `Lagoon-全部账户-2026-10-20.mbox` for all of them.
    public static func defaultExportName(label: String, date: Date) -> String {
        let part = sanitizedFileNameComponent(label)
        return "Lagoon-\(part)-\(dayStamp(date)).mbox"
    }

    /// `yyyy-MM-dd` — sortable, unambiguous, and the same in every locale.
    static func dayStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

/// Why a backup or an export did not produce a file.
///
/// `LocalizedError` because every one of these reaches the user inside an
/// `ErrorBanner`: the banner's detail line is the third sentence of INV-3
/// (what failed, why, and what to do), and a generic "the operation
/// couldn't be completed" would be the silent failure the lint exists to
/// prevent, wearing a different coat.
public enum BackupError: LocalizedError, Equatable {
    case databaseUnavailable
    case snapshotFailed(reason: String)
    case exportFailed(reason: String)
    case exportCancelled(exported: Int)

    public var errorDescription: String? {
        switch self {
        case .databaseUnavailable:
            return L10n.current.backupDataDirectoryMissingDetail
        case .snapshotFailed(let reason):
            return reason
        case .exportFailed(let reason):
            return reason
        case .exportCancelled(let exported):
            return L10n.current.backupExportCancelledDetail(exported: exported)
        }
    }
}
