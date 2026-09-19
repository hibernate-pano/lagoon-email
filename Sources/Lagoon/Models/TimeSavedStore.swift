import Foundation
import LagoonKit

/// Client-side cache of `GET /api/time-saved` for the status bar
/// (spec principle #3: quantified time saved).
///
/// A failed refresh keeps the previous report: the status bar is a passive
/// instrument, and flashing an error banner for it would outrank the surfaces
/// that actually need attention (sync health, load errors).
@MainActor
public final class TimeSavedStore: ObservableObject {
    @Published public private(set) var report: TimeSavedReport?

    /// Slower than the directory poll — the numbers move on human timescale.
    public static let refreshInterval: Duration = .seconds(60)

    private let api: APIClient

    public init(api: APIClient = APIClient()) {
        self.api = api
    }

    public func refresh(accountId: UUID) async {
        report = try? await api.fetchTimeSaved(accountId: accountId)
    }

    public func clear() {
        report = nil
    }
}
