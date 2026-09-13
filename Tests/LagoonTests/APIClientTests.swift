import Foundation
import XCTest
import LagoonKit
@testable import Lagoon

/// Strictly-offline URLProtocol stub. Every request is answered from the
/// per-test handler; nothing ever reaches the network.
final class StubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var _handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    private static var _requests: [URLRequest] = []

    static func setHandler(_ handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?) {
        lock.lock()
        defer { lock.unlock() }
        _handler = handler
        _requests = []
    }

    static var capturedRequests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self._requests.append(request)
        let handler = Self._handler
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class APIClientTests: XCTestCase {
    private let baseURL = URL(string: "http://127.0.0.1:8080")!

    override func setUp() {
        super.setUp()
        StubURLProtocol.setHandler(nil)
    }

    override func tearDown() {
        StubURLProtocol.setHandler(nil)
        super.tearDown()
    }

    private func makeClient() -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return APIClient(baseURL: baseURL, session: session)
    }

    private func stub(status: Int, body: Data) {
        StubURLProtocol.setHandler { request in
            let url = request.url ?? URL(string: "http://127.0.0.1:8080")!
            let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json; charset=utf-8"]
            )!
            return (response, body)
        }
    }

    private func queryValue(_ name: String, in request: URLRequest) -> String? {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        return (components.queryItems ?? []).first { $0.name == name }?.value
    }

    func test_fetchAccounts_returns_empty_for_empty_array() async throws {
        stub(status: 200, body: Data("[]".utf8))

        let accounts = try await makeClient().fetchAccounts()

        XCTAssertEqual(accounts.count, 0)
    }

    func test_fetchAccounts_decodes_one_element() async throws {
        let id = UUID()
        let body = Data(#"""
        [{"id":"\#(id.uuidString)","provider":"qq","email":"a@b.com","isActive":true,
          "syncHealth":{"status":"needsReconnect","lastError":"auth failed"},
          "capabilities":{"archiveFolder":false,"idle":true,"move":true,"serverSnippet":false}}]
        """#.utf8)
        stub(status: 200, body: body)

        let accounts = try await makeClient().fetchAccounts()

        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts.first?.id, id)
        XCTAssertEqual(accounts.first?.provider, .qq)
        XCTAssertEqual(accounts.first?.email, "a@b.com")
        XCTAssertEqual(accounts.first?.isActive, true)
        XCTAssertEqual(accounts.first?.syncHealth.status, .needsReconnect)
        XCTAssertEqual(accounts.first?.capabilities.idle, true)
    }

    func test_fetchAccounts_non2xx_throwsBadStatusWithBodySnippet() async throws {
        stub(status: 502, body: Data("upstream exploded".utf8))

        do {
            _ = try await makeClient().fetchAccounts()
            XCTFail("expected APIError.badStatus")
        } catch APIError.badStatus(let code, let bodySnippet) {
            XCTAssertEqual(code, 502)
            XCTAssertTrue(bodySnippet.contains("upstream exploded"), bodySnippet)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_fetchAccounts_malformedJSON_throws() async throws {
        stub(status: 200, body: Data("{not valid json".utf8))

        do {
            _ = try await makeClient().fetchAccounts()
            XCTFail("expected a decoding error")
        } catch is DecodingError {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_fetchMessages_buildsQueryAndDecodesISO8601SyncResponse() async throws {
        let accountId = UUID()
        let messageId = UUID()
        let receivedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let lastFetchedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let body = Data("""
        {
          "cursor": {
            "accountId": "\(accountId.uuidString)",
            "lastFetchedAt": "\(formatter.string(from: lastFetchedAt))",
            "totalUnread": 2
          },
          "messages": [
            {
              "id": "\(messageId.uuidString)",
              "accountId": "\(accountId.uuidString)",
              "remoteId": "g1",
              "threadId": "t1",
              "fromAddress": "alice@example.com",
              "fromName": "Alice",
              "subject": "Hi",
              "snippet": "Hello",
              "receivedAt": "\(formatter.string(from: receivedAt))",
              "isRead": false,
              "isArchived": false
            }
          ]
        }
        """.utf8)
        stub(status: 200, body: body)

        let response = try await makeClient().fetchMessages(accountId: accountId, limit: 25)

        XCTAssertEqual(response.cursor.accountId, accountId)
        XCTAssertEqual(response.cursor.lastFetchedAt, lastFetchedAt)
        XCTAssertEqual(response.cursor.totalUnread, 2)
        XCTAssertEqual(response.messages.count, 1)
        XCTAssertEqual(response.messages.first?.receivedAt, receivedAt)

        let request = try XCTUnwrap(StubURLProtocol.capturedRequests.first)
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.path, "/api/messages")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = components.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "accountId" }?.value, accountId.uuidString)
        XCTAssertEqual(items.first { $0.name == "limit" }?.value, "25")
    }

    func test_requestSync_postsToTheSyncWakeEndpoint() async throws {
        stub(status: 204, body: Data())

        try await makeClient().requestSync()

        let request = try XCTUnwrap(StubURLProtocol.capturedRequests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/sync")
    }

    // MARK: - M1 APIClient surface

    func test_fetchBriefing_buildsQueryAndDecodesAllFiveGroups() async throws {
        let accountId = UUID()
        let receivedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        func itemJSON(group: BriefingGroup, remoteId: String) -> String {
            """
            {
              "message": {
                "id": "\(UUID().uuidString)",
                "accountId": "\(accountId.uuidString)",
                "remoteId": "\(remoteId)",
                "threadId": "t-\(remoteId)",
                "fromAddress": "alice@example.com",
                "fromName": "Alice",
                "subject": "Subject \(remoteId)",
                "snippet": "Snippet",
                "receivedAt": "\(formatter.string(from: receivedAt))",
                "isRead": false,
                "isArchived": false
              },
              "group": "\(group.rawValue)",
              "reasonCode": "needs-reply"
            }
            """
        }

        let items = BriefingGroup.allCases.enumerated().map { index, group in
            itemJSON(group: group, remoteId: "g\(index)")
        }
        stub(status: 200, body: Data("{\"items\":[\(items.joined(separator: ","))]}".utf8))

        let response = try await makeClient().fetchBriefing(accountId: accountId, limit: 7)

        XCTAssertEqual(response.items.count, 5)
        XCTAssertEqual(Set(response.items.map(\.group)), Set(BriefingGroup.allCases))
        XCTAssertEqual(response.items.first?.message.receivedAt, receivedAt)
        XCTAssertEqual(response.items.first?.reasonCode, "needs-reply")
        XCTAssertEqual(response.items.first?.reason, .needsReply)

        let request = try XCTUnwrap(StubURLProtocol.capturedRequests.first)
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.path, "/api/briefing")
        XCTAssertEqual(request.httpMethod ?? "GET", "GET")
        XCTAssertEqual(queryValue("accountId", in: request), accountId.uuidString)
        XCTAssertEqual(queryValue("limit", in: request), "7")
    }

    func test_fetchBody_percentEncodesGmailIdAndDecodesISO8601ReceivedAt() async throws {
        let accountId = UUID()
        let remoteId = "a/b?c#d e"
        let receivedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let body = Data("""
        {
          "remoteId": "\(remoteId)",
          "subject": "Hello",
          "fromAddress": "alice@example.com",
          "fromName": "Alice",
          "toAddress": "bob@example.com",
          "receivedAt": "\(formatter.string(from: receivedAt))",
          "text": "Plain text body"
        }
        """.utf8)
        stub(status: 200, body: body)

        let messageBody = try await makeClient().fetchBody(remoteId: remoteId, accountId: accountId)

        XCTAssertEqual(messageBody.remoteId, remoteId)
        XCTAssertEqual(messageBody.receivedAt, receivedAt)
        XCTAssertEqual(messageBody.text, "Plain text body")

        let request = try XCTUnwrap(StubURLProtocol.capturedRequests.first)
        let url = try XCTUnwrap(request.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.percentEncodedPath, "/api/messages/a%2Fb%3Fc%23d%20e/body")
        XCTAssertEqual(url.path, "/api/messages/\(remoteId)/body")
        XCTAssertEqual(queryValue("accountId", in: request), accountId.uuidString)
    }

    func test_markRead_postsAndTreats204AsSuccess() async throws {
        let accountId = UUID()
        stub(status: 204, body: Data())

        try await makeClient().markRead(remoteId: "msg-1", accountId: accountId)

        let request = try XCTUnwrap(StubURLProtocol.capturedRequests.first)
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(url.path, "/api/messages/msg-1/read")
        XCTAssertEqual(queryValue("accountId", in: request), accountId.uuidString)
    }

    func test_setPinned_postsAndSendsPinnedQueryForBothValues() async throws {
        let accountId = UUID()
        stub(status: 204, body: Data())

        let client = makeClient()
        try await client.setPinned(remoteId: "msg-1", accountId: accountId, pinned: true)
        try await client.setPinned(remoteId: "msg-1", accountId: accountId, pinned: false)

        let requests = StubURLProtocol.capturedRequests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "POST" })
        XCTAssertEqual(requests.first?.url?.path, "/api/messages/msg-1/pin")
        XCTAssertEqual(queryValue("accountId", in: requests[0]), accountId.uuidString)
        XCTAssertEqual(queryValue("pinned", in: requests[0]), "true")
        XCTAssertEqual(queryValue("pinned", in: requests[1]), "false")
    }

    func test_fetchSummary_buildsURLAndDecodesMessageSummary() async throws {
        let accountId = UUID()
        let body = Data("""
        {
          "remoteId": "msg-1",
          "summary": "Short summary",
          "actionItems": ["Reply", "Archive"],
          "provider": "openai"
        }
        """.utf8)
        stub(status: 200, body: body)

        let summary = try await makeClient().fetchSummary(remoteId: "msg-1", accountId: accountId)

        XCTAssertEqual(summary.remoteId, "msg-1")
        XCTAssertEqual(summary.summary, "Short summary")
        XCTAssertEqual(summary.actionItems, ["Reply", "Archive"])
        XCTAssertEqual(summary.provider, "openai")

        let request = try XCTUnwrap(StubURLProtocol.capturedRequests.first)
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.path, "/api/messages/msg-1/summary")
        XCTAssertEqual(queryValue("accountId", in: request), accountId.uuidString)
    }

    func test_fetchSummary_503_throwsBadStatusWithBodySnippet() async throws {
        let accountId = UUID()
        stub(status: 503, body: Data("no AI provider configured".utf8))

        do {
            _ = try await makeClient().fetchSummary(remoteId: "msg-1", accountId: accountId)
            XCTFail("expected APIError.badStatus(503)")
        } catch APIError.badStatus(let code, let bodySnippet) {
            XCTAssertEqual(code, 503)
            XCTAssertTrue(bodySnippet.contains("no AI provider configured"), bodySnippet)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_oauthStartURL_endsWithOAuthGmailStart() {
        let client = makeClient()
        XCTAssertTrue(
            client.oauthStartURL.absoluteString.hasSuffix("/oauth/gmail/start"),
            client.oauthStartURL.absoluteString
        )
    }

    // MARK: - T9: IMAP connect + account directory

    /// URLSession hands the body to `URLProtocol` as a stream, so body
    /// assertions read whichever form the request carries.
    private func bodyData(of request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    func test_connectQQ_postsJSONBodyAndDecodesConnectedAccount() async throws {
        let id = UUID()
        let body = Data("""
        {"id":"\(id.uuidString)","provider":"qq","email":"me@qq.com","isActive":true,
         "syncHealth":{"status":"ok"},
         "capabilities":{"archiveFolder":true,"idle":true,"move":true,"serverSnippet":true}}
        """.utf8)
        stub(status: 201, body: body)

        let account = try await makeClient().connectQQ(email: "me@qq.com", authCode: "secret-code")

        XCTAssertEqual(account.id, id)
        XCTAssertEqual(account.provider, .qq)
        XCTAssertEqual(account.email, "me@qq.com")
        XCTAssertTrue(account.isActive)
        XCTAssertTrue(account.capabilities.archiveFolder)

        let request = try XCTUnwrap(StubURLProtocol.capturedRequests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/accounts/imap")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let sent = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: bodyData(of: request)) as? [String: String]
        )
        XCTAssertEqual(sent["provider"], "qq")
        XCTAssertEqual(sent["email"], "me@qq.com")
        XCTAssertEqual(sent["authCode"], "secret-code")
    }

    func test_connectQQ_401_throwsBadStatus() async throws {
        stub(status: 401, body: Data("{\"error\":\"imap-auth-failed\"}".utf8))

        do {
            _ = try await makeClient().connectQQ(email: "me@qq.com", authCode: "wrong")
            XCTFail("expected APIError.badStatus(401)")
        } catch APIError.badStatus(let code, _) {
            XCTAssertEqual(code, 401)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Server error-envelope parsing (guards the connect error mapping)

    func test_serverErrorCode_parsesTheSmallErrorEnvelope() {
        let error = APIError.badStatus(code: 409, bodySnippet: #"{"error":"account-exists"}"#)
        XCTAssertEqual(error.serverErrorCode, "account-exists")
    }

    func test_serverErrorCode_isNilWhenTheBodyIsNotTheEnvelope() {
        XCTAssertNil(APIError.badStatus(code: 502, bodySnippet: "upstream exploded").serverErrorCode)
        XCTAssertNil(APIError.badStatus(code: 500, bodySnippet: "").serverErrorCode)
        XCTAssertNil(APIError.badStatus(code: 500, bodySnippet: "(empty body)").serverErrorCode)
        XCTAssertNil(APIError.badStatus(code: 400, bodySnippet: #"{"error":""}"#).serverErrorCode)
        XCTAssertNil(APIError.badStatus(code: 400, bodySnippet: #"{"error":123}"#).serverErrorCode)
        XCTAssertNil(APIError.invalidResponse.serverErrorCode)
    }

    func test_activateAccount_postsToActivateAndTreats204AsSuccess() async throws {
        let id = UUID()
        stub(status: 204, body: Data())

        try await makeClient().activateAccount(id: id)

        let request = try XCTUnwrap(StubURLProtocol.capturedRequests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/accounts/\(id.uuidString)/activate")
    }

    func test_deleteAccount_sendsDeleteAndTreats204AsSuccess() async throws {
        let id = UUID()
        stub(status: 204, body: Data())

        try await makeClient().deleteAccount(id: id)

        let request = try XCTUnwrap(StubURLProtocol.capturedRequests.first)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url?.path, "/api/accounts/\(id.uuidString)")
    }

    func test_deleteAccount_404_throwsBadStatus() async throws {
        let id = UUID()
        stub(status: 404, body: Data("{\"error\":\"unknown-account\"}".utf8))

        do {
            try await makeClient().deleteAccount(id: id)
            XCTFail("expected APIError.badStatus(404)")
        } catch APIError.badStatus(let code, _) {
            XCTAssertEqual(code, 404)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Reply send (T11)

    func test_sendReply_postsBodyAndDecodesProviderMessageId() async throws {
        let accountId = UUID()
        let remoteId = "1234"
        let requestId = UUID().uuidString.lowercased()
        stub(status: 200, body: Data(#"{"ok":true,"providerMessageId":"<smtp-1@qq.com>"}"#.utf8))

        let response = try await makeClient().sendReply(
            remoteId: remoteId,
            accountId: accountId,
            body: "好的，我周五前给答复。",
            requestId: requestId
        )

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.providerMessageId, "<smtp-1@qq.com>")

        let request = try XCTUnwrap(StubURLProtocol.capturedRequests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/messages/1234/send")
        XCTAssertEqual(queryValue("accountId", in: request), accountId.uuidString)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let sent = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: bodyData(of: request)) as? [String: String]
        )
        XCTAssertEqual(sent, [
            "body": "好的，我周五前给答复。",
            "requestId": requestId,
        ])
    }

    func test_sendReply_acceptsNullProviderMessageId() async throws {
        stub(status: 200, body: Data(#"{"ok":true,"providerMessageId":null}"#.utf8))

        let response = try await makeClient().sendReply(
            remoteId: "42",
            accountId: UUID(),
            body: "hi",
            requestId: UUID().uuidString
        )

        XCTAssertTrue(response.ok)
        XCTAssertNil(response.providerMessageId)
    }

    func test_sendReply_401_surfacesSmtpAuthFailureAsBadStatus() async throws {
        stub(status: 401, body: Data("{\"error\":\"smtp-auth-failed\"}".utf8))

        do {
            _ = try await makeClient().sendReply(
                remoteId: "42",
                accountId: UUID(),
                body: "hi",
                requestId: UUID().uuidString
            )
            XCTFail("expected APIError.badStatus(401)")
        } catch APIError.badStatus(let code, let snippet) {
            XCTAssertEqual(code, 401)
            XCTAssertTrue(snippet.contains("smtp-auth-failed"), "snippet: \(snippet)")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_sendNewMessage_postsEnvelopeAndDecodesProviderMessageId() async throws {
        let accountId = UUID()
        let requestId = UUID().uuidString.lowercased()
        stub(status: 200, body: Data(#"{"ok":true,"providerMessageId":"<new-1@qq.com>"}"#.utf8))

        let response = try await makeClient().sendNewMessage(
            to: "alice@example.com",
            subject: "Project kickoff",
            body: "First note",
            accountId: accountId,
            requestId: requestId
        )

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.providerMessageId, "<new-1@qq.com>")
        let request = try XCTUnwrap(StubURLProtocol.capturedRequests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/compose/send")
        XCTAssertEqual(queryValue("accountId", in: request), accountId.uuidString)
        let sent = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: bodyData(of: request)) as? [String: String]
        )
        XCTAssertEqual(sent, [
            "to": "alice@example.com",
            "subject": "Project kickoff",
            "body": "First note",
            "requestId": requestId,
        ])
    }
}
