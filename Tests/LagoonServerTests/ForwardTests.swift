import XCTest
import Foundation
import Logging
import Hummingbird
import HummingbirdTesting
import NIOCore
import GRDB
@testable import LagoonKit
@testable import LagoonServer

/// Forwarding a message.
///
/// ## Why this file exists
///
/// The old forward took the message's plain-text body, wrapped it in `>`
/// characters, and sent that as a new message. The recipient got a wall
/// of quoted text: the original's HTML formatting was gone, its
/// attachments were gone, its headers were gone, and what was left could
/// not be replied to in the original thread.
///
/// It *looked* like a forward. That is what made it a problem: the user
/// had no way to tell that the mail they sent had lost the original's
/// attachments.
///
/// RFC 5322 §3.6.4 has the answer, and these tests pin it: the original
/// travels as a `message/rfc822` part — the original message, bytes and
/// all.
final class ForwardTests: XCTestCase {
    private let logger = Logger(label: "forward-tests")

    private func makeAccount() -> Account {
        Account(
            id: UUID(),
            provider: .qq,
            oauthUser: "fwd-\(UUID().uuidString)",
            email: "fwd-\(UUID().uuidString)@qq.com",
            credentials: nil
        )
    }

    private func seed(_ account: Account, db: LagoonDB) async throws {
        try await AccountStore.upsert(
            account,
            credentials: try CredentialVault.seal(
                .imap(username: account.email, authCode: "auth-code")
            ),
            db: db
        )
    }

    private func header(_ remoteId: String, accountId: UUID, subject: String = "原始主题") -> MessageHeader {
        MessageHeader(
            id: UUID(),
            accountId: accountId,
            remoteId: remoteId,
            threadId: "t-\(remoteId)",
            fromAddress: "person@example.com",
            fromName: "Person",
            subject: subject,
            snippet: nil,
            receivedAt: Date(),
            isRead: true,
            isArchived: false
        )
    }

    /// The original message, as the server would fetch it: a real RFC 5322
    /// message with its own headers, its own body and its own attachment.
    private let originalRaw = """
        From: Person <person@example.com>
        To: me@example.com
        Subject: 原始主题
        Message-ID: <original@example.com>
        MIME-Version: 1.0
        Content-Type: text/plain; charset=UTF-8

        原始正文，里面有一份重要的东西。
        """

    // MARK: - The MIME structure

    /// A forwarded message carries the original as a `message/rfc822` part.
    ///
    /// This is the assertion that would have failed with the old
    /// implementation: the original was flattened into the body, so there
    /// was no part that carried it.
    func test_theOriginalTravelsAsAMessageRFC822Part() {
        let outbound = OutboundMessage(
            fromEmail: "me@example.com",
            fromName: nil,
            to: "them@example.com",
            subject: "Fwd: 原始主题",
            body: "看一下这个",
            inReplyTo: nil,
            references: nil,
            isReply: false,
            attachments: [
                OutboundAttachment(
                    filename: "原始主题.eml",
                    mimeType: "message/rfc822",
                    data: Data(originalRaw.utf8),
                    disposition: .inline
                )
            ]
        )

        let raw = String(decoding: MIMEBuilder.newMessage(outbound, messageId: "<t@lagoon>"), as: UTF8.self)
        XCTAssertTrue(
            raw.contains("Content-Type: message/rfc822"),
            "the original must travel as a message/rfc822 part, not as quoted text"
        )
        XCTAssertTrue(
            raw.contains("multipart/mixed"),
            "a message with a part inside it must be multipart"
        )
        // And the original's own headers are inside it, base64-encoded.
        let encoded = originalRaw.data(using: .utf8)!.base64EncodedString()
        let wrapped = encoded.chunked(into: 76).joined(separator: "\r\n")
        XCTAssertTrue(
            raw.contains(wrapped),
            "the original's bytes must travel verbatim — a reconstruction from a parse is a guess"
        )
    }

    /// The forwarded part is `inline`, not `attachment`.
    ///
    /// `inline` is what makes the recipient's client *render* the original
    /// rather than offer it as a file to save. The difference between a
    /// forward and a "here is the original, download it" is exactly this
    /// disposition.
    func test_theForwardedPartIsInline() {
        let outbound = OutboundMessage(
            fromEmail: "me@example.com",
            fromName: nil,
            to: "them@example.com",
            subject: "Fwd: 原始主题",
            body: "",
            inReplyTo: nil,
            references: nil,
            isReply: false,
            attachments: [
                OutboundAttachment(
                    filename: "original.eml",
                    mimeType: "message/rfc822",
                    data: Data(originalRaw.utf8),
                    disposition: .inline
                )
            ]
        )
        let raw = String(decoding: MIMEBuilder.newMessage(outbound, messageId: "<t@lagoon>"), as: UTF8.self)
        XCTAssertTrue(
            raw.contains("Content-Disposition: inline"),
            "the forwarded original must be inline — the recipient should read it, not download it"
        )
    }

