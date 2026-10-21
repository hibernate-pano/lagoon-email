import XCTest
import Foundation
import GRDB
import Crypto
import Logging
@testable import LagoonKit
@testable import LagoonServer

/// The AI-generated reply drafts, sealed at rest.
///
/// ## Why this file exists
///
/// The product encrypts the mail body so that a copied database file does
/// not hand over readable mail. The drafts were in the clear: a draft is
/// generated *from* the mail, so it reproduces the substance of somebody
/// else's email ("关于贵方提出的开源维护者合作方案") in a column the
/// product never sealed — and in a column the user's manual did not list
/// as plaintext either.
///
/// The user's own database proved it: `SELECT substr(variants,1,300) FROM
/// draft_replies` returned readable Chinese reply text.
///
/// This file is the executable claim that it no longer does.
final class DraftSealTests: XCTestCase {
    private let logger = Logger(label: "draft-seal-tests")

    private var previousBodyKey: (() throws -> SymmetricKey)?
    private var previousTokenKey: (() throws -> SymmetricKey)?

    override func setUp() {
        super.setUp()
        previousBodyKey = BodyCipher.keyProvider
        TestDatabase.installTestBodyKey()
        // Seeding an account writes sealed credentials, so the store needs
        // the *credential* key as well as the body key. A fixed test key,
        // same reasoning as `installTestBodyKey`: a throwaway store in the
        // temporary directory protects nothing.
        previousTokenKey = AccessTokenCipher.keyProvider
        let tokenBytes = Data((32..<64).map { UInt8($0) })
        AccessTokenCipher.keyProvider = { SymmetricKey(data: tokenBytes) }
    }

