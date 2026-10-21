import XCTest
import Foundation
import LagoonKit
@testable import Lagoon

/// The Briefing Feed's multi-select and bulk actions.
///
/// ## Why this file exists
///
/// The Briefing is the product's front door, and it was the one mail surface
/// without a bulk verb: 40 messages meant 40 separate archive round trips,
/// so the "10 分钟清零" promise the product makes was not actually kept on
/// the page people open most. The raw list already had the whole vocabulary
/// (selection set, bulk bar, undo toast, failure banner with a retry) — the
/// Briefing had none of it.
///
/// ## What is tested where
///
/// The **arithmetic** (which rows ⌘A selects, which one the reader pane
/// previews, when the bulk bar appears) lives in the product code, in
/// `BriefingSelection`, and is driven here directly.
///
/// That split is deliberate. An earlier version of this file carried its
/// own copy of the rules and asserted against that copy — and it stayed
/// green after the view's own implementation was broken, because the test
/// was checking itself. A test that re-implements the thing it checks is a
/// decoration. The production type is the one under test, so a mutation
/// there turns this file red.
///
/// The **wiring** (which route a verb calls, which banner a failure
/// raises) is asserted on the source, the same way the sibling files in
/// this suite do it: the package has no UI-test target and SwiftUI's view
/// tree is not inspectable from a unit test, so the assertions pin the
/// *attachment* — a string that only exists where the wiring exists.
final class BriefingMultiSelectTests: XCTestCase {
    // MARK: - ⌘A semantics

    /// ⌘A selects the loaded window, and only the loaded window.
    func test_selectAllSelectsTheLoadedWindowOnly() {
        let result = BriefingSelection.toggledAll(selected: [], loaded: ["a", "b", "c"])
        XCTAssertEqual(result, ["a", "b", "c"])
    }

    /// ⌘A again returns to an empty selection.
    ///
    /// This is the invariant the whole two-stage design protects: the most
    /// natural thing a user can do is press ⌘A twice and then ⌫, and the
    /// result must be "nothing selected", never "more selected than before".
    func test_selectAllTwiceReturnsToEmptySelection() {
        let loaded: Set<String> = ["a", "b", "c"]
        let once = BriefingSelection.toggledAll(selected: [], loaded: loaded)
        let twice = BriefingSelection.toggledAll(selected: once, loaded: loaded)
        XCTAssertTrue(
            twice.isEmpty,
            "⌘A twice must clear the selection, not widen it"
        )
    }

    /// ⌘A cannot reach past the loaded window.
    ///
    /// The Briefing is a server-side window (the feed's own footer says how
    /// many more exist outside it). There is no "everything on the server"
    /// scope on this surface, so ⌘A must never pretend to offer one.
    func test_selectAllNeverReachesPastTheLoadedWindow() {
        let result = BriefingSelection.toggledAll(selected: [], loaded: ["a", "b"])
        XCTAssertTrue(
            result.isDisjoint(with: ["c", "d"]),
            "⌘A selected something the user cannot see"
        )
        XCTAssertEqual(result.count, 2)
    }

    /// A partial selection is *replaced* by ⌘A, not extended.
    ///
    /// The user holding one row and pressing ⌘A means "everything", not
    /// "that one plus everything".
    func test_selectAllReplacesAPartialSelection() {
        let result = BriefingSelection.toggledAll(selected: ["a"], loaded: ["a", "b", "c"])
        XCTAssertEqual(result, ["a", "b", "c"])
    }

    /// A selection that is *not* everything loaded is not cleared by ⌘A —
    /// only a full selection toggles off.
    ///
    /// Otherwise "⌘A, then ⌘A" on a mailbox whose window shrank between the
    /// two presses would leave the user with a partial selection they never
    /// asked for.
    func test_selectAllOnlyTogglesOffAFullSelection() {
        let result = BriefingSelection.toggledAll(selected: ["a"], loaded: ["a", "b", "c"])
        XCTAssertEqual(result, ["a", "b", "c"], "a partial selection must not be cleared")
    }

