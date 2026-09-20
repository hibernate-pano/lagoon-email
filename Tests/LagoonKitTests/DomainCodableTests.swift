import XCTest
@testable import LagoonKit

/// Wire-format tests.
///
/// The server encodes dates with `.iso8601` (SyncRoutes.swift:24-25) and the
/// client decodes with `.iso8601` (APIClient.swift), so these tests use the
/// same strategies. Round-tripping with the default (numeric) date strategy
/// would pass while the real wire format silently broke.
final class DomainCodableTests: XCTestCase {
    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func test_account_roundtrip() throws {
        let a = Account(
            id: UUID(),
            provider: .gmail,
            oauthUser: "u",
            email: "u@example.com",
            credentials: Data([0x01, 0x02]),
            syncState: MailSyncState(historyId: "h1"),
            capabilities: MailCapabilities(archiveFolder: true, idle: true, move: true, serverSnippet: true),
            isActive: true,
            syncHealth: SyncHealth(status: .ok)
        )
        let data = try makeEncoder().encode(a)
        let back = try makeDecoder().decode(Account.self, from: data)
        XCTAssertEqual(a, back)
    }

    func test_message_header_roundtrip() throws {
        let m = MessageHeader(
            id: UUID(),
            accountId: UUID(),
            remoteId: "abc",
            threadId: "t1",
            fromAddress: "alice@example.com",
            fromName: "Alice",
            subject: "Hi",
            snippet: "Hello...",
            receivedAt: Date(timeIntervalSince1970: 2000),
            isRead: false,
            isArchived: false
        )
        let data = try makeEncoder().encode(m)
        let back = try makeDecoder().decode(MessageHeader.self, from: data)
        XCTAssertEqual(m, back)
    }

    func test_sync_response_roundtrip_preserves_whole_second_dates() throws {
        let accountId = UUID()
        // `.iso8601` truncates sub-second precision, so use whole-second dates
        // (what the server produces from `Date()` is not guaranteed to be
        // whole-second, but the wire contract is second-granular).
        let receivedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let lastFetchedAt = Date(timeIntervalSince1970: 1_700_000_500)
        let message = MessageHeader(
            id: UUID(),
            accountId: accountId,
            remoteId: "g1",
            threadId: "t1",
            fromAddress: "alice@example.com",
            fromName: "Alice",
            subject: "Hi",
            snippet: "Hello",
            receivedAt: receivedAt,
            isRead: false,
            isArchived: false
        )
        let response = SyncResponse(
            cursor: SyncCursor(accountId: accountId, lastFetchedAt: lastFetchedAt, totalUnread: 3),
            messages: [message]
        )

        let data = try makeEncoder().encode(response)
        let back = try makeDecoder().decode(SyncResponse.self, from: data)

        XCTAssertEqual(back, response)
        XCTAssertEqual(back.cursor.lastFetchedAt, lastFetchedAt)
        XCTAssertEqual(back.messages.first?.receivedAt, receivedAt)
    }

    func test_encoded_dates_are_iso8601_strings_not_numbers() throws {
        let accountId = UUID()
        let response = SyncResponse(
            cursor: SyncCursor(
                accountId: accountId,
                lastFetchedAt: Date(timeIntervalSince1970: 1_700_000_500),
                totalUnread: 0
            ),
            messages: [
                MessageHeader(
                    id: UUID(),
                    accountId: accountId,
                    remoteId: "g2",
                    threadId: "t2",
                    fromAddress: "bob@example.com",
                    fromName: nil,
                    subject: nil,
                    snippet: nil,
                    receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    isRead: true,
                    isArchived: false
                )
            ]
        )

        let data = try makeEncoder().encode(response)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        let cursor = try XCTUnwrap(object["cursor"] as? [String: Any])
        let lastFetchedAt = try XCTUnwrap(cursor["lastFetchedAt"] as? String)
        XCTAssertTrue(lastFetchedAt.contains("T"), "expected an ISO8601 date, got \(lastFetchedAt)")
        XCTAssertTrue(lastFetchedAt.hasSuffix("Z"), "expected a UTC ISO8601 date, got \(lastFetchedAt)")

        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        let receivedAt = try XCTUnwrap(messages.first?["receivedAt"] as? String)
        XCTAssertTrue(receivedAt.contains("T"), "expected an ISO8601 date, got \(receivedAt)")
        XCTAssertTrue(receivedAt.hasSuffix("Z"), "expected a UTC ISO8601 date, got \(receivedAt)")
    }

    func test_message_header_nil_optional_fields_roundtrip() throws {
        let message = MessageHeader(
            id: UUID(),
            accountId: UUID(),
            remoteId: "g3",
            threadId: "t3",
            fromAddress: "carol@example.com",
            fromName: nil,
            subject: nil,
            snippet: nil,
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
            isRead: false,
            isArchived: false
        )

        let data = try makeEncoder().encode(message)
        let back = try makeDecoder().decode(MessageHeader.self, from: data)

        XCTAssertNil(back.fromName)
        XCTAssertNil(back.subject)
        XCTAssertNil(back.snippet)
        XCTAssertEqual(back, message)
    }

    func test_message_header_decodes_missing_optional_keys() throws {
        // Real server payloads omit absent optional keys entirely; decoding must
        // treat a missing key the same as nil.
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "accountId": "\(UUID().uuidString)",
          "remoteId": "g4",
          "threadId": "t4",
          "fromAddress": "dave@example.com",
          "receivedAt": "2023-11-14T22:13:20Z",
          "isRead": false,
          "isArchived": false
        }
        """
        let back = try makeDecoder().decode(MessageHeader.self, from: Data(json.utf8))
        XCTAssertNil(back.fromName)
        XCTAssertNil(back.subject)
        XCTAssertNil(back.snippet)
    }

    func test_connected_account_decodes_server_json() throws {
        // Exact shape of GET /api/accounts (ConnectedAccount.swift contract).
        let json = """
        [{
          "id":"00000000-0000-0000-0000-000000000001",
          "provider":"qq",
          "email":"a@b.com",
          "isActive":true,
          "unreadCount":7,
          "syncHealth":{"status":"degraded","lastError":"imap timeout"},
          "capabilities":{"archiveFolder":false,"idle":true,"move":false,"serverSnippet":false}
        }]
        """
        let accounts = try makeDecoder().decode([ConnectedAccount].self, from: Data(json.utf8))
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts.first?.id, UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        XCTAssertEqual(accounts.first?.provider, .qq)
        XCTAssertEqual(accounts.first?.email, "a@b.com")
        XCTAssertEqual(accounts.first?.isActive, true)
        XCTAssertEqual(accounts.first?.unreadCount, 7)
        XCTAssertEqual(accounts.first?.syncHealth.status, .degraded)
        XCTAssertEqual(accounts.first?.capabilities.idle, true)
        XCTAssertEqual(accounts.first?.capabilities.archiveFolder, false)
    }
}
