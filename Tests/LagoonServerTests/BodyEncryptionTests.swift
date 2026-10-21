import XCTest
import GRDB
import Crypto
import Logging
import Hummingbird
import HummingbirdTesting
@testable import LagoonKit
@testable import LagoonServer

/// The body's storage guarantee, as an executable claim.
///
/// The spec pins it in one line (`docs/superpowers/specs/2026-09-09-lagoon-email-design.md`
/// §6.6 rule 5): "Message bodies never leave the client unencrypted. Server
/// stores ciphertext + metadata only. Body encryption keys live in client
/// keychain" — and names the enforcement: "unit test that asserts no
/// plaintext body field exists in any server-side table".
///
/// That test did not exist, and the body was stored as plain TEXT. This
/// file is it.
final class BodyEncryptionTests: XCTestCase {
    private let logger = Logger(label: "body-encryption-tests")

    /// The token key is read from the environment by `AccessTokenCipher`, and
    /// the body key from a process-wide provider. Both are installed here so
    /// every test in this class starts from the same known state — and the
    /// previous values are restored afterwards, because the environment
    /// variable may have been set by something outside the test process.
    private var previousTokenKey: String?
    private var previousBodyKey: (() throws -> SymmetricKey)?

    override func setUp() {
        super.setUp()
        previousTokenKey = TokenKeyFixture.current()
        previousBodyKey = BodyCipher.keyProvider
        TokenKeyFixture.apply(TokenKeyFixture.freshKey())
        TestDatabase.installTestBodyKey()
    }

