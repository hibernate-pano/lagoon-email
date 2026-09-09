import Foundation
import Logging
import PostgresNIO
import LagoonKit

public actor GmailPoller {
    private let db: PostgresConnection
    private let client: GmailClient
    private let logger: Logger

    public init(db: PostgresConnection, client: GmailClient, logger: Logger) {
        self.db = db
        self.client = client
        self.logger = logger
    }

    /// Poll all accounts once. Designed for a periodic task in M0;
    /// M1+ replaces this with Pub/Sub webhook fanout (spec §6.4).
    public func tick() async {
        do {
            let accounts = try await Self.allAccounts(db: db)
            for acct in accounts {
                await syncAccount(acct)
            }
        } catch {
            logger.error("gmail poller tick failed", metadata: ["err": .string("\(error)")])
        }
    }

    private static func allAccounts(db: PostgresConnection) async throws -> [Account] {
        let result = try await db.query(
            "SELECT id, provider, oauth_user, email, token_expires_at, history_id FROM accounts",
            []
        ).get()
        return try result.rows.map { try AccountStore.decode($0) }
    }

    private func syncAccount(_ account: Account) async {
        do {
            let accessToken = try await AccessTokenCipher.readToken(accountId: account.id, db: db)
            let list = try await client.listMessageRefs(accessToken: accessToken, maxResults: 50)
            guard let refs = list.messages else { return }
            for ref in refs.prefix(50) {
                let raw = try await client.getMessage(accessToken: accessToken, gmailId: ref.id)
                let fromHeader = raw.payload?.headers?.first { $0.name.lowercased() == "from" }?.value ?? ""
                let subject = raw.payload?.headers?.first { $0.name.lowercased() == "subject" }?.value
                let (addr, name) = Self.parseFromHeader(fromHeader)
                let receivedAt = raw.internalDate.flatMap { Int64($0) }
                    .map { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) } ?? Date()
                let msg = MessageHeader(
                    id: UUID(),
                    accountId: account.id,
                    gmailId: raw.id,
                    threadId: raw.threadId,
                    fromAddress: addr,
                    fromName: name,
                    subject: subject,
                    snippet: raw.snippet,
                    receivedAt: receivedAt,
                    isRead: false,
                    isArchived: false
                )
                try await MessageStore.upsert(msg, db: db)
            }
            logger.info("synced", metadata: ["account": .string(account.email), "count": .string("\(refs.count)")])
        } catch GmailClientError.unauthorized {
            logger.warning("token expired; refresh flow lands in M1", metadata: ["account": .string(account.email)])
        } catch {
            logger.error("account sync failed", metadata: ["account": .string(account.email), "err": .string("\(error)")])
        }
    }

    static func parseFromHeader(_ raw: String) -> (String, String?) {
        if raw.contains("<") && raw.contains(">") {
            let namePart = raw.split(separator: "<").first.map(String.init)?
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let addrPart = raw.split(separator: "<").last.map(String.init)?
                .replacingOccurrences(of: ">", with: "")
                .trimmingCharacters(in: .whitespaces)
            return (addrPart ?? raw, (namePart?.isEmpty == false) ? namePart : nil)
        }
        return (raw.trimmingCharacters(in: .whitespaces), nil)
    }
}