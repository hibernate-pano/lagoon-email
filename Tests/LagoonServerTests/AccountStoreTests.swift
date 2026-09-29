import XCTest
import GRDB
@testable import LagoonServer
@testable import LagoonKit

final class AccountStoreTests: XCTestCase {
    private func makeAccount(
        oauthUser: String,
        email: String = "u@example.com",
        lastUid: Int64? = nil
    ) -> Account {
        Account(
            id: UUID(),
            provider: .qq,
            oauthUser: oauthUser,
            email: email,
            credentials: nil,
            syncState: MailSyncState(lastUid: lastUid)
        )
    }

    private func sealedCredentials() throws -> Data {
        try CredentialVault.seal(.imap(
            username: "user-\(UUID().uuidString)",
            authCode: "code-\(UUID().uuidString)"
        ))
    }

    /// Deletes only the account row this test created (by `oauth_user`).
    /// There is deliberately no table-wide delete helper.
    private func cleanup(_ oauthUser: String) -> @Sendable (LagoonDB) async -> Void {
        { conn in
            try? await TestDatabase.deleteAccount(oauthUser: oauthUser, provider: .qq, db: conn)
        }
    }

    func test_upsert_then_find_roundtrip() async throws {
        let oauthUser = "acct-\(UUID().uuidString)"
        try await TestDatabase.withConnection(cleanup: cleanup(oauthUser)) { conn in
            let a = makeAccount(oauthUser: oauthUser)
            try await AccountStore.upsert(
                a,
                credentials: Data([1, 2, 3]),
                db: conn
            )
            let back = try await AccountStore.find(
                byOAuthUser: oauthUser,
                provider: .qq,
                db: conn
            )
            XCTAssertEqual(back?.id, a.id)
            XCTAssertEqual(back?.email, a.email)
            XCTAssertEqual(back?.provider, .qq)
            XCTAssertEqual(back?.credentials, Data([1, 2, 3]))
        }
    }

    func test_updateCredentials_readsBackThroughVault() async throws {
        let oauthUser = "acct-\(UUID().uuidString)"
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            try await TestDatabase.withConnection(cleanup: cleanup(oauthUser)) { conn in
                let a = makeAccount(oauthUser: oauthUser)
                try await AccountStore.upsert(
                    a,
                    credentials: try sealedCredentials(),
                    db: conn
                )

                let newUser = "user-\(UUID().uuidString)"
                let newCode = "code-\(UUID().uuidString)"
                try await AccountStore.updateCredentials(
                    accountId: a.id,
                    credentials: try CredentialVault.seal(.imap(
                        username: newUser, authCode: newCode
                    )),
                    db: conn
                )

                let stored = try await CredentialVault.read(accountId: a.id, db: conn)
                guard case .imap(let username, let authCode) = stored else {
                    return XCTFail("expected imap credentials after updateCredentials")
                }
                XCTAssertEqual(username, newUser)
                XCTAssertEqual(authCode, newCode)
            }
        }
    }

    /// Re-connecting an existing (provider, oauth_user) refreshes email and
    /// credentials but must never clobber the sync cursor or the active flag.
    func test_upsert_existingAccount_keepsCursorAndActiveFlag() async throws {
        let oauthUser = "acct-\(UUID().uuidString)"
        try await TestDatabase.withConnection(cleanup: cleanup(oauthUser)) { conn in
            let first = makeAccount(oauthUser: oauthUser, email: "first@example.com", lastUid: 42)
            try await AccountStore.upsert(first, credentials: Data([1]), db: conn)
            // The active choice survives a credential refresh: `upsert`'s
            // ON CONFLICT branch only touches email/credentials.
            try await AccountStore.setActive(accountId: first.id, db: conn)

            let second = makeAccount(oauthUser: oauthUser, email: "second@example.com", lastUid: nil)
            try await AccountStore.upsert(second, credentials: Data([2]), db: conn)

            let found = try await AccountStore.find(byOAuthUser: oauthUser, provider: .qq, db: conn)
            XCTAssertEqual(found?.id, first.id, "same (provider, oauth_user) must reuse the row")
            XCTAssertEqual(found?.email, "second@example.com")
            XCTAssertEqual(found?.credentials, Data([2]))
            XCTAssertEqual(found?.syncState.lastUid, 42, "re-connect must not reset the cursor")
            XCTAssertEqual(found?.isActive, true, "re-connect must not clear the active flag")
        }
    }

    /// Selecting one account moves the single active marker and leaves the
    /// other stored mailbox dormant.
    func test_setActive_isExclusive() async throws {
        let oauthA = "acct-\(UUID().uuidString)"
        let oauthB = "acct-\(UUID().uuidString)"
        try await TestDatabase.withConnection(cleanup: { conn in
            try? await TestDatabase.deleteAccount(oauthUser: oauthA, provider: .qq, db: conn)
            try? await TestDatabase.deleteAccount(oauthUser: oauthB, provider: .qq, db: conn)
        }) { conn in
            let a = makeAccount(oauthUser: oauthA, email: "a-\(UUID().uuidString)@example.com")
            let b = makeAccount(oauthUser: oauthB, email: "b-\(UUID().uuidString)@example.com")
            try await AccountStore.upsert(a, credentials: Data([1]), db: conn)
            try await AccountStore.upsert(b, credentials: Data([1]), db: conn)

            try await AccountStore.setActive(accountId: a.id, db: conn)
            var active = try await AccountStore.active(db: conn)
            XCTAssertEqual(active?.id, a.id)
            var dormant = try await AccountStore.find(byId: b.id, db: conn)
            XCTAssertEqual(dormant?.isActive, false)

            try await AccountStore.setActive(accountId: b.id, db: conn)
            active = try await AccountStore.active(db: conn)
            XCTAssertEqual(active?.id, b.id)
            dormant = try await AccountStore.find(byId: a.id, db: conn)
            XCTAssertEqual(dormant?.isActive, false)
        }
    }

    func test_all_returnsInsertedRows() async throws {
        let oauthA = "acct-\(UUID().uuidString)"
        let oauthB = "acct-\(UUID().uuidString)"
        try await TestDatabase.withConnection(cleanup: { conn in
            try? await TestDatabase.deleteAccount(oauthUser: oauthA, provider: .qq, db: conn)
            try? await TestDatabase.deleteAccount(oauthUser: oauthB, provider: .qq, db: conn)
        }) { conn in
            let a = makeAccount(oauthUser: oauthA, email: "a-\(UUID().uuidString)@example.com")
            let b = makeAccount(oauthUser: oauthB, email: "b-\(UUID().uuidString)@example.com")
            try await AccountStore.upsert(a, credentials: Data([1]), db: conn)
            try await AccountStore.upsert(b, credentials: Data([1]), db: conn)

            let all = try await AccountStore.all(db: conn)
            let ids = Set(all.map(\.id))
            XCTAssertTrue(ids.contains(a.id), "AccountStore.all must include inserted account A")
            XCTAssertTrue(ids.contains(b.id), "AccountStore.all must include inserted account B")
        }
    }
}
