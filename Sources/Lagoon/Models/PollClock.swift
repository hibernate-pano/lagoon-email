import Foundation
import SwiftUI

/// Sleeps one interval for a keep-alive poll loop.
///
/// `Task.sleep` defaults to `ContinuousClock`, which keeps counting while
/// the machine is suspended: after a two-hour sleep every window's 30s
/// timer expires at once and the app fires a burst of requests at a server
/// that was idle the whole time. `SuspendingClock` measures awake time only,
/// which is what "every 30 seconds" was supposed to mean.
///
/// Returns false only on cancellation, so the caller's `while` exits.
/// Deliberately *not* false when the app is in the background: ending the
/// loop there would be worse than polling, because a view still in the
/// hierarchy never gets its `.task` back and the list would stop updating
/// for the rest of the session. Backgrounding is handled by skipping the
/// work instead — see `shouldPoll`.
@discardableResult
func sleepForPoll(_ interval: Duration) async -> Bool {
    do {
        try await Task.sleep(for: interval, clock: .suspending)
    } catch {
        return false
    }
    return true
}

/// Whether a keep-alive loop should do its work right now.
///
/// A surface the user has switched away from has nothing to show, and the
/// server's sync loop runs whether or not anyone is looking, so the client
/// polling adds nothing but wake-ups. This is the one rule all four loops
/// share.
func shouldPoll(isVisible: Bool, scenePhase: ScenePhase) -> Bool {
    isVisible && scenePhase == .active
}