    /// The view must go through the shared rule, not carry its own copy.
    ///
    /// A second implementation of "what does ⌘A select" is a second opinion
    /// that can disagree with the first — and the disagreement is invisible
    /// until the user selects 500 rows and hits ⌫.
    func test_theViewGoesThroughTheSharedRule() throws {
        let feed = try ViewSource.read("BriefingFeedView")
        XCTAssertTrue(
            feed.contains("BriefingSelection.toggledAll("),
            "the ⌘A button no longer goes through the shared selection rule"
        )
    }

    // MARK: - The reading pane

    /// One selected row previews; two or more preview nothing.
    ///
    /// The pane must not quietly show one of the selected messages while a
    /// bulk verb is about to act on all of them — that is the classic shape
    /// of a bulk verb firing on mail the user never saw selected.
    func test_readerPreviewsExactlyOneSelectedRow() {
        XCTAssertEqual(
            BriefingSelection.readerId(selected: ["a"], valid: ["a", "b"]),
            "a"
        )
        XCTAssertNil(
            BriefingSelection.readerId(selected: ["a", "b"], valid: ["a", "b"]),
            "a multi-selection must not preview one of its rows"
        )
        XCTAssertNil(
            BriefingSelection.bulkCount(selected: ["a"]),
            "one selected row must not raise the bulk bar"
        )
        XCTAssertEqual(BriefingSelection.bulkCount(selected: ["a", "b"]), 2)
    }

    /// A selected row that has left the feed previews nothing.
    ///
    /// The selection can outlive the row: a poll that drops the selected
    /// message (archived from another client, or reclassified out of the
    /// window) would otherwise leave the pane rendering a detail view with
    /// no header — a blank reader that reads as a broken app.
    func test_readerRetractsWhenTheRowHasLeftTheFeed() {
        XCTAssertNil(
            BriefingSelection.readerId(selected: ["gone"], valid: ["a", "b"]),
            "the reader pane previews a row that is no longer in the feed"
        )
    }

    /// The bulk bar's threshold matches the raw list's.
    ///
    /// The two surfaces are two views of one mailbox; a bar that appears at
    /// one row on one surface and two rows on the other teaches the user
    /// that the surfaces behave differently, and then they stop trusting
    /// either.
    func test_bulkBarThresholdMatchesTheRawList() throws {
        let list = try ViewSource.read("MessageListView")
        XCTAssertTrue(
            list.contains("selection.count > 1 ? selection.count : nil"),
            "the raw list's bulk-bar threshold moved"
        )
        // And the Briefing must *use* the shared rule rather than carrying
        // its own copy of it.
        let feed = try ViewSource.read("BriefingFeedView")
        XCTAssertTrue(
            feed.contains("BriefingSelection.bulkCount(selected: selection)"),
            "the Briefing no longer goes through the shared bulk-count rule"
        )
    }

    // MARK: - The wiring

    /// The selection is a **set**, not a single id.
    ///
    /// The Briefing used to hold `selectedMessageId: String?` — the shape
    /// that makes multi-select impossible. A test that only looked for
    /// "no more `selectedMessageId`" would pass with a `Set<String>` that
    /// still only ever held one element, so this asserts the *type* and
    /// that the list is bound to it.
    func test_theSelectionIsASetBoundToTheList() throws {
        let source = try ViewSource.read("BriefingFeedView")
        XCTAssertTrue(
            source.contains("@State private var selection: Set<String> = []"),
            "the Briefing's selection is not a Set<String> — multi-select cannot work"
        )
        XCTAssertTrue(
            source.contains("List(selection: $selection)"),
            "the feed's list is not bound to the selection set"
        )
        XCTAssertFalse(
            source.contains("selectedMessageId"),
            "the single-id selection is still around; a second source of truth is a bug"
        )
    }

