import XCTest
import Foundation
import GRDB
@testable import Lagoon
@testable import LagoonKit

/// P2-06: the product promised "your data stays on this Mac" and then gave
/// the user no way to take it off.
///
/// ## What was wrong
///
/// There was no export, no backup button, and no migration path. The user
/// guide said "back up = quit the app and copy this one file" — which in WAL
/// mode is three files, with no consistency guarantee, and no route to
/// another mail client at all.
///
/// ## What these tests pin
///
/// The three behaviours that make a backup *trustworthy*, each of which can
/// fail independently and invisibly:
///
/// 1. **Consistency.** The snapshot must be a transactionally consistent
///    copy taken while the app may be writing, and it must be **one file**.
///    A plain copy of the WAL database is neither. That is a real, measured
///    distinction here, and the test below proves the difference rather than
///    asserting a preference.
/// 2. **Honesty.** A failure must reach the user as a failure with a reason —
///    a backup that silently does nothing is worse than no backup, because
///    the user believes they are covered.
/// 3. **Wiring.** The About sheet must actually offer the entry point, and
///    the client must call a route the server actually registers.
///
/// The mbox tests are byte-level on purpose: the format's framing (`From `
/// separator, mboxrd quoting) is the part that silently corrupts a mailbox
/// on import when it is wrong.
final class BackupWiringTests: XCTestCase {
    // MARK: - Helpers

    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lagoon-backup-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        try super.tearDownWithError()
    }

    /// A WAL source database with one committed row still sitting in the
    /// `-wal` file (the live pool is kept open so it cannot be checkpointed).
    private func makeLiveWALDatabase(
        rows: [String] = ["row-1"]
    ) throws -> (url: URL, pool: DatabasePool) {
        let url = scratch.appendingPathComponent("lagoon.sqlite")
        let pool = try DatabasePool(path: url.path)
        try pool.write { db in
            try db.execute(sql: "CREATE TABLE t(a TEXT)")
            for row in rows {
                try db.execute(sql: "INSERT INTO t VALUES (?)", arguments: [row])
            }
        }
        return (url, pool)
    }

    private func rows(in url: URL) throws -> [String] {
        let queue = try DatabaseQueue(path: url.path)
        return try queue.read { db in try String.fetchAll(db, sql: "SELECT a FROM t") }
    }

    // MARK: - 1. The snapshot is consistent AND a single file

    /// The snapshot must contain the rows that are still in the `-wal` file.
    ///
    /// This is the whole reason the feature exists. In WAL mode a committed
    /// write lives in `lagoon.sqlite-wal` until a checkpoint, so copying the
    /// main file alone loses the newest mail — silently. The snapshot is
    /// taken through SQLite (`VACUUM INTO`), which reads the live snapshot,
    /// so those rows are present.
    func test_theSnapshotContainsWritesStillInTheWAL() throws {
        let (source, pool) = try makeLiveWALDatabase(rows: ["row-1", "row-2"])
        defer { try? pool.close() }

        // Prove the premise: a plain copy of the main file really does lose
        // the data. Without this the test could pass for the wrong reason on
        // a build that happens to have checkpointed.
        let plainCopy = scratch.appendingPathComponent("plain-copy.sqlite")
        try FileManager.default.copyItem(at: source, to: plainCopy)
        let copiedRows = (try? rows(in: plainCopy)) ?? []
        XCTAssertFalse(
            copiedRows.contains("row-2"),
            """
            The premise of this test is wrong: a plain file copy preserved the \
            WAL rows, so it would be a consistent backup on this machine. The \
            snapshot must still be taken through SQLite — the copy is only safe \
            when nothing is writing.
            """
        )

        let destination = scratch.appendingPathComponent("backup.sqlite")
        let snapshot = try BackupService.makeSnapshot(from: source, to: destination)
        XCTAssertEqual(
            try rows(in: destination).sorted(), ["row-1", "row-2"],
            "the snapshot is missing a committed write that was still in the WAL"
        )
        XCTAssertEqual(snapshot.url, destination)
        XCTAssertGreaterThan(snapshot.byteCount, 0)
    }

    /// The snapshot must be **one file**, not three.
    ///
    /// `VACUUM INTO` writes a fresh database in `journal_mode=delete`, so no
    /// `-wal`/`-shm` siblings appear — which is what makes "copy this one
    /// file" true. GRDB's `backup(to:)` was measured and rejected for
    /// exactly this: it copies the source's journal mode, so the destination
    /// is a WAL database whose later open recreates two siblings.
    func test_theSnapshotIsASingleFileInDeleteJournalMode() throws {
        let (source, pool) = try makeLiveWALDatabase()
        defer { try? pool.close() }
        let destination = scratch.appendingPathComponent("backup.sqlite")

        _ = try BackupService.makeSnapshot(from: source, to: destination)

        let siblings = try FileManager.default
            .contentsOfDirectory(atPath: scratch.path)
            .filter { $0.hasPrefix("backup.sqlite") }
            .sorted()
        XCTAssertEqual(
            siblings, ["backup.sqlite"],
            "the snapshot must be one file; WAL siblings would make 'copy this file' false"
        )
        let queue = try DatabaseQueue(path: destination.path)
        let mode = try queue.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode")
        }
        XCTAssertEqual(
            mode, "delete",
            "the snapshot must be a delete-mode database, or opening it recreates -wal/-shm"
        )
    }

    /// The snapshot must never overwrite a good backup until it is complete,
    /// and must never leave a half-written file at the user's chosen path.
    ///
    /// The destination here is an existing, valid database. If the new
    /// snapshot failed halfway and wrote in place, the user would be left
    /// with a corrupt file where their last good backup was.
    func test_aSnapshotReplacesAnExistingFileAtomically() throws {
        let (source, pool) = try makeLiveWALDatabase(rows: ["old"])
        defer { try? pool.close() }
        let destination = scratch.appendingPathComponent("backup.sqlite")

        // A previous backup, with different content.
        let previous = try DatabaseQueue(path: destination.path)
        try previous.write { db in
            try db.execute(sql: "CREATE TABLE t(a TEXT)")
            try db.execute(sql: "INSERT INTO t VALUES ('previous-backup')")
        }
        try previous.close()

        _ = try BackupService.makeSnapshot(from: source, to: destination)

        XCTAssertEqual(
            try rows(in: destination), ["old"],
            "the new snapshot must replace the old file"
        )
        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: scratch.path)
            .filter { $0.hasPrefix(".lagoon-snapshot") }
        XCTAssertTrue(
            leftovers.isEmpty,
            "the staging file must be cleaned up: \(leftovers)"
        )
    }

    /// A missing database is an error, not an empty snapshot.
    ///
    /// `VACUUM INTO` on a path that does not exist would happily create an
    /// empty database. Reporting that as "备份完成" is the worst possible
    /// outcome for a trust feature — the user would hold a file that restores
    /// to nothing.
    func test_aMissingDatabaseFailsInsteadOfProducingAnEmptyBackup() throws {
        let missing = scratch.appendingPathComponent("does-not-exist.sqlite")
        let destination = scratch.appendingPathComponent("backup.sqlite")
        XCTAssertThrowsError(
            try BackupService.makeSnapshot(from: missing, to: destination)
        ) { error in
            guard case BackupError.databaseUnavailable = error else {
                return XCTFail("expected .databaseUnavailable, got \(error)")
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.path),
            "a failed snapshot must not leave a file behind"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: missing.path),
            "the snapshot must not create the source database it could not find"
        )
    }

    /// The snapshot path is bound, never interpolated into the SQL.
    ///
    /// Two independent reasons: the repo's guardrail rejects interpolated
    /// SQL (`scripts/ci-guardrails.sh` rule 1), and a user-chosen file name is
    /// untrusted text. The assertion is on the *call site*, because that is
    /// the part a future edit can quietly change.
    func test_theSnapshotSQLBindsItsPath() throws {
        let source = ViewSource.url(under: "Services", "BackupService")
        let text = try String(contentsOf: source, encoding: .utf8)
        XCTAssertTrue(
            text.contains("VACUUM INTO ?"),
            "the snapshot must bind its destination path"
        )
        // The interpolation marker, spelled without letting this very test
        // interpolate: "\\(" is a literal backslash followed by a paren.
        let interpolationMarker = "VACUUM INTO \\("
        XCTAssertFalse(
            text.contains(interpolationMarker),
            "the destination path must never be interpolated into the SQL"
        )
    }

    // MARK: - 2. The mbox format is importable

    /// Every entry starts with the `From ` separator and ends with a blank
    /// line, and the message bytes survive intact.
    func test_anMboxEntryHasTheFormatsFraming() throws {
        let raw = Data("Subject: hi\r\n\r\nbody\r\n".utf8)
        let item = BackupService.ExportItem(
            remoteId: "m1",
            fromAddress: "alice@example.com",
            receivedAt: Date(timeIntervalSince1970: 0),
            accountId: UUID()
        )
        let entry = BackupService.mboxEntry(raw, from: item)
        let text = try XCTUnwrap(String(data: entry, encoding: .utf8))

        XCTAssertTrue(
            text.hasPrefix("From alice@example.com "),
            "an mbox entry must open with the From_ separator, got: \(text.prefix(60))"
        )
        XCTAssertTrue(text.contains("Subject: hi"), "the message headers must be preserved")
        // The entry ends with a blank line. The raw bytes may end LF or CRLF,
        // so the property is "the last line is empty", not a fixed suffix.
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(
            lines.suffix(2).filter { $0.isEmpty }.count, 2,
            "an entry must end with a blank line, got: \(text.suffix(12).debugDescription)"
        )
    }

    /// A body line that looks like a separator must be escaped.
    ///
    /// Without this, a message whose body contains `From the desk of …` is
    /// split into two messages on import. mboxrd (Thunderbird, Apple Mail,
    /// mutt) prefixes one `>` to the longest existing run, and readers strip
    /// exactly one, so the original text comes back byte-identical.
    func test_bodyLinesThatLookLikeASeparatorAreQuoted() throws {
        let body = "From the desk of Alice\n>From a quoted mail\n>>From deeper\n"
        let quoted = try XCTUnwrap(
            String(data: BackupService.mboxQuoted(Data(body.utf8)), encoding: .utf8)
        )
        XCTAssertEqual(
            quoted,
            ">From the desk of Alice\n>>From a quoted mail\n>>>From deeper\n",
            "every line starting with From_ must gain exactly one '>'"
        )
    }

    /// A line that merely *starts with* `From` but is not a separator must
    /// not be touched — over-quoting corrupts real text.
    func test_onlyActualSeparatorsAreQuoted() throws {
        let body = "Fromage is a cheese\nFrom: a real header\nFromX\n"
        let quoted = try XCTUnwrap(
            String(data: BackupService.mboxQuoted(Data(body.utf8)), encoding: .utf8)
        )
        XCTAssertEqual(quoted, body)
    }

    /// A message with no trailing newline must not swallow the next entry.
    ///
    /// Raw IMAP bytes do not always end with a newline; concatenating them
    /// directly would glue the next `From ` separator onto the last body
    /// line, corrupting both messages.
    func test_anEntryWithNoTrailingNewlineStillSeparatesCleanly() throws {
        let raw = Data("Subject: x\r\n\r\nno newline at end".utf8)
        let item = BackupService.ExportItem(
            remoteId: "m1", fromAddress: "a@example.com",
            receivedAt: Date(timeIntervalSince1970: 0), accountId: UUID()
        )
        let text = try XCTUnwrap(
            String(data: BackupService.mboxEntry(raw, from: item), encoding: .utf8)
        )
        XCTAssertTrue(
            text.hasSuffix("no newline at end\n\n"),
            "a missing trailing newline must be added, not inherited"
        )
    }

    /// Every message lands in the file, and the summary counts them.
    func test_theExportWritesEveryMessageAndCountsThem() async throws {
        let destination = scratch.appendingPathComponent("export.mbox")
        let items = (0..<3).map { index in
            BackupService.ExportItem(
                remoteId: "m\(index)",
                fromAddress: "sender\(index)@example.com",
                receivedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                accountId: UUID()
            )
        }
        let summary = try await BackupService.writeMbox(
            items: items,
            to: destination,
            fetch: { item in Data("Subject: \(item.remoteId)\r\n\r\nbody\r\n".utf8) },
            progress: { _, _ in }
        )
        XCTAssertEqual(summary.exported, 3)
        XCTAssertEqual(summary.skipped, 0)

        let text = try String(contentsOf: destination, encoding: .utf8)
        for index in 0..<3 {
            XCTAssertTrue(text.contains("Subject: m\(index)"), "m\(index) is missing")
        }
        // Three entries means three separator lines. Counting the lines that
        // *begin* with the marker is the property an importer relies on; a
        // substring count would also match a quoted body line.
        let separators = text
            .components(separatedBy: "\n")
            .filter { $0.hasPrefix("From ") }
        XCTAssertEqual(
            separators.count, 3,
            "the file must contain one From_ separator per message, got \(separators)"
        )
    }

    /// A message that cannot be fetched is counted as skipped, not hidden.
    ///
    /// A mail deleted from another client between the sync and the export is
    /// a normal event. Aborting 3,000 messages over it would be useless; a
    /// file that quietly dropped it and reported success would be wrong.
    func test_aMissingMessageIsReportedAsSkippedNotSwallowed() async throws {
        let destination = scratch.appendingPathComponent("partial.mbox")
        let items = (0..<3).map { index in
            BackupService.ExportItem(
                remoteId: "m\(index)",
                fromAddress: "s@example.com",
                receivedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                accountId: UUID()
            )
        }
        struct Gone: Error {}
        let summary = try await BackupService.writeMbox(
            items: items,
            to: destination,
            fetch: { item in
                if item.remoteId == "m1" { throw Gone() }
                return Data("Subject: \(item.remoteId)\r\n\r\nbody\r\n".utf8)
            },
            progress: { _, _ in }
        )
        XCTAssertEqual(summary.exported, 2)
        XCTAssertEqual(summary.skipped, 1, "a vanished message must be counted, not hidden")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    /// When *every* message fails, the export must fail rather than write an
    /// empty file and call it a success.
    ///
    /// This is the shape of "the provider is not answering": a run where
    /// nothing works is not a partial export, it is a failed one, and the
    /// user has to be told.
    func test_anExportWhereNothingWorksFails() async throws {
        let destination = scratch.appendingPathComponent("empty.mbox")
        let items = (0..<8).map { index in
            BackupService.ExportItem(
                remoteId: "m\(index)",
                fromAddress: "s@example.com",
                receivedAt: Date(),
                accountId: UUID()
            )
        }
        struct Down: Error {}
        do {
            _ = try await BackupService.writeMbox(
                items: items,
                to: destination,
                fetch: { _ in throw Down() },
                progress: { _, _ in }
            )
            XCTFail("an export where every message failed must not report success")
        } catch {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: destination.path),
                "a failed export must not leave a file that looks like a backup"
            )
        }
    }

    /// A cancelled export must stop, say how far it got, and leave no file.
    ///
    /// The user pressed Stop; a file that half-exists at the path they chose
    /// would be imported later as if it were complete.
    func test_aCancelledExportStopsAndLeavesNoFile() async throws {
        let destination = scratch.appendingPathComponent("cancelled.mbox")
        let items = (0..<50).map { index in
            BackupService.ExportItem(
                remoteId: "m\(index)",
                fromAddress: "s@example.com",
                receivedAt: Date(),
                accountId: UUID()
            )
        }
        let task = Task {
            try await BackupService.writeMbox(
                items: items,
                to: destination,
                fetch: { item in
                    // Cancel while the export is running, the way the Stop
                    // button does.
                    if item.remoteId == "m5" {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                    return Data("Subject: x\r\n\r\nbody\r\n".utf8)
                },
                progress: { _, _ in }
            )
        }
        do {
            _ = try await task.value
            XCTFail("a cancelled export must not report success")
        } catch let error as BackupError {
            guard case .exportCancelled(let exported) = error else {
                return XCTFail("expected .exportCancelled, got \(error)")
            }
            XCTAssertGreaterThan(exported, 0, "the cancellation must report how far it got")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.path),
            "a cancelled export must not leave a partial file at the user's path"
        )
    }

    // MARK: - 3. Names and dates

    /// A subject or address must not be able to become a path.
    ///
    /// The two things that matter are that no separator survives and that a
    /// leading dot cannot hide the file — not the exact spelling of the
    /// result, which is why the assertions are on the property.
    func test_fileNameComponentsAreSanitized() {
        XCTAssertEqual(BackupService.sanitizedFileNameComponent("a/b:c"), "a-b-c")
        let traversal = BackupService.sanitizedFileNameComponent("../../etc")
        XCTAssertFalse(traversal.contains("/"), "no separator may survive: \(traversal)")
        XCTAssertFalse(traversal.hasPrefix("."), "no result may be a hidden file: \(traversal)")
        XCTAssertTrue(traversal.hasSuffix("etc"), "the useful part must survive: \(traversal)")
        XCTAssertEqual(
            BackupService.sanitizedFileNameComponent("   "), "Lagoon",
            "an empty result must fall back to a real name"
        )
        XCTAssertFalse(
            BackupService.sanitizedFileNameComponent("/").contains("/"),
            "a separator must never survive"
        )
        // A long subject must not blow the name past what a file system or
        // an importer wants to handle.
        XCTAssertLessThanOrEqual(
            BackupService.sanitizedFileNameComponent(String(repeating: "x", count: 500)).count,
            80
        )
    }

    /// The separator date is the fixed, locale-free form every mbox reader
    /// parses.
    func test_theMboxDateIsLocaleIndependent() {
        var components = DateComponents()
        components.year = 2026
        components.month = 10
        components.day = 20
        components.hour = 15
        components.minute = 4
        components.second = 5
        let date = Calendar(identifier: .gregorian).date(from: components)!
        let stamp = BackupService.mboxDate(date)
        XCTAssertTrue(
            stamp.contains("Oct 20 15:04:05 2026"),
            "the mbox separator needs an asctime-style date, got '\(stamp)'"
        )
        XCTAssertFalse(
            stamp.contains("年"),
            "the date must not follow the user's locale"
        )
    }

    // MARK: - 4. The wiring

    /// The About sheet must offer the entry point.
    ///
    /// A feature nobody can reach is the same as a feature that does not
    /// exist — which is exactly what the audit found.
    func test_theAboutSheetOffersTheDataAndBackupEntryPoint() throws {
        let about = try ViewSource.read("AboutSheet")
        XCTAssertTrue(
            about.contains("l10n.backupSectionTitle"),
            "the About sheet must show the 数据与备份 entry"
        )
        XCTAssertTrue(
            about.contains("BackupSheet()"),
            "the entry must open the backup panel"
        )
    }

    /// The client must call the route the server registers.
    ///
    /// A typo in the path would make every export a 404 — and the user would
    /// see "导出失败" for a feature that works.
    func test_theClientCallsTheRouteTheServerRegisters() throws {
        let client = try String(
            contentsOf: ViewSource.url(under: "Services", "APIClient+Backup"),
            encoding: .utf8
        )
        XCTAssertTrue(
            client.contains("\"api\", \"export\", \"index\""),
            "the client must call api/export/index"
        )
        let server = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/LagoonServer/Routes/BackupRoutes.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            server.contains("router.get(\"api/export/index\")"),
            "the server must register the route the client calls"
        )
    }

    /// The export must reuse the existing raw `.eml` route rather than
    /// re-rendering the message.
    ///
    /// A message rebuilt from a parse is a guess: the formatting, the
    /// attachments and the headers are gone. The export has to write the
    /// original bytes.
    func test_theExportReusesTheRawEmlRoute() throws {
        let sheet = try ViewSource.read("BackupSheet")
        XCTAssertTrue(
            sheet.contains("downloadRawMessage("),
            "the export must use the existing raw.eml download, not a second rendering"
        )
    }

    /// The export must carry the account id with each message.
    ///
    /// A remote id is only unique within an account, so fetching without one
    /// would export the wrong mail for a user with two mailboxes that
    /// received the same message.
    func test_anExportItemCarriesItsAccount() throws {
        let source = try String(
            contentsOf: ViewSource.url(under: "Services", "BackupService"),
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains("public let accountId: UUID"),
            "the export item must carry the account it came from"
        )
    }

    /// The data path must live in exactly one place.
    ///
    /// The server, the Settings window and the About sheet all point at the
    /// same folder. Two copies of the literal are free to drift, and when
    /// they do the app opens one database while telling the user to back up
    /// another.
    func test_theDataPathIsDefinedOnce() throws {
        let embedded = try String(
            contentsOf: ViewSource.url(under: "Services", "EmbeddedServer"),
            encoding: .utf8
        )
        XCTAssertTrue(
            embedded.contains("LagoonDataPaths.databaseURL"),
            "the server must read the path from the shared helper"
        )
        XCTAssertFalse(
            embedded.contains("appendingPathComponent(\"Lagoon\", isDirectory: true)"),
            "the server must not spell out the data directory a second time"
        )
        let paths = try String(
            contentsOf: ViewSource.url(under: "Services", "LagoonDataPaths"),
            encoding: .utf8
        )
        XCTAssertTrue(
            paths.contains(#"public static let directoryName = "Lagoon""#),
            "the directory name belongs in the shared helper"
        )
    }

    /// A failed backup must reach the user with a reason and a next step.
    ///
    /// A backup that silently does nothing is worse than no backup, because
    /// the user believes they are covered.
    func test_aFailedBackupIsReportedToTheUser() throws {
        let sheet = try ViewSource.read("BackupSheet")
        XCTAssertTrue(
            sheet.contains("l10n.backupFailed"),
            "a failed backup must produce a visible failure"
        )
        let backupRange = try XCTUnwrap(sheet.range(of: "private func backupNow()"))
        let section = String(sheet[backupRange.lowerBound...].prefix(2600))
        XCTAssertTrue(
            section.contains("detail: l10n.backupFailedDetail(reason:"),
            "the failure must say why, not just that something went wrong"
        )
        XCTAssertFalse(
            section.contains("try? BackupService.snapshotDatabase"),
            "the snapshot must not swallow its own failure"
        )
    }

    /// Every localized string this feature declares must reach the screen.
    ///
    /// `L10nDeadKeyTests` enforces this globally; this asserts the specific
    /// ones the audit item asked for, so a copy edit that drops one from the
    /// UI fails here with a name rather than as a dead-key list.
    func test_everyBackupStringIsUsed() throws {
        let decl = try String(
            contentsOf: ViewSource.url(under: "Localization", "L10n+Backup"),
            encoding: .utf8
        )
        let users = try [
            ViewSource.read("AboutSheet"),
            ViewSource.read("BackupSheet"),
            String(
                contentsOf: ViewSource.url(under: "Services", "BackupService"),
                encoding: .utf8
            ),
        ].joined(separator: "\n")

        var missing: [String] = []
        for line in decl.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let range = trimmed.range(of: "public var ") else { continue }
            let name = trimmed[range.upperBound...].prefix {
                $0.isLetter || $0.isNumber || $0 == "_"
            }
            guard !name.isEmpty else { continue }
            if !users.contains(String(name)) { missing.append(String(name)) }
        }
        XCTAssertTrue(
            missing.isEmpty,
            "these backup strings are declared but never shown: \(missing.sorted())"
        )
    }
}