    override func tearDown() {
        BodyCipher.keyProvider = previousBodyKey
        AccessTokenCipher.keyProvider = previousTokenKey
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeAccount() -> Account {
        Account(
            id: UUID(),
            provider: .qq,
            oauthUser: "ds-\(UUID().uuidString)",
            email: "ds-\(UUID().uuidString)@qq.com",
            credentials: nil
        )
    }

    @discardableResult
    private func seedAccount(_ account: Account, db: LagoonDB) async throws -> UUID {
        try await AccountStore.upsert(
            account,
            credentials: try CredentialVault.seal(
                .imap(username: account.email, authCode: "code")
            ),
            db: db
        )
        return account.id
    }

    /// The raw `variants` column, read straight out of SQLite.
    private func rawVariants(accountId: UUID, remoteId: String, db: LagoonDB) async throws -> String {
        try db.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT variants FROM draft_replies WHERE account_id = ? AND remote_id = ?",
                arguments: [accountId, remoteId]
            )
            return (row?["variants"] as String?) ?? ""
        }
    }

    // MARK: - The write path seals

    /// The claim the defect was: a draft written by the store must not be
    /// readable in the raw column.
    func test_theStoredDraftIsAnEnvelopeNotPlaintext() async throws {
        let account = makeAccount()
        let secret = "关于贵方提出的开源维护者合作方案，我方目前仍在评估阶段。"
        try await TestDatabase.withConnection { conn in
            try await seedAccount(account, db: conn)
            let draft = try await DraftReplyStore.create(
                accountId: account.id,
                remoteId: "m1",
                variants: [secret, "谢谢再次跟进！", "收到。"],
                db: conn
            )
            XCTAssertEqual(draft.variants, [secret, "谢谢再次跟进！", "收到。"])

            let raw = try await rawVariants(
                accountId: account.id, remoteId: "m1", db: conn
            )
            XCTAssertFalse(
                raw.contains(secret),
                "the draft is stored in the clear — the guarantee is false"
            )
            XCTAssertFalse(raw.contains("谢谢再次跟进"), "the draft is stored in the clear")
            XCTAssertTrue(
                raw.hasPrefix(BodyCipher.envelopePrefix),
                "the stored draft must be a sealed envelope, got: \(raw.prefix(24))…"
            )
        }
    }

    /// The round trip: what goes in comes out, in order.
    func test_theStoreHandsBackWhatItStored() async throws {
        let account = makeAccount()
        let variants = ["第一版：简洁直接", "第二版：礼貌周全", "第三版：稍长"]
        try await TestDatabase.withConnection { conn in
            try await seedAccount(account, db: conn)
            _ = try await DraftReplyStore.create(
                accountId: account.id, remoteId: "m1", variants: variants, db: conn
            )
            let listed = try await DraftReplyStore.list(
                accountId: account.id, remoteId: "m1", db: conn
            )
            XCTAssertEqual(listed.count, 1)
            XCTAssertEqual(listed.first?.variants, variants)
        }
    }

    /// `chosen_variant` is an **index into the array**, and it has to keep
    /// pointing at the same element after the round trip. If sealing
    /// reordered the array, the user's pick would silently become somebody
    /// else's text.
    func test_chosenVariantStillPointsAtTheSameElement() async throws {
        let account = makeAccount()
        let variants = ["第一版：简洁直接", "第二版：礼貌周全", "第三版：稍长"]
        try await TestDatabase.withConnection { conn in
            try await seedAccount(account, db: conn)
            let draft = try await DraftReplyStore.create(
                accountId: account.id, remoteId: "m1", variants: variants, db: conn
            )
            try conn.write { db in
                try db.execute(
                    sql: "UPDATE draft_replies SET chosen_variant = ? WHERE id = ?",
                    arguments: [2, draft.id]
                )
            }
            let listed = try await DraftReplyStore.list(
                accountId: account.id, remoteId: "m1", db: conn
            )
            XCTAssertEqual(listed.first?.chosenVariant, 2)
            XCTAssertEqual(listed.first?.variants, variants)
            // And the element the index names is the one the user picked.
            let chosen = try XCTUnwrap(listed.first?.variants[2])
            XCTAssertEqual(chosen, "第三版：稍长")
        }
    }

    // MARK: - The read path fails loudly

    /// A draft that cannot be opened must **fail**, not come back as an
    /// empty array.
    ///
    /// An empty array is what a draft with no variants looks like, so a
    /// reader that swallowed the failure would show the user an empty draft
    /// and say nothing — the exact silent downgrade this store refuses.
    func test_readingAnUnsealedDraftFailsLoudly() async throws {
        let account = makeAccount()
        try await TestDatabase.withConnection { conn in
            try await seedAccount(account, db: conn)
            try conn.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO draft_replies (account_id, remote_id, variants)
                        VALUES (?, ?, ?)
                        """,
                    arguments: [account.id, "m1", "[\"明文草稿\"]"]
                )
            }
            do {
                let listed = try await DraftReplyStore.list(
                    accountId: account.id, remoteId: "m1", db: conn
                )
                XCTFail("an unreadable draft must not decode to \(listed)")
            } catch let error as DraftCipherError {
                XCTAssertEqual(error, .notSealed)
            }
        }
    }

    /// A draft sealed with a *different* key must fail too — that is what a
    /// restored backup with a mismatched keychain looks like.
    func test_readingADraftSealedWithAnotherKeyFailsLoudly() async throws {
        let account = makeAccount()
        let otherKey = SymmetricKey(data: Data((100..<132).map { UInt8($0) }))
        let foreign = try BodyCipher.seal("[\"别人的草稿\"]", using: otherKey)
        try await TestDatabase.withConnection { conn in
            try await seedAccount(account, db: conn)
            try conn.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO draft_replies (account_id, remote_id, variants)
                        VALUES (?, ?, ?)
                        """,
                    arguments: [account.id, "m1", foreign]
                )
            }
            do {
                let listed = try await DraftReplyStore.list(
                    accountId: account.id, remoteId: "m1", db: conn
                )
                XCTFail("a draft sealed with another key must not decode to \(listed)")
            } catch let error as DraftCipherError {
                XCTAssertEqual(error, .notAuthentic, "a wrong key is an authenticity failure, not a shape error")
            }
        }
    }

    // MARK: - The migration

    /// A store written by an older build — a plaintext draft — must come out
    /// sealed, with the draft still readable.
    func test_theMigrationSealsALegacyPlaintextDraft() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("lagoon-legacy-draft-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let accountId = UUID()
        let secret = "旧版本写下来的草稿：关于开源维护者合作方案"

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
                    INSERT INTO draft_replies (account_id, remote_id, variants)
                    VALUES (?, ?, ?)
                    """,
                arguments: [
                    accountId, "old-1",
                    "[\"旧版本写下来的草稿：关于开源维护者合作方案\"]",
                ]
            )
        }
        try legacy.close()

        // Opening the store is what runs the migration.
        let pool = try LagoonDatabase.open(path: path)
        defer { try? pool.close() }
        let db = LagoonDB(pool)

        let raw = try db.read { db -> String in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT variants FROM draft_replies WHERE remote_id = ?",
                arguments: ["old-1"]
            )
            return (row?["variants"] as String?) ?? ""
        }
        XCTAssertFalse(raw.contains(secret), "the legacy draft is still in the clear")
        XCTAssertTrue(raw.hasPrefix(BodyCipher.envelopePrefix))

        // And the draft is still readable through the store.
        let listed = try await DraftReplyStore.list(
            accountId: accountId, remoteId: "old-1", db: db
        )
        XCTAssertEqual(listed.first?.variants, [secret])
    }

    /// The migration must be **idempotent**: a value that is already sealed
    /// is left alone, not sealed again.
    ///
    /// Sealing an envelope would produce the envelope *of* an envelope, and
    /// the draft would become unreadable — so a migration that ran twice
    /// would quietly destroy every draft it was supposed to protect.
    func test_theMigrationLeavesAnAlreadySealedDraftAlone() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("lagoon-idem-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let accountId = UUID()
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
                    accountId, "qq", "idem@example.com", "idem@example.com",
                    "2026-09-01 00:00:00.000",
                ]
            )
        }
        try legacy.close()

        // First open: the migration seals nothing (there is nothing to
        // seal) and the store is at the current version.
        let pool = try LagoonDatabase.open(path: path)
        let db = LagoonDB(pool)

        // Write a draft through the store — already sealed by the write path.
        let draft = try await DraftReplyStore.create(
            accountId: accountId, remoteId: "m1", variants: ["第一版", "第二版"], db: db
        )
        let before = try db.read { db -> String in
            let row = try Row.fetchOne(
                db, sql: "SELECT variants FROM draft_replies WHERE id = ?",
                arguments: [draft.id]
            )
            return (row?["variants"] as String?) ?? ""
        }
        try pool.close()

        // Second open: the migration runs again (the migrator is
        // re-applied to a fresh pool in this test by dropping the recorded
        // identifier), and the already-sealed value must survive.
        let reopened = try DatabasePool(path: path)
        try await reopened.write { db in
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
                           arguments: [LagoonDatabase.sealedDraftsVersion])
        }
        try reopened.close()

        let pool2 = try LagoonDatabase.open(path: path)
        defer { try? pool2.close() }
        let db2 = LagoonDB(pool2)
        let after = try db2.read { db -> String in
            let row = try Row.fetchOne(
                db, sql: "SELECT variants FROM draft_replies WHERE id = ?",
                arguments: [draft.id]
            )
            return (row?["variants"] as String?) ?? ""
        }
        XCTAssertEqual(
            before, after,
            "the migration sealed an already-sealed draft a second time"
        )
        let listed = try await DraftReplyStore.list(
            accountId: accountId, remoteId: "m1", db: db2
        )
        XCTAssertEqual(listed.first?.variants, ["第一版", "第二版"])
    }

    /// A fresh install has no drafts, so the migration is a no-op.
    func test_theMigrationIsANoOpOnAFreshDatabase() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("lagoon-fresh-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let pool = try LagoonDatabase.open(path: path)
        defer { try? pool.close() }
        let db = LagoonDB(pool)

        let drafts = try db.read { db -> Int in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM draft_replies") ?? -1
        }
        XCTAssertEqual(drafts, 0)

        // The notice table exists and is empty: nothing was dropped, so
        // nothing has to be reported.
        let notices = try db.read { db -> Int in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM store_notices") ?? -1
        }
        XCTAssertEqual(notices, 0)
    }

    // MARK: - The no-key path fails closed

    /// A store opened **without** a key must not keep a plaintext draft.
    ///
    /// Drafts are a cache — the model can write the same three replies
    /// again — so dropping them costs one API call. Keeping them readable
    /// would cost the guarantee.
    func test_aStoreOpenedWithoutAKeyDropsPlaintextDraftsAndSaysSo() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("lagoon-nokey-draft-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let accountId = UUID()
        let secret = "没有密钥时写下的草稿"

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
                    INSERT INTO draft_replies (account_id, remote_id, variants)
                    VALUES (?, ?, ?)
                    """,
                // The plaintext is `secret` — one source of truth, so the
                // string the test names is the string that gets written.
                arguments: [accountId, "nk-1", "[\"\(secret)\"]"]
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
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM draft_replies") ?? -1
        }
        XCTAssertEqual(remaining, 0, "a draft that cannot be sealed must not survive")

        // …and the deletion is **reported**, not silent.
        let notices = try await StoreNoticeStore.list(db: db)
        XCTAssertEqual(notices.count, 1, "the dropped drafts must be reported")
        XCTAssertEqual(notices.first?.id, StoreNotice.draftsDroppedID)
        XCTAssertEqual(notices.first?.detail, "1")
    }

    /// The notice is written once, not once per launch: the same condition
    /// is the same notice, and the user should hear about it once.
    func test_theDroppedDraftsNoticeIsWrittenOnlyOnce() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("lagoon-nokey-once-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let accountId = UUID()
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
                    accountId, "qq", "once@example.com", "once@example.com",
                    "2026-09-01 00:00:00.000",
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO draft_replies (account_id, remote_id, variants)
                    VALUES (?, ?, ?)
                    """,
                arguments: [accountId, "nk-1", "[\"草稿\"]"]
            )
        }
        try legacy.close()

        let previous = BodyCipher.keyProvider
        BodyCipher.keyProvider = nil
        defer { BodyCipher.keyProvider = previous }

        let pool = try LagoonDatabase.open(path: path)
        defer { try? pool.close() }
        let db = LagoonDB(pool)

        // Run the sealing step again by hand: the condition recurred, and
        // the notice must not be duplicated.
        try db.write { db in
            try DraftCipher.sealLegacyRows(in: db)
        }
        let notices = try await StoreNoticeStore.list(db: db)
        XCTAssertEqual(notices.count, 1, "the notice must be written once")
    }
}

// MARK: - A test-only sealing helper

extension BodyCipher {
    /// Seals with an explicit key, for the "a backup restored with a
    /// different keychain" case.
    static func seal(_ plaintext: String, using key: SymmetricKey) throws -> String {
        let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: key)
        guard let combined = sealed.combined else { throw BodyCipherError.badKey }
        return envelopePrefix + combined.base64EncodedString()
    }
}
