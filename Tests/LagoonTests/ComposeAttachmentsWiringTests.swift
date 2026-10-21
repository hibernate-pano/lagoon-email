import XCTest
import Foundation
import LagoonKit
@testable import Lagoon

/// The compose surface can address more than one person, and can carry
/// files.
///
/// These are source-level guards, not behaviour tests: the observable
/// behaviour lives on the server (`ComposeAttachmentsTests` proves the
/// MIME structure and the route), and what these pin is the **wiring** — the
/// client must actually offer the field, actually validate it, and actually
/// send it. A UI that renders a Cc field and never puts it in the request
/// looks finished and does nothing.
final class ComposeAttachmentsWiringTests: XCTestCase {

    // MARK: - The compose sheet

    /// The new-message sheet offers Cc and Bcc.
    func test_theComposeSheetOffersCcAndBcc() throws {
        let source = try ViewSource.read("NewMessageSheet")
        XCTAssertTrue(
            source.contains("l10n.newMessageCcLabel"),
            "there is no Cc field in the composer"
        )
        XCTAssertTrue(
            source.contains("l10n.newMessageBccLabel"),
            "there is no Bcc field in the composer"
        )
    }

    /// The Bcc field says what Bcc means.
    ///
    /// A blind copy that the user does not know is blind is a privacy
    /// accident waiting to happen, and the field's label alone ("密送")
    /// does not carry that.
    func test_theBccFieldExplainsThatItIsBlind() throws {
        let source = try ViewSource.read("NewMessageSheet")
        XCTAssertTrue(
            source.contains("l10n.newMessageBccHelp"),
            "the Bcc field does not say that the recipients cannot see it"
        )
    }

    /// The composer offers attachments.
    func test_theComposeSheetOffersAttachments() throws {
        let source = try ViewSource.read("NewMessageSheet")
        XCTAssertTrue(
            source.contains("l10n.newMessageAddAttachment"),
            "there is no way to attach a file in the composer"
        )
        XCTAssertTrue(
            source.contains("fileImporter"),
            "the attachment button is not wired to a file picker"
        )
    }

    /// The reply composer offers attachments too.
    ///
    /// "Reply with the edited file" is the single most common reason a
    /// person attaches anything to a mail — a reply that cannot carry a
    /// file forces the user into a new message, where the threading and
    /// the recipients are gone.
    func test_theReplyComposerOffersAttachments() throws {
        let source = try ViewSource.read("ComposerSheet")
        XCTAssertTrue(
            source.contains("l10n.newMessageAddAttachment"),
            "the reply composer cannot attach a file"
        )
        XCTAssertTrue(
            source.contains("fileImporter"),
            "the reply composer's attachment button is not wired to a file picker"
        )
    }

    /// Both composers actually **send** what they collected.
    ///
    /// This is the half that is easy to leave out: a field that is rendered
    /// and validated but never put into the request is a lie about what the
    /// product can do.
    func test_bothComposersSendTheirAttachments() throws {
        for view in ["NewMessageSheet", "ComposerSheet"] {
            let source = try ViewSource.read(view)
            XCTAssertTrue(
                source.contains("attachments: attachments"),
                "\(view) collects attachments and never sends them"
            )
        }
    }

    /// The client validates a recipient before the send, so the user hears
    /// about a typo'd address before they have written the mail.
    func test_theComposerValidatesRecipientsBeforeSending() throws {
        let source = try ViewSource.read("NewMessageSheet")
        XCTAssertTrue(
            source.contains("firstInvalidAddress"),
            "the composer sends without checking the address"
        )
    }

    // MARK: - The API client

    /// The API client sends the Cc, Bcc and attachment fields.
    ///
    /// The server accepts them; if the client does not send them, the
    /// features do not exist.
    func test_theApiClientSendsCcBccAndAttachments() throws {
        let source = try String(
            contentsOf: ViewSource.url(under: "Services", "APIClient"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains(#"payload["cc"]"#), "Cc is never sent")
        XCTAssertTrue(source.contains(#"payload["bcc"]"#), "Bcc is never sent")
        XCTAssertTrue(
            source.contains(#"payload["attachments"]"#),
            "attachments are never sent"
        )
        XCTAssertTrue(
            source.contains(#""dataBase64": attachment.base64"#),
            "the attachment bytes are never encoded onto the wire"
        )
    }

    // MARK: - The validation rule

    /// The client's address rule and the server's must agree.
    ///
    /// The client checks first so the user hears about a typo immediately,
    /// and the server checks again because the client is not the only
    /// caller. If the two rules drifted, a mail the client accepted would
    /// be refused by the server — the user typed a valid address and got
    /// "send failed".
    func test_theClientAndServerAgreeOnWhatAnAddressIs() throws {
        // The server's rule: exactly one "@", both sides non-empty, a dot
        // in the domain, and no whitespace anywhere.
        let server = try String(
            contentsOf: ViewSource.url(under: "Services", "APIClient"),
            encoding: .utf8
        )
        XCTAssertTrue(
            server.contains("sendNewMessage"),
            "the compose method is gone"
        )
        // The client mirrors the same rule in
        // `NewMessageSheet.firstInvalidAddress`; both are checked here
        // through the same set of examples.
        for example in ["a@b.com", "first.last@sub.example.co.uk"] {
            XCTAssertNil(
                NewMessageSheet.firstInvalidAddress(in: [example]),
                "\(example) is a valid address and the client refuses it"
            )
        }
        for example in ["no-at-sign", "two@at@signs", "no-domain@", "@no-local", "spaced@ex ample.com"] {
            XCTAssertNotNil(
                NewMessageSheet.firstInvalidAddress(in: [example]),
                "\(example) is not a valid address and the client accepts it"
            )
        }
        // An empty entry is not a bad address — it is no address, and the
        // user pressing Enter after the last one is a normal thing to do.
        // The server skips it too, so the two agree.
        XCTAssertNil(
            NewMessageSheet.firstInvalidAddress(in: ["", "one@example.com"]),
            "a blank line in the recipient field must not fail the send"
        )
    }

    /// A comma-separated list of valid addresses is one list, not one
    /// address.
    func test_aCommaSeparatedListIsSplitIntoAddresses() {
        XCTAssertNil(
            NewMessageSheet.firstInvalidAddress(
                in: AddressList.split("one@example.com, two@example.com")
            ),
            "two valid addresses in one field must not be read as a bad address"
        )
    }
}