    /// A file the user picked stays `attachment`.
    ///
    /// The disposition is not a global switch: a file from the user's disk
    /// is a file to save, and only a forwarded message is rendered.
    func test_aPickedFileStaysAnAttachment() {
        let outbound = OutboundMessage(
            fromEmail: "me@example.com",
            fromName: nil,
            to: "them@example.com",
            subject: "Report",
            body: "See attached.",
            inReplyTo: nil,
            references: nil,
            isReply: false,
            attachments: [
                OutboundAttachment(
                    filename: "report.pdf",
                    mimeType: "application/pdf",
                    data: Data("%PDF-1.4".utf8)
                )
            ]
        )
        let raw = String(decoding: MIMEBuilder.newMessage(outbound, messageId: "<t@lagoon>"), as: UTF8.self)
        XCTAssertTrue(
            raw.contains("Content-Disposition: attachment"),
            "a file from the user's disk is a file to save"
        )
    }

    /// The subject gets exactly one "Fwd:".
    ///
    /// Forwarding an already-forwarded message must not produce
    /// "Fwd: Fwd: Fwd: …" — the same de-dup rule the reply path uses for
    /// "Re:".
    func test_theSubjectGetsExactlyOneFwdPrefix() {
        XCTAssertEqual(
            MessageRoutes.forwardSubject(nil, original: "原始主题"),
            "Fwd: 原始主题"
        )
        XCTAssertEqual(
            MessageRoutes.forwardSubject("Fwd: 原始主题", original: "原始主题"),
            "Fwd: 原始主题",
            "an already-forwarded subject must not get a second prefix"
        )
        XCTAssertEqual(
            MessageRoutes.forwardSubject("Fwd: Fwd: 原始主题", original: "原始主题"),
            "Fwd: Fwd: 原始主题",
            "the de-dup rule applies to the prefix, not to the whole string"
        )
        XCTAssertEqual(
            MessageRoutes.forwardSubject(nil, original: nil),
            "Fwd:",
            "a message with no subject still needs a prefix"
        )
    }

    // MARK: - The route

    /// The route sends the original, not a quote of it.
    func test_theRouteSendsTheOriginalAsAPart() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            let provider = ForwardProvider(rawMessage: Data(originalRaw.utf8))
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await MessageStore.upsert(
                    header("m1", accountId: account.id), db: conn
                )

                let app = Application(router: router(conn, provider: provider))
                try await app.test(.router) { client in
                    let payload = try JSONSerialization.data(withJSONObject: [
                        "to": ["them@example.com"],
                        "body": "看一下这个",
                    ])
                    try await client.execute(
                        uri: "/api/messages/m1/forward?accountId=\(account.id.uuidString)",
                        method: .post,
                        body: ByteBuffer(data: payload)
                    ) { response in
                        XCTAssertEqual(response.status, .ok)
                    }
                }

