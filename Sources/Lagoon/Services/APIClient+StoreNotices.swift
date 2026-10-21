import Foundation
import LagoonKit

/// The store's one-shot notices for the user.
///
/// ## Why this is an extension and not a method on `APIClient`
///
/// `APIClient.swift` is a file several features edit. This is one feature's
/// need, and putting it here means that feature can change without
/// touching the file everyone else is in.
extension APIClient {
    /// `GET /api/store-notices` — every notice the store has.
    public func fetchStoreNotices() async throws -> [StoreNotice] {
        let url = try makeURL(path: ["api", "store-notices"], query: [])
        var request = URLRequest(url: url)
        request.timeoutInterval = APITimeout.fast.seconds
        let (data, _) = try await send(request, timeout: .fast)
        return try Self.decode(StoreNoticeListResponse.self, from: data).notices
    }

    /// `POST /api/store-notices/{id}/ack` — the user has seen the notice.
    ///
    /// Called **after** the notice has been shown, so a failure here leaves
    /// the notice in place and the user hears about it again next time.
    /// That is the right way round: a notice that was shown and could not be
    /// marked as shown is annoying, and a notice that was never shown and
    /// was marked as shown is invisible.
    public func acknowledgeStoreNotice(id: String) async throws {
        let url = try makeURL(path: ["api", "store-notices", id, "ack"], query: [])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = APITimeout.fast.seconds
        _ = try await send(request, timeout: .fast)
    }
}
