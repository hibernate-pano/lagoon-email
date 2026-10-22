import XCTest
import Foundation
import LagoonKit
@testable import Lagoon

/// The compose surface must not say things it does not do.
///
/// The three composers are the only place in the product where the user
/// hands over something irreversible — a mail that leaves. A button that
/// says "send" and opens a composer, a promise that the draft is kept
/// when nothing can get it back, a failure that says "HTTP 401" and
/// nothing else: each of those is a lie told at the exact moment the
/// user is about to trust the product.
///
/// These are source-level guards. What they pin is the *wiring* — that
/// the sheet renders the promise, and that the promise is the one the
/// code keeps. Every one of them was checked by mutation: break the
/// thing and the test goes red.
final class ComposeSheetHonestyTests: XCTestCase {

    /// The three sheets that write mail.
    private static let composers = ["ComposerSheet", "NewMessageSheet", "ForwardSheet"]

    // MARK: - S-01 · The draft picker does not send

    /// The button that takes an AI variant into the composer must not
    /// claim to send it.
    ///
    /// It used to read 「选这个 → 发送」, and choosing a variant opens the
    /// reply composer with that text in it. A button that says "send" and
    /// does not send teaches the user that this app's buttons lie.
    func test_theDraftPickerButtonDoesNotPromiseASend() throws {
        let source = try ViewSource.read("DraftPickerSheet")
        XCTAssertFalse(
            source.contains("chooseAndSend"),
            "the old key is back: the button promises a send it does not do"
        )
        XCTAssertTrue(
            source.contains("l10n.useDraftVariant"),
            "the button does not use the honest label"
        )
        for language in AppLanguage.allCases {
            let label = L10n(language: language).useDraftVariant
            XCTAssertFalse(
                label.contains("发送") || label.lowercased().contains("send"),
                "the button label still promises a send: \(label)"
            )
        }
    }

    /// The sheet says what choosing a variant does.
    func test_theDraftPickerSaysWhatChoosingDoes() throws {
        let source = try ViewSource.read("DraftPickerSheet")
        XCTAssertTrue(
            source.contains("l10n.useDraftVariantHelp"),
            "the sheet does not say that the variant lands in the composer"
        )
        XCTAssertFalse(
            source.contains("api."),
            "the draft picker must not send anything on its own"
        )
    }

    // MARK: - S-02 · The draft is kept, and it can be got back

    /// The reply draft comes back when the composer is opened again.
    ///
    /// The quoted original used to win over the saved draft, so the reply
    /// a user typed was shadowed by the mail they were replying to: the
    /// draft was written and never read.
    func test_theReplyDraftIsRestoredInsteadOfTheQuotedOriginal() {
        XCTAssertEqual(
            ComposerSheet.restoredBody(
                initialBody: "",
                saved: "my reply",
                quotedText: "the original"
            ),
            "my reply",
            "the saved draft must win over the quoted original"
        )
        XCTAssertEqual(
            ComposerSheet.restoredBody(
                initialBody: "",
                saved: "",
                quotedText: "the original"
            ),
            ComposerSheet.formatQuotedReply("the original"),
            "with nothing saved, the composer shows the quote"
        )
        XCTAssertEqual(
            ComposerSheet.restoredBody(
                initialBody: "the AI variant",
                saved: "my reply",
                quotedText: "the original"
            ),
            "the AI variant",
            "a variant the user just picked wins over everything"
        )
    }

    /// The quoted original is not a draft.
    ///
    /// The body starts out holding the quote, and a slot that holds only
    /// the quote must not be announced as "your last draft was
    /// restored".
    func test_theQuoteIsNotADraft() {
        let quoted = ComposerSheet.formatQuotedReply("the original")
        XCTAssertFalse(
            ComposerSheet.isUserDraft(saved: quoted, quotedText: "the original"),
            "the quote was announced as a restored draft"
        )
        XCTAssertTrue(
            ComposerSheet.isUserDraft(saved: quoted + "\n\nmy reply", quotedText: "the original"),
            "a draft the user wrote must be recognised as one"
        )
        XCTAssertFalse(
            ComposerSheet.isUserDraft(saved: "", quotedText: "the original")
        )
    }

    /// The new-message sheet shows that the draft was saved.
    ///
    /// It used to carry the sentence 「草稿会自动保存」 and nothing else —
    /// a promise with no proof next to it, while the reply composer
    /// showed a live tick.
    func test_theNewMessageSheetShowsThatTheDraftWasSaved() throws {
        let source = try ViewSource.read("NewMessageSheet")
        XCTAssertTrue(
            source.contains("draftJustSaved"),
            "the new-message sheet has no live save indicator"
        )
        XCTAssertTrue(
            source.contains("l10n.draftSavedNow"),
            "the new-message sheet never says the draft was saved"
        )
    }

