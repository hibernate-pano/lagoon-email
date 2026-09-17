import Foundation
import SwiftUI

/// Global sink for ephemeral error / success notices (spec §2.3).
///
/// `ErrorCenter` is the channel for failures raised outside the view
/// layer (e.g. a polling task, a `NotificationCenter` handler, a
/// background sync loop) so they can still surface to the user without
/// coupling the producer to a specific view. Views that own their own
/// state can keep their local `@State` banners; this is the fallback for
/// "I caught an error and I don't know who to tell".
@MainActor
public final class ErrorCenter: ObservableObject {
    public static let shared = ErrorCenter()

    @Published public var banner: ErrorBanner?

    private init() {}

    /// Replace whatever banner is currently showing. Per spec INV-6, the
    /// latest report always wins — there is never more than one banner
    /// on screen.
    public func report(_ banner: ErrorBanner) {
        self.banner = banner
    }

    /// Clear whatever banner is currently showing. Safe to call when no
    /// banner is present.
    public func dismiss() {
        self.banner = nil
    }
}
