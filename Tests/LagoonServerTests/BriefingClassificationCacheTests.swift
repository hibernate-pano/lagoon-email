import XCTest
import Foundation
import Logging
import PostgresNIO
import Hummingbird
import HummingbirdTesting
@testable import LagoonServer
@testable import LagoonKit

/// Counts classify() calls and remembers how many messages were sent, so the
/// tests can prove the cache prevents re-classification on every refresh.
private final class CountingClassifier: BriefingClassifying, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private var _messagesSeen = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    var messagesSeen: Int { lock.lock(); defer { lock.unlock() }; return _messagesSeen }

    func classify(
        _ messages: [MessageHeader],
        accountEmail: String,
        language: String?
    ) async throws -> [String: BriefingGroup] {
        lock.lock()
        _calls += 1
        _messagesSeen += messages.count
        lock.unlock()
        return Dictionary(uniqueKeysWithValues: messages.map { ($0.remoteId, .subscriptionNoise) })
    }
}

/// Omits every id — the classifier has no opinion.
private struct SilentClassifier: BriefingClassifying {
    func classify(
        _ messages: [MessageHeader],
        accountEmail: String,
        language: String?
    ) async throws -> [String: BriefingGroup] { [:] }
}

final class BriefingClassificationCacheTests: XCTestCase {

    private func header(_ id: String, isRead: Bool = false) -> MessageHeader {
        MessageHeader(
            id: UUID(),
            accountId: UUID(),
            remoteId: id,
            threadId: "t-\(id)",
            fromAddress: "a@example.com",
            fromName: nil,
            subject: "s",
            snippet: nil,
            receivedAt: Date(),
            isRead: isRead,
            isArchived: false
        )
    }

    // MARK: - Cache unit behaviour

    func test_firstLookup_returnsEverythingAsPending() async {
        let cache = BriefingClassificationCache()
        let messages = [header("a"), header("b")]
        let (known, pending) = await cache.cached(for: messages)
        XCTAssertTrue(known.isEmpty)
        XCTAssertEqual(pending.map(\.remoteId), ["a", "b"])
    }

    func test_storedGroups_areServedAndNotAskedAgain() async {
        let cache = BriefingClassificationCache()
        let messages = [header("a"), header("b")]
        await cache.store(["a": .needsReply], for: messages)

        let (known, pending) = await cache.cached(for: messages)
        XCTAssertEqual(known, ["a": .needsReply])
        XCTAssertTrue(pending.isEmpty, "an id the classifier omitted must not be re-asked")
    }

    /// Marking a message read legitimately changes its group, so the cache key
    /// includes the read flag and the message is re-classified.
    func test_readStateChange_reclassifies() async {
        let cache = BriefingClassificationCache()
        let unread = header("a", isRead: false)
        await cache.store(["a": .needsReply], for: [unread])

        let read = header("a", isRead: true)
        let (known, pending) = await cache.cached(for: [read])
        XCTAssertTrue(known.isEmpty)
        XCTAssertEqual(pending.map(\.remoteId), ["a"])
    }

    func test_entriesExpireAfterTTL() async {
        let cache = BriefingClassificationCache(ttl: 60)
        let messages = [header("a")]
        await cache.store(["a": .pinned], for: messages)

        let fresh = await cache.cached(for: messages, now: Date())
        XCTAssertEqual(fresh.known, ["a": .pinned])

        let stale = await cache.cached(for: messages, now: Date().addingTimeInterval(120))
        XCTAssertTrue(stale.known.isEmpty)
        XCTAssertEqual(stale.pending.count, 1)
    }

    // MARK: - Route behaviour (the cost fix)

    private func makeAccount(oauthUser: String) -> Account {
        Account(
            id: UUID(),
            provider: .gmail,
            oauthUser: oauthUser,
            email: "\(oauthUser)@example.com",
            credentials: nil,
            isActive: false
        )
    }

