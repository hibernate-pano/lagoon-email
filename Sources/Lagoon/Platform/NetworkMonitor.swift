import Foundation
import Network

/// Whether the Mac currently has a usable network path.
///
/// ## Why the app needs this
///
/// The embedded server holds the last synced mail in a local SQLite file, so
/// when the network drops the window still shows every message the user has
/// already seen. Nothing in the UI said so: the list simply stopped
/// changing, and the first sign of trouble was a red banner about a failed
/// sync — which reads like *the app is broken* when the truth is *the
/// network is gone and what you see is fine, just stale*.
///
/// These are different situations and they deserve different words, so the
/// app watches the path instead of inferring "offline" from a failed
/// request. A failed request has a dozen causes; a failed path has one.
@MainActor
public final class NetworkMonitor: ObservableObject {
    /// The process-wide monitor. One `NWPathMonitor` is enough for the whole
    /// app; several of them wake the network stack for the same answer.
    public static let shared = NetworkMonitor()

    /// `true` when there is a path that can carry traffic.
    @Published public private(set) var isOnline: Bool = true

    /// `true` when the path is metered (cellular, or a hotspot). The app can
    /// still work; it just should not quietly pull a hundred megabytes of
    /// mail over someone's data plan.
    @Published public private(set) var isExpensive: Bool = false

    /// `true` until the monitor has reported its first path. Before that the
    /// app cannot honestly claim to be online, and showing the offline strip
    /// for a split second on launch would be noise.
    @Published public private(set) var hasReported: Bool = false

    private var monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "lagoon.network-monitor")

    /// - Parameter monitoring: `false` builds a monitor that never touches
    ///   the network stack, so the state can be driven by hand. The app uses
    ///   the shared instance; tests and previews use this seam, because a
    ///   test that races the real path updates proves nothing.
    public init(monitoring: Bool = true) {
        guard monitoring else { return }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let expensive = path.isExpensive
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isOnline = online
                self.isExpensive = expensive
                self.hasReported = true
            }
        }
        monitor.start(queue: queue)
    }

    /// Test seam: the monitoring logic is what the tests care about, not
    /// `NWPathMonitor` itself. `apply(path:)` takes the two facts the
    /// handler reads and pushes them through the same door.
    public func apply(online: Bool, expensive: Bool) {
        isOnline = online
        isExpensive = expensive
        hasReported = true
    }
}
