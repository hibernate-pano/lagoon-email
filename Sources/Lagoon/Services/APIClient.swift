import Foundation
import LagoonKit

public final class APIClient: Sendable {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL = URL(string: "http://127.0.0.1:8080")!, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func fetchMessages(accountId: UUID, limit: Int = 50) async throws -> SyncResponse {
        var c = URLComponents(url: baseURL.appendingPathComponent("api/messages"), resolvingAgainstBaseURL: false)!
        c.queryItems = [
            .init(name: "accountId", value: accountId.uuidString),
            .init(name: "limit", value: String(limit))
        ]
        let (data, resp) = try await session.data(from: c.url!)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "lagoon.api", code: 1)
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(SyncResponse.self, from: data)
    }
}