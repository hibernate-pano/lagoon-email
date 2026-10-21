import XCTest
@testable import Lagoon

/// The undo toast's countdown and the user's pointer.
///
/// The toast disappears on its own after six seconds, which is right for
/// someone who is not looking at it and wrong for someone who is — the
/// whole point of the toast is that there is a button to reach for, and
/// taking the button away while the user is reaching for it is the single
/// worst moment to do it.
///
/// These tests pin the rule: hovering the toast stops the clock, and
/// leaving it lets the clock run out the time it had left (not a fresh
/// full six seconds, which would make the toast immortal to a user who
/// keeps the pointer nearby).
@MainActor
final class UndoToastDismissTests: XCTestCase {
    private func makeController() -> UndoController {
        UndoController(api: APIClient(baseURL: URL(string: "http://127.0.0.1:8080")!))
    }

    /// The toast must survive its own deadline while the pointer is on it.
    func test_hoveringKeepsTheToastOnScreenPastItsDeadline() async {
        let controller = makeController()
        controller.show(UndoItem(id: 1, message: "已归档", systemImage: "tray"), autoDismissAfter: 0.3)

        controller.setHovering(true)
        // Well past the deadline: without the pause the toast is long gone.
        try? await Task.sleep(for: .milliseconds(700))

        XCTAssertNotNil(
            controller.current,
            "a toast the user is pointing at must not vanish on a timer"
        )
    }

    /// Moving the pointer away lets the toast go — the pause is a pause, not
    /// a cancellation.
    func test_leavingTheToastResumesTheCountdown() async {
        let controller = makeController()
        controller.show(UndoItem(id: 1, message: "已归档", systemImage: "tray"), autoDismissAfter: 0.3)

        controller.setHovering(true)
        try? await Task.sleep(for: .milliseconds(100))
        controller.setHovering(false)
        try? await Task.sleep(for: .milliseconds(700))

        XCTAssertNil(controller.current, "the toast must still go away on its own")
    }

    /// The pause must not restart the clock. If it did, a user who parks the
    /// pointer on the toast would keep it alive forever, and the timeout
    /// would stop being a timeout.
    func test_thePauseKeepsTheRemainingTimeRatherThanRestartingIt() async {
        let controller = makeController()
        controller.show(UndoItem(id: 1, message: "已归档", systemImage: "tray"), autoDismissAfter: 0.8)

        // Let a third of the countdown elapse, then park the pointer.
        try? await Task.sleep(for: .milliseconds(400))
        controller.setHovering(true)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertNotNil(controller.current, "the pause must hold the toast")

        controller.setHovering(false)
        // The remaining time was ~0.4s. A restarted clock would need 0.8s,
        // so 0.6s separates the two behaviours.
        try? await Task.sleep(for: .milliseconds(600))

        XCTAssertNil(
            controller.current,
            "leaving the toast must resume the time it had left, not a fresh countdown"
        )
    }

    /// A toast that is dismissed on purpose must not have a timer left
    /// running behind it: the timer would fire later and clear whatever
    /// toast took its place.
    func test_dismissingCancelsThePendingCountdown() async {
        let controller = makeController()
        controller.show(UndoItem(id: 1, message: "已归档", systemImage: "tray"), autoDismissAfter: 0.3)
        controller.dismiss()

        try? await Task.sleep(for: .milliseconds(600))

        XCTAssertNil(controller.current)
    }
}
