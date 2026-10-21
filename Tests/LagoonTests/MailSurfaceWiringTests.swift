import XCTest
import Foundation
@testable import Lagoon
@testable import LagoonKit

/// Source-level guards for the UX-03/04/06/07/08/09/10 batch and the F-01 doc
/// fix (docs/全方位审查报告-2026-10-16.md).
///
/// ## Why source, and why *attachment*
///
/// Each fix here is **wiring**: a banner assigned in a catch, a branch that
/// renders one line instead of three, a label attached to a container, a
/// binding added to a hidden button, a text that comes from L10n. None of it
/// is reachable from a unit test that drives a `@State` view, and all of it is
/// exactly the kind of code a later edit deletes without noticing — which is
/// how the silent-catch orginally shipped under a green suite.
///
/// So each assertion below pins the *attachment* — a string that only exists
/// where the wiring exists, positioned between anchors — never mere presence
/// of a word somewhere in the file. Every one of these was verified by
/// mutation: delete the wiring and the test goes red.
final class MailSurfaceWiringTests: XCTestCase {
    /// The repo root, from this file's own path.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // LagoonTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // package root

    /// One function's text: from its declaration line onward, with comment
    /// lines stripped (several fixes *name* their bug in a comment, and a test
    /// that reads the comment as code would pass for the wrong reason).
    private static func body(
        _ signature: String, in source: String, limit: Int
    ) throws -> String {
        let start = try XCTUnwrap(
            source.range(of: signature), "\(signature) moved"
        )
        return ViewSource.code(after: start.lowerBound, in: source, limit: limit)
    }

    // MARK: - UX-03: list toggles report failures through the banner

    /// Both optimistic toggles used to catch their failure and… nothing: the
    /// row reverted and the user was never told, which reads as "the app
    /// ignored the click". Each catch must revert AND raise the view's own
    /// banner with a retry that re-attempts the same flip.
    func test_listToggleFailures_reportThroughTheBanner() throws {
        let source = try ViewSource.read("MessageListView")

        let read = try Self.body("private func toggleRead", in: source, limit: 1500)
        let readCatch = try XCTUnwrap(
            read.range(of: "} catch {"), "toggleRead lost its catch"
        )
        let readCatchBody = read[readCatch.upperBound...].prefix(600)
        XCTAssertTrue(
            readCatchBody.contains("errorBanner = ErrorBanner("),
            "toggleRead swallows its failure again — the silent revert is back"
        )
        XCTAssertTrue(readCatchBody.contains("l10n.markReadFailedTitle"))
        XCTAssertTrue(readCatchBody.contains("l10n.markReadFailedDetail"))
        XCTAssertTrue(
            readCatchBody.contains("action: { [self] in await self.toggleRead(m) }"),
            "the banner must offer a retry that re-attempts the same flip"
        )

        let pin = try Self.body("private func togglePin", in: source, limit: 1500)
        let pinCatch = try XCTUnwrap(
            pin.range(of: "} catch {"), "togglePin lost its catch"
        )
        let pinCatchBody = pin[pinCatch.upperBound...].prefix(600)
        XCTAssertTrue(
            pinCatchBody.contains("errorBanner = ErrorBanner("),
            "togglePin swallows its failure again — the silent revert is back"
        )
        XCTAssertTrue(pinCatchBody.contains("l10n.pinFailed"))
        XCTAssertTrue(pinCatchBody.contains("l10n.unpinFailed"))
        XCTAssertTrue(
            pinCatchBody.contains("action: { [self] in await self.togglePin(m) }")
        )
    }

    // MARK: - UX-08: bulk delete names the right operation

