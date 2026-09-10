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
        let body = Data(#"[{"id":"\#(id.uuidString)","provider":"gmail","email":"a@b.com"}]"#.utf8)
        stub(status: 200, body: body)

        let accounts = try await makeClient().fetchAccounts()

        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts.first?.id, id)
        XCTAssertEqual(accounts.first?.provider, .gmail)
        XCTAssertEqual(accounts.first?.email, "a@b.com")
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
              "gmailId": "g1",
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

    // MARK: - M1 APIClient surface

    func test_fetchBriefing_buildsQueryAndDecodesAllFiveGroups() async throws {
        let accountId = UUID()
        let receivedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        func itemJSON(group: BriefingGroup, gmailId: String) -> String {
            """
            {
              "message": {
                "id": "\(UUID().uuidString)",
                "accountId": "\(accountId.uuidString)",
                "gmailId": "\(gmailId)",
                "threadId": "t-\(gmailId)",
                "fromAddress": "alice@example.com",
                "fromName": "Alice",
                "subject": "Subject \(gmailId)",
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
            itemJSON(group: group, gmailId: "g\(index)")
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
        let gmailId = "a/b?c#d e"
        let receivedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let body = Data("""
        {
          "gmailId": "\(gmailId)",
          "subject": "Hello",
          "fromAddress": "alice@example.com",
          "fromName": "Alice",
          "toAddress": "bob@example.com",
          "receivedAt": "\(formatter.string(from: receivedAt))",
          "text": "Plain text body"
        }
        """.utf8)
        stub(status: 200, body: body)

        let messageBody = try await makeClient().fetchBody(gmailId: gmailId, accountId: accountId)

        XCTAssertEqual(messageBody.gmailId, gmailId)
        XCTAssertEqual(messageBody.receivedAt, receivedAt)
        XCTAssertEqual(messageBody.text, "Plain text body")

        let request = try XCTUnwrap(StubURLProtocol.capturedRequests.first)
        let url = try XCTUnwrap(request.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.percentEncodedPath, "/api/messages/a%2Fb%3Fc%23d%20e/body")
        XCTAssertEqual(url.path, "/api/messages/\(gmailId)/body")
        XCTAssertEqual(queryValue("accountId", in: request), accountId.uuidString)
    }

    func test_markRead_postsAndTreats204AsSuccess() async throws {
        let accountId = UUID()
        stub(status: 204, body: Data())

        try await makeClient().markRead(gmailId: "msg-1", accountId: accountId)

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
        try await client.setPinned(gmailId: "msg-1", accountId: accountId, pinned: true)
        try await client.setPinned(gmailId: "msg-1", accountId: accountId, pinned: false)

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
          "gmailId": "msg-1",
          "summary": "Short summary",
          "actionItems": ["Reply", "Archive"],
          "provider": "openai"
        }
        """.utf8)
        stub(status: 200, body: body)

        let summary = try await makeClient().fetchSummary(gmailId: "msg-1", accountId: accountId)

        XCTAssertEqual(summary.gmailId, "msg-1")
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
            _ = try await makeClient().fetchSummary(gmailId: "msg-1", accountId: accountId)
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
}