                let sent = await provider.sent
                XCTAssertEqual(sent.count, 1)
                let outbound = try XCTUnwrap(sent.first)
                XCTAssertEqual(
                    outbound.attachments.count, 1,
                    "the forward carries exactly one part — the original"
                )
                let part = try XCTUnwrap(outbound.attachments.first)
                XCTAssertEqual(part.mimeType, "message/rfc822")
                XCTAssertEqual(part.disposition, .inline)
                XCTAssertEqual(
                    part.data,
                    Data(originalRaw.utf8),
                    "the original's bytes must be verbatim"
                )
                // The user's note is the body, above the original.
                XCTAssertEqual(outbound.body, "看一下这个")
                XCTAssertEqual(outbound.subject, "Fwd: 原始主题")
            }
        }
    }

    /// A bad address refuses the whole forward.
    ///
    /// A mail that reached fewer people than the user asked is a mail the
    /// user cannot tell was wrong.
    func test_aBadAddressRefusesTheForward() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            let provider = ForwardProvider(rawMessage: Data(originalRaw.utf8))
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await MessageStore.upsert(
                    header("m1", accountId: account.id), db: conn
                )

                let app = Application(router: router(conn, provider: provider))
                try await app.test(.router) { client in
                    let payload = try JSONSerialization.data(withJSONObject: [
                        "to": ["them@example.com", "not-an-address"],
                        "body": "",
                    ])
                    try await client.execute(
                        uri: "/api/messages/m1/forward?accountId=\(account.id.uuidString)",
                        method: .post,
                        body: ByteBuffer(data: payload)
                    ) { response in
                        XCTAssertEqual(response.status, .badRequest)
                        let body = String(decoding: response.body.readableBytesView, as: UTF8.self)
                        XCTAssertTrue(
                            body.contains("malformed-recipient"),
                            "the client cannot tell a bad address from a broken request: \(body)"
                        )
                    }
                }

                let sent = await provider.sent
                XCTAssertTrue(sent.isEmpty, "a refused forward still went out")
            }
        }
    }

    /// A message that cannot be fetched cannot be forwarded.
    ///
    /// The client needs to say *that* — "this mail is gone" — rather than
    /// "the send failed", because the two have different fixes.
    func test_aMessageThatIsGoneIs404() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            let provider = ForwardProvider(rawMessage: Data(originalRaw.utf8))
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)

                let app = Application(router: router(conn, provider: provider))
                try await app.test(.router) { client in
                    let payload = try JSONSerialization.data(withJSONObject: [
                        "to": ["them@example.com"],
                        "body": "",
                    ])
                    try await client.execute(
                        uri: "/api/messages/no-such/forward?accountId=\(account.id.uuidString)",
                        method: .post,
                        body: ByteBuffer(data: payload)
                    ) { response in
                        XCTAssertEqual(response.status, .notFound)
                    }
                }
            }
        }
    }

    /// A forward with no recipients is refused.
    func test_aForwardWithNoRecipientsIsRefused() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            let provider = ForwardProvider(rawMessage: Data(originalRaw.utf8))
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                try await MessageStore.upsert(
                    header("m1", accountId: account.id), db: conn
                )

                let app = Application(router: router(conn, provider: provider))
                try await app.test(.router) { client in
                    let payload = try JSONSerialization.data(withJSONObject: [
                        "to": [String](),
                        "body": "",
                    ])
                    try await client.execute(
                        uri: "/api/messages/m1/forward?accountId=\(account.id.uuidString)",
                        method: .post,
                        body: ByteBuffer(data: payload)
                    ) { response in
                        XCTAssertEqual(response.status, .badRequest)
                    }
                }

                let sent = await provider.sent
                XCTAssertTrue(sent.isEmpty, "a forward with nobody to send to still went out")
            }
        }
    }

    private func router(
        _ db: LagoonDB,
        provider: any MailProvider
    ) -> Router<BasicRequestContext> {
        let router = Router()
        MessageRoutes.register(
            on: router, db: db, logger: self.logger, summarizer: nil,
            makeProvider: { _ in provider }
        )
        return router
    }
}

/// A provider that hands out a fixed original message.
private actor ForwardProvider: MailProvider {
    nonisolated let kind: MailProviderKind = .qq
    private(set) var sent: [OutboundMessage] = []
    private let rawMessage: Data

    init(rawMessage: Data) {
        self.rawMessage = rawMessage
    }

    func capabilities() async -> MailCapabilities? {
        MailCapabilities(archiveFolder: true, idle: true, move: true, serverSnippet: true)
    }

    func pullChanges(after cursor: MailSyncState, waitUpTo: Duration) async throws -> MailChangeSet {
        MailChangeSet(upserts: [], resetRequired: false, cursor: cursor)
    }

    func fetchBody(remoteId: String) async throws -> FetchedBody {
        FetchedBody(text: "", html: nil, attachments: [], hasMore: false, to: [], cc: [])
    }

    func fetchAttachment(remoteId: String, attachmentId: String) async throws -> FetchedAttachmentBytes {
        throw AttachmentError.notFound
    }

    func fetchRawMessage(remoteId: String) async throws -> Data { rawMessage }
    func fetchRawHeaderValues(remoteId: String) async throws -> [String: String] { [:] }

    func setRead(remoteId: String, isRead: Bool) async throws {}
    func archive(remoteId: String) async throws {}
    func unarchive(remoteId: String) async throws {}
    func trash(remoteId: String) async throws {}
    func restoreFromTrash(remoteId: String) async throws {}
    func permanentlyDelete(remoteId: String) async throws {}
    func emptyTrash() async throws {}

    var folderRows: [MailFolder] = []
    func listFolders() async throws -> [MailFolder] { folderRows }
    @discardableResult
    func move(remoteId: String, to folder: String, createIfMissing: Bool) async throws -> Bool { true }
    func listSent(limit: Int) async throws -> [MessageHeader] { [] }

    func send(_ outbound: OutboundMessage) async throws -> String? {
        sent.append(outbound)
        return "<sent@lagoon>"
    }

    func probe() async throws {}
}

private extension String {
    /// The same chunking the MIME builder uses for base64 bodies.
    func chunked(into size: Int) -> [String] {
        guard count > size else { return [self] }
        var chunks: [String] = []
        var index = startIndex
        while index < endIndex {
            let end = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            chunks.append(String(self[index..<end]))
            index = end
        }
        return chunks
    }
}
