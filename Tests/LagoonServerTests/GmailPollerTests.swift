import XCTest
import Foundation
import Logging
import PostgresNIO
@testable import LagoonServer
@testable import LagoonKit

/// Drives the real `GmailPoller.tick()` against the guarded test DB with
/// URLProtocol-stubbed `GmailClient` / `GoogleOAuthClient` sessions. No network.
///
/// `tick()` polls *every* account row, so assertions filter the captured
/// requests by this test's unique access/refresh tokens; other rows (if any
/// survive from a crashed run) cannot inflate the counts.
final class GmailPollerTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    // MARK: - Stub plumbing

    private static let emptyListBody = Data(#"{"messages":[]}"#.utf8)

    /// `users.messages.list` response for the given ids.
    private static func listBody(ids: [String]) -> Data {
        let messages = ids.map { ["id": $0, "threadId": "thread-\($0)"] }
        return (try? JSONSerialization.data(withJSONObject: ["messages": messages]))
            ?? Data("{}".utf8)
    }

    /// `users.messages.get?format=metadata` response.
    private static func metadataBody(
        remoteId: String,
        from: String,
        subject: String,
        unread: Bool,
        listUnsubscribe: Bool
    ) -> Data {
        var headers: [[String: String]] = [
            ["name": "From", "value": from],
            ["name": "Subject", "value": subject],
        ]
        if listUnsubscribe {
            headers.append(["name": "List-Unsubscribe", "value": "<mailto:unsub@example.com>"])
        }
        var message: [String: Any] = [
            "id": remoteId,
            "threadId": "thread-\(remoteId)",
            "snippet": "snippet \(remoteId)",
            "internalDate": "1700000000000",
            "payload": ["headers": headers],
        ]
        if unread { message["labelIds"] = ["UNREAD"] }
        return (try? JSONSerialization.data(withJSONObject: message)) ?? Data("{}".utf8)
    }

    private static func http(_ url: URL, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: config)
    }

    /// Answers the OAuth token endpoint with `tokenBody` and the Gmail list
    /// endpoint with an empty page. Access tokens in `rejectAccessTokens` get a
    /// 401 (simulating early revocation).
    private func installStub(
        tokenBody: Data,
        rejectAccessTokens: Set<String> = [],
        listBody: Data = GmailPollerTests.emptyListBody,
        metadata: [String: Data] = [:]
    ) {
        URLProtocolStub.install { request in
            let url = request.url!
            if url.host == "oauth2.googleapis.com" {
                return (Self.http(url, 200), tokenBody)
            }
            if url.host == "gmail.googleapis.com" {
                let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
                if rejectAccessTokens.contains(auth) {
                    return (Self.http(url, 401), Data("{}".utf8))
                }
                if url.path.hasSuffix("/messages") {
                    return (Self.http(url, 200), listBody)
                }
                if let id = url.path.split(separator: "/").last,
                   let body = metadata[String(id)] {
                    return (Self.http(url, 200), body)
                }
                return (Self.http(url, 404), Data())
            }
            return (Self.http(url, 404), Data())
        }
    }

    private func makePoller(db: PostgresConnection) -> GmailPoller {
        let session = makeSession()
        return GmailPoller(
            db: db,
            client: GmailClient(session: session),
            oauth: GoogleOAuthClient(
                clientID: "test-client",
                clientSecret: "test-secret",
                redirectURI: "http://127.0.0.1:9999/callback",
                session: session
            ),
            logger: Logger(label: "gmail-poller-tests")
        )
    }

    private func tokenBody(
        accessToken: String,
        refreshToken: String? = nil,
        expiresIn: Int = 3600
    ) -> Data {
        var obj: [String: Any] = [
            "access_token": accessToken,
            "expires_in": expiresIn,
            "scope": "https://www.googleapis.com/auth/gmail.readonly",
            "token_type": "Bearer"
        ]
        if let refreshToken { obj["refresh_token"] = refreshToken }
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    // MARK: - Account plumbing

    private func makeAccount(oauthUser: String) -> Account {
        Account(
            id: UUID(),
            provider: .gmail,
            oauthUser: oauthUser,
            email: "\(oauthUser)@example.com",
            credentials: nil
        )
    }

    private func seed(
        _ account: Account,
        accessToken: String,
        refreshToken: String,
        expiresAt: Date,
        db: PostgresConnection
    ) async throws {
        try await AccountStore.upsert(
            account,
            credentials: try CredentialVault.seal(.gmail(
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresAt: expiresAt
            )),
            db: db
        )
    }

    /// Decrypted Gmail credentials for assertions (fails the test on mismatch).
    private func gmailTokens(
        _ accountId: UUID,
        db: PostgresConnection
    ) async throws -> (accessToken: String, refreshToken: String, expiresAt: Date) {
        let credentials = try await CredentialVault.read(accountId: accountId, db: db)
        guard case .gmail(let accessToken, let refreshToken, let expiresAt) = credentials else {
            XCTFail("expected gmail credentials for this account")
            throw GmailTokenError.notGmailAccount
        }
        return (accessToken, refreshToken, expiresAt)
    }

    private func cleanup(_ oauthUser: String) -> @Sendable (PostgresConnection) async -> Void {
        { conn in
            try? await TestDatabase.deleteAccount(oauthUser: oauthUser, provider: .gmail, db: conn)
        }
    }

    // MARK: - Captured-request filters

    private func refreshRequests(forRefreshToken token: String) -> [URLProtocolStub.CapturedRequest] {
        URLProtocolStub.capturedRequests.filter { captured in
            guard captured.request.url?.host == "oauth2.googleapis.com" else { return false }
            guard captured.request.httpMethod == "POST" else { return false }
            let body = captured.body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return body.contains("grant_type=refresh_token")
                && body.contains("refresh_token=\(token)")
        }
    }

    private func listRequests(
        accessTokens: Set<String>
    ) -> [URLProtocolStub.CapturedRequest] {
        URLProtocolStub.capturedRequests.filter { captured in
            guard captured.request.url?.host == "gmail.googleapis.com" else { return false }
            guard captured.request.url?.path.hasSuffix("/messages") == true else { return false }
            let auth = captured.request.value(forHTTPHeaderField: "Authorization") ?? ""
            return accessTokens.contains(auth)
        }
    }

    // MARK: - Tests

    /// (a) expired token -> exactly one refresh POST, new access token + expiry persisted.
    func test_expiredToken_refreshesOnceAndPersistsNewAccessTokenAndExpiry() async throws {
        let oauthUser = "poller-\(UUID().uuidString)"
        let oldAccess = "old-access-\(UUID().uuidString)"
        let oldRefresh = "rt-original-\(UUID().uuidString)"
        let newAccess = "new-access-\(UUID().uuidString)"
        let newRefresh = "rt-rotated-\(UUID().uuidString)"

        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            try await TestDatabase.withConnection(cleanup: cleanup(oauthUser)) { conn in
                let account = makeAccount(oauthUser: oauthUser)
                try await seed(
                    account,
                    accessToken: oldAccess,
                    refreshToken: oldRefresh,
                    expiresAt: Date().addingTimeInterval(-3600),
                    db: conn
                )
                installStub(tokenBody: tokenBody(accessToken: newAccess, refreshToken: newRefresh))

                await makePoller(db: conn).tick()

                XCTAssertEqual(
                    refreshRequests(forRefreshToken: oldRefresh).count, 1,
                    "an expired token must trigger exactly one refresh POST"
                )
                XCTAssertEqual(
                    listRequests(accessTokens: ["Bearer \(newAccess)"]).count, 1,
                    "the sync must use the freshly refreshed access token"
                )

                let stored = try await gmailTokens(account.id, db: conn)
                XCTAssertEqual(stored.accessToken, newAccess)
                XCTAssertEqual(stored.refreshToken, newRefresh)
                XCTAssertEqual(
                    stored.expiresAt.timeIntervalSinceNow, 3600, accuracy: 60,
                    "persisted expiry must be derived from expires_in"
                )
            }
        }
    }

    /// (b) a 401 from Gmail triggers exactly one refresh + exactly one retry.
    func test_unauthorized_refreshesOnceAndRetriesSameAccountOnce() async throws {
        let oauthUser = "poller-\(UUID().uuidString)"
        let oldAccess = "old-access-\(UUID().uuidString)"
        let oldRefresh = "rt-original-\(UUID().uuidString)"
        let newAccess = "new-access-\(UUID().uuidString)"
        let newRefresh = "rt-rotated-\(UUID().uuidString)"

        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            try await TestDatabase.withConnection(cleanup: cleanup(oauthUser)) { conn in
                // Still valid: the proactive path must NOT run, so the 401 is
                // the only reason to refresh.
                let account = makeAccount(oauthUser: oauthUser)
                try await seed(
                    account,
                    accessToken: oldAccess,
                    refreshToken: oldRefresh,
                    expiresAt: Date().addingTimeInterval(3600),
                    db: conn
                )
                installStub(
                    tokenBody: tokenBody(accessToken: newAccess, refreshToken: newRefresh),
                    rejectAccessTokens: ["Bearer \(oldAccess)"]
                )

                await makePoller(db: conn).tick()

                XCTAssertEqual(
                    refreshRequests(forRefreshToken: oldRefresh).count, 1,
                    "a genuine 401 must trigger exactly one refresh"
                )
                let attempts = listRequests(
                    accessTokens: ["Bearer \(oldAccess)", "Bearer \(newAccess)"]
                )
                XCTAssertEqual(attempts.count, 2, "one initial attempt + exactly one retry")
                XCTAssertEqual(
                    attempts.first?.request.value(forHTTPHeaderField: "Authorization"),
                    "Bearer \(oldAccess)",
                    "first attempt uses the stored token"
                )
                XCTAssertEqual(
                    attempts.last?.request.value(forHTTPHeaderField: "Authorization"),
                    "Bearer \(newAccess)",
                    "the single retry uses the refreshed token"
                )

                let stored = try await gmailTokens(account.id, db: conn)
                XCTAssertEqual(stored.accessToken, newAccess)
            }
        }
    }

    /// (c) refresh response omitting refresh_token must not drop the stored one.
    func test_refreshWithoutRefreshToken_keepsStoredRefreshToken() async throws {
        let oauthUser = "poller-\(UUID().uuidString)"
        let oldAccess = "old-access-\(UUID().uuidString)"
        let oldRefresh = "rt-original-\(UUID().uuidString)"
        let newAccess = "new-access-\(UUID().uuidString)"

        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            try await TestDatabase.withConnection(cleanup: cleanup(oauthUser)) { conn in
                let account = makeAccount(oauthUser: oauthUser)
                try await seed(
                    account,
                    accessToken: oldAccess,
                    refreshToken: oldRefresh,
                    expiresAt: Date().addingTimeInterval(-3600),
                    db: conn
                )
                // Google omits refresh_token on refresh grants.
                installStub(tokenBody: tokenBody(accessToken: newAccess))

                await makePoller(db: conn).tick()

                XCTAssertEqual(refreshRequests(forRefreshToken: oldRefresh).count, 1)
                let stored = try await gmailTokens(account.id, db: conn)
                XCTAssertEqual(stored.accessToken, newAccess)
                XCTAssertEqual(
                    stored.refreshToken, oldRefresh,
                    "refresh response omitted refresh_token; the stored one must survive"
                )
            }
        }
    }

    /// (d) a still-valid token triggers zero refresh POSTs.
    func test_validToken_triggersZeroRefreshes() async throws {
        let oauthUser = "poller-\(UUID().uuidString)"
        let oldAccess = "old-access-\(UUID().uuidString)"
        let oldRefresh = "rt-original-\(UUID().uuidString)"
        let newAccess = "new-access-\(UUID().uuidString)"

        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            try await TestDatabase.withConnection(cleanup: cleanup(oauthUser)) { conn in
                let account = makeAccount(oauthUser: oauthUser)
                try await seed(
                    account,
                    accessToken: oldAccess,
                    refreshToken: oldRefresh,
                    expiresAt: Date().addingTimeInterval(3600),
                    db: conn
                )
                installStub(tokenBody: tokenBody(accessToken: newAccess))

                await makePoller(db: conn).tick()

                XCTAssertEqual(
                    refreshRequests(forRefreshToken: oldRefresh).count, 0,
                    "a valid token must not be refreshed"
                )
                XCTAssertEqual(
                    listRequests(accessTokens: ["Bearer \(oldAccess)"]).count, 1,
                    "the stored access token is used directly"
                )
            }
        }
    }

    /// (N5) proactive expiry refresh followed by a 401 must not refresh twice.
    func test_proactiveRefreshThenUnauthorized_doesNotRefreshASecondTime() async throws {
        let oauthUser = "poller-\(UUID().uuidString)"
        let oldAccess = "old-access-\(UUID().uuidString)"
        let oldRefresh = "rt-original-\(UUID().uuidString)"
        let newAccess = "new-access-\(UUID().uuidString)"
        let newRefresh = "rt-rotated-\(UUID().uuidString)"

        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            try await TestDatabase.withConnection(cleanup: cleanup(oauthUser)) { conn in
                let account = makeAccount(oauthUser: oauthUser)
                try await seed(
                    account,
                    accessToken: oldAccess,
                    refreshToken: oldRefresh,
                    expiresAt: Date().addingTimeInterval(-3600),
                    db: conn
                )
                // Proactive refresh succeeds but the new token is still 401'd.
                installStub(
                    tokenBody: tokenBody(accessToken: newAccess, refreshToken: newRefresh),
                    rejectAccessTokens: ["Bearer \(newAccess)"]
                )

                await makePoller(db: conn).tick()

                XCTAssertEqual(
                    refreshRequests(forRefreshToken: oldRefresh).count, 1,
                    "exactly one proactive refresh"
                )
                XCTAssertEqual(
                    refreshRequests(forRefreshToken: newRefresh).count, 0,
                    "the 401 path must not issue a second refresh in the same tick"
                )
                XCTAssertEqual(
                    listRequests(accessTokens: ["Bearer \(newAccess)"]).count, 1,
                    "no retry after a proactive refresh"
                )
            }
        }
    }

    /// (e) a non-empty page is fetched in bounded concurrent batches and every
    /// message is persisted with headers, read state and the List-Unsubscribe
    /// signal intact. Covers the concurrent fetch path added to syncMessages.
    func test_listWithMessages_persistsEveryHeader() async throws {
        let oauthUser = "poller-\(UUID().uuidString)"
        let access = "access-\(UUID().uuidString)"
        let refresh = "rt-\(UUID().uuidString)"
        let ids = (0..<12).map { "msg-\($0)-\(UUID().uuidString)" }

        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            try await TestDatabase.withConnection(cleanup: cleanup(oauthUser)) { conn in
                let account = makeAccount(oauthUser: oauthUser)
                try await seed(
                    account,
                    accessToken: access,
                    refreshToken: refresh,
                    expiresAt: Date().addingTimeInterval(3600),
                    db: conn
                )

                var metadata: [String: Data] = [:]
                for (index, id) in ids.enumerated() {
                    metadata[id] = Self.metadataBody(
                        remoteId: id,
                        from: "Sender \(index) <sender\(index)@example.com>",
                        subject: "Subject \(index)",
                        unread: index.isMultiple(of: 2),
                        listUnsubscribe: index.isMultiple(of: 3)
                    )
                }
                installStub(
                    tokenBody: tokenBody(accessToken: access),
                    listBody: Self.listBody(ids: ids),
                    metadata: metadata
                )

                await makePoller(db: conn).tick()

                let stored = try await MessageStore.recent(
                    forAccount: account.id,
                    limit: 50,
                    db: conn
                )
                XCTAssertEqual(stored.count, ids.count, "every listed message must be stored")
                XCTAssertEqual(Set(stored.map(\.remoteId)), Set(ids))

                for index in 0..<ids.count {
                    let row = stored.first { $0.remoteId == ids[index] }
                    XCTAssertEqual(row?.fromAddress, "sender\(index)@example.com")
                    XCTAssertEqual(row?.fromName, "Sender \(index)")
                    XCTAssertEqual(row?.subject, "Subject \(index)")
                    XCTAssertEqual(
                        row?.isRead, !index.isMultiple(of: 2),
                        "the UNREAD label must drive is_read"
                    )
                }

                let withUnsubscribe = try await MessageStore.listUnsubscribeIds(
                    forAccount: account.id,
                    db: conn
                )
                let expected = Set(
                    ids.enumerated()
                        .filter { $0.offset.isMultiple(of: 3) }
                        .map(\.element)
                )
                XCTAssertEqual(withUnsubscribe, expected)
                XCTAssertEqual(
                    listRequests(accessTokens: ["Bearer \(access)"]).count, 1,
                    "exactly one list call per tick"
                )
            }
        }
    }
}
