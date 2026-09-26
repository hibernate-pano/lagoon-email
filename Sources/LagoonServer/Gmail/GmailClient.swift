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
        public let filename: String?
        public let body: Body?
        /// Nested parts of a `multipart/*` payload.
        public let parts: [Payload]?
    }

    public struct Body: Codable, Sendable {
        /// base64url-encoded bytes. Absent for oversized messages, which only
        /// carry an `attachmentId`.
        public let data: String?
        public let size: Int?
        /// Present when this part is an attachment; bytes are fetched via
        /// `users.messages.attachments.get`.
        public let attachmentId: String?
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

/// Response of `users.messages.attachments.get`. `data` is base64url-encoded
/// (Gmail's URL-safe variant); decode with `GmailBodyExtractor.base64URLDecode`.
public struct RawGmailAttachment: Codable, Sendable {
    public let attachmentId: String?
    public let size: Int?
    public let data: String
}

/// Response of `users.messages.get?format=raw`. `raw` is base64url-encoded
/// RFC 5322 source.
public struct RawGmailRawMessage: Codable, Sendable {
    public let id: String?
    public let threadId: String?
    public let raw: String
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
        remoteId: String
    ) async throws -> RawGmailMessage {
        try await fetchMessage(
            accessToken: accessToken,
            remoteId: remoteId,
            format: "metadata",
            metadataHeaders: [
                "From", "Subject", "To", "List-Unsubscribe",
                // Threading/reply-chain headers: the store keeps them so a
                // reply can set In-Reply-To/References (IMAP has no threads API
                // either, so both providers share this contract).
                "Message-ID", "In-Reply-To", "References",
            ]
        )
    }

    /// `format=full`: returns the MIME tree so the caller can extract the body.
    public func getMessageFull(
        accessToken: String,
        remoteId: String
    ) async throws -> RawGmailMessage {
        try await fetchMessage(
            accessToken: accessToken,
            remoteId: remoteId,
            format: "full",
            metadataHeaders: []
        )
    }

    private func fetchMessage(
        accessToken: String,
        remoteId: String,
        format: String,
        metadataHeaders: [String]
    ) async throws -> RawGmailMessage {
        // remoteId is a server-issued opaque token; percent-encode it so a
        // hostile value cannot alter the path (spec §6.6 rule 2).
        var c = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        c.path += "/\(Self.percentEncodePath(remoteId))"
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

    /// `users.messages.attachments.get` — base64url-encoded bytes for one
    /// attachment (Gmail splits attachments into a separate API call when
    /// they are too large to fit in the message payload).
    public func getAttachment(
        accessToken: String,
        messageId: String,
        attachmentId: String
    ) async throws -> RawGmailAttachment {
        var c = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        c.path += "/\(Self.percentEncodePath(messageId))/attachments/\(Self.percentEncodePath(attachmentId))"
        var req = URLRequest(url: c.url!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        try OutboundGuard.validate(req.url!)
        let (data, resp) = try await session.outboundData(for: req)
        try Self.assertOK(resp, data)
        return try JSONDecoder().decode(RawGmailAttachment.self, from: data)
    }

    /// `users.messages.get?format=raw` — base64url-encoded RFC 5322 source
    /// for the whole message. Used by the `.eml` export route.
    public func getMessageRaw(
        accessToken: String,
        remoteId: String
    ) async throws -> RawGmailRawMessage {
        var c = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        c.path += "/\(Self.percentEncodePath(remoteId))"
        c.queryItems = [.init(name: "format", value: "raw")]
        var req = URLRequest(url: c.url!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        try OutboundGuard.validate(req.url!)
        let (data, resp) = try await session.outboundData(for: req)
        try Self.assertOK(resp, data)
        return try JSONDecoder().decode(RawGmailRawMessage.self, from: data)
    }

    /// `users.messages.modify` — add/remove labels. Requires `gmail.modify`
    /// scope; returns 403 otherwise. Caller catches and degrades.
    public func modifyMessageLabels(
        accessToken: String,
        remoteId: String,
        addLabelIds: [String] = [],
        removeLabelIds: [String] = []
    ) async throws {
        var c = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        c.path += "/\(Self.percentEncodePath(remoteId))/modify"
        var req = URLRequest(url: c.url!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try OutboundGuard.validate(req.url!)
        let body: [String: Any] = [
            "addLabelIds": addLabelIds,
            "removeLabelIds": removeLabelIds,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.outboundData(for: req)
        try Self.assertOK(resp, data)
    }

    /// `messages.trash` — the standard delete-with-recovery path; Gmail
    /// keeps the message in Trash for 30 days before expunging.
    public func trashMessage(accessToken: String, remoteId: String) async throws {
        var c = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        c.path += "/\(Self.percentEncodePath(remoteId))/trash"
        var req = URLRequest(url: c.url!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        try OutboundGuard.validate(req.url!)
        let (data, resp) = try await session.outboundData(for: req)
        try Self.assertOK(resp, data)
    }

    /// `messages.untrash` — the delete undo.
    public func untrashMessage(accessToken: String, remoteId: String) async throws {
        var c = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        c.path += "/\(Self.percentEncodePath(remoteId))/untrash"
        var req = URLRequest(url: c.url!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        try OutboundGuard.validate(req.url!)
        let (data, resp) = try await session.outboundData(for: req)
        try Self.assertOK(resp, data)
    }

    /// `users.drafts.create` with `threadId` — places a reply draft in the
    /// same thread. Requires `gmail.compose` scope; 403 without it.
    public func createDraft(
        accessToken: String,
        threadId: String,
        to: String,
        subject: String,
        body: String
    ) async throws -> String {
        var c = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/drafts")!
        var req = URLRequest(url: c.url!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try OutboundGuard.validate(req.url!)
        let raw = "To: \(to)\r\nSubject: \(subject)\r\n\r\n\(body)"
        let payload: [String: Any] = [
            "message": [
                "threadId": threadId,
                "raw": raw.data(using: .utf8)!.base64EncodedString(),
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, resp) = try await session.outboundData(for: req)
        try Self.assertOK(resp, data)
        struct R: Codable { let id: String }
        return try JSONDecoder().decode(R.self, from: data).id
    }

    /// `users.messages.send` — actually send a message. Requires `gmail.send`
    /// scope. `threadId` is optional: a reply threads through the References
    /// chain in `rawRFC822` alone.
    public func sendMessage(
        accessToken: String,
        threadId: String?,
        rawRFC822: String
    ) async throws -> String {
        var c = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")!
        var req = URLRequest(url: c.url!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try OutboundGuard.validate(req.url!)
        var payload: [String: Any] = [
            "raw": rawRFC822.data(using: .utf8)!.base64EncodedString(),
        ]
        if let threadId { payload["threadId"] = threadId }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, resp) = try await session.outboundData(for: req)
        try Self.assertOK(resp, data)
        struct R: Codable { let id: String }
        return try JSONDecoder().decode(R.self, from: data).id
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