    /// The bulk bar hangs off the bottom inset and reuses the shared
    /// component.
    ///
    /// Reuse is the point: the raw list's bar and this one must be the same
    /// widget, or the two surfaces drift apart and the user learns two
    /// different vocabularies for the same four verbs.
    func test_theBulkBarReusesTheSharedComponent() throws {
        let source = try ViewSource.read("BriefingFeedView")
        XCTAssertTrue(
            source.contains(".safeAreaInset(edge: .bottom, spacing: 0)"),
            "the bulk bar is not on the bottom inset; the raw list puts it there"
        )
        XCTAssertTrue(
            source.contains("BulkActionBar("),
            "the Briefing does not show the shared bulk bar"
        )
        for verb in ["onArchive:", "onDelete:", "onMarkRead:", "onMarkUnread:", "onClear:"] {
            XCTAssertTrue(
                source.contains(verb),
                "the bulk bar is missing \(verb) — the four verbs must all be there"
            )
        }
    }

    /// The archive verb is gated on the same condition the per-row archive
    /// is.
    ///
    /// The bulk bar offering a verb the row would have refused is the
    /// "the bar offers something the server will 409" bug.
    func test_theBulkBarSharesTheRowsArchiveGate() throws {
        let source = try ViewSource.read("BriefingFeedView")
        XCTAssertTrue(
            source.contains("canArchive: canArchive"),
            "the bulk bar's archive button is not gated on `canArchive`"
        )
        // And `canArchive` itself must be the account's negotiated
        // capability, not a hardcoded true.
        //
        // Read through `allowsArchive`, not the raw field: the raw field is
        // three-state, and "not determined" has to read as *allowed*. A
        // client that tested the raw `Bool?` for truthiness would switch
        // archive off for every account that has not been probed yet — which
        // is the disabled-button half of the id-encoding defect.
        XCTAssertTrue(
            source.contains("directory.active?.capabilities.allowsArchive ?? true"),
            "`canArchive` no longer reads the account's negotiated capability, or "
                + "collapses 'not determined' into 'no'"
        )
    }

    /// The bulk verbs go through the server's *sweep* routes.
    ///
    /// A per-message loop is the thing this feature exists to remove: 40
    /// messages would be 40 remote MOVE round trips, which is exactly the
    /// "10 分钟清零" the Briefing could not keep.
    func test_bulkArchiveAndDeleteUseTheSweepRoutes() throws {
        let source = try ViewSource.read("BriefingFeedView")
        XCTAssertTrue(
            source.contains("api.archiveBulk("),
            "the bulk archive does not use the server's sweep route"
        )
        XCTAssertTrue(
            source.contains("api.deleteBulk("),
            "the bulk delete does not use the server's sweep route"
        )
        XCTAssertTrue(
            source.contains("DeleteBulkRequest(remoteIds:"),
            "the bulk delete does not send an explicit id list"
        )
        // And it must NOT use the server-wide shape: the Briefing has no
        // scope for "everything on the server".
        XCTAssertFalse(
            source.contains("allMatchingIn:"),
            "the Briefing asked the server for 'everything matching' — that scope does not exist here"
        )
    }

    /// The read/unread verbs are per-message writes, and they say so.
    ///
    /// Read state lives on the server (`\Seen`), so it cannot be waved away
    /// by clearing the selection: each message gets its own request and its
    /// own failure. A test that only checked "markRead is called" would pass
    /// on an implementation that silently dropped the failures — which is
    /// how "8 messages marked read" could mean "7 messages marked read".
    func test_markReadIsPerMessageAndRecordsItsFailures() throws {
        let source = try ViewSource.read("BriefingFeedView")
        XCTAssertTrue(
            source.contains("api.markRead("),
            "the bulk mark-read does not call the server"
        )
        // `record: true` is what makes the batch undoable — a deliberate
        // read/write must land in the audit log.
        XCTAssertTrue(
            source.contains("record: true"),
            "the bulk mark-read is not recorded, so it cannot be undone"
        )
        // The per-message result must be captured, not thrown away.
        XCTAssertTrue(
            source.contains("failed.append(remoteId)"),
            "a failed mark-read is not recorded — the user would be told a lie"
        )
    }

