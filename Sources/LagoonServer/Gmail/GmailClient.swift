import Foundation
import LagoonKit

public struct RawGmailMessage: Codable, Sendable {
    public let id: String
    public let threadId: String
    public let snippet: String?
    public let internalDate: String?   // ms since epoch, string from Gmail
    /// Present on both metadata and full responses. Contains "UNREAD" when the
    /// message is unread — this is how real read state reaches the poller.
    public let labelIds: [String]?
    public let payload: Payload?

    public struct Payload: Codable, Sendable {
        public let headers: [Header]?
        /// MIME type of this part ("text/plain", "text/html", "multipart/…").
        public let mimeType: String?
        public let body: Body?
        /// Nested parts of a `multipart/*` payload.
        public let parts: [Payload]?
    }

    public struct Body: Codable, Sendable {
        /// base64url-encoded bytes. Absent for oversized messages, which only
        /// carry an `attachmentId`.
        public let data: String?
        public let size: Int?
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

    public init(session: URLSession = .outbound) {
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

        let (data, resp) = try await session.outboundData(for: req)
        try Self.assertOK(resp, data)
        return try JSONDecoder().decode(RawGmailList.self, from: data)
    }

    public func getMessage(
        accessToken: String,
        gmailId: String
    ) async throws -> RawGmailMessage {
        try await fetchMessage(
            accessToken: accessToken,
            gmailId: gmailId,
            format: "metadata",
            metadataHeaders: ["From", "Subject", "To", "List-Unsubscribe"]
        )
    }

    /// `format=full`: returns the MIME tree so the caller can extract the body.
    public func getMessageFull(
        accessToken: String,
        gmailId: String
    ) async throws -> RawGmailMessage {
        try await fetchMessage(
            accessToken: accessToken,
            gmailId: gmailId,
            format: "full",
            metadataHeaders: []
        )
    }

    private func fetchMessage(
        accessToken: String,
        gmailId: String,
        format: String,
        metadataHeaders: [String]
    ) async throws -> RawGmailMessage {
        // gmailId is a server-issued opaque token; percent-encode it so a
        // hostile value cannot alter the path (spec §6.6 rule 2).
        var c = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        c.path += "/\(Self.percentEncodePath(gmailId))"
        var items: [URLQueryItem] = [.init(name: "format", value: format)]
        items += metadataHeaders.map { .init(name: "metadataHeaders", value: $0) }
        c.queryItems = items
        var req = URLRequest(url: c.url!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        try OutboundGuard.validate(req.url!)

        let (data, resp) = try await session.outboundData(for: req)
        try Self.assertOK(resp, data)
        return try JSONDecoder().decode(RawGmailMessage.self, from: data)
    }

    public func getProfileEmail(accessToken: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        try OutboundGuard.validate(req.url!)

        let (data, resp) = try await session.outboundData(for: req)
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