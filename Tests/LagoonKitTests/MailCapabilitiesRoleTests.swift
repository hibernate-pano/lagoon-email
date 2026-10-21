import XCTest
@testable import LagoonKit

/// P2-10: `MailCapabilities` only modelled four capabilities, so the client
/// could not know — before the click — that a server lacked UIDPLUS or a
/// Sent/Trash folder. It learned by clicking and getting a 409.
///
/// ## The part that is easy to get wrong
///
/// The new fields are `Bool?`, not `Bool`, and that is not a stylistic
/// choice. A capability row written before these fields existed decodes
/// with them **absent**. If "absent" meant "not supported", every account
/// that connected before the upgrade would have lost delete — with no way
/// for the user to get it back, because the gate would refuse before the
/// request that could have proved otherwise.
///
/// So the three states have to stay distinct:
///
/// * `true` — the server said it can.
/// * `false` — the server said it cannot.
/// * `nil` — nobody asked yet.
///
/// These tests pin that distinction, because it is the one that silently
/// destroys data when it collapses.
final class MailCapabilitiesRoleTests: XCTestCase {
    // MARK: - The three states stay distinct

    /// A legacy payload (no new keys at all) must decode to "not
    /// determined", never to "not supported".
    func test_aLegacyPayloadDecodesToUnknownNotToFalse() throws {
        let legacy = #"{"archiveFolder":true,"idle":true,"move":true,"serverSnippet":true}"#
        let decoded = try JSONDecoder().decode(MailCapabilities.self, from: Data(legacy.utf8))

        XCTAssertNil(decoded.uidplus, "absent must mean 'not determined'")
        XCTAssertNil(decoded.sentFolder, "absent must mean 'not determined'")
        XCTAssertNil(decoded.trashFolder, "absent must mean 'not determined'")
        XCTAssertNil(decoded.archiveFolderName, "absent must mean 'not determined'")
        // The fields that were always present keep their values.
        XCTAssertEqual(decoded.archiveFolder, true)
        XCTAssertTrue(decoded.idle)
    }

    /// An empty object must decode, not throw — and `archiveFolder` must come
    /// out **`nil`, not `false`**.
    ///
    /// A stored `{}` is a real row shape (the pre-008 default), and a decode
    /// failure there would take the whole account list down. The `nil` is the
    /// other half: `false` is a settled "this server cannot archive", and a
    /// row that was never negotiated has not earned that verdict. This is the
    /// exact shape that turned a missing account row into a permanently
    /// disabled archive button.
    func test_anEmptyObjectDecodesWithoutThrowingAndWithoutInventingAVerdict() throws {
        let decoded = try JSONDecoder().decode(MailCapabilities.self, from: Data("{}".utf8))
        XCTAssertNil(decoded.archiveFolder, "never negotiated must decode as 'not determined'")
        XCTAssertNil(decoded.uidplus)
        XCTAssertNil(decoded.trashFolder)
        XCTAssertTrue(decoded.allowsArchive, "an unnegotiated row must not lose archive")
    }

    /// The full round trip preserves every field.
    func test_theRoundTripPreservesEveryRole() throws {
        let original = MailCapabilities(
            archiveFolder: true, idle: true, move: false, serverSnippet: true,
            uidplus: false, sentFolder: true, trashFolder: false,
            archiveFolderName: "Archive"
        )
        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(MailCapabilities.self, from: data)

        XCTAssertEqual(original, back)
        XCTAssertEqual(back.archiveFolderName, "Archive")
        XCTAssertEqual(back.uidplus, false)
        XCTAssertEqual(back.trashFolder, false)
    }

    // MARK: - The gates the client reads

    /// "Not determined" must read as *allowed*.
    ///
    /// This is the load-bearing assertion of the whole item. The server is
    /// the authority: it resolves the trash folder at request time and
    /// answers 409 when the folder really is missing. A client that
    /// refused on a stale or absent answer would be stricter than the
    /// server, and a user locked out of delete by a cached guess has no way
    /// to appeal the guess.
    func test_unknownMeansAllowedSoAnOldAccountDoesNotLoseDelete() {
        let unknown = MailCapabilities(
            archiveFolder: true, idle: true, move: true, serverSnippet: true
        )
        XCTAssertTrue(unknown.allowsDelete, "an unprobed account must not lose delete")
        XCTAssertTrue(unknown.allowsPurge, "an unprobed account must not lose 彻底删除")
        XCTAssertTrue(unknown.allowsSent, "an unprobed account must not lose 已发送")
    }

    /// A settled "no" must actually close the gate.
    func test_aSettledNoClosesTheGate() {
        let noTrash = MailCapabilities(
            archiveFolder: true, idle: true, move: true, serverSnippet: true,
            uidplus: true, sentFolder: true, trashFolder: false
        )
        XCTAssertFalse(noTrash.allowsDelete, "no trash folder means no delete")
        XCTAssertTrue(noTrash.allowsPurge, "UIDPLUS is a separate question from the trash folder")
        XCTAssertTrue(noTrash.allowsSent)

        let noUIDPlus = MailCapabilities(
            archiveFolder: true, idle: true, move: true, serverSnippet: true,
            uidplus: false, sentFolder: true, trashFolder: true
        )
        XCTAssertFalse(noUIDPlus.allowsPurge, "no UIDPLUS means no 彻底删除")
        XCTAssertTrue(noUIDPlus.allowsDelete, "the trash folder is a separate question")

        let noSent = MailCapabilities(
            archiveFolder: true, idle: true, move: true, serverSnippet: true,
            uidplus: true, sentFolder: false, trashFolder: true
        )
        XCTAssertFalse(noSent.allowsSent, "no Sent folder means no 已发送")
    }

    /// The archive gate is three-state too: a settled "no" closes it, and
    /// "not determined" does not.
    ///
    /// `archiveFolder` used to be a plain `Bool`, on the theory that a
    /// `false` was always a settled verdict (Lagoon *creates* the folder when
    /// the server has none). The theory missed the case that actually
    /// happened: an account row that could not be found was never negotiated,
    /// kept the all-false default, and every archive — down to `bulk archive`
    /// — was refused with `409 archive-unavailable`. The user was told their
    /// server could not archive when nobody had ever asked it.
    func test_theArchiveGateIsThreeState() {
        let settledNo = MailCapabilities(
            archiveFolder: false, idle: true, move: true, serverSnippet: true
        )
        XCTAssertFalse(settledNo.allowsArchive, "a probe that could not create the folder is a no")
        XCTAssertTrue(settledNo.allowsDelete, "the archive verdict says nothing about the trash")

        let notDetermined = MailCapabilities(
            archiveFolder: nil, idle: true, move: true, serverSnippet: true
        )
        XCTAssertTrue(
            notDetermined.allowsArchive,
            "an account nobody has probed must not lose archive — the server is the authority"
        )
        XCTAssertTrue(
            MailCapabilities.unknown.allowsArchive,
            "the default record must not switch archive off"
        )
    }
}
