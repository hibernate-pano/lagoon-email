import XCTest
import Foundation
import Logging
import Hummingbird
import NIOCore
import GRDB
@testable import LagoonKit
@testable import LagoonServer

/// `GET /api/messages/{remoteId}/attachments/{attachmentId}` — the attachment
/// download route, end to end.
///
/// ## Why this file exists (Q-02 in docs/全方位审查报告-2026-10-16.md)
///
/// This was the only public API with **zero route-level tests**, and the
/// damage was not theoretical: the too-large branch answered 500 behind a
/// comment claiming Hummingbird exposed no named 413 case — the dependency
/// chain says otherwise (`HTTPResponse.Status.contentTooLarge` = 413), so the
/// client was told "the server broke" for a condition no retry can fix.
///
/// These tests pin the four observable contracts against the real route and
/// the real error mapping, with a stub provider on the existing
/// `makeProvider` seam:
///
/// 1. **200** — the exact bytes, plus Content-Type / Content-Length /
///    Content-Disposition (single-encoded `filename*` for UTF-8 names; quotes
///    and CR/LF stripped, never escaped — a header split here would let a
///    message name its own response headers);
/// 2. **404** `attachment-not-found`;
/// 3. **413** `attachment-too-large` (mutation check: reverting to
///    `.internalServerError` turns this red);
/// 4. an unknown account never reaches the provider.
final class AttachmentDownloadTests: XCTestCase {
    private let logger = Logger(label: "attachment-download-tests")

