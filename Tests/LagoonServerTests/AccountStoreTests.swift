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

    /// `reconcileActive` repairs a zero-selected state, but it used to be
    /// three separate transactions: "nobody is active" → "newest account" →
    /// activate it. An activate that committed inside that gap was undone by
    /// the final flip, because the flip used the account list read *before*
    /// the activate — so the user clicked account B and the UI went back to
    /// the previously-newest account C.
    ///
    /// The test holds SQLite's single write lock (the pool serializes writers)
    /// while it activates B, and runs `reconcileActive` alongside. Reconcile's
    /// write can only proceed after B's transaction commits, so a
    /// single-transaction reconcile reads "B is active" and leaves it alone.
    func test_reconcileActive_doesNotRevertAnActivateThatCommittedDuringIt() async throws {
        let oauthA = "acct-\(UUID().uuidString)"
        let oauthB = "acct-\(UUID().uuidString)"
        let oauthC = "acct-\(UUID().uuidString)"
        try await TestDatabase.withConnection(cleanup: { conn in
            try? await TestDatabase.deleteAccount(oauthUser: oauthA, provider: .qq, db: conn)
            try? await TestDatabase.deleteAccount(oauthUser: oauthB, provider: .qq, db: conn)
            try? await TestDatabase.deleteAccount(oauthUser: oauthC, provider: .qq, db: conn)
        }) { conn in
            let a = makeAccount(oauthUser: oauthA, email: "a@example.com")
            let b = makeAccount(oauthUser: oauthB, email: "b@example.com")
            let c = makeAccount(oauthUser: oauthC, email: "c@example.com")
            for account in [a, b, c] {
                try await AccountStore.upsert(account, credentials: Data([1]), db: conn)
            }
            // C is the most recently updated, so a reconcile run right now
            // would pick C. A is oldest, B is the one the user clicks.
            try conn.write { raw in
                try raw.execute(
                    sql: "UPDATE accounts SET updated_at = ? WHERE id = ?",
                    arguments: ["2026-01-01 00:00:00.000", a.id]
                )
                try raw.execute(
                    sql: "UPDATE accounts SET updated_at = ? WHERE id = ?",
                    arguments: ["2026-01-02 00:00:00.000", b.id]
                )
                try raw.execute(
                    sql: "UPDATE accounts SET updated_at = ? WHERE id = ?",
                    arguments: ["2026-01-03 00:00:00.000", c.id]
                )
            }
            let noneActive = try await AccountStore.active(db: conn)
            XCTAssertNil(noneActive, "precondition: no mailbox is selected")

            // The activate holds SQLite's single write lock from its first
            // UPDATE until the test releases it, so reconcile's reads see the
            // pre-activate snapshot and its write can only land afterwards —
            // exactly the interleaving that used to lose the user's choice.
            let lockHeld = DispatchSemaphore(value: 0)
            let mayCommit = DispatchSemaphore(value: 0)
            let activate = Task { () -> Void in
                // `LagoonDB.write` is synchronous: this blocks the calling
                // thread on purpose, holding SQLite's write lock.
                try? conn.write { raw in
                    try raw.execute(sql: "UPDATE accounts SET is_active = FALSE WHERE is_active = TRUE")
                    try raw.execute(
                        sql: "UPDATE accounts SET is_active = TRUE WHERE id = ?",
                        arguments: [b.id]
                    )
                    lockHeld.signal()
                    mayCommit.wait()
                }
            }
            lockHeld.wait()
            let reconcile = Task { try await AccountStore.reconcileActive(db: conn) }
            // Blocking (not `await`ing) so reconcile's reads definitely run
            // before the activate is allowed to commit.
            Thread.sleep(forTimeInterval: 0.3)
            mayCommit.signal()
            try await reconcile.value
            await activate.value

            let active = try await AccountStore.active(db: conn)
            XCTAssertEqual(
                active?.id, b.id,
                "the mailbox the user just selected must survive a concurrent reconcile"
            )
            let actives = try await AccountStore.all(db: conn).filter(\.isActive)
            XCTAssertEqual(actives.count, 1)
        }
    }
}
