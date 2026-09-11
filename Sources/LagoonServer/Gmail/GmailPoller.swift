import Foundation
import Logging
import PostgresNIO
import LagoonKit

public actor GmailPoller {
    private let db: PostgresConnection
    private let client: GmailClient
    private let tokens: GmailTokenService
    private let logger: Logger

    public init(
        db: PostgresConnection,
        client: GmailClient,
        oauth: GoogleOAuthClient,
        logger: Logger
    ) {
        self.init(
            db: db,
            client: client,
            tokens: GmailTokenService(db: db, oauth: oauth, logger: logger),
            logger: logger
        )
    }

    /// Production init: share the same `GmailTokenService` (and therefore the
    /// same single-flight registry) with the message routes.
    public init(
        db: PostgresConnection,
        client: GmailClient,
        tokens: GmailTokenService,
        logger: Logger
    ) {
        self.db = db
        self.client = client
        self.tokens = tokens
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
        try await AccountStore.all(db: db)
    }

    private func syncAccount(_ account: Account) async {
        do {
            let token = try await tokens.validToken(for: account)
            do {
                try await syncMessages(account: account, accessToken: token.accessToken)
            } catch GmailClientError.unauthorized {
                // Google revoked the token early: refresh once, retry once,
                // then give up (the next tick will try again). If the proactive
                // path already refreshed, a 401 is genuine and must not trigger
                // a second POST to Google.
                guard !token.didRefresh else { throw GmailClientError.unauthorized }
                let refreshed = try await tokens.forceRefresh(for: account)
                try await syncMessages(account: account, accessToken: refreshed)
            }
        } catch {
            logger.error("account sync failed", metadata: [
                "account": .string(account.email),
                "err": .string("\(error)")
            ])
        }
    }

    /// Gmail `messages.get` calls in flight at once. A metadata get costs 5
    /// quota units against Gmail's ~250 units/s/user budget, so 8 concurrent
    /// calls stay inside quota while cutting a 50-message poll from ~50 serial
    /// round-trips to ~7 batches.
    static let fetchConcurrency = 8

    private func syncMessages(account: Account, accessToken: String) async throws {
        let list = try await client.listMessageRefs(accessToken: accessToken, maxResults: 50)
        guard let refs = list.messages else { return }
        let ids = refs.prefix(50).map(\.id)
        guard !ids.isEmpty else { return }

        // Fetch concurrently in bounded batches, then upsert afterwards so the
        // single Postgres connection stays a serial write path.
        var fetched: [(header: MessageHeader, listUnsubscribe: Bool)] = []
        fetched.reserveCapacity(ids.count)
        for start in stride(from: 0, to: ids.count, by: Self.fetchConcurrency) {
            let batch = Array(ids[start..<min(start + Self.fetchConcurrency, ids.count)])
            let responses = try await withThrowingTaskGroup(of: RawGmailMessage.self) { group in
                for id in batch {
                    group.addTask { [client, accessToken] in
                        try await client.getMessage(accessToken: accessToken, remoteId: id)
                    }
                }
                var collected: [RawGmailMessage] = []
                for try await response in group { collected.append(response) }
                return collected
            }
            for raw in responses {
                fetched.append((
                    Self.header(from: raw, accountId: account.id),
                    Self.hasListUnsubscribe(raw)
                ))
            }
        }
        for item in fetched {
            try await MessageStore.upsert(item.header, listUnsubscribe: item.listUnsubscribe, db: db)
        }
        logger.info("synced", metadata: [
            "account": .string(account.email),
            "count": .string("\(fetched.count)")
        ])
    }

    /// Map a Gmail metadata response onto the row we store.
    static func header(from raw: RawGmailMessage, accountId: UUID) -> MessageHeader {
        let fromHeader = raw.payload?.headers?
            .first { $0.name.lowercased() == "from" }?.value ?? ""
        let (address, name) = parseFromHeader(fromHeader)
        let receivedAt = raw.internalDate.flatMap { Int64($0) }
            .map { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) } ?? Date()
        return MessageHeader(
            id: UUID(),
            accountId: accountId,
            remoteId: raw.id,
            threadId: raw.threadId,
            fromAddress: address,
            fromName: name,
            subject: raw.payload?.headers?.first { $0.name.lowercased() == "subject" }?.value,
            snippet: raw.snippet,
            receivedAt: receivedAt,
            isRead: !(raw.labelIds ?? []).contains("UNREAD"),
            isArchived: false
        )
    }

    /// Presence of a non-empty List-Unsubscribe header on the metadata response.
    static func hasListUnsubscribe(_ raw: RawGmailMessage) -> Bool {
        raw.payload?.headers?.contains {
            $0.name.lowercased() == "list-unsubscribe"
                && !$0.value.trimmingCharacters(in: .whitespaces).isEmpty
        } ?? false
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