    // MARK: - Failure handling

    /// A partial failure must say which half failed, and the retry must
    /// cover exactly that half.
    ///
    /// Two separate claims, both silent if broken:
    ///
    /// 1. the banner exists at all (INV-3: detail non-empty, INV-4: retry
    ///    present) — a bulk bar that says "done" while 30 of 200 failed
    ///    teaches people to distrust it;
    /// 2. the retry re-runs the **failed** ids, not the whole batch. A
    ///    retry that re-archives the successful ones is a second MOVE per
    ///    message for no reason, and a retry that re-reads "the current
    ///    selection" would aim at whatever the user has selected *now* —
    ///    which is a different set of mail than the one the button was
    ///    labelled for.
    func test_aPartialFailureOffersARetryOverTheFailedRowsOnly() throws {
        let source = try ViewSource.read("BriefingFeedView")

        // The banner: a title, a detail, a retry label, and an action.
        for marker in [
            "l10n.senderBulkPartial",
            "detail: l10n.senderBulkPartialDetail(",
            "actionLabel: l10n.retry",
        ] {
            XCTAssertTrue(
                source.contains(marker),
                "the bulk failure banner lost \(marker)"
            )
        }

        // The retry re-runs the failed subset. Both the archive path and
        // the delete path must do this, and neither may re-run the whole
        // captured batch.
        XCTAssertTrue(
            source.contains("archiveBulk(ids: Set(failed.map(\\.remoteId)))"),
            "the bulk archive's retry does not cover exactly the failed rows"
        )
        XCTAssertTrue(
            source.contains("deleteBulk(ids: Set(failed.map(\\.remoteId)))"),
            "the bulk delete's retry does not cover exactly the failed rows"
        )
    }

    /// The whole-batch failure also gets a retry, over the same ids.
    ///
    /// The request-level failure is the one where *nothing* moved, so the
    /// whole captured batch is still the right scope — and the ids must come
    /// from the capture, not from the current selection (which was cleared
    /// the moment the verb was pressed).
    func test_aWholeBatchFailureRetriesTheCapturedBatch() throws {
        let source = try ViewSource.read("BriefingFeedView")
        // The captured id set.
        XCTAssertTrue(
            source.contains("let ids = selection"),
            "the bulk verbs do not capture the selection before clearing it"
        )
        // The retry over that captured set.
        XCTAssertTrue(
            source.contains("action: { [self] in await self.archiveBulk(ids: ids) }"),
            "the whole-batch archive failure does not retry the captured batch"
        )
        XCTAssertTrue(
            source.contains("action: { [self] in await self.deleteBulk(ids: ids) }"),
            "the whole-batch delete failure does not retry the captured batch"
        )
    }

    /// The undo toast covers the *successful* rows only.
    ///
    /// A failed row was never moved, so offering to undo it would be
    /// offering to reverse something that did not happen. And the toast
    /// must carry **every** successful action id, not just the first —
    /// `UndoController` posts to `undo-bulk` when `extraIds` is non-empty,
    /// and undoing only the newest of 40 would leave 39 in place and read
    /// to the user as "undo did nothing".
    func test_theUndoToastCoversEverySuccessfulRow() throws {
        let source = try ViewSource.read("BriefingFeedView")
        XCTAssertTrue(
            source.contains("let actionIds = ok.compactMap(\\.actionId)"),
            "the bulk archive does not collect the action ids of the successful rows"
        )
        XCTAssertTrue(
            source.contains("extraIds: Array(actionIds.dropFirst())"),
            "the bulk undo toast carries only one id — undoing 1 of 40 reads as 'undo did nothing'"
        )
        XCTAssertTrue(
            source.contains("undo.show(UndoItem("),
            "the bulk verbs raise no undo toast at all"
        )
    }