    /// The stage-two delete failure used to reuse 加载失败 — the wrong
    /// operation at the moment the user most needs to know what failed.
    func test_bulkDeleteFailureNamesTheOperation() throws {
        let source = try ViewSource.read("MessageListView")
        // The window is measured from the *end* of the catch marker. It has
        // to be wide enough to reach the banner: the success path above
        // grew (the undo toast was added), which pushed the catch further
        // down the function, and a window that stops before the banner is
        // reached reports a missing title for a banner that is right there.
        let region = try Self.body("private func deleteAllMatching", in: source, limit: 5200)
        let catchIndex = try XCTUnwrap(
            region.range(of: "} catch {"), "deleteAllMatching lost its catch"
        )
        let catchBody = region[catchIndex.upperBound...].prefix(900)
        XCTAssertTrue(
            catchBody.contains("l10n.bulkDeleteFailed"),
            "the bulk delete failure does not name the operation"
        )
        XCTAssertFalse(
            catchBody.contains("l10n.loadFailed"),
            "the wrong-operation title is back on the bulk delete failure"
        )
    }

    // MARK: - UX-04: dense briefing rows are single-line

    /// Dense mode must render the same one-line scan the raw list does — and
    /// trade away the avatar, the snippet/reason AND the advice strip, because
    /// a row that sometimes wraps to two lines is not a dense row.
    func test_briefingDenseRow_isSingleLineAndDropsTheExtras() throws {
        let source = try ViewSource.read("BriefingFeedView")
        XCTAssertTrue(
            source.contains("if density == .dense {"),
            "the feed's dense branch disappeared — dense falls back to compact again"
        )
        // Sliced between the two property declarations: a fixed-length window
        // would bleed into `regularRow` and find its avatar/strip there.
        let denseStart = try XCTUnwrap(source.range(of: "private var denseRow"))
        let denseEnd = try XCTUnwrap(
            source.range(of: "private var regularRow", range: denseStart.upperBound..<source.endIndex)
        )
        let denseSlice = source[denseStart.upperBound..<denseEnd.lowerBound]
        let dense = ViewSource.code(
            after: denseSlice.startIndex, in: denseSlice, limit: denseSlice.count
        )
        XCTAssertTrue(dense.contains("Text(item.message.fromName ?? item.message.fromAddress)"))
        XCTAssertTrue(dense.contains("Text(item.message.subject ?? l10n.noSubject)"))
        XCTAssertFalse(
            dense.contains("RowAdviceStrip"),
            "the advice strip is an extra line; dense promises one — it belongs to the other two modes"
        )
        XCTAssertFalse(
            dense.contains("SenderAvatar"),
            "dense traded the avatar away for the one-line scan"
        )

        // The strip and the snippet still ride along in the other densities,
        // so the trade is a trade, not a deletion.
        let regular = try Self.body("private var regularRow", in: source, limit: 3200)
        XCTAssertTrue(regular.contains("RowAdviceStrip"))
        XCTAssertTrue(regular.contains("showsSnippet"))
    }

    // MARK: - UX-10: the hover card carries the row's advice

    /// The card hardcoded `advice: nil` while the advice table sat loaded in
    /// the view — and `hoverTracked`, a wrapper with zero call sites, was dead
    /// code. Both are asserted here: the advice is *passed*, and the dead
    /// tracker stays gone.
    func test_hoverCardCarriesTheRowsAdvice_andTheDeadTrackerStaysGone() throws {
        let source = try ViewSource.read("MessageListView")
        let hover = try Self.body("private var hoverCard", in: source, limit: 1200)
        XCTAssertTrue(
            hover.contains("advice: adviceByRemoteId[message.remoteId]"),
            "the hover card hardcodes `advice: nil` again — the data sits in the table unused"
        )
        XCTAssertFalse(hover.contains("advice: nil"))
        // The table is loaded with the list, mirroring the feed: a hover-time
        // round trip would flash the card without its judgement.
        XCTAssertTrue(source.contains("private func loadAdvice()"))
        XCTAssertTrue(
            source.contains("await loadAdvice()"),
            "loadAdvice exists but nothing calls it — the card would always be empty"
        )
        XCTAssertFalse(
            source.contains("hoverTracked"),
            "the dead hover tracker came back; the real wiring is the rows' own .onHover"
        )
    }

    // MARK: - UX-09: ⌘[ is bound on both surfaces

