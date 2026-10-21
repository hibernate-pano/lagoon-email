import Foundation
import SwiftUI
import LagoonKit

/// The store's one-shot notices, and the banner that shows them.
///
/// ## Why this is a view-level store and not a `log` line
///
/// A migration that had to **delete** rows — because they could not be
/// encrypted — did something the user did not ask for and cannot undo. The
/// body migration was allowed to be silent because a body is a cache and
/// the next sync fetches it again. A draft is regenerable too, but the
/// user still asked for it, and "your drafts are gone" is a sentence they
/// are entitled to read.
///
/// The notice therefore lives in the **store** (a row the server keeps until
/// the client has shown it) rather than in a log file the user will never
/// open. The app may not even be running when the migration happens; the
/// notice waits.
///
/// ## Why the acknowledgement happens after the banner is shown
///
/// `acknowledge` is called once the banner has been handed to `ErrorCenter`.
/// A notice that was shown but could not be marked as shown comes back on
/// the next launch — mildly annoying, and the user can dismiss it. A notice
/// that was never shown and was marked as shown is *invisible*, and the user
/// never learns their drafts are gone. The asymmetry is deliberate.
@MainActor
public final class StoreNoticeCenter: ObservableObject {
    public static let shared = StoreNoticeCenter()

    /// The notices the store has, oldest first.
    @Published public private(set) var notices: [StoreNotice] = []

    /// The notice the banner is currently showing.
    ///
    /// One at a time, like every other banner in this app: a stack of
    /// notices is a stack the user reads past.
    @Published public private(set) var current: StoreNotice?

    private let api: APIClient

    public init(api: APIClient = APIClient.shared) {
        self.api = api
    }

    /// Fetches the notices the store has and shows the first one.
    ///
    /// Best-effort by design: a failure to fetch notices is not a reason to
    /// take the app down, and the notices are still in the store — the next
    /// poll will pick them up.
    public func refresh() async {
        do {
            let fetched = try await api.fetchStoreNotices()
            notices = fetched
            if current == nil {
                current = fetched.first
            }
        } catch {
            // The notices stay where they are: the store keeps them until
            // they have been shown, so a failed poll costs a delay, not a
            // message.
        }
    }

    /// Marks the current notice as seen.
    ///
    /// The banner is cleared **first**: the user has been told, and the
    /// acknowledgement is a bookkeeping call that may fail. A notice that
    /// stays on screen because the bookkeeping failed would be a banner the
    /// user cannot get rid of.
    public func acknowledgeCurrent() async {
        guard let notice = current else { return }
        current = nil
        notices.removeAll { $0.id == notice.id }
        do {
            try await api.acknowledgeStoreNotice(id: notice.id)
        } catch {
            // The server keeps the notice and will offer it again. The
            // user has already read it once; a repeat is better than a
            // message that vanishes without the server knowing.
        }
    }
}