    /// Every bulk failure banner carries a retry.
    ///
    /// INV-4: a retryable failure carries `actionLabel = l10n.retry`. The
    /// scanner-based `BannerInvariantTests` already checks the *shape* of
    /// every banner in the client; this checks the one thing that scanner
    /// cannot see — that the retry is aimed at the right rows.
    func test_everyBulkFailureBannerCarriesARetry() throws {
        let source = try ViewSource.read("BriefingFeedView")
        // The count of bulk failure banners must not exceed the count of
        // retry actions in the file — a banner without one is a dead end.
        let bulkBanners = source.components(separatedBy: "l10n.senderBulkPartial").count - 1
        let retries = source.components(separatedBy: "actionLabel: l10n.retry").count - 1
        XCTAssertGreaterThan(bulkBanners, 0, "no bulk partial-failure banner found")
        XCTAssertGreaterThanOrEqual(
            retries,
            bulkBanners,
            "a bulk failure banner has no retry button"
        )
    }

    /// The 409 (no archive folder) failure gets a way out, not a retry.
    ///
    /// Retrying cannot fix "this mailbox has no archive folder" — INV-5 says
    /// such a failure must offer a help link instead. A retry button there
    /// is a button that cannot work.
    ///
    /// Scoped to the *bulk* archive's 409 branch: the file has two of them
    /// (the single-message path and the sweep path), and a window that
    /// reached past the branch would pick up the *next* branch's retry and
    /// report a false failure.
    func test_theArchiveUnavailablePathOffersHelpRatherThanRetry() throws {
        let source = try ViewSource.read("BriefingFeedView")
        // The bulk archive's own body, so the scan cannot wander into the
        // single-message path's 409 or out of the branch.
        let bulk = try XCTUnwrap(
            source.range(of: "private func archiveBulk(ids: Set<String>) async {"),
            "the bulk archive moved"
        )
        let after = source[bulk.upperBound...]
        let start = try XCTUnwrap(
            after.range(of: "code == 409"),
            "the bulk archive no longer handles the 409 (no archive folder) case"
        )
        // The branch ends at the next `catch`.
        let branch = after[start.lowerBound...]
        let end = try XCTUnwrap(branch.range(of: "} catch {"), "the 409 branch has no sibling catch")
        let region = branch[..<end.lowerBound]
        XCTAssertTrue(
            region.contains("helpURL: LagoonHelp.bannerMailto("),
            "the 409 path offers no way out"
        )
        XCTAssertFalse(
            region.contains("actionLabel: l10n.retry"),
            "the 409 path offers a retry that cannot work"
        )
    }

    // MARK: - Shortcuts

    /// The new view-level keys are gated on the surface's visibility.
    ///
    /// Both surfaces are mounted at all times (RootView's ZStack), so a key
    /// bound in both without this gate fires twice. The *ownership* list in
    /// `SurfaceShortcutOwnershipTests` checks the gate is present; this
    /// checks the specific keys this feature added are in that list — the
    /// list is only as good as what is in it.
    func test_theNewKeysAreOnTheSharedKeyList() throws {
        // The sibling test file, found from this file's own path: the
        // `ViewSource` helpers all resolve under `Sources/Lagoon/`, and this
        // file lives under `Tests/LagoonTests/`.
        let ownershipURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LagoonTests
            .appendingPathComponent("SurfaceShortcutOwnershipTests.swift")
        let ownership = try String(contentsOf: ownershipURL, encoding: .utf8)
        for key in [
            #"keyboardShortcut("a", modifiers: .command)"#,
            #"keyboardShortcut(.delete, modifiers: .command)"#,
        ] {
            XCTAssertTrue(
                ownership.contains(key),
                "\(key) is bound on both surfaces but is not on the shared-key list"
            )
        }
        // Both surfaces must carry both keys, or the list names a key that
        // only one of them has.
        for view in ["BriefingFeedView", "MessageListView"] {
            let source = try ViewSource.read(view)
            for key in [
                #"keyboardShortcut("a", modifiers: .command)"#,
                #"keyboardShortcut(.delete, modifiers: .command)"#,
            ] {
                XCTAssertTrue(
                    source.contains(key),
                    "\(view) no longer binds \(key); the shared-key list is now wrong"
                )
            }
        }
    }

