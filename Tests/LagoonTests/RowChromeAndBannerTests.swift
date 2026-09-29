import XCTest
import SwiftUI
import LagoonKit
@testable import Lagoon

/// F5: the row's read verb is dead on an already-read row, because the
/// server's read route is one-way and `toggleRead` returns immediately.
/// The control rendered anyway — swipeable, clickable, and visibly inert.
final class RowReadVerbTests: XCTestCase {
    private func header(isRead: Bool) -> MessageHeader {
        MessageHeader(
            id: UUID(),
            accountId: UUID(),
            remoteId: "r-\(UUID().uuidString)",
            threadId: "t",
            fromAddress: "a@example.com",
            fromName: "A",
            subject: "S",
            snippet: nil,
            receivedAt: Date(),
            isRead: isRead,
            isArchived: false
        )
    }

    func test_unreadRowOffersTheReadVerb() {
        XCTAssertTrue(offersReadVerb(header(isRead: false)))
    }

    /// The regression: an already-read row used to render "标记为已读" in
    /// both the leading swipe and the context menu, and tapping either did
    /// nothing at all.
    func test_readRowDoesNotOfferTheReadVerb() {
        XCTAssertFalse(
            offersReadVerb(header(isRead: true)),
            "the verb is a no-op here; rendering it is a dead control"
        )
    }

    /// The rule only makes sense because the wire is one-way. If a route
    /// ever accepts `isRead: false`, both this and `toggleRead`'s own guard
    /// have to change together — this test is the reminder.
    func test_theVerbIsGatedOnTheSameConditionToggleReadUses() throws {
        let source = try ViewSource.read("MessageListView")
        let line = try XCTUnwrap(
            source.components(separatedBy: "\n").first { $0.contains("guard !m.isRead") },
            "toggleRead's early return moved; the row verb's gate must be revisited"
        )
        XCTAssertEqual(line.trimmingCharacters(in: .whitespaces), "guard !m.isRead else { return }")
    }
}

/// F29: ⌘R is "refresh" on a list surface and "reply" on the message the
/// user has pushed onto it, and both were live at once. The app's own help
/// sheet listed ⌘R twice, which is the same bug stated out loud.
final class RefreshShortcutScopeTests: XCTestCase {
    private static let refreshShortcut = #".keyboardShortcut("r", modifiers: .command)"#

    /// Both list headers attach ⌘R only while the navigation stack is at
    /// the root. Asserted on the source: a keyboard shortcut is not
    /// reachable from a unit test, and the package has no UI-test target.
    func test_refreshShortcutIsOnlyBoundAtTheRootOfTheStack() throws {
        for view in ["MessageListView", "BriefingFeedView"] {
            let source = try ViewSource.read(view)
            let shortcut = try XCTUnwrap(
                source.range(of: Self.refreshShortcut),
                "\(view): the ⌘R binding disappeared"
            )
            // A push always makes `path` non-empty, so the binding has to
            // sit inside a `path.isEmpty` guard.
            let guards = ViewSource.occurrences(of: "if path.isEmpty {", in: source)
            XCTAssertFalse(guards.isEmpty, "\(view): no `path.isEmpty` guard found")
            XCTAssertTrue(
                guards.contains { $0 < shortcut.lowerBound },
                "\(view): ⌘R is bound outside a `path.isEmpty` guard, so it also fires on an open message"
            )
        }
    }

    /// The detail view keeps ⌘R for reply — the *list* moved, not the
    /// message. Reply is what the user is reaching for when a message is
    /// open, and the binding predates the list's.
    func test_theMessageKeepsCommandRForReply() throws {
        let detail = try ViewSource.read("MessageDetailView")
        let reply = try XCTUnwrap(
            detail.range(of: Self.refreshShortcut),
            "the reply binding disappeared"
        )
        let preceding = detail[detail.startIndex..<reply.lowerBound]
        let label = try XCTUnwrap(
            preceding.range(of: "Label(l10n.reply,", options: .backwards),
            "⌘R should still sit on the reply button, not on anything else"
        )
        let between = preceding[label.upperBound...]
        XCTAssertFalse(
            between.contains(".keyboardShortcut"),
            "another binding sits between the reply label and its ⌘R"
        )
    }
}

/// F30: the four keep-alive loops polled with no notion of the app being
/// in the background, and on a `ContinuousClock` that kept counting while
/// the machine slept — so every window fired at once on wake.
final class PollClockTests: XCTestCase {
    /// A backgrounded window has nothing to show, and the server's own sync
    /// loop runs regardless, so the poll is skipped. This is the rule all
    /// four loops gate on.
    func test_pollingStopsWhenTheSurfaceIsHiddenOrTheAppIsInTheBackground() {
        XCTAssertTrue(shouldPoll(isVisible: true, scenePhase: .active))
        XCTAssertFalse(shouldPoll(isVisible: false, scenePhase: .active))
        XCTAssertFalse(shouldPoll(isVisible: true, scenePhase: .background))
        XCTAssertFalse(shouldPoll(isVisible: true, scenePhase: .inactive))
    }

    /// The sleep returns false only when the task is cancelled. Ending the
    /// loop on background instead would be *worse* than polling: a view
    /// still in the hierarchy never gets its `.task` back, so the list
    /// would stop updating for the rest of the session.
    func test_aCompletedSleepMeansTheLoopContinues() async {
        let due = await sleepForPoll(.milliseconds(1))
        XCTAssertTrue(due)
    }