    /// All three composers write their draft somewhere, and all three
    /// flush it when the sheet closes.
    func test_everyComposerKeepsItsDraft() throws {
        for view in Self.composers {
            let source = try ViewSource.read(view)
            XCTAssertTrue(
                source.contains("draftSlot.save("),
                "\(view) never writes its draft"
            )
            let disappear = try XCTUnwrap(
                body(of: source, startingAt: ".onDisappear"),
                "\(view) has no teardown flush"
            )
            XCTAssertTrue(
                disappear.contains("writeDraft("),
                "\(view) closes without flushing the draft it was holding"
            )
        }
    }

    // MARK: - S-03 · A failure says what failed, and can be retried

    /// Every composer names the cause and offers a retry where a retry
    /// can work.
    func test_everyComposerOffersARetryWhereOneCanWork() throws {
        for view in Self.composers {
            let source = try ViewSource.read(view)
            XCTAssertTrue(
                source.contains("sendFailure"),
                "\(view) does not remember why the send failed"
            )
            XCTAssertTrue(
                source.contains("canRetry"),
                "\(view) does not decide whether a retry can help"
            )
            let retry = try XCTUnwrap(
                body(of: source, startingAt: "Button(l10n.retry)"),
                "\(view) offers no retry"
            )
            XCTAssertTrue(
                retry.contains("await send()"),
                "\(view)'s retry button does not send again"
            )
        }
    }

    /// A retry reuses the same request id, so it cannot send twice.
    ///
    /// The server treats the request id as an idempotency key: the same
    /// id either replays the first attempt's answer or proceeds. A fresh
    /// id per attempt would turn "try again" into "send it again".
    func test_aRetryReusesTheSameRequestId() throws {
        for view in Self.composers {
            let source = try ViewSource.read(view)
            let send = try XCTUnwrap(
                body(of: source, startingAt: "private func send() async"),
                "\(view) has no send function"
            )
            XCTAssertFalse(
                send.contains("requestId ="),
                "\(view) mints a new request id per attempt — a retry could send the same mail twice"
            )
        }
    }

    // MARK: - S-04 · The forward keeps the note

    /// The forward sheet has a draft slot of its own.
    ///
    /// The note the user writes on top of a forwarded original is the
    /// only part of a forward that exists nowhere else — the original
    /// travels as itself — so it is the one thing that must not evaporate
    /// when the sheet closes.
    func test_theForwardSheetKeepsTheNote() throws {
        let source = try ViewSource.read("ForwardSheet")
        XCTAssertTrue(
            source.contains("lagoon.forward."),
            "the forward sheet has no draft slot of its own"
        )
        XCTAssertTrue(
            source.contains("draftSlot.save("),
            "the forward sheet never writes its draft"
        )
    }

    // MARK: - S-05 · Leaving is one action with one name

    /// The three composers leave the same way, and the button that leaves
    /// says the same thing in all three.
    ///
    /// 「稍后继续」 and 「取消」 are different promises: one parks the
    /// work, the other throws it away. The composer parks it.
    func test_theThreeComposersLeaveTheSameWay() throws {
        for view in Self.composers {
            let source = try ViewSource.read(view)
            XCTAssertTrue(
                source.contains("l10n.closeComposer"),
                "\(view) names its close button something else"
            )
            XCTAssertFalse(
                source.contains("Button(l10n.cancel)"),
                "\(view) calls the close button \"Cancel\" — it parks the work, it does not throw it away"
            )
            XCTAssertTrue(
                source.contains("showUnsavedAlert"),
                "\(view) closes a mail that is not finished without asking"
            )
            XCTAssertTrue(
                source.contains("l10n.discardDraft"),
                "\(view) has no way to throw the draft away"
            )
            XCTAssertTrue(
                source.contains("l10n.keepWriting"),
                "\(view) cannot tell the user to stay and finish"
            )
        }
    }

    // MARK: - S-06 · Return does not submit a variant

    /// The variant text is selectable, so Return must not submit.
    ///
    /// Return inside a text selection ended the selection by choosing a
    /// variant — and the variant was marked as chosen on the server.
    func test_theDraftPickerDoesNotBindReturnInASelectableText() throws {
        let source = try ViewSource.read("DraftPickerSheet")
        XCTAssertFalse(
            source.contains(".keyboardShortcut(.defaultAction)"),
            "Return still submits the variant from inside the text selection"
        )
    }

    // MARK: - S-07 · The count counts the envelope

