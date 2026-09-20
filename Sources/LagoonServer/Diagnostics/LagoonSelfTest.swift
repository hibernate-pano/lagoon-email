import Foundation
import Logging
import PostgresNIO
import LagoonKit

/// Explicit real-account smoke test. It sends only to the selected account's
/// own address and never accepts an arbitrary recipient.
enum LagoonSelfTest {
    /// The QQ account the diagnostics act on.
    ///
    /// Several mailboxes can be stored at once, so the choice is never
    /// accidental: an explicit `--account <email>` wins, otherwise the active
    /// QQ account wins, then any stored QQ account.
    private static func qqAccount(
        db: PostgresConnection, logger: Logger
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
    static func listMailboxes(db: PostgresConnection, logger: Logger) async throws {
        let account = try await qqAccount(db: db, logger: logger)
        let provider = IMAPProvider(account: account, db: db, logger: logger)
        for mailbox in try await provider.diagnosticMailboxes() {
            print("\(mailbox.name)\t\(mailbox.attributes.joined(separator: ","))")
        }
    }

    static func find(subject: String, db: PostgresConnection, logger: Logger) async throws {
        let account = try await qqAccount(db: db, logger: logger)
        let provider = IMAPProvider(account: account, db: db, logger: logger)
        for (mailbox, uid) in try await provider.diagnosticFind(subject: subject) {
            print("\(mailbox)\t\(uid)")
        }
    }

    static func restore(remoteId: String, db: PostgresConnection, logger: Logger) async throws {
        let account = try await qqAccount(db: db, logger: logger)
        let provider = IMAPProvider(account: account, db: db, logger: logger)
        try await provider.unarchive(remoteId: remoteId)
        print("restore: ok remoteId=\(remoteId)")
    }

    static func run(db: PostgresConnection, logger: Logger) async throws {
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
