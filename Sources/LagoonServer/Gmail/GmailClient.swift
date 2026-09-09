import Foundation
import LagoonKit

public struct RawGmailMessage: Codable, Sendable {
    public let id: String
    public let threadId: String
    public let snippet: String?
    public let internalDate: String?   // ms since epoch, string from Gmail
    public let payload: Payload?

    public struct Payload: Codable, Sendable {
        public let headers: [Header]?
    }

    public struct Header: Codable, Sendable {
        public let name: String
        public let value: String
    }
}

public struct RawGmailList: Codable, Sendable {
    public let messages: [Ref]?
    public let nextPageToken: String?

    public struct Ref: Codable, Sendable {
        public let id: String
        public let threadId: String
    }
}

public enum GmailClientError: Error { case unauthorized, http(Int, String) }

public final class GmailClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .direct) {
        self.session = session
    }

    public func listMessageRefs(
        accessToken: String,
        maxResults: Int = 100,
        pageToken: String? = nil
    ) async throws -> RawGmailList {
        var c = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        var items: [URLQueryItem] = [
            .init(name: "maxResults", value: String(maxResults))
        ]
        if let pageToken { items.append(.init(name: "pageToken", value: pageToken)) }
        c.queryItems = items
        var req = URLRequest(url: c.url!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        try OutboundGuard.validate(req.url!)

        let (data, resp) = try await session.data(for: req)
        try Self.assertOK(resp, data)
        return try JSONDecoder().decode(RawGmailList.self, from: data)
    }

    public func getMessage(
        accessToken: String,
        gmailId: String
    ) async throws -> RawGmailMessage {
        // gmailId is a server-issued opaque token; percent-encode it so a
        // hostile value cannot alter the path (spec §6.6 rule 2).
        var c = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        c.path += "/\(Self.percentEncodePath(gmailId))"
        c.queryItems = [
            .init(name: "format", value: "metadata"),
            .init(name: "metadataHeaders", value: "From"),
            .init(name: "metadataHeaders", value: "Subject")
        ]
        var req = URLRequest(url: c.url!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        try OutboundGuard.validate(req.url!)

        let (data, resp) = try await session.data(for: req)
        try Self.assertOK(resp, data)
        return try JSONDecoder().decode(RawGmailMessage.self, from: data)
    }

    public func getProfileEmail(accessToken: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        try OutboundGuard.validate(req.url!)

        let (data, resp) = try await session.data(for: req)
        try Self.assertOK(resp, data)
        struct R: Codable { let emailAddress: String }
        return try JSONDecoder().decode(R.self, from: data).emailAddress
    }

    static func percentEncodePath(_ s: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private static func assertOK(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else {
            throw GmailClientError.http(0, "non-HTTP response")
        }
        if http.statusCode == 401 { throw GmailClientError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw GmailClientError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }
}