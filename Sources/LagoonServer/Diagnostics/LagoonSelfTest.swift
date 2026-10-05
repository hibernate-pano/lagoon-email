import Foundation
import Logging
import GRDB
import LagoonKit

/// Explicit real-account smoke test. It sends only to the selected account's
/// own address and never accepts an arbitrary recipient.
public enum LagoonSelfTest {
    /// The QQ account the diagnostics act on.
    ///
    /// Several mailboxes can be stored at once, so the choice is never
    /// accidental: an explicit `--account <email>` wins, otherwise the active
    /// QQ account wins, then any stored QQ account.
    private static func qqAccount(
        db: LagoonDB, logger: Logger
    ) async throws -> Account {
        let accounts = try await AccountStore.all(db: db)
            .filter { $0.provider == .qq }
        if let flag = CommandLine.arguments.firstIndex(of: "--account") {
            let valueIndex = CommandLine.arguments.index(after: flag)
            if valueIndex < CommandLine.arguments.endIndex {
                let wanted = CommandLine.arguments[valueIndex]
                guard let match = accounts.first(where: { $0.email == wanted }) else {
                    throw SelfTestError.unknownAccount(wanted)
                }
                return match
            }
        }
        guard let first = accounts.first(where: \.isActive) ?? accounts.first else {
            throw SelfTestError.noQQAccount
        }
        logger.info("self-test account", metadata: ["email": .string(first.email)])
        return first
    }
    public static func listMailboxes(db: LagoonDB, logger: Logger) async throws {
        let account = try await qqAccount(db: db, logger: logger)
        let provider = IMAPProvider(account: account, db: db, logger: logger)
        for mailbox in try await provider.diagnosticMailboxes() {
            print("\(mailbox.name)\t\(mailbox.attributes.joined(separator: ","))")
        }
    }

    /// Read-only coverage report: what the provider holds versus what the
    /// local store holds, per folder.
    ///
    /// Answers the one question behind every "where is my old mail" report —
    /// is the list window too small (rows are stored but never shown), or did
    /// the sync never reach that far back (rows were never fetched at all)?
    /// The two look identical on screen. Sends no mail and writes nothing.
    public static func mailboxStats(db: LagoonDB, logger: Logger) async throws {
        let account = try await qqAccount(db: db, logger: logger)
        let stored = try await MessageStore.count(forAccount: account.id, db: db)
        let storedUnarchived = try await MessageStore.count(
            forAccount: account.id, archived: false, db: db
        )
        print("local-rows\ttotal=\(stored)\tlive=\(storedUnarchived)")
        if let oldest = try await MessageStore.oldestReceivedAt(
            forAccount: account.id, db: db
        ) {
            print("local-oldest\t\(oldest)")
        }
        let provider = IMAPProvider(account: account, db: db, logger: logger)
        let stats: [IMAPMailboxStats]
        do {
            stats = try await provider.diagnosticMailboxStats()
        } catch {
            // QQ caps concurrent IMAP sessions per account; hand the session
            // back before the process exits instead of letting the server's
            // idle timeout reclaim it.
            await provider.shutdown()
            throw error
        }
        await provider.shutdown()
        for stat in stats {
            print(
                "folder\t\(stat.name)\texists=\(stat.exists)"
                    + "\tuidNext=\(stat.uidNext)\tuidValidity=\(stat.uidValidity)"
                    + "\tolderThanWindow=\(stat.olderThanBackfillWindow)"
                    + "\tattrs=\(stat.attributes.joined(separator: ","))"
            )
        }
        // The cursor is what the next round resumes from. `lastUid` without a
        // `historyFloorUid` is the signature of a history window that never
        // completed — and the round that sees it refills the gap.
        print(
            "cursor\tlastUid=\(account.syncState.lastUid.map(String.init) ?? "nil")"
                + "\thistoryFloorUid=\(account.syncState.historyFloorUid.map(String.init) ?? "nil")"
        )
        print("backfillWindow\t\(IMAPProvider.backfillWindow) messages")
    }

    /// One real `pullChanges` round against the live mailbox, reported and
    /// discarded: nothing is written, the stored cursor is not advanced, and
    /// the session is handed back before the process exits.
    ///
    /// This exists because the window bug it verifies was invisible to every
    /// offline signal — 44 scripted IMAP tests were green, sync health read
    /// `ok`, and the cursor sat at the top of the mailbox while 222 messages
    /// had never been fetched. A scripted transport proves the logic; only a
    /// real round proves the *semantics* matched the mailbox in front of us.
    /// Read-only by construction: `pullChanges` returns rows for the caller to
    /// store, and this caller stores none.
    public static func dryRunPull(db: LagoonDB, logger: Logger) async throws {
        let account = try await qqAccount(db: db, logger: logger)
        let provider = IMAPProvider(account: account, db: db, logger: logger)
        let change: MailChangeSet
        do {
            change = try await provider.pullChanges(
                after: account.syncState,
                waitUpTo: .zero
            )
        } catch {
            await provider.shutdown()
            throw error
        }
        await provider.shutdown()
        // One measure, one denominator: `remoteIds` counts every stored row
        // (read, unread, archived alike) because that is the set a pull is
        // diffed against. Mixing that against `count(...)`, which filters on
        // `is_archived = FALSE`, produced a "stored" number smaller than the
        // set the difference was taken from — a coverage line that did not
        // add up and could not be trusted.
        let known = try await MessageStore.remoteIds(forAccount: account.id, db: db)
        let fresh = change.upserts.filter { !known.contains($0.remoteId) }
        print("dry-run-pull\tfetched=\(change.upserts.count)")
        print("dry-run-cursor\tlastUid=\(change.cursor.lastUid.map(String.init) ?? "nil")"
            + "\thistoryFloorUid=\(change.cursor.historyFloorUid.map(String.init) ?? "nil")")
        print("dry-run-coverage\tstoredRows=\(known.count)"
            + "\tnewRowsWouldBe=\(fresh.count)"
            + "\tstoredAfterWouldBe=\(known.count + fresh.count)")
        print("dry-run-reset\t\(change.resetRequired)")
    }