    func test_cancellationStopsTheLoop() async {
        let task = Task { await sleepForPoll(.seconds(30)) }
        task.cancel()
        let due = await task.value
        XCTAssertFalse(due, "a cancelled sleep must end the loop, not poll once more")
    }

    /// The interval must be measured in awake time. `SuspendingClock` is
    /// the whole point: on a `ContinuousClock` a two-hour suspend expires
    /// every window's 30s timer at once and the app fires a burst of
    /// requests at a server that was idle the whole time.
    func test_theSleepUsesSuspendingClockSoSuspendTimeDoesNotCount() async throws {
        let source = try String(contentsOf: ViewSource.url(under: "Models", "PollClock"), encoding: .utf8)
        XCTAssertTrue(
            source.contains("clock: .suspending"),
            "the poll interval must not advance while the machine is asleep"
        )
        XCTAssertFalse(
            source.contains("Task.sleep(for: interval)"),
            "a bare Task.sleep defaults to ContinuousClock, which keeps counting while asleep"
        )
    }
}

/// F4: the ✕ on the AI-status banner matched none of the three sources in
/// `dismissPriorityBanner`, so it did nothing — and on the circuit-open
/// banner, which has no action button, that ✕ was the only control.
final class PriorityBannerDismissalTests: XCTestCase {
    private let banners = ["undoErrorBanner", "syncHealthBanner", "aiStatusBanner", "loadErrorBanner"]

    /// Every source `priorityBanner` can select needs a branch that
    /// dismisses it, or its ✕ is a dead control. Checked on the source
    /// because a `@State` view is not drivable from a unit test.
    func test_everyPriorityBannerSourceHasADismissBranch() throws {
        let source = try ViewSource.read("RootView")
        let selection = try XCTUnwrap(
            source.range(of: "private var priorityBanner"),
            "priorityBanner moved"
        )
        let dismissal = try XCTUnwrap(
            source.range(of: "private func dismissPriorityBanner"),
            "dismissPriorityBanner moved"
        )
        let selected = source[selection.lowerBound..<dismissal.lowerBound]
        let dismissed = source[dismissal.lowerBound...].prefix(3_000)

        for banner in banners {
            XCTAssertTrue(
                selected.contains(banner),
                "\(banner) is no longer in the priority chain; the ✕ contract changed"
            )
            XCTAssertTrue(
                dismissed.contains("\(banner)?.title == banner.title"),
                "\(banner) has no dismiss branch; its ✕ does nothing"
            )
        }
    }

    /// The load-error branch used to set `syncHealthDismissed`, which
    /// silenced the *sync-health* banner and left the load error on screen.
    func test_dismissingTheLoadErrorNoLongerMutesTheSyncHealthBanner() throws {
        let source = try ViewSource.read("RootView")
        let start = try XCTUnwrap(source.range(of: "private func dismissPriorityBanner"))
        let body = source[start.lowerBound...].prefix(3_000)
        let branch = try XCTUnwrap(
            body.range(of: "loadErrorBanner?.title == banner.title"),
            "the load-error dismiss branch moved"
        )
        // The branch body is the text up to the next branch or the end.
        // Comments are stripped: the branch explains the old bug by name.
        let code = ViewSource.code(after: branch.upperBound, in: body, limit: 400)
        XCTAssertFalse(
            code.contains("syncHealthDismissed"),
            "dismissing the load error must not silence the sync-health banner"
        )
        XCTAssertTrue(
            code.contains("loadErrorDismissed"),
            "dismissing the load error must actually clear the load error"
        )
    }

    /// A dismissal only lasts until the next poll; otherwise a one-off
    /// failure would stay hidden for the rest of the session.
    func test_dismissalsAreResetOnTheNextPoll() throws {
        let source = try ViewSource.read("RootView")
        let loop = try XCTUnwrap(
            source.range(of: "while !Task.isCancelled {"),
            "the directory poll loop moved"
        )
        // Anchored on the loop: the same identifiers also appear in their
        // `@State` declarations, which is a `= false` that means nothing.
        let body = ViewSource.code(after: loop.lowerBound, in: source[loop.lowerBound...], limit: 600)
        for flag in [
            "syncHealthDismissed = false",
            "loadErrorDismissed = false",
            "aiStatusDismissed = false",
        ] {
            XCTAssertTrue(body.contains(flag), "\(flag) must be reset after every poll")
        }
    }
}

/// Locates and reads this package's production sources, so the tests above
/// can assert on code the type system cannot reach: SwiftUI modifier
/// placement, a view's private state, and a keyboard shortcut.
///
/// Deliberately literal — `String.range(of:)` is a substring search, not a
/// regular expression, and a regex-looking pattern silently never matches.
enum ViewSource {
    static func read(_ view: String) throws -> String {
        try String(contentsOf: url(under: "Views", view), encoding: .utf8)
    }

    static func url(under directory: String, _ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LagoonTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Sources/Lagoon/\(directory)/\(name).swift")
    }

    static func occurrences(of needle: String, in source: String) -> [String.Index] {
        var found: [String.Index] = []
        var cursor = source.startIndex
        while let next = source.range(of: needle, range: cursor..<source.endIndex) {
            found.append(next.lowerBound)
            cursor = next.upperBound
        }
        return found
    }

    /// The code that follows `index`, with comment lines removed. Several
    /// fixes here *name* the bug they fixed in a comment, and a test that
    /// reads the comment as the code would pass for the wrong reason.
    static func code<S: StringProtocol>(
        after index: S.Index,
        in source: S,
        limit: Int
    ) -> String {
        source[index...].prefix(limit)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