    /// The cheatsheet lists ⌘[ as a global "back"; on the list surface it was
    /// a dead key. Both surfaces now clear the selection with it.
    /// (`ShortcutSheetCoversRealBindingsTests` checks the other direction —
    /// every documented key is bound *somewhere*; this one pins both
    /// surfaces.)
    func test_backShortcutIsBoundOnBothSurfaces() throws {
        for view in ["BriefingFeedView", "MessageListView"] {
            let source = try ViewSource.read(view)
            XCTAssertTrue(
                source.contains(#".keyboardShortcut("[", modifiers: .command)"#),
                "\(view): ⌘[ (back) lost its binding — the cheatsheet row is a ghost again"
            )
        }
    }

    // MARK: - UX-07: the message body container carries its VoiceOver label

    func test_messageBodyContainerCarriesItsVoiceOverLabel() throws {
        let source = try ViewSource.read("MessageDetailView")
        let region = try Self.body("private func bodyContent", in: source, limit: 3000)
        XCTAssertTrue(
            region.contains(".accessibilityElement(children: .contain)"),
            "the body container stopped being a container — the label below means nothing then"
        )
        XCTAssertTrue(
            region.contains(".accessibilityLabel(l10n.messageBody)"),
            "the body container lost its label — VoiceOver enters an unlabelled region"
        )
    }

    // MARK: - UX-06: startup copy comes from L10n

    /// The boot screen and the embedded server's two errors were hardcoded
    /// Chinese — the one systematic localization gap. Both now read L10n, and
    /// the strings are asserted in both languages by `LocalizationTests`.
    func test_startupCopyComesFromL10n() throws {
        let app = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Sources/Lagoon/LagoonApp.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(
            app.contains("正在启动"),
            "the boot screen regressed to a hardcoded Chinese literal"
        )
        XCTAssertTrue(app.contains("L10n.current.serverStarting"))
        XCTAssertTrue(app.contains("L10n.current.serverStartFailed"))

        let embedded = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Sources/Lagoon/Services/EmbeddedServer.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(embedded.contains("无法生成加密密钥"))
        XCTAssertFalse(embedded.contains("内嵌服务启动失败"))
        XCTAssertTrue(embedded.contains("L10n.current.keyGenerationFailed"))
        XCTAssertTrue(embedded.contains("L10n.current.embeddedServerStartFailed"))
    }

    // MARK: - F-01/UX-01: the user guide matches the real key semantics

    /// ⌫ archives and ⌘⌫ deletes (`onDeleteCommand` → `archiveSelected`; the
    /// hidden button binds ⌘⌫ to `deleteSelected`). The guide shipped with
    /// both reversed, which taught users the wrong key.
    func test_userGuideDescribesTheRealBackspaceSemantics() throws {
        let url = Self.repoRoot.appendingPathComponent("docs/使用说明.md")
        let doc = try String(contentsOf: url, encoding: .utf8)

        // What has to stay true is the *mapping* — ⌫ archives, ⌘⌫ trashes —
        // not the exact wording. The previous version matched on the literal
        // "删除（⌘⌫）", so improving the copy to "移到废纸篓（⌘⌫）" failed
        // the test even though the behaviour it protects was unchanged. A
        // test that breaks when the words get better is a test that
        // rewards freezing the words.
        let lines = doc.split(separator: "\n").map(String.init)
        let plain = lines.filter { $0.contains("⌫") && !$0.contains("⌘⌫") }
        let command = lines.filter { $0.contains("⌘⌫") }

        XCTAssertTrue(
            plain.contains { $0.contains("归档") },
            "the guide no longer documents ⌫ = archive: \(plain)"
        )
        XCTAssertTrue(
            command.contains { $0.contains("废纸篓") || $0.contains("删除") },
            "the guide no longer documents ⌘⌫ = move to trash: \(command)"
        )
        XCTAssertFalse(
            command.contains { $0.contains("归档") },
            "the reversed mapping is back in the user guide: \(command)"
        )
        XCTAssertFalse(
            plain.contains { $0.contains("废纸篓") && !$0.contains("归档") },
            "the reversed mapping is back in the user guide: \(plain)"
        )
        XCTAssertTrue(
            doc.contains("⌘A 然后 ⌘⌫"),
            "the two-stage-select rationale must name the actually-destructive combo"
        )
    }
}