    /// Two consecutive feed refreshes must send the LLM only the messages it
    /// has never seen. The macOS client refreshes every 30 s; before the cache
    /// every refresh cost a full 50-message classification (~8k prompt tokens).
    func test_repeatedBriefingRequests_classifyOnlyOnce() async throws {
        let oauthUser = "cache-\(UUID().uuidString)"
        let account = makeAccount(oauthUser: oauthUser)

        try await TestDatabase.withConnection(cleanup: { conn in
            try? await TestDatabase.deleteMessages(accountId: account.id, db: conn)
            try? await TestDatabase.deleteAccount(id: account.id, db: conn)
        }) { conn in
            try await AccountStore.upsert(
                account,
                credentials: Data([1, 2, 3]),
                db: conn
            )
            let ids = ["m1-\(UUID())", "m2-\(UUID())", "m3-\(UUID())"]
            for id in ids {
                try await MessageStore.upsert(
                    MessageHeader(
                        id: UUID(),
                        accountId: account.id,
                        remoteId: id,
                        threadId: "t-\(id)",
                        fromAddress: "sender@example.com",
                        fromName: nil,
                        subject: "subject",
                        snippet: nil,
                        receivedAt: Date(),
                        isRead: false,
                        isArchived: false
                    ),
                    db: conn
                )
            }

            let classifier = CountingClassifier()
            let router = Router()
            BriefingRoutes.register(
                on: router,
                db: conn,
                logger: Logger(label: "cache-tests"),
                classifier: classifier
            )
            let app = Application(router: router)
            let uri = "/api/briefing?accountId=\(account.id.uuidString)"

            try await app.test(.router) { client in
                for _ in 0..<3 {
                    try await client.execute(uri: uri, method: .get) { response in
                        XCTAssertEqual(response.status, .ok)
                        let decoded = try JSONDecoder.iso8601.decode(
                            BriefingResponse.self,
                            from: Data(buffer: response.body)
                        )
                        XCTAssertEqual(decoded.items.count, 3)
                        XCTAssertTrue(decoded.items.allSatisfy { $0.group == .subscriptionNoise })
                    }
                }
            }

            XCTAssertEqual(classifier.calls, 1, "three refreshes must classify once")
            XCTAssertEqual(classifier.messagesSeen, 3, "only the unseen messages are sent")

            // Marking one read changes its cache key -> only that one is re-sent.
            try await MessageStore.markRead(remoteId: ids[0], accountId: account.id, db: conn)
            try await app.test(.router) { client in
                try await client.execute(uri: uri, method: .get) { response in
                    XCTAssertEqual(response.status, .ok)
                }
            }
            XCTAssertEqual(classifier.calls, 2)
            XCTAssertEqual(classifier.messagesSeen, 4, "one re-classified message, not three")
        }
    }

    /// A classifier with no opinion must not be re-asked on every refresh.
    func test_silentClassifier_isAskedOnce() async throws {
        let oauthUser = "cache-\(UUID().uuidString)"
        let account = makeAccount(oauthUser: oauthUser)

        try await TestDatabase.withConnection(cleanup: { conn in
            try? await TestDatabase.deleteMessages(accountId: account.id, db: conn)
            try? await TestDatabase.deleteAccount(id: account.id, db: conn)
        }) { conn in
            try await AccountStore.upsert(
                account,
                credentials: Data([1, 2, 3]),
                db: conn
            )
            let id = "s-\(UUID())"
            try await MessageStore.upsert(
                MessageHeader(
                    id: UUID(),
                    accountId: account.id,
                    remoteId: id,
                    threadId: "t-\(id)",
                    fromAddress: "alice@example.com",
                    fromName: nil,
                    subject: "subject",
                    snippet: nil,
                    receivedAt: Date(),
                    isRead: false,
                    isArchived: false
                ),
                db: conn
            )

            let cache = BriefingClassificationCache()
            let router = Router()
            BriefingRoutes.register(
                on: router,
                db: conn,
                logger: Logger(label: "cache-tests"),
                classifier: SilentClassifier(),
                cache: cache
            )
            let app = Application(router: router)
            let uri = "/api/briefing?accountId=\(account.id.uuidString)"

            try await app.test(.router) { client in
                for _ in 0..<2 {
                    try await client.execute(uri: uri, method: .get) { response in
                        XCTAssertEqual(response.status, .ok)
                        let decoded = try JSONDecoder.iso8601.decode(
                            BriefingResponse.self,
                            from: Data(buffer: response.body)
                        )
                        // Heuristics stand when the classifier says nothing.
                        XCTAssertEqual(decoded.items.first?.group, .needsReply)
                        XCTAssertEqual(decoded.items.first?.reasonCode, "needs-reply")
                    }
                }
            }
            let count = await cache.count()
            XCTAssertEqual(count, 1, "the asked-but-omitted id must be cached")
        }
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
