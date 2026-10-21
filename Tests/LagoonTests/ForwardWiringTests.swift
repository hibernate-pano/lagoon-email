import XCTest
import Foundation
import LagoonKit
@testable import Lagoon

/// The forward must be a **real** forward.
///
/// ## Why source, and why *attachment*
///
/// The old forward was a quoted block of `>` characters, pasted into the
/// new-message sheet. It *looked* like a forward and was not one: the
/// recipient got no formatting, no attachments, no headers.
///
/// The observable behaviour lives on the server (`ForwardTests` proves
/// the `message/rfc822` part and the route). What these pin is the
/// **wiring** — the client must actually ask the server to forward, and
/// must not build the original itself.
///
/// Every one of these was checked by mutation: remove the wiring and the
/// test goes red.
final class ForwardWiringTests: XCTestCase {

    /// The detail view must open the forward sheet, and the sheet must
    /// name the message being forwarded.
    func test_theDetailViewOpensTheForwardSheet() throws {
        let source = try ViewSource.read("MessageDetailView")
        XCTAssertTrue(
            source.contains("ForwardSheet("),
            "the detail view does not open the forward sheet"
        )
        let sheetStart = try XCTUnwrap(
            source.range(of: "ForwardSheet("),
            "the forward sheet is never presented"
        )
        let sheet = ViewSource.code(after: sheetStart.lowerBound, in: source, limit: 400)
        XCTAssertTrue(
            sheet.contains("remoteId:"),
            "the sheet must name the mail — a forward of the wrong message is worse than none"
        )
    }

    /// The old quoted-forward code must be **gone**.
    ///
    /// A leftover `formatForwardBody` would be a second, wrong forward
    /// implementation — the kind of thing that stays in a file for a year
    /// and gets used again by someone who does not know what it does.
    func test_theQuotedForwardIsGone() throws {
        let source = try ViewSource.read("MessageDetailView")
        XCTAssertFalse(
            source.contains("formatForwardBody"),
            "the quoted forward is still here — the recipient gets `>` characters instead of the original"
        )
        XCTAssertFalse(
            source.contains("Forwarded message ----------"),
            "the quoted-forward header block is still here"
        )
    }

    /// The client must ask the server to forward.
    ///
    /// The original's bytes live on the server; the client has a *parse* of
    /// it, and a message reassembled from a parse is a guess.
    func test_theClientAsksTheServerToForward() throws {
        let source = try String(
            contentsOf: ViewSource.url(under: "Services", "APIClient"),
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains("func forwardMessage("),
            "the API client has no forward method"
        )
        let start = try XCTUnwrap(
            source.range(of: "func forwardMessage("),
            "the forward method is gone"
        )
        let body = ViewSource.code(after: start.lowerBound, in: source, limit: 1400)
        XCTAssertTrue(
            body.contains("\"forward\""),
            "the forward must go to the forward route, not to the compose route"
        )
        XCTAssertTrue(
            body.contains("remoteId"),
            "the forward must name the message"
        )
    }

    /// The forward sheet must not quote the original into the body.
    ///
    /// The whole point is that the original travels as itself.
    func test_theForwardSheetDoesNotQuoteTheOriginal() throws {
        let source = try ViewSource.read("ForwardSheet")
        XCTAssertFalse(
            source.contains("Forwarded message ----------"),
            "the forward sheet still builds a quoted block"
        )
        XCTAssertTrue(
            source.contains("api.forwardMessage("),
            "the forward sheet does not send the forward"
        )
    }

    /// The sheet must say what happens to the original.
    ///
    /// The old forward looked like a forward and was not one, and the user
    /// had no way to tell. The sheet now says that the original travels
    /// as the original, with its attachments.
    func test_theSheetTellsTheUserTheOriginalComesAlong() throws {
        let l10n = try String(
            contentsOf: ViewSource.url(under: "Localization", "L10n"),
            encoding: .utf8
        )
        let declaration = try XCTUnwrap(
            l10n.range(of: "public var forwardKeepsOriginal: String"),
            "the forward explanation line is gone"
        )
        let line = l10n[declaration.lowerBound...].prefix(300)
        XCTAssertTrue(
            line.contains("附件"),
            "the sheet must say the original's attachments come along — that is what the old forward lost"
        )
    }

    /// The subject gets exactly one "Fwd:".
    func test_theSeededSubjectHasOneFwdPrefix() {
        XCTAssertEqual(ForwardSheet.forwardSubject("原始主题"), "Fwd: 原始主题")
        XCTAssertEqual(
            ForwardSheet.forwardSubject("Fwd: 原始主题"),
            "Fwd: 原始主题",
            "an already-forwarded subject must not get a second prefix"
        )
        XCTAssertEqual(ForwardSheet.forwardSubject(nil), "Fwd:")
    }
}
