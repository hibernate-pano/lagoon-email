import XCTest
import Foundation
import Logging
import Hummingbird
import HummingbirdTesting
import NIOCore
import GRDB
@testable import LagoonKit
@testable import LagoonServer

/// `GET /api/messages/{remoteId}/inline-images` — the route that replaced
/// N per-attachment requests with one response.
///
/// ## What this fixes
///
/// A mail with inline (`cid:`) images used to cost the client **N+1 round
/// trips**: one for the body, then one per image. The server's cost was
/// worse than the client's — the per-attachment endpoint re-fetched and
/// re-parsed the **entire message** for every single part, so a 20-image
/// newsletter meant 20 full-message IMAP fetches.
///
/// These tests pin the contract that makes the one-round-trip path real:
/// the route reads the message **once**, keys the images by lower-cased
/// Content-ID (the shape the HTML's `cid:` reference uses), and never
/// returns non-image or non-inline parts.
final class InlineImageRouteTests: XCTestCase {
    private let logger = Logger(label: "inline-image-route-tests")

    // MARK: - Fixtures

    private func makeAccount() -> Account {
        Account(
            id: UUID(),
            provider: .qq,
            oauthUser: "inline-\(UUID().uuidString)",
            email: "inline-\(UUID().uuidString)@qq.com",
            credentials: nil,
            capabilities: MailCapabilities(
                archiveFolder: true, idle: true, move: true, serverSnippet: false
            )
        )
    }

    /// A 1x1 transparent PNG — the smallest real image bytes.
    private static let pngBytes = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
        0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
        0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00,
        0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
        0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    ])

    /// A `multipart/related` message with one inline image and one ordinary
    /// attachment. Both have bytes; only the inline image belongs in the
    /// inline-images response.
    private static func relatedMessage() -> Data {
        let b64 = pngBytes.base64EncodedString()
        let raw = """
        Content-Type: multipart/related; boundary="r"

        --r
        Content-Type: text/html; charset=UTF-8

        <html><body><img src="cid:logo-cid-1">hi</body></html>
        --r
        Content-Type: image/png
        Content-ID: <logo-cid-1>
        Content-Disposition: inline
        Content-Transfer-Encoding: base64

        \(b64)
        --r
        Content-Type: application/pdf
        Content-Disposition: attachment; filename="invoice.pdf"
        Content-Transfer-Encoding: base64

        JVBERi0xLjQ=
        --r--
        """.replacingOccurrences(of: "\n", with: "\r\n")
        return Data(raw.utf8)
    }

    private func seed(_ account: Account, db: LagoonDB) async throws {
        try await AccountStore.upsert(
            account,
            credentials: try CredentialVault.seal(
                .imap(username: account.email, authCode: "code")
            ),
            db: db
        )
    }

    /// One request against the real route, returning status + decoded JSON.
    private func get(
        _ accountId: UUID,
        _ db: LagoonDB,
        _ provider: any MailProvider,
        remoteId: String = "m1"
    ) async throws -> (status: Int, images: [String: Data]?, errorCode: String?) {
        let router = Router<BasicRequestContext>()
        InlineImageRoutes.register(
            on: router, db: db, logger: self.logger, makeProvider: { _ in provider }
        )
        let app = Application(router: router)
        // The response lands in a box rather than in a captured `var`: the
        // client closure runs concurrently, and mutating a captured local
        // from it is an error in the Swift 6 language mode.
        let response = ResponseBox()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/messages/\(remoteId)/inline-images?accountId=\(accountId.uuidString)",
                method: .get
            ) { reply in
                response.set(
                    status: Int(reply.status.code),
                    body: Data(reply.body.readableBytesView)
                )
            }
        }
        struct ErrorEnvelope: Decodable { let error: String }
        let (status, body) = response.value()
        let errorCode = try? JSONDecoder().decode(ErrorEnvelope.self, from: body).error
        // Only a 200 carries the image map. Decoding an error envelope
        // would succeed (the type is lenient on purpose, for wire compat)
        // and turn `{"error":"…"}` into an empty map — which reads as
        // "no images" instead of "this failed".
        let decoded = status == 200
            ? try? JSONDecoder().decode(InlineImagesResponse.self, from: body)
            : nil
        return (status, decoded?.images, errorCode)
    }

    // MARK: - The one-round-trip contract

    /// The whole point: every inline image of the message comes back in one
    /// response, keyed by lower-cased Content-ID.
    ///
    /// Mutation check: make the route ask the provider once per attachment
    /// (the old behaviour) and the `fetchRawMessage` count below goes red.
    func test_oneRequestReturnsEveryInlineImage_withNoPerImageFetching() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let provider = InlineImageProvider(message: Self.relatedMessage())
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)

                let result = try await get(account.id, conn, provider)

                XCTAssertEqual(result.status, 200)
                // Lower-cased: the `cid:` in the HTML is compared
                // case-insensitively, and senders do not case it
                // consistently.
                XCTAssertEqual(result.images?["logo-cid-1"], Self.pngBytes)
                // One message read for the whole response. This is the
                // assertion that the N full-message IMAP fetches are gone.
                let reads = await provider.rawMessageReads
                XCTAssertEqual(reads, 1, "the message must be read once, not once per image")
            }
        }
    }

    /// An ordinary attachment is not an inline image and must not be in the
    /// response: its bytes would be payload the renderer never asks for.
    func test_aRegularAttachmentIsNotIncluded() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let provider = InlineImageProvider(message: Self.relatedMessage())
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)

                let result = try await get(account.id, conn, provider)

                XCTAssertEqual(result.status, 200)
                XCTAssertEqual(result.images?.count, 1, "only the inline image belongs here")
                let pdf = Data("%PDF-1.4".utf8)
                XCTAssertFalse(
                    result.images?.values.contains(pdf) ?? false,
                    "an attachment's bytes leaked into the inline-image response"
                )
            }
        }
    }

    /// A message with no inline images answers an empty map, not an error —
    /// the client treats "no images" as the normal case.
    func test_aMessageWithoutInlineImages_returnsAnEmptyMap() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let raw = """
            Content-Type: text/plain; charset=UTF-8

            just text, no pictures
            """.replacingOccurrences(of: "\n", with: "\r\n")
            let provider = InlineImageProvider(message: Data(raw.utf8))
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)

                let result = try await get(account.id, conn, provider)

                XCTAssertEqual(result.status, 200)
                XCTAssertEqual(result.images?.isEmpty, true)
            }
        }
    }

    /// The provider failing must answer the same 410/5xx mapping every other
    /// body-reading route uses — not a 200 with a half-filled map, which
    /// would tell the client "there are no images" when the truth is
    /// "we could not look".
    func test_aProviderFailure_isNotReportedAsNoImages() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let provider = InlineImageProvider(
                message: Data(),
                failure: .messageGone
            )
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)

                let result = try await get(account.id, conn, provider)

                XCTAssertEqual(result.status, 410)
                XCTAssertEqual(result.errorCode, "message-gone")
                XCTAssertNil(result.images)
            }
        }
    }

    /// An unknown account never reaches the provider.
    func test_anUnknownAccount_neverReachesTheProvider() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let provider = InlineImageProvider(message: Self.relatedMessage())
            try await TestDatabase.withConnection { conn in
                let result = try await get(UUID(), conn, provider)

                XCTAssertEqual(result.status, 404)
                XCTAssertEqual(result.errorCode, "unknown-account")
                let reads = await provider.rawMessageReads
                XCTAssertEqual(reads, 0)
            }
        }
    }
}