    override func tearDown() {
        TokenKeyFixture.apply(previousTokenKey)
        BodyCipher.keyProvider = previousBodyKey
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeAccount() -> Account {
        Account(
            id: UUID(),
            provider: .qq,
            oauthUser: "be-\(UUID().uuidString)",
            email: "be-\(UUID().uuidString)@qq.com",
            credentials: nil
        )
    }

    private func seedAccount(_ account: Account, db: LagoonDB) async throws {
        try await AccountStore.upsert(
            account,
            credentials: try CredentialVault.seal(
                .imap(username: account.email, authCode: "code")
            ),
            db: db
        )
    }

    @discardableResult
    private func seedMessage(
        _ remoteId: String,
        accountId: UUID,
        db: LagoonDB,
        subject: String = "标题",
        snippet: String? = "预览文字"
    ) async throws -> UUID {
        let id = UUID()
        try await MessageStore.upsert(
            MessageHeader(
                id: id,
                accountId: accountId,
                remoteId: remoteId,
                threadId: "t-\(remoteId)",
                fromAddress: "sender@example.com",
                fromName: "Sender",
                subject: subject,
                snippet: snippet,
                receivedAt: Date(),
                isRead: true,
                isArchived: false
            ),
            db: db
        )
        return id
    }

    private func body(_ text: String, html: String? = nil) -> FetchedBody {
        FetchedBody(text: text, html: html, attachments: [], hasMore: false)
    }

    // MARK: - The spec's test: no plaintext body field exists

    /// **The test the spec asked for.**
    ///
    /// A body is stored, and then the *raw column* is read back — not
    /// through the store, which would decrypt it on the way out. If the
    /// plaintext is in there, the guarantee is false.
    func test_noPlaintextBodyFieldExistsInAnyServerSideTable() async throws {
        let account = makeAccount()
        let secret = "会议纪要：第三季度预算 1,200,000 元，密码 hunter2"
        try await TestDatabase.withConnection { conn in
            try await seedAccount(account, db: conn)
            try await seedMessage("m1", accountId: account.id, db: conn)
            try await BodyStore.put(
                accountId: account.id,
                remoteId: "m1",
                body: self.body(secret, html: "<p>\(secret)</p>"),
                db: conn
            )

            let raw = try conn.read { db -> (String, String?) in
                let row = try Row.fetchOne(
                    db,
                    sql: "SELECT body_cipher, body_html_cipher FROM message_bodies WHERE remote_id = ?",
                    arguments: ["m1"]
                )
                let text: String = row?["body_cipher"] ?? ""
                let html: String? = row?["body_html_cipher"]
                return (text, html)
            }

            XCTAssertFalse(
                raw.0.contains(secret),
                "the body is stored in the clear — the whole guarantee is false"
            )
            XCTAssertFalse(
                (raw.1 ?? "").contains(secret),
                "the HTML body is stored in the clear"
            )
            XCTAssertTrue(
                raw.0.hasPrefix(BodyCipher.envelopePrefix),
                "the stored body must be a sealed envelope, got: \(raw.0.prefix(24))…"
            )
            XCTAssertTrue(
                (raw.1 ?? "").hasPrefix(BodyCipher.envelopePrefix),
                "the stored HTML body must be a sealed envelope"
            )
        }
    }

    /// The preview in the list is body text too. Leaving it in the clear
    /// while sealing the body would make the guarantee a half-truth.
    func test_theSnippetIsSealedToo() async throws {
        let account = makeAccount()
        let preview = "附件里是工资单"
        try await TestDatabase.withConnection { conn in
            try await seedAccount(account, db: conn)
            try await seedMessage(
                "m1", accountId: account.id, db: conn, snippet: preview
            )
            let raw = try conn.read { db -> String in
                let row = try Row.fetchOne(
                    db,
                    sql: "SELECT snippet_cipher FROM message_headers WHERE remote_id = ?",
                    arguments: ["m1"]
                )
                let value: String = row?["snippet_cipher"] ?? ""
                return value
            }
            XCTAssertFalse(raw.contains(preview), "the preview is stored in the clear")
            XCTAssertTrue(raw.hasPrefix(BodyCipher.envelopePrefix))
        }
    }

    // MARK: - Round trip

    func test_sealOpenRoundTrip() throws {
        let plaintext = "正文 \(UUID().uuidString)"
        let sealed = try BodyCipher.seal(plaintext)
        XCTAssertTrue(sealed.hasPrefix(BodyCipher.envelopePrefix))
        XCTAssertFalse(sealed.contains(plaintext))
        XCTAssertEqual(try BodyCipher.open(sealed), plaintext)
    }

    /// Two seals of the same text differ — AES-GCM draws a fresh nonce every
    /// time. A store that produced identical ciphertext for identical bodies
    /// would be leaking equality.
    func test_sealingTheSameTextTwiceProducesDifferentCiphertext() throws {
        let plaintext = "同样的正文"
        let a = try BodyCipher.seal(plaintext)
        let b = try BodyCipher.seal(plaintext)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(try BodyCipher.open(a), plaintext)
        XCTAssertEqual(try BodyCipher.open(b), plaintext)
    }

    /// A reader that accepted an unsealed value would make the guarantee
    /// unfalsifiable — and a migration bug would become a quiet downgrade
    /// instead of a loud failure.
    func test_openingAnUnsealedValueFails() throws {
        XCTAssertThrowsError(try BodyCipher.open("明文正文")) { error in
            XCTAssertEqual(error as? BodyCipherError, .notSealed)
        }
    }

    /// The store still hands back the body it was given.
    func test_theStoreHandsBackWhatItStored() async throws {
        let account = makeAccount()
        let text = "正文内容"
        try await TestDatabase.withConnection { conn in
            try await seedAccount(account, db: conn)
            try await seedMessage("m1", accountId: account.id, db: conn)
            try await BodyStore.put(
                accountId: account.id,
                remoteId: "m1",
                body: self.body(text, html: "<p>\(text)</p>"),
                db: conn
            )
            let fetched = try await BodyStore.get(
                accountId: account.id, remoteId: "m1", db: conn
            )
            XCTAssertEqual(fetched?.text, text)
            XCTAssertEqual(fetched?.html, "<p>\(text)</p>")
        }
    }

    // MARK: - The migration

    /// A store written by an older build — plaintext body, plaintext snippet —
    /// must come out sealed, with the body still readable.
    func test_theMigrationSealsALegacyPlaintextStore() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("lagoon-legacy-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let accountId = UUID()
        let secret = "旧版本写下来的正文"

        // Stand up the pre-encryption shape by hand: the legacy column
        // names, plain values, and the `lagoon-v1` schema underneath.
        let legacy = try DatabasePool(path: path)
        var legacyMigrator = DatabaseMigrator()
        legacyMigrator.registerMigration("lagoon-v1") { db in
            try db.execute(sql: LagoonDatabase.schema)
        }
        try legacyMigrator.migrate(legacy)
        try await legacy.write { db in
            try db.execute(
                sql: """
                    INSERT INTO accounts (id, provider, oauth_user, email, created_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [
                    accountId, "qq", "legacy@example.com", "legacy@example.com",
                    "2026-09-01 00:00:00.000",
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO message_headers
                        (id, account_id, remote_id, thread_id, from_address,
                         subject, snippet, received_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID(), accountId, "old-1", "t-old-1", "sender@example.com",
                    "旧标题", secret, "2026-09-01 00:00:00.000",
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO message_bodies
                        (account_id, remote_id, body_text, body_html)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [accountId, "old-1", secret, "<p>\(secret)</p>"]
            )
        }
        try legacy.close()

        // Opening the store is what runs the migration.
        let pool = try LagoonDatabase.open(path: path)
        defer { try? pool.close() }
        let db = LagoonDB(pool)

        let stored = try db.read { db -> (String, String, String) in
            let bodyRow = try Row.fetchOne(
                db,
                sql: "SELECT body_cipher, body_html_cipher FROM message_bodies WHERE remote_id = ?",
                arguments: ["old-1"]
            )
            let headerRow = try Row.fetchOne(
                db,
                sql: "SELECT snippet_cipher FROM message_headers WHERE remote_id = ?",
                arguments: ["old-1"]
            )
            let bodyText: String = bodyRow?["body_cipher"] ?? ""
            let bodyHTML: String? = bodyRow?["body_html_cipher"]
            let snippet: String = headerRow?["snippet_cipher"] ?? ""
            return (bodyText, bodyHTML ?? "", snippet)
        }
        XCTAssertFalse(stored.0.contains(secret), "the legacy body is still in the clear")
        XCTAssertFalse(stored.1.contains(secret), "the legacy HTML body is still in the clear")
        XCTAssertFalse(stored.2.contains(secret), "the legacy snippet is still in the clear")
        XCTAssertTrue(stored.0.hasPrefix(BodyCipher.envelopePrefix))
        XCTAssertTrue(stored.1.hasPrefix(BodyCipher.envelopePrefix))
        XCTAssertTrue(stored.2.hasPrefix(BodyCipher.envelopePrefix))

        // And the body is still readable through the store.
        let fetched = try await BodyStore.get(
            accountId: accountId, remoteId: "old-1", db: db
        )
        XCTAssertEqual(fetched?.text, secret)
    }

    /// A store opened **without** a key must not keep a plaintext body.
    ///
    /// Bodies are a cache, so dropping them costs a re-download and no mail.
    /// Keeping them readable would cost the guarantee.
    func test_aStoreOpenedWithoutAKeyDoesNotKeepPlaintextBodies() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("lagoon-nokey-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let accountId = UUID()
        let secret = "没有密钥时写下的正文"

        let legacy = try DatabasePool(path: path)
        var legacyMigrator = DatabaseMigrator()
        legacyMigrator.registerMigration("lagoon-v1") { db in
            try db.execute(sql: LagoonDatabase.schema)
        }
        try legacyMigrator.migrate(legacy)
        try await legacy.write { db in
            try db.execute(
                sql: """
                    INSERT INTO accounts (id, provider, oauth_user, email, created_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [
                    accountId, "qq", "nokey@example.com", "nokey@example.com",
                    "2026-09-01 00:00:00.000",
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO message_headers
                        (id, account_id, remote_id, thread_id, from_address,
                         subject, snippet, received_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID(), accountId, "nk-1", "t-nk-1", "sender@example.com",
                    "标题", secret, "2026-09-01 00:00:00.000",
                ]
            )
            try db.execute(
                sql: "INSERT INTO message_bodies (account_id, remote_id, body_text) VALUES (?, ?, ?)",
                arguments: [accountId, "nk-1", secret]
            )
        }
        try legacy.close()

        // No key installed for this open.
        let previous = BodyCipher.keyProvider
        BodyCipher.keyProvider = nil
        defer { BodyCipher.keyProvider = previous }

        let pool = try LagoonDatabase.open(path: path)
        defer { try? pool.close() }
        let db = LagoonDB(pool)

        let remaining = try db.read { db -> Int in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message_bodies") ?? 0
        }
        XCTAssertEqual(remaining, 0, "a body that cannot be sealed must not survive")
        let snippet = try db.read { db -> String in
            let row = try Row.fetchOne(
                db, sql: "SELECT snippet_cipher FROM message_headers WHERE remote_id = ?",
                arguments: ["nk-1"]
            )
            let value: String = row?["snippet_cipher"] ?? ""
            return value
        }
        XCTAssertFalse(snippet.contains(secret), "a snippet that cannot be sealed must not survive")
        XCTAssertEqual(snippet, "")
    }

    // MARK: - Search

    /// Sealing the body must not cost the user the ability to search it.
    ///
    /// The body arm used to be `body_text LIKE '%needle%'`. It is now a
    /// registered SQL function that opens the envelope — and the search has
    /// to keep working, or "加密存储" would have quietly cost a core feature.
    func test_searchStillFindsAMatchInsideTheSealedBody() async throws {
        let account = makeAccount()
        let needle = "发票抬头"
        try await TestDatabase.withConnection { conn in
            try await seedAccount(account, db: conn)
            try await seedMessage(
                "m1", accountId: account.id, db: conn, subject: "无关的标题", snippet: "无关的预览"
            )
            try await BodyStore.put(
                accountId: account.id,
                remoteId: "m1",
                body: self.body("你好，这是附件里的\(needle)，请查收。"),
                db: conn
            )
            let hits = try await search(account.id, q: needle, db: conn)
            XCTAssertEqual(hits.map(\.remoteId), ["m1"])
        }
    }

    /// The preview is matched the same way, and the match is
    /// case-insensitive like the `LIKE` arms it sits next to.
    func test_searchMatchesTheSealedSnippetCaseInsensitively() async throws {
        let account = makeAccount()
        try await TestDatabase.withConnection { conn in
            try await seedAccount(account, db: conn)
            try await seedMessage(
                "m1", accountId: account.id, db: conn, subject: "无关的标题", snippet: "Invoice ATTACHED"
            )
            let hits = try await search(account.id, q: "invoice", db: conn)
            XCTAssertEqual(hits.map(\.remoteId), ["m1"])
        }
    }

    /// A body that does not contain the needle must not come back.
    func test_searchDoesNotMatchASealedBodyThatDoesNotContainTheNeedle() async throws {
        let account = makeAccount()
        try await TestDatabase.withConnection { conn in
            try await seedAccount(account, db: conn)
            try await seedMessage(
                "m1", accountId: account.id, db: conn, subject: "无关的标题", snippet: "无关的预览"
            )
            try await BodyStore.put(
                accountId: account.id,
                remoteId: "m1",
                body: self.body("完全不同的内容"),
                db: conn
            )
            let hits = try await search(account.id, q: "发票抬头", db: conn)
            XCTAssertTrue(hits.isEmpty, "a sealed body must not match a needle it does not contain")
        }
    }

    private func search(_ accountId: UUID, q: String, db: LagoonDB) async throws -> [MessageHeader] {
        let router = Router<BasicRequestContext>()
        SearchRoutes.register(on: router, db: db, logger: self.logger)
        let app = Application(router: router)
        var out: [MessageHeader] = []
        try await app.test(.router) { client in
            let escaped = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
            try await client.execute(
                uri: "/api/search?accountId=\(accountId.uuidString)&q=\(escaped)",
                method: .get
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                out = try decoder.decode(
                    SearchResponse.self,
                    from: Data(response.body.readableBytesView)
                ).results
            }
        }
        return out
    }
}