    /// The number of recipients is the whole envelope's.
    func test_theRecipientCountIsTheWholeEnvelope() {
        XCTAssertEqual(
            NewMessageSheet.recipientCount(
                to: "a@example.com",
                cc: "b@example.com",
                bcc: "c@example.com"
            ),
            3,
            "To, Cc and Bcc together are three people"
        )
        XCTAssertEqual(
            NewMessageSheet.recipientCount(to: "a@example.com", cc: "", bcc: ""),
            1
        )
    }

    /// The count is shown with the send button, not with the To label.
    ///
    /// A number next to a field it does not describe is a number the user
    /// cannot trust: "3 recipients" next to a To field holding one
    /// address reads as a lie about the To field.
    func test_theRecipientCountSitsWithTheSendButtonNotWithTheToLabel() throws {
        let source = try ViewSource.read("NewMessageSheet")
        let occurrences = ViewSource.occurrences(of: "newMessageTotalRecipients", in: source)
        XCTAssertEqual(
            occurrences.count,
            1,
            "the envelope's size must be shown once"
        )
        let shortcut = try XCTUnwrap(
            source.range(of: "l10n.shortcutSend"),
            "the bottom row is gone"
        )
        XCTAssertTrue(
            occurrences[0] > shortcut.lowerBound,
            "the envelope total is back next to the To label"
        )
        XCTAssertTrue(
            source.contains("if toAddresses.count > 1"),
            "the comma hint must be about the To field, not about the whole envelope"
        )
    }

    // MARK: - S-08 · The read-only recipients say so

    /// The reply composer explains the fields it will not let the user
    /// change, and says how many people the reply reaches.
    func test_theReplyComposerSaysWhyTheRecipientsCannotBeChanged() throws {
        let source = try ViewSource.read("ComposerSheet")
        XCTAssertTrue(
            source.contains("l10n.replyRecipientsFixed"),
            "the read-only recipients have no explanation — the field looks broken"
        )
        XCTAssertTrue(
            source.contains("newMessageRecipientsCount"),
            "the reply composer does not say how many people it reaches"
        )
        XCTAssertEqual(
            ComposerSheet.recipientCount(
                to: "a@example.com",
                cc: ["b@example.com", "c@example.com"]
            ),
            3
        )
    }

    // MARK: - S-09 · Nothing is sent to nobody, and no subject is guessed

    /// The send button waits for a recipient and says why.
    func test_theSendButtonWaitsForARecipient() throws {
        for view in ["NewMessageSheet", "ForwardSheet"] {
            let source = try ViewSource.read(view)
            XCTAssertTrue(
                source.contains("!canSend"),
                "\(view) lets the user press send with nobody to send to"
            )
            XCTAssertTrue(
                source.contains("l10n.sendNeedsRecipient"),
                "\(view) does not say why the send button is off"
            )
        }
    }

    /// A subject the client does not own is not sent.
    ///
    /// The reader hands over its *display* subject, which falls back to
    /// the "（无主题）" placeholder. Seeding that would put "Fwd:
    /// （无主题）" on the wire.
    func test_theForwardDoesNotSeedAPlaceholderSubject() {
        XCTAssertNil(
            ForwardSheet.knownSubject(nil, noSubject: "（无主题）"),
            "no subject is no subject"
        )
        XCTAssertNil(
            ForwardSheet.knownSubject("（无主题）", noSubject: "（无主题）"),
            "the placeholder is not a subject"
        )
        XCTAssertNil(
            ForwardSheet.knownSubject("   ", noSubject: "（无主题）"),
            "a blank subject is no subject"
        )
        XCTAssertEqual(
            ForwardSheet.knownSubject("报价", noSubject: "（无主题）"),
            "报价"
        )
    }

    /// The forward sends the server's own subject when the user wrote
    /// none.
    func test_theForwardLetsTheServerDeriveTheSubject() throws {
        let source = try ViewSource.read("ForwardSheet")
        let arguments = try XCTUnwrap(
            arguments(of: source, startingAt: "api.forwardMessage("),
            "the forward sheet does not send"
        )
        XCTAssertTrue(
            arguments.contains("subjectWasEdited"),
            "the forward sends a subject it does not own"
        )
        XCTAssertTrue(
            arguments.contains("nil"),
            "the forward never lets the server derive the subject"
        )
    }

    // MARK: - S-10 · The total attachment cap is the client's too

    /// Both composers check the total, not only the single file.
    func test_theClientChecksTheTotalAttachmentSize() throws {
        for view in ["ComposerSheet", "NewMessageSheet"] {
            let source = try ViewSource.read(view)
            XCTAssertTrue(
                source.contains("ComposeFlow.Attachments.fits("),
                "\(view) checks each file but not the total — the server's limit is on the total"
            )
            XCTAssertTrue(
                source.contains("l10n.newMessageAttachmentTotalSize"),
                "\(view) does not show how big the attachments are together"
            )
        }
    }

