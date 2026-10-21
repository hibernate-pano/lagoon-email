import XCTest
import Foundation
import Logging
import Hummingbird
import HummingbirdTesting
import NIOCore
import GRDB
@testable import LagoonKit
@testable import LagoonServer

/// Composing a mail to more than one person, with a blind copy, with files.
///
/// Three gaps that all came from the same place: the compose route accepted
/// exactly one address and no files, so "reply to three people" and "reply
/// with the spreadsheet attached" — the two most ordinary things a mail
/// client is asked to do — could not be expressed at all.
final class ComposeAttachmentsTests: XCTestCase {
    private let logger = Logger(label: "compose-attachments-tests")

    private func makeAccount() -> Account {
        Account(
            id: UUID(),
            provider: .qq,
            oauthUser: "ca-\(UUID().uuidString)",
            email: "ca-\(UUID().uuidString)@qq.com",
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

    // MARK: - The envelope

    /// Bcc goes into the envelope and **not** into the headers.
    ///
    /// That contrast is the whole feature: a blind copy that named itself
    /// in the `To:`/`Cc:` headers would not be blind. So the headers must
    /// not carry it, and the envelope must — otherwise the person who was
    /// supposed to get a private copy never gets one.
    func test_bccIsInTheEnvelopeAndNotInTheHeaders() {
        let outbound = OutboundMessage(
            fromEmail: "me@example.com",
            fromName: nil,
            to: "one@example.com",
            cc: ["two@example.com"],
            bcc: ["secret@example.com"],
            subject: "Hello",
            body: "Body",
            inReplyTo: nil,
            references: nil,
            isReply: false
        )

        let envelope = outbound.envelopeRecipients
        XCTAssertEqual(
            Set(envelope), ["one@example.com", "two@example.com", "secret@example.com"],
            "every recipient — including the blind one — must get a forward-path"
        )

        let raw = String(decoding: MIMEBuilder.newMessage(outbound, messageId: "<t@lagoon>"), as: UTF8.self)
        XCTAssertFalse(
            raw.lowercased().contains("bcc:"),
            "a Bcc header exposes the blind copy to everyone else"
        )
        XCTAssertFalse(
            raw.contains("secret@example.com"),
            "the blind recipient must not appear anywhere in the headers"
        )
        XCTAssertTrue(raw.contains("two@example.com"), "Cc is visible — it belongs in the headers")
    }

    /// The same person in two lists gets one forward-path.
    ///
    /// RFC 5321 wants one `RCPT TO` per forward-path, and a duplicate would
    /// deliver the mail twice.
    func test_aDuplicateRecipientGetsOneForwardPath() {
        let outbound = OutboundMessage(
            fromEmail: "me@example.com",
            fromName: nil,
            to: "one@example.com",
            cc: ["ONE@example.com"],
            bcc: [],
            subject: "Hello",
            body: "Body",
            inReplyTo: nil,
            references: nil,
            isReply: false
        )
        XCTAssertEqual(outbound.envelopeRecipients, ["one@example.com"])
    }

    // MARK: - The MIME structure

    /// A mail with an attachment is `multipart/mixed`, with the body first
    /// and one part per file.
    func test_aMessageWithAttachmentsIsMultipartMixed() {
        let outbound = OutboundMessage(
            fromEmail: "me@example.com",
            fromName: nil,
            to: "one@example.com",
            subject: "Report",
            body: "See attached.",
            inReplyTo: nil,
            references: nil,
            isReply: false,
            attachments: [
                OutboundAttachment(
                    filename: "report.pdf",
                    mimeType: "application/pdf",
                    data: Data("%PDF-1.4 hello".utf8)
                ),
            ]
        )
        let raw = String(decoding: MIMEBuilder.newMessage(outbound, messageId: "<t@lagoon>"), as: UTF8.self)

        XCTAssertTrue(raw.contains("Content-Type: multipart/mixed;"), "not multipart/mixed")
        XCTAssertTrue(raw.contains("Content-Type: text/plain; charset=UTF-8"), "the body part is missing")
        XCTAssertTrue(raw.contains("Content-Type: application/pdf"), "the file's type is missing")
        XCTAssertTrue(
            raw.contains("Content-Disposition: attachment; filename=\"report.pdf\""),
            "the file's name is missing"
        )
        XCTAssertTrue(raw.contains("Content-Transfer-Encoding: base64"), "the body is not encoded")
    }

    /// The message the server builds is one the parser can read back.
    ///
    /// This is the test that matters: a `multipart/mixed` message that
    /// Lagoon cannot parse is a message Lagoon cannot display, and a
    /// message the recipient cannot open is a message that failed.
    func test_theBuiltMessageRoundTripsThroughTheParser() throws {
        let outbound = OutboundMessage(
            fromEmail: "me@example.com",
            fromName: nil,
            to: "one@example.com",
            subject: "Report",
            body: "See attached.",
            inReplyTo: nil,
            references: nil,
            isReply: false,
            attachments: [
                OutboundAttachment(
                    filename: "notes.txt",
                    mimeType: "text/plain",
                    data: Data("the file body".utf8)
                ),
            ]
        )
        let raw = MIMEBuilder.newMessage(outbound, messageId: "<t@lagoon>")

        let parsed = MIMEParser.parse(message: raw, decodeAttachmentBytes: true)
        XCTAssertTrue(
            parsed.text.contains("See attached."),
            "the typed body did not survive: \(parsed.text)"
        )
        XCTAssertEqual(
            parsed.attachments.count, 1,
            "the attachment was lost: \(parsed.attachments.map(\.filename))"
        )
        XCTAssertEqual(parsed.attachments.first?.filename, "notes.txt")
        XCTAssertEqual(
            parsed.attachments.first?.data,
            Data("the file body".utf8),
            "the file's bytes did not survive the round trip"
        )
    }

    /// A file name with a newline cannot forge a header.
    ///
    /// The name comes off the user's disk, and it goes into a header. A
    /// CRLF in it would let the *file name* end the header line and start
    /// a new one — so the injected text must not be able to appear at the
    /// start of any line.
    func test_aFileNameWithCRLFDoesNotForgeAHeader() {
        let outbound = OutboundMessage(
            fromEmail: "me@example.com",
            fromName: nil,
            to: "one@example.com",
            subject: "Hello",
            body: "Body",
            inReplyTo: nil,
            references: nil,
            isReply: false,
            attachments: [
                OutboundAttachment(
                    filename: "evil.txt\r\nX-Injected: yes",
                    mimeType: "text/plain",
                    data: Data("x".utf8)
                ),
            ]
        )
        let raw = String(decoding: MIMEBuilder.newMessage(outbound, messageId: "<t@lagoon>"), as: UTF8.self)
        XCTAssertFalse(
            raw.contains("\r\nX-Injected:"),
            "the file name forged a header"
        )
        // The whole header block is one line per header: the injected text
        // stayed inside the file name instead of becoming a header.
        let headerBlock = raw.components(separatedBy: "\r\n\r\n").first ?? ""
        XCTAssertFalse(
            headerBlock.contains("\n"),
            "the header block has a line break in it — a name forged one"
        )
    }

    /// A Chinese file name survives, in both the plain and the RFC 5987
    /// form.
    ///
    /// Without `filename*` the recipient's client shows mojibake: the
    /// attachment is there and unusable.
    func test_aNonASCIINameCarriesBothFilenameForms() {
        let outbound = OutboundMessage(
            fromEmail: "me@example.com",
            fromName: nil,
            to: "one@example.com",
            subject: "Hello",
            body: "Body",
            inReplyTo: nil,
            references: nil,
            isReply: false,
            attachments: [
                OutboundAttachment(
                    filename: "季度报告.xlsx",
                    mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                    data: Data("x".utf8)
                ),
            ]
        )
        let raw = String(decoding: MIMEBuilder.newMessage(outbound, messageId: "<t@lagoon>"), as: UTF8.self)
        XCTAssertTrue(
            raw.contains("filename*=UTF-8''"),
            "the RFC 5987 form is missing — a non-ASCII name arrives as mojibake"
        )
    }

    /// A mail with no attachment is still a plain `text/plain` message.
    ///
    /// The multipart path is a new branch; the old one has to stay exactly
    /// as it was, because every existing reply goes through it.
    func test_aMessageWithoutAttachmentsIsStillPlainText() {
        let outbound = OutboundMessage(
            fromEmail: "me@example.com",
            fromName: nil,
            to: "one@example.com",
            subject: "Hello",
            body: "Body",
            inReplyTo: nil,
            references: nil,
            isReply: false
        )
        let raw = String(decoding: MIMEBuilder.newMessage(outbound, messageId: "<t@lagoon>"), as: UTF8.self)
        XCTAssertTrue(raw.contains("Content-Type: text/plain; charset=UTF-8"))
        XCTAssertFalse(raw.contains("multipart/"), "a plain mail must not become multipart")
    }

    // MARK: - The route

    /// A compose request with several recipients is accepted.
    ///
    /// The route used to accept exactly one address: two addresses in the
    /// `To:` field came back as `malformed-compose`, and the client showed
    /// the user a bare HTTP 400.
    func test_aComposeRequestWithSeveralRecipientsIsAccepted() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                let provider = RecordingProvider()
                let router = Router()
                MessageRoutes.register(
                    on: router,
                    db: conn,
                    logger: self.logger,
                    makeProvider: { _ in provider }
                )
                let app = Application(router: router)
                try await app.test(.router) { client in
                    try await client.execute(
                        uri: "/api/compose/send?accountId=\(account.id.uuidString)",
                        method: .post,
                        body: ByteBuffer(data: Data(#"{"to":"one@example.com, two@example.com","subject":"Hi","body":"Hello"}"#.utf8))
                    ) { response in
                        XCTAssertEqual(response.status, .ok)
                    }
                }
                let sent = await provider.sent
                XCTAssertEqual(sent.count, 1, "the mail did not go out")
                XCTAssertEqual(
                    Set(sent.first?.recipientAddresses ?? []),
                    ["one@example.com", "two@example.com"],
                    "both recipients must be addressed"
                )
            }
        }
    }

    /// A Cc/Bcc list with a bad address is refused as a whole.
    ///
    /// Silently dropping the bad entry would send the mail to fewer people
    /// than the user asked, with nothing to tell them.
    func test_aBadAddressInTheCcListRefusesTheSend() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                let provider = RecordingProvider()
                let router = Router()
                MessageRoutes.register(
                    on: router,
                    db: conn,
                    logger: self.logger,
                    makeProvider: { _ in provider }
                )
                let app = Application(router: router)
                try await app.test(.router) { client in
                    try await client.execute(
                        uri: "/api/compose/send?accountId=\(account.id.uuidString)",
                        method: .post,
                        body: ByteBuffer(data: Data(#"{"to":"one@example.com","cc":["good@example.com","not-an-address"],"subject":"Hi","body":"Hello"}"#.utf8))
                    ) { response in
                        XCTAssertEqual(response.status, .badRequest)
                        let body = String(decoding: response.body.readableBytesView, as: UTF8.self)
                        XCTAssertTrue(
                            body.contains("malformed-recipient"),
                            "the client cannot tell a bad address from a bad send: \(body)"
                        )
                    }
                }
                let sent = await provider.sent
                XCTAssertTrue(sent.isEmpty, "a refused request must not send")
            }
        }
    }