    public static func find(subject: String, db: LagoonDB, logger: Logger) async throws {
        let account = try await qqAccount(db: db, logger: logger)
        let provider = IMAPProvider(account: account, db: db, logger: logger)
        for (mailbox, uid) in try await provider.diagnosticFind(subject: subject) {
            print("\(mailbox)\t\(uid)")
        }
    }

    public static func restore(remoteId: String, db: LagoonDB, logger: Logger) async throws {
        let account = try await qqAccount(db: db, logger: logger)
        let provider = IMAPProvider(account: account, db: db, logger: logger)
        try await provider.unarchive(remoteId: remoteId)
        print("restore: ok remoteId=\(remoteId)")
    }

    public static func run(db: LagoonDB, logger: Logger) async throws {
        let account = try await qqAccount(db: db, logger: logger)

        let marker = "[Lagoon Self-Test \(UUID().uuidString.prefix(8))]"
        print("marker: \(marker)")
        let provider = IMAPProvider(account: account, db: db, logger: logger)
        let outbound = OutboundMessage(
            fromEmail: account.email,
            fromName: "Lagoon Self Test",
            to: account.email,
            subject: marker,
            body: """
                This is an automated Lagoon self-test.

                It verifies SMTP send, IMAP receive, archive, and unarchive.
                No external recipient is involved.
                """,
            inReplyTo: nil,
            references: nil
        )

        let providerMessageId = try await provider.send(outbound)
        print("send: ok")
        if let providerMessageId {
            print("providerMessageId: \(providerMessageId)")
        }

        var cursor = account.syncState
        var deliveredRemoteId: String?
        for _ in 0..<3 {
            try await Task.sleep(for: .seconds(5))
            let change = try await provider.pullChanges(after: cursor, waitUpTo: .seconds(3))
            cursor = change.cursor
            if let match = change.upserts.first(where: { $0.subject == marker }) {
                deliveredRemoteId = match.remoteId
                break
            }
        }
        if let deliveredRemoteId {
            print("receive: ok remoteId=\(deliveredRemoteId)")
        } else {
            print("receive: skipped (QQ did not loop the self-send back to INBOX)")
        }

        let archiveRemoteId: String
        if let deliveredRemoteId {
            archiveRemoteId = deliveredRemoteId
        } else {
            let messages = try await MessageStore.recent(forAccount: account.id, limit: 100, db: db)
            let subscriptionIds = try await MessageStore.listUnsubscribeIds(
                forAccount: account.id,
                db: db
            )
            guard let candidate = messages.last(where: { subscriptionIds.contains($0.remoteId) })
                    ?? messages.last
            else {
                throw SelfTestError.noArchiveCandidate
            }
            archiveRemoteId = candidate.remoteId
            print("archiveTarget: existing remoteId=\(archiveRemoteId)")
        }

        try await provider.archive(remoteId: archiveRemoteId)
        print("archive: ok")
        try await provider.unarchive(remoteId: archiveRemoteId)
        print("unarchive: ok")

        var sentFound = false
        for _ in 0..<6 {
            if try await provider.diagnosticSentContains(subject: marker) {
                sentFound = true
                break
            }
            try await Task.sleep(for: .seconds(5))
        }
        print("sentFolder: \(sentFound ? "ok" : "not-found")")

        if let deliveredRemoteId {
            // Leave the test message in Archive rather than the inbox.
            try await provider.archive(remoteId: deliveredRemoteId)
            print("cleanupArchive: ok")
        }
        if sentFound {
            print("self-test: passed")
        } else {
            print("self-test: degraded (Sent-folder copy not found)")
        }
    }
}

private enum SelfTestError: Error, CustomStringConvertible {
    case noQQAccount
    case unknownAccount(String)
    case noArchiveCandidate

    var description: String {
        switch self {
        case .noQQAccount:
            "self-test requires a stored QQ account (none found)"
        case .unknownAccount(let email):
            "no stored QQ account matches --account \(email)"
        case .noArchiveCandidate:
            "no existing INBOX message is available for archive/unarchive verification"
        }
    }
}
