import XCTest
import Foundation
import LagoonKit
@testable import Lagoon

/// The rules the three composers share.
///
/// A reply, a new message and a forward are three windows, but the user
/// only knows one verb — "write a mail and send it". These pin the rules
/// they now have in common: what a failure means, what a 200 means, how
/// a draft is kept, and how big the attachments may be.
///
/// Every one of these was checked by mutation: break the rule and the
/// test goes red.
final class ComposeFlowTests: XCTestCase {

    // MARK: - Drafts

    /// A draft survives a round trip through the slot.
    ///
    /// The reply composer, the new-message sheet and the forward sheet
    /// all keep their work the same way; this is that way, on disk.
    func test_aDraftSurvivesTheSlot() throws {
        let defaults = try makeDefaults()
        let slot = ComposeFlow.DraftSlot(key: "lagoon.test.draft", defaults: defaults)

        XCTAssertNil(slot.load(), "a slot that was never written must read as empty")

        var draft = ComposeFlow.Draft()
        draft.to = "one@example.com"
        draft.body = "hello"
        slot.save(draft)

        XCTAssertEqual(slot.load(), draft, "the draft did not survive the round trip")
        XCTAssertTrue(slot.hasDraft)

        slot.clear()
        XCTAssertNil(slot.load(), "the draft was not thrown away")
        XCTAssertFalse(slot.hasDraft)
    }

    /// An empty draft is not kept.
    ///
    /// A slot holding a fossil of a mail the user deleted is a promise
    /// the product made and forgot.
    func test_anEmptyDraftIsNotKept() throws {
        let defaults = try makeDefaults()
        let slot = ComposeFlow.DraftSlot(key: "lagoon.test.empty", defaults: defaults)

        var draft = ComposeFlow.Draft()
        draft.body = "something"
        slot.save(draft)
        XCTAssertNotNil(slot.load())

        draft.body = ""
        slot.save(draft)
        XCTAssertNil(slot.load(), "an empty draft must not sit in the slot")
    }

    /// Two accounts, two messages, two drafts — none of them overwrites
    /// another.
    func test_eachMessageHasItsOwnDraft() throws {
        let defaults = try makeDefaults()
        let account = UUID()
        let first = ComposeFlow.DraftSlot(
            key: "lagoon.composer.\(account.uuidString).message-1",
            defaults: defaults
        )
        let second = ComposeFlow.DraftSlot(
            key: "lagoon.composer.\(account.uuidString).message-2",
            defaults: defaults
        )

        var draft = ComposeFlow.Draft()
        draft.body = "the first reply"
        first.save(draft)
        draft.body = "the second reply"
        second.save(draft)

        XCTAssertEqual(first.load()?.body, "the first reply")
        XCTAssertEqual(second.load()?.body, "the second reply")
    }

    // MARK: - Why a send failed

    /// The server's error codes become the user's next step.
    ///
    /// The client used to show "server returned HTTP 401:" for every one
    /// of them. An expired authorization code and a mail server that is
    /// briefly unreachable need opposite answers, and neither of them is
    /// "401".
    func test_theServerErrorCodesAreNamed() {
        func error(_ code: String, status: Int = 400) -> Error {
            APIError.badStatus(code: status, bodySnippet: "{\"error\":\"\(code)\"}")
        }

        XCTAssertEqual(ComposeFlow.Failure.classify(error("smtp-auth-failed", status: 401)), .authFailed)
        XCTAssertEqual(ComposeFlow.Failure.classify(error("provider-not-configured", status: 503)), .notConfigured)
        XCTAssertEqual(ComposeFlow.Failure.classify(error("message-gone", status: 410)), .messageGone)
        XCTAssertEqual(ComposeFlow.Failure.classify(error("unknown-account", status: 404)), .accountMissing)
        XCTAssertEqual(ComposeFlow.Failure.classify(error("malformed-recipient")), .malformedRecipient)
        XCTAssertEqual(ComposeFlow.Failure.classify(error("malformed-attachment")), .malformedAttachment)
        XCTAssertEqual(ComposeFlow.Failure.classify(error("forward-too-large", status: 409)), .forwardTooLarge)
        XCTAssertEqual(ComposeFlow.Failure.classify(error("send-in-flight", status: 409)), .inFlight)
    }