    private func makeAccount() -> Account {
        Account(
            id: UUID(),
            provider: .qq,
            oauthUser: "att-\(UUID().uuidString)",
            email: "att-\(UUID().uuidString)@qq.com",
            credentials: nil,
            capabilities: MailCapabilities(
                archiveFolder: true, idle: true, move: true, serverSnippet: false
            )
        )
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

    /// One download against the real route, capturing the full observable
    /// response: status, the three metadata headers, raw bytes, and the JSON
    /// error code when the body carries one.
    private func download(
        _ accountId: UUID,
        _ db: LagoonDB,
        _ provider: any MailProvider,
        remoteId: String = "m1",
        attachmentId: String = "a1"
    ) async throws -> (
        status: Int, contentType: String?, contentLength: String?,
        disposition: String?, body: Data, errorCode: String?
    ) {
        let router = Router<BasicRequestContext>()
        MessageRoutes.register(
            on: router, db: db, logger: self.logger, makeProvider: { _ in provider }
        )
        let app = Application(router: router)
        var status = 0
        var contentType: String?
        var contentLength: String?
        var disposition: String?
        var body = Data()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/messages/\(remoteId)/attachments/\(attachmentId)?accountId=\(accountId.uuidString)",
                method: .get
            ) { response in
                status = Int(response.status.code)
                contentType = response.headers[.contentType]
                contentLength = response.headers[.contentLength]
                disposition = response.headers[.contentDisposition]
                body = Data(response.body.readableBytesView)
            }
        }
        struct ErrorEnvelope: Decodable { let error: String }
        let errorCode = try? JSONDecoder().decode(ErrorEnvelope.self, from: body).error
        return (status, contentType, contentLength, disposition, body, errorCode)
    }

    /// The 200 path: exact bytes (no re-encode) and the metadata headers the
    /// client needs to save the file under the right name and type.
    func test_download_servesTheExactBytesWithMetadataHeaders() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let provider = StubMailProvider()
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                let pdf = Data("%PDF-1.4 lagoon attachment".utf8)
                await provider.setAttachmentResult(.success(FetchedAttachmentBytes(
                    mimeType: "application/pdf", filename: "report.pdf", data: pdf
                )))

                let result = try await download(account.id, conn, provider)
                XCTAssertEqual(result.status, 200)
                XCTAssertEqual(result.contentType, "application/pdf")
                XCTAssertEqual(result.contentLength, String(pdf.count))
                XCTAssertEqual(result.body, pdf, "the body must be the bytes, not a re-encode")
                XCTAssertEqual(
                    result.disposition,
                    "attachment; filename=\"report.pdf\"; filename*=UTF-8''report.pdf"
                )

                let calls = await provider.attachmentCalls
                XCTAssertEqual(calls.count, 1, "exactly one provider fetch per request")
                XCTAssertEqual(calls.first?.remoteId, "m1")
                XCTAssertEqual(calls.first?.attachmentId, "a1")
            }
        }
    }

    /// A UTF-8 filename is percent-encoded **exactly once** in `filename*`.
    ///
    /// Double-encoding (`%25E6…`) is the historical bug this asserts against:
    /// the save dialog offered the encoded text as the literal file name.
    func test_download_utf8Filename_isEncodedExactlyOnce() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let provider = StubMailProvider()
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                await provider.setAttachmentResult(.success(FetchedAttachmentBytes(
                    mimeType: "application/octet-stream",
                    filename: "报告.pdf",
                    data: Data([0x00, 0x01, 0x02])
                )))

                let result = try await download(account.id, conn, provider)
                XCTAssertEqual(result.status, 200)
                XCTAssertEqual(
                    result.disposition,
                    "attachment; filename=\"报告.pdf\"; filename*=UTF-8''%E6%8A%A5%E5%91%8A.pdf"
                )
                XCTAssertFalse(
                    result.disposition?.contains("%25") ?? true,
                    "filename* is double-encoded — the save dialog will offer percent text as the name"
                )
            }
        }
    }

    /// Quotes and CR/LF are *stripped* from the filename, not escaped.
    ///
    /// The name is attacker-supplied text going into a response header; a
    /// header split here would let a message name its own headers.
    func test_download_stripsQuotesAndNewlinesFromTheFilename() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let provider = StubMailProvider()
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                await provider.setAttachmentResult(.success(FetchedAttachmentBytes(
                    mimeType: "application/octet-stream",
                    filename: "e\"vil\r\nfile.pdf",
                    data: Data([0xAA])
                )))

                let result = try await download(account.id, conn, provider)
                XCTAssertEqual(result.status, 200)
                XCTAssertEqual(
                    result.disposition,
                    "attachment; filename=\"evilfile.pdf\"; filename*=UTF-8''evilfile.pdf"
                )
                XCTAssertFalse(result.disposition?.contains("\r") ?? true)
                XCTAssertFalse(result.disposition?.contains("\n") ?? true)
            }
        }
    }

    /// An attachment the provider cannot find is a 404 with the machine
    /// code the client branches on — not a 500.
    func test_download_attachmentNotFound_is404() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let provider = StubMailProvider()
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                // Default provider state: .failure(.notFound).

                let result = try await download(account.id, conn, provider)
                XCTAssertEqual(result.status, 404)
                XCTAssertEqual(result.errorCode, "attachment-not-found")
            }
        }
    }

    /// Too large is **413** — the documented size contract, not a server
    /// fault. This is the assertion that failed against the old mapping:
    /// `.internalServerError` answered 500 behind a comment claiming the
    /// named case did not exist.
    func test_download_tooLarge_is413() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let provider = StubMailProvider()
            let account = makeAccount()
            try await TestDatabase.withConnection { conn in
                try await seed(account, db: conn)
                await provider.setAttachmentResult(.failure(.tooLarge))

                let result = try await download(account.id, conn, provider)
                XCTAssertEqual(
                    result.status, 413,
                    "a size limit must not masquerade as a server fault; 413 is the contract"
                )
                XCTAssertEqual(result.errorCode, "attachment-too-large")
            }
        }
    }

    /// An unknown account is 404 and never reaches the provider.
    func test_download_unknownAccount_is404WithoutProviderCall() async throws {
        try await TokenKeyFixture.withKeyAsync(TokenKeyFixture.freshKey()) {
            let provider = StubMailProvider()
            try await TestDatabase.withConnection { conn in
                let ghost = UUID()
                let result = try await download(ghost, conn, provider)
                XCTAssertEqual(result.status, 404)
                let calls = await provider.attachmentCalls
                XCTAssertTrue(calls.isEmpty, "a 404 must not reach the provider")
            }
        }
    }
}