    // MARK: - S-12 · The cheatsheet's scope claim is checked

    /// ⌘↩ is bound in the composers and nowhere else.
    ///
    /// The cheatsheet says "composer only". That is a claim about the
    /// whole app, so it is checked against the whole app: a binding added
    /// to the reader later would make the sheet wrong, and now the build
    /// says so.
    func test_theSendKeyIsBoundOnlyInTheComposers() throws {
        let root = ViewSource.url(under: "Views", "RootView")
            .deletingLastPathComponent()          // Views
            .deletingLastPathComponent()          // Lagoon
        let urls = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        )?.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(urls.isEmpty, "no client sources found")

        var bound: Set<String> = []
        for url in urls {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains(".keyboardShortcut(.return, modifiers: .command)") {
                bound.insert(url.lastPathComponent)
            }
        }
        XCTAssertEqual(
            bound,
            ["ComposerSheet.swift", "NewMessageSheet.swift", "ForwardSheet.swift"],
            "⌘↩ is bound somewhere the cheatsheet does not claim — the \"composer only\" scope is a lie"
        )
    }

    /// The cheatsheet's row names the surface.
    func test_theCheatsheetSaysWhereTheSendKeyWorks() {
        let row = ShortcutsSheet().entries.first { $0.id == "send" }
        XCTAssertEqual(row?.scope, .composer)
        let description = row?.description ?? ""
        XCTAssertTrue(
            description.contains("写信框") || description.lowercased().contains("composer"),
            "the row does not say where the key works: \(description)"
        )
    }

    // MARK: - S-13 · The emphasis is rendered, not printed

    /// The forward explanation shows no asterisks.
    ///
    /// A plain `Text` does not read `**` as anything, so the user saw
    /// the markers — and the emphasis the sentence was written for did
    /// not happen.
    func test_theForwardExplanationShowsNoAsterisks() {
        for language in AppLanguage.allCases {
            let l10n = L10n(language: language)
            let rendered = ForwardSheet.emphasis(l10n.forwardKeepsOriginal)
            XCTAssertFalse(
                rendered.characters.contains("*"),
                "the asterisks are on screen: \(rendered.characters)"
            )
            XCTAssertTrue(
                rendered.runs.contains { run in
                    run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
                },
                "the emphasis the sentence was written for did not happen"
            )
        }
    }

    // MARK: - S-14 · The server's own answer decides

    /// No composer announces a send before it has read the server's
    /// answer.
    func test_theComposersReadTheServerFlagBeforeAnnouncingASend() throws {
        for view in Self.composers {
            let source = try ViewSource.read(view)
            let send = try XCTUnwrap(
                body(of: source, startingAt: "private func send() async"),
                "\(view) has no send function"
            )
            let check = try XCTUnwrap(
                send.range(of: "ComposeFlow.outcome(of: response)"),
                "\(view) never reads the server's answer"
            )
            let announce = try XCTUnwrap(
                send.range(of: "onSent("),
                "\(view) never announces the send"
            )
            XCTAssertTrue(
                check.lowerBound < announce.lowerBound,
                "\(view) announces the send before reading the server's answer"
            )
        }
    }

    // MARK: - Helpers

    /// The body of the function that starts at `marker`, braces balanced.
    ///
    /// A guard that reads the whole file passes for the wrong reason half
    /// the time: the first `onSend` in a file is not necessarily the one
    /// under test. This reads the function it was pointed at.
    private func body(of source: String, startingAt marker: String) -> String? {
        guard let start = source.range(of: marker),
              let open = source.range(of: "{", range: start.upperBound..<source.endIndex)
        else { return nil }
        var depth = 0
        var index = open.lowerBound
        while index < source.endIndex {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" {
                depth -= 1
                if depth == 0 { return String(source[open.lowerBound...index]) }
            }
            index = source.index(after: index)
        }
        return nil
    }

    /// The argument list of the call that starts at `marker`, parens
    /// balanced.
    ///
    /// The marker usually ends with the opening paren itself, so the
    /// search starts at the marker's own beginning.
    private func arguments(of source: String, startingAt marker: String) -> String? {
        guard let start = source.range(of: marker),
              let open = source.range(of: "(", range: start.lowerBound..<source.endIndex)
        else { return nil }
        var depth = 0
        var index = open.lowerBound
        while index < source.endIndex {
            if source[index] == "(" { depth += 1 }
            if source[index] == ")" {
                depth -= 1
                if depth == 0 { return String(source[open.lowerBound...index]) }
            }
            index = source.index(after: index)
        }
        return nil
    }
}