    /// An attachment that is not valid base64 is refused.
    func test_anUndecodableAttachmentRefusesTheSend() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                let provider = RecordingProvider()
                let router = Router()
                MessageRoutes.register(
                    on: router,
                    db: conn,
                    logger: self.logger,
                    makeProvider: { _ in provider }
                )
                let app = Application(router: router)
                let payload = #"{"to":"one@example.com","subject":"Hi","body":"Hello","attachments":[{"filename":"a.txt","mimeType":"text/plain","dataBase64":"!!!not base64!!!"}]}"#
                try await app.test(.router) { client in
                    try await client.execute(
                        uri: "/api/compose/send?accountId=\(account.id.uuidString)",
                        method: .post,
                        body: ByteBuffer(data: Data(payload.utf8))
                    ) { response in
                        XCTAssertEqual(response.status, .badRequest)
                        let body = String(decoding: response.body.readableBytesView, as: UTF8.self)
                        XCTAssertTrue(body.contains("malformed-attachment"), body)
                    }
                }
                let sent = await provider.sent
                XCTAssertTrue(sent.isEmpty, "a refused request must not send")
            }
        }
    }

    /// A valid attachment reaches the provider, with its bytes intact.
    func test_aValidAttachmentReachesTheProvider() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                let provider = RecordingProvider()
                let router = Router()
                MessageRoutes.register(
                    on: router,
                    db: conn,
                    logger: self.logger,
                    makeProvider: { _ in provider }
                )
                let app = Application(router: router)
                let encoded = Data("the file body".utf8).base64EncodedString()
                let payload = #"{"to":"one@example.com","subject":"Hi","body":"Hello","attachments":[{"filename":"a.txt","mimeType":"text/plain","dataBase64":"\#(encoded)"}]}"#
                try await app.test(.router) { client in
                    try await client.execute(
                        uri: "/api/compose/send?accountId=\(account.id.uuidString)",
                        method: .post,
                        body: ByteBuffer(data: Data(payload.utf8))
                    ) { response in
                        XCTAssertEqual(response.status, .ok)
                    }
                }
                let sent = await provider.sent
                let attachments = sent.first?.attachments ?? []
                XCTAssertEqual(attachments.count, 1)
                XCTAssertEqual(attachments.first?.filename, "a.txt")
                XCTAssertEqual(attachments.first?.data, Data("the file body".utf8))
            }
        }
    }
}

