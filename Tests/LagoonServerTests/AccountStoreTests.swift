import XCTest
import PostgresNIO
@testable import LagoonServer
@testable import LagoonKit

final class AccountStoreTests: XCTestCase {
    private func makeAccount(
        oauthUser: String,
        email: String = "u@example.com",
        historyId: String? = nil
    ) -> Account {
        Account(
            id: UUID(),
            provider: .gmail,
            oauthUser: oauthUser,
            email: email,
            tokenExpiresAt: Date(),
            historyId: historyId
        )
    }

    /// Deletes only the account row this test created (by `oauth_user`).
    /// There is deliberately no table-wide delete helper.
    private func cleanup(_ oauthUser: String) -> @Sendable (PostgresConnection) async -> Void {
        { conn in
            try? await TestDatabase.deleteAccount(oauthUser: oauthUser, provider: .gmail, db: conn)
        }
    }

    func test_upsert_then_find_roundtrip() async throws {
        let oauthUser = "acct-\(UUID().uuidString)"
        try await TestDatabase.withConnection(cleanup: cleanup(oauthUser)) { conn in
            let a = makeAccount(oauthUser: oauthUser)
            try await AccountStore.upsert(
                a,
                accessToken: Data([1, 2, 3]),
                refreshToken: Data([4, 5, 6]),
                db: conn
            )
            let back = try await AccountStore.find(
                byOAuthUser: oauthUser,
                provider: .gmail,
                db: conn
            )
            XCTAssertEqual(back?.id, a.id)
            XCTAssertEqual(back?.email, a.email)
        }
    }

    func test_updateTokens_readsBackThroughCipher() async throws {
        let oauthUser = "acct-\(UUID().uuidString)"
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            try await TestDatabase.withConnection(cleanup: cleanup(oauthUser)) { conn in
                let a = makeAccount(oauthUser: oauthUser)
                try await AccountStore.upsert(
                    a,
                    accessToken: Data([9]),
                    refreshToken: Data([9]),
                    db: conn
                )

                let newAccess = "access-\(UUID().uuidString)"
                let newRefresh = "refresh-\(UUID().uuidString)"
                let expiry = Date().addingTimeInterval(3600)
                try await AccountStore.updateTokens(
                    accountId: a.id,
                    accessTokenCiphertext: try AccessTokenCipher.seal(newAccess),
                    refreshTokenCiphertext: try AccessTokenCipher.seal(newRefresh),
                    expiresAt: expiry,
                    db: conn
                )

                let stored = try await AccessTokenCipher.read(accountId: a.id, db: conn)
                XCTAssertEqual(stored.accessToken, newAccess)
                XCTAssertEqual(stored.refreshToken, newRefresh)
                XCTAssertEqual(
                    stored.expiresAt.timeIntervalSince1970,
                    expiry.timeIntervalSince1970,
                    accuracy: 0.001
                )
            }
        }
    }

    func test_upsert_nilHistoryId_preservesExisting_andNonNilOverwrites() async throws {
        let oauthUser = "acct-\(UUID().uuidString)"
        try await TestDatabase.withConnection(cleanup: cleanup(oauthUser)) { conn in
            let first = makeAccount(oauthUser: oauthUser, email: "first@example.com", historyId: "h1")
            try await AccountStore.upsert(
                first,
                accessToken: Data([1]),
                refreshToken: Data([1]),
                db: conn
            )

            // Re-upsert with historyId nil: must NOT clobber the stored cursor.
            let second = makeAccount(oauthUser: oauthUser, email: "second@example.com", historyId: nil)
            try await AccountStore.upsert(
                second,
                accessToken: Data([2]),
                refreshToken: Data([2]),
                db: conn
            )
            var found = try await AccountStore.find(byOAuthUser: oauthUser, provider: .gmail, db: conn)
            XCTAssertEqual(found?.historyId, "h1")
            XCTAssertEqual(found?.email, "second@example.com")

            // A non-nil historyId overwrites.
            let third = makeAccount(oauthUser: oauthUser, email: "third@example.com", historyId: "h2")
            try await AccountStore.upsert(
                third,
                accessToken: Data([3]),
                refreshToken: Data([3]),
                db: conn
            )
            found = try await AccountStore.find(byOAuthUser: oauthUser, provider: .gmail, db: conn)
            XCTAssertEqual(found?.historyId, "h2")
            XCTAssertEqual(found?.email, "third@example.com")
        }
    }

    func test_all_returnsInsertedRows() async throws {
        let oauthA = "acct-\(UUID().uuidString)"
        let oauthB = "acct-\(UUID().uuidString)"
        try await TestDatabase.withConnection(cleanup: { conn in
            try? await TestDatabase.deleteAccount(oauthUser: oauthA, provider: .gmail, db: conn)
            try? await TestDatabase.deleteAccount(oauthUser: oauthB, provider: .gmail, db: conn)
        }) { conn in
            let a = makeAccount(oauthUser: oauthA, email: "a-\(UUID().uuidString)@example.com")
            let b = makeAccount(oauthUser: oauthB, email: "b-\(UUID().uuidString)@example.com")
            try await AccountStore.upsert(a, accessToken: Data([1]), refreshToken: Data([1]), db: conn)
            try await AccountStore.upsert(b, accessToken: Data([1]), refreshToken: Data([1]), db: conn)

            let all = try await AccountStore.all(db: conn)
            let ids = Set(all.map(\.id))
            XCTAssertTrue(ids.contains(a.id), "AccountStore.all must include inserted account A")
            XCTAssertTrue(ids.contains(b.id), "AccountStore.all must include inserted account B")
        }
    }
}
