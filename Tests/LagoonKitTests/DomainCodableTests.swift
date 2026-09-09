import XCTest
@testable import LagoonKit

final class DomainCodableTests: XCTestCase {
    func test_account_roundtrip() throws {
        let a = Account(
            id: UUID(),
            provider: .gmail,
            oauthUser: "u",
            email: "u@example.com",
            tokenExpiresAt: Date(timeIntervalSince1970: 1000),
            historyId: "h1"
        )
        let data = try JSONEncoder().encode(a)
        let back = try JSONDecoder().decode(Account.self, from: data)
        XCTAssertEqual(a, back)
    }

    func test_message_header_roundtrip() throws {
        let m = MessageHeader(
            id: UUID(),
            accountId: UUID(),
            gmailId: "abc",
            threadId: "t1",
            fromAddress: "alice@example.com",
            fromName: "Alice",
            subject: "Hi",
            snippet: "Hello...",
            receivedAt: Date(timeIntervalSince1970: 2000),
            isRead: false,
            isArchived: false
        )
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(MessageHeader.self, from: data)
        XCTAssertEqual(m, back)
    }
}