    /// Each new shortcut carries its own visibility gate.
    ///
    /// The gate has to sit on the *same* view as the binding, and it has to
    /// be found without reading the surrounding prose. `SurfaceShortcutOwnershipTests`
    /// looks a fixed number of lines ahead for `.disabled(!isVisible)` — which
    /// works today only because the comment between the binding and its gate
    /// happens to be three lines long. Shorten that comment, and the gate
    /// moves out of the window while the test still passes: a guardrail that
    /// goes blind because someone edited a comment is not a guardrail.
    ///
    /// So this walks the modifier chain properly: from each binding, the
    /// next `.disabled(...)` must come before the next `Button(` — the next
    /// `Button(` is where the next shortcut's chain starts, and anything
    /// after that belongs to a different view.
    ///
    /// The gate is matched on *containing* `!isVisible`, not on being
    /// exactly `.disabled(!isVisible)`: a shortcut can carry a second
    /// condition (the delete shortcut is also gated on the account having a
    /// trash folder), and the two have to be **one** `.disabled` call —
    /// SwiftUI's `.disabled` overwrites the environment value rather than
    /// composing with it, so two stacked calls would silently drop the
    /// first.
    func test_eachNewShortcutHasItsOwnVisibilityGate() throws {
        let source = try ViewSource.read("BriefingFeedView")
        let lines = source.split(separator: "\n").map(String.init)
        for key in [
            #"keyboardShortcut("a", modifiers: .command)"#,
            #"keyboardShortcut(.delete, modifiers: .command)"#,
        ] {
            let index = try XCTUnwrap(
                lines.firstIndex(where: { $0.contains(key) }),
                "\(key) is no longer bound in the Briefing"
            )
            var sawGate = false
            for line in lines[(index + 1)..<min(index + 12, lines.count)] {
                if line.contains(".disabled(") && line.contains("!isVisible") {
                    sawGate = true
                    break
                }
                // The next button starts the next shortcut's chain. Its
                // gate is its own business.
                if line.contains("Button(") { break }
            }
            XCTAssertTrue(
                sawGate,
                "\(key) has no `.disabled(!isVisible)` of its own — the hidden Briefing would answer it"
            )
        }
    }

    /// The ⌫ gesture archives the selection — and does nothing when nothing
    /// is selected.
    ///
    /// The raw list's rule: an empty selection used to silently archive the
    /// *first message in the list*. The undo toast is a safety net, not a
    /// licence to guess.
    func test_backspaceArchivesTheSelectionAndNothingElse() throws {
        let source = try ViewSource.read("BriefingFeedView")
        XCTAssertTrue(
            source.contains(".onDeleteCommand { archiveSelected() }"),
            "the Briefing's ⌫ does not archive the selection"
        )
        XCTAssertTrue(
            source.contains("guard !selection.isEmpty else { return }"),
            "an empty selection no longer does nothing"
        )
    }

    /// The j/k walk replaces the selection instead of extending it.
    ///
    /// j/k is a cursor. A cursor that accumulates would leave the reading
    /// pane reporting "已选 N 封" while the user is trying to walk the list
    /// — and there is no gesture to take a row back out.
    func test_theWalkReplacesTheSelection() throws {
        let source = try ViewSource.read("BriefingFeedView")
        XCTAssertTrue(
            source.contains("selection = [remoteId]"),
            "j/k no longer collapses the selection to the row it landed on"
        )
        XCTAssertTrue(
            source.contains("tags.firstIndex(where: { selection.contains($0) })"),
            "the walk no longer finds its position from the selection set"
        )
    }
}