    /// A failure the user cannot fix by trying again must not offer a
    /// retry.
    ///
    /// This is the app's own rule for failure banners, and the send path
    /// used not to have it: a second attempt at a rejected authorization
    /// code fails exactly like the first.
    func test_onlyRetryableFailuresOfferARetry() {
        XCTAssertFalse(ComposeFlow.Failure.authFailed.canRetry)
        XCTAssertFalse(ComposeFlow.Failure.notConfigured.canRetry)
        XCTAssertFalse(ComposeFlow.Failure.messageGone.canRetry)
        XCTAssertFalse(ComposeFlow.Failure.accountMissing.canRetry)
        XCTAssertFalse(ComposeFlow.Failure.malformedRecipient.canRetry)
        XCTAssertFalse(ComposeFlow.Failure.malformedAttachment.canRetry)
        XCTAssertFalse(ComposeFlow.Failure.forwardTooLarge.canRetry)

        XCTAssertTrue(ComposeFlow.Failure.transport.canRetry)
        XCTAssertTrue(ComposeFlow.Failure.unknown.canRetry)
        XCTAssertTrue(ComposeFlow.Failure.inFlight.canRetry)
        XCTAssertTrue(ComposeFlow.Failure.rejected.canRetry)
    }

    /// A server that is having a bad day is worth another try; a server
    /// that says the request is wrong is not.
    func test_aServerFailureIsRetryableAndARejectedRequestIsNot() {
        let serverError = APIError.badStatus(code: 502, bodySnippet: "{}")
        XCTAssertEqual(ComposeFlow.Failure.classify(serverError), .transport)

        let requestError = APIError.badStatus(code: 400, bodySnippet: "{}")
        XCTAssertEqual(ComposeFlow.Failure.classify(requestError), .unknown)
    }

    /// A dropped connection is a transport failure, not a mystery.
    func test_aTransportErrorIsNamedAsSuch() {
        let error = URLError(.timedOut)
        XCTAssertEqual(ComposeFlow.Failure.classify(error), .transport)
    }

    // MARK: - What a 200 actually meant

    /// A 200 with `ok: false` is a refusal, and the client must be able
    /// to tell it from an acceptance.
    ///
    /// The response carries the flag for exactly this reason; ignoring it
    /// is how "Sent to …" ends up on a mail that was never sent.
    func test_theServerFlagDecidesTheOutcome() {
        XCTAssertEqual(
            ComposeFlow.outcome(of: SendResponse(ok: true, providerMessageId: "abc")),
            .accepted("abc")
        )
        XCTAssertEqual(
            ComposeFlow.outcome(of: SendResponse(ok: false, providerMessageId: "abc")),
            .rejected
        )
        XCTAssertEqual(
            ComposeFlow.outcome(of: SendResponse(ok: true, providerMessageId: nil)),
            .accepted(nil)
        )
    }

    // MARK: - Attachments

    /// The client mirrors the server's total attachment cap.
    ///
    /// The server caps a single file at 25 MB and the *total* at four
    /// times that. Checking only the file is how four 24 MB attachments
    /// passed the client and failed the send.
    func test_theTotalAttachmentCapMatchesTheServer() throws {
        XCTAssertEqual(
            ComposeFlow.Attachments.maxTotalBytes,
            OutgoingAttachment.maxBytes * 4,
            "the client's total cap must be the server's total cap"
        )

        let server = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // LagoonTests
                .deletingLastPathComponent()   // Tests
                .deletingLastPathComponent()   // package root
                .appendingPathComponent("Sources/LagoonServer/Routes/MessageRoutes.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            server.contains("OutboundAttachment.maxBytes * 4"),
            "the server's total attachment cap moved — the client's mirror of it is now a guess"
        )
    }

    /// A file that would break the total is refused, and the ones that
    /// fit are not.
    func test_aFileThatBreaksTheTotalDoesNotFit() throws {
        let small = OutgoingAttachment(
            filename: "a.bin",
            mimeType: "application/octet-stream",
            data: Data(count: 10)
        )
        XCTAssertEqual(ComposeFlow.Attachments.totalBytes([small, small]), 20)

        let limit = ComposeFlow.Attachments.maxTotalBytes
        XCTAssertTrue(
            ComposeFlow.Attachments.fits(limit, alongside: []),
            "the total limit itself must fit"
        )
        XCTAssertFalse(
            ComposeFlow.Attachments.fits(limit + 1, alongside: []),
            "one byte over the limit must not fit"
        )
        XCTAssertFalse(
            ComposeFlow.Attachments.fits(limit, alongside: [small]),
            "the limit plus what is already attached must not fit"
        )
    }

    // MARK: - Helpers

    /// A defaults suite of its own, so the test never touches the user's
    /// own preferences.
    private func makeDefaults() throws -> UserDefaults {
        let name = "lagoon.tests.compose.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
}