/// Carries the route's answer out of the concurrent client closure.
///
/// A plain captured `var` cannot be written from that closure — Swift 6
/// rejects the mutation, and before that it was simply a data race. The
/// lock is the smallest thing that is actually correct.
private final class ResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var status = 0
    private var body = Data()

    func set(status: Int, body: Data) {
        lock.lock()
        defer { lock.unlock() }
        self.status = status
        self.body = body
    }

    func value() -> (status: Int, body: Data) {
        lock.lock()
        defer { lock.unlock() }
        return (status, body)
    }
}

/// Scripted provider for the inline-image route: one fixed message, and a
/// count of how many times it was read.
private actor InlineImageProvider: MailProvider {
    let kind: MailProviderKind = .qq

    private let message: Data
    private let failure: MailError?
    /// How many times the message was read. The route's whole reason for
    /// existing is that this stays at 1 — so the tests assert on it.
    private(set) var rawMessageReads = 0

    init(message: Data, failure: MailError? = nil) {
        self.message = message
        self.failure = failure
    }

    func capabilities() async -> MailCapabilities? {
        MailCapabilities(archiveFolder: true, idle: true, move: true, serverSnippet: false)
    }

    func pullChanges(after cursor: MailSyncState, waitUpTo: Duration) async throws -> MailChangeSet {
        MailChangeSet(upserts: [], resetRequired: false, cursor: cursor)
    }

    func fetchBody(remoteId: String) async throws -> FetchedBody {
        throw MailError.notConfigured("the inline-image route must not use fetchBody")
    }

    func fetchAttachment(remoteId: String, attachmentId: String) async throws -> FetchedAttachmentBytes {
        throw MailError.notConfigured("the inline-image route must not read one part at a time")
    }

    func fetchRawMessage(remoteId: String) async throws -> Data {
        rawMessageReads += 1
        if let failure { throw failure }
        return message
    }

    func fetchRawHeaderValues(remoteId: String) async throws -> [String: String] { [:] }
    func setRead(remoteId: String, isRead: Bool) async throws {}
    func archive(remoteId: String) async throws {}
    func unarchive(remoteId: String) async throws {}
    func trash(remoteId: String) async throws {}
    func restoreFromTrash(remoteId: String) async throws {}
    func permanentlyDelete(remoteId: String) async throws {}
    func emptyTrash() async throws {}
    func send(_ outbound: OutboundMessage) async throws -> String? { nil }
    func listFolders() async throws -> [MailFolder] { [] }
    func move(remoteId: String, to folder: String, createIfMissing: Bool) async throws -> Bool { true }
    func listSent(limit: Int) async throws -> [MessageHeader] { [] }
    func probe() async throws {}
}
