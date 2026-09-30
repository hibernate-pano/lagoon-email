import XCTest
import SwiftUI
import LagoonKit
@testable import Lagoon

/// F5 (fixed as V1): the wire is two-way now — `/read?isRead=false`
/// clears `\\Seen` remotely and writes FALSE locally — so the row offers
/// the toggle in both directions instead of hiding it on read rows.
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

    func test_readVerbTitlePointsBothWays() {
        XCTAssertEqual(readVerbTitle(header(isRead: false), l10n: L10n(language: .zhHans)), "标为已读")
        XCTAssertEqual(readVerbTitle(header(isRead: true), l10n: L10n(language: .zhHans)), "标为未读")
    }

    /// The toggle must compute its target from the row, not early-return:
    /// a `guard !m.isRead else { return }` here means mark-unread is dead.
    func test_toggleReadHasNoOneWayGuard() throws {
        let source = try ViewSource.read("MessageListView")
        XCTAssertFalse(
            source.contains("guard !m.isRead else { return }"),
            "toggleRead still early-returns on read rows; mark-unread is dead"
        )
        XCTAssertTrue(
            source.contains("let target = !m.isRead"),
            "toggleRead must derive its target from the row"
        )
    }

    /// The API client must send isRead=false for the unread direction.
    func test_apiClientSendsIsReadFalse() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Lagoon/Services/APIClient.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("isRead"), "APIClient.markRead lost its isRead parameter")
    }
}

/// F29 (fixed as V1 decision): refresh moved to ⌥⌘R so it never collides
/// with ⌘R = reply on the open message. The old `path.isEmpty` guard is gone
/// on purpose — disjoint modifiers mean both bindings stay live in the same
/// stack without stealing each other.
final class RefreshShortcutScopeTests: XCTestCase {
    private static let replyShortcut = #".keyboardShortcut("r", modifiers: .command)"#
    private static let refreshShortcut = #".keyboardShortcut("r", modifiers: [.command, .option])"#

    /// Both list surfaces bind refresh as ⌥⌘R, and no plain ⌘R remains there
    /// to fight the detail view's reply binding.
    func test_refreshUsesOptionCommandRAndReplyKeepsCommandR() throws {
        for view in ["MessageListView", "BriefingFeedView"] {
            let source = try ViewSource.read(view)
            XCTAssertNotNil(
                source.range(of: Self.refreshShortcut),
                "\(view): the ⌥⌘R refresh binding disappeared"
            )
            XCTAssertNil(
                source.range(of: Self.replyShortcut),
                "\(view): plain ⌘R is still bound here and will steal reply"
            )
        }
    }

    /// The detail view keeps ⌘R for reply — the *list* moved, not the
    /// message. Reply is what the user is reaching for when a message is
    /// open, and the binding predates the list's.
    func test_theMessageKeepsCommandRForReply() throws {
        let detail = try ViewSource.read("MessageDetailView")
        let reply = try XCTUnwrap(
            detail.range(of: Self.replyShortcut),
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

    /// The help surfaces must not list ⌘R twice: reply keeps ⌘R, refresh
    /// shows ⌥⌘R.
    func test_helpSurfacesShowDisjointShortcuts() throws {
        let sheet = ShortcutsSheet().entries
        let reply = sheet.first { $0.id == "reply" }
        let refresh = sheet.first { $0.id == "refresh" }
        XCTAssertEqual(reply?.keys, "⌘R")
        XCTAssertEqual(refresh?.keys, "⌥⌘R")
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

    /// V1: an unconfigured AI must surface a banner that routes to the
    /// settings sheet — otherwise a fresh install shows no AI hint and no
    /// path to fix it. The banner's action opens the sheet.
    func test_unconfiguredAIBannerRoutesToSettings() throws {
        let source = try ViewSource.read("RootView")
        let start = try XCTUnwrap(source.range(of: "private var aiStatusBanner"))
        let body = source[start.lowerBound...].prefix(2_000)
        XCTAssertTrue(
            body.contains("!status.configured"),
            "aiStatusBanner lost its unconfigured branch; fresh installs get no AI hint"
        )
        XCTAssertTrue(
            body.contains("showAISettings = true"),
            "the unconfigured banner must open the AI settings sheet"
        )
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
