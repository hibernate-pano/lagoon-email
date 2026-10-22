import XCTest
import Foundation
import Logging
import Hummingbird
import GRDB
import Crypto
@testable import LagoonServer
@testable import LagoonKit

/// The guardrail for a store whose body key is gone.
///
/// ## What is being defended
///
/// The body key lives in the Keychain; the sealed bodies live in the store.
/// When the Keychain comes back without the key, **writing a new one** is
/// what turns "I lost my key" into "my mail is gone for good": the new key
/// cannot open what the old one sealed, the rows stay in the database, and
/// nothing in the product says so.
///
/// These tests pin the three answers that keep that from happening: the
/// probe tells "the store holds nothing" apart from "I could not look"; a
/// missing key does not take the sync down with it; and the user is told.
final class BodyKeyGuardTests: XCTestCase {
    private static let logger = Logger(label: "body-key-guard-tests")

    // MARK: - The probe

    /// A store on disk, at a path this test owns.
    private func makeStore() throws -> (pool: DatabasePool, path: String) {
        // The body is sealed at rest, so a store that is opened needs a key —
        // the same fixed test key the rest of the suite uses.
        TestDatabase.installTestBodyKey()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lagoon-body-key-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("lagoon.sqlite").path
        return (try LagoonDatabase.open(path: path), path)
    }

    func test_probe_reportsASealedStore() async throws {
        let (pool, path) = try makeStore()
        defer { try? pool.close() }
        let db = LagoonDB(pool)
        let account = makeAccount()
        try await AccountStore.upsert(account, credentials: Data([1, 2, 3]), db: db)
        try await MessageStore.upsert(
            header(accountId: account.id, remoteId: "m-1", snippet: "the first lines"),
            db: db
        )
        try await BodyStore.put(
            accountId: account.id, remoteId: "m-1", body: body("the body"), db: db
        )

        XCTAssertEqual(
            SealedStoreProbe.state(dbPath: path), .sealed,
            "a store that holds a sealed body must be reported as sealed"
        )
    }

    func test_probe_reportsAStoreWithNothingSealed() async throws {
        let (pool, path) = try makeStore()
        defer { try? pool.close() }
        let db = LagoonDB(pool)
        let account = makeAccount()
        try await AccountStore.upsert(account, credentials: Data([1, 2, 3]), db: db)
        try await MessageStore.upsert(
            header(accountId: account.id, remoteId: "m-1", snippet: nil), db: db
        )

        XCTAssertEqual(
            SealedStoreProbe.state(dbPath: path), .empty,
            "a store that holds no sealed value must be reported as empty"
        )
    }

    func test_probe_reportsEmptyWhenThereIsNoStoreYet() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("lagoon-absent-\(UUID().uuidString).sqlite").path
        XCTAssertEqual(
            SealedStoreProbe.state(dbPath: missing), .empty,
            "a store that is not there yet holds nothing, and a key is safe to make"
        )
    }

    func test_probe_reportsUndeterminedWhenTheFileCannotBeRead() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("lagoon-garbage-\(UUID().uuidString).sqlite").path
        try Data("this is not a database".utf8).write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }

        XCTAssertEqual(
            SealedStoreProbe.state(dbPath: path), .undetermined,
            "a store that cannot be read proves nothing — absence is not established"
        )
    }

    // MARK: - The sync survives a missing key

    func test_upsert_keepsSyncingWhenThereIsNoKey() async throws {
        let (pool, _) = try makeStore()
        defer { try? pool.close() }
        let db = LagoonDB(pool)
        let account = makeAccount()
        try await AccountStore.upsert(account, credentials: Data([1, 2, 3]), db: db)

        let previous = BodyCipher.keyProvider
        BodyCipher.keyProvider = nil
        defer { BodyCipher.keyProvider = previous }

        try await MessageStore.upsert(
            header(accountId: account.id, remoteId: "m-1", snippet: "the first lines"),
            db: db
        )

        let stored = try await MessageStore.recent(forAccount: account.id, limit: 10, db: db)
        XCTAssertEqual(
            stored.count, 1,
            "a missing body key must not take the headers down with it"
        )
        XCTAssertNil(
            stored.first?.snippet,
            "a preview that cannot be sealed is left empty, not written in the clear"
        )
    }

    // MARK: - The user is told

    func test_storeNotice_isRaisedWhenTheKeyIsGoneAndTheStoreHoldsSealedValues() async throws {
        let (pool, _) = try makeStore()
        defer { try? pool.close() }
        let db = LagoonDB(pool)
        let account = makeAccount()
        try await AccountStore.upsert(account, credentials: Data([1, 2, 3]), db: db)
        try await MessageStore.upsert(
            header(accountId: account.id, remoteId: "m-1", snippet: "the first lines"), db: db
        )
        try await BodyStore.put(
            accountId: account.id, remoteId: "m-1", body: body("the body"), db: db
        )

        let previous = BodyCipher.keyProvider
        BodyCipher.keyProvider = nil
        defer { BodyCipher.keyProvider = previous }

        let router = Router<BasicRequestContext>()
        StoreNoticeRoutes.register(on: router, db: db, logger: Self.logger)
        let app = Application(router: router)
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/store-notices", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
                let decoded = try RouteJSON.decoder().decode(
                    StoreNoticeListResponse.self, from: Data(buffer: response.body)
                )
                let notice = decoded.notices.first { $0.id == StoreNotice.bodyKeyLostID }
                XCTAssertNotNil(
                    notice,
                    "a store that cannot open its own bodies has to say so"
                )
                XCTAssertEqual(
                    notice?.detail, "1",
                    "the notice carries how many bodies are affected"
                )
            }
        }
    }

    func test_storeNotice_isNotRaisedWhileTheKeyIsThere() async throws {
        let (pool, _) = try makeStore()
        defer { try? pool.close() }
        let db = LagoonDB(pool)
        let account = makeAccount()
        try await AccountStore.upsert(account, credentials: Data([1, 2, 3]), db: db)
        try await MessageStore.upsert(
            header(accountId: account.id, remoteId: "m-1", snippet: "the first lines"), db: db
        )
        try await BodyStore.put(
            accountId: account.id, remoteId: "m-1", body: body("the body"), db: db
        )

        let router = Router<BasicRequestContext>()
        StoreNoticeRoutes.register(on: router, db: db, logger: Self.logger)
        let app = Application(router: router)
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/store-notices", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
                let decoded = try RouteJSON.decoder().decode(
                    StoreNoticeListResponse.self, from: Data(buffer: response.body)
                )
                XCTAssertFalse(
                    decoded.notices.contains { $0.id == StoreNotice.bodyKeyLostID },
                    "a store whose key is present is not a store that has lost one"
                )
            }
        }
    }

    // MARK: - Fixtures

    private func makeAccount() -> Account {
        Account(
            id: UUID(),
            provider: .qq,
            oauthUser: "body-key-\(UUID().uuidString)",
            email: "body-key-\(UUID().uuidString)@qq.com",
            credentials: nil
        )
    }

    private func header(accountId: UUID, remoteId: String, snippet: String?) -> MessageHeader {
        MessageHeader(
            id: UUID(),
            accountId: accountId,
            remoteId: remoteId,
            threadId: "t-\(remoteId)",
            fromAddress: "alice@example.com",
            fromName: nil,
            subject: "a subject",
            snippet: snippet,
            receivedAt: Date(),
            isRead: false,
            isArchived: false
        )
    }

    private func body(_ text: String) -> FetchedBody {
        FetchedBody(text: text, html: "<p>\(text)</p>", attachments: [], hasMore: false)
    }
}