/// A provider that records what it was asked to send.
private actor RecordingProvider: MailProvider {
    nonisolated let kind: MailProviderKind = .qq
    private(set) var sent: [OutboundMessage] = []

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

    func fetchRawMessage(remoteId: String) async throws -> Data { Data() }

    func fetchRawHeaderValues(remoteId: String) async throws -> [String: String] { [:] }

    func setRead(remoteId: String, isRead: Bool) async throws {}
    func archive(remoteId: String) async throws {}
    func unarchive(remoteId: String) async throws {}
    func trash(remoteId: String) async throws {}
    func restoreFromTrash(remoteId: String) async throws {}
    func permanentlyDelete(remoteId: String) async throws {}
    func emptyTrash() async throws {}
    var folderRows: [MailFolder] = []
    var moveCalls: [(remoteId: String, folder: String, createIfMissing: Bool)] = []
    var moveFailure: MailError?
    func listFolders() async throws -> [MailFolder] { folderRows }
    @discardableResult
    func move(remoteId: String, to folder: String, createIfMissing: Bool) async throws -> Bool {
        moveCalls.append((remoteId, folder, createIfMissing))
        if let moveFailure { throw moveFailure }
        return true
    }
    func listSent(limit: Int) async throws -> [MessageHeader] { [] }

    func send(_ outbound: OutboundMessage) async throws -> String? {
        sent.append(outbound)
        return "<sent@lagoon>"
    }

    func probe() async throws {}
}
