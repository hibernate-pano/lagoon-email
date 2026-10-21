import Foundation
import LagoonKit

/// The data-export endpoints.
///
/// An extension rather than new methods on `APIClient` for the same reason
/// `L10n+Backup` is an extension: the export is one feature, and neither
/// half of it should require editing a 1300-line file that every other
/// feature also edits.
extension APIClient {
    /// `GET /api/export/index?accountId=` — every message the local store
    /// knows about, oldest first.
    ///
    /// A dedicated route rather than `fetchMessages(limit:)`: that one is
    /// capped at the server's list ceiling and has no cursor, so an export
    /// built on it would stop at the cap and write a file that looks complete
    /// and is not. `.slow` because a large mailbox returns tens of thousands
    /// of small rows in one response, and the 10s fast tier is a gamble on
    /// how long that takes over a loaded disk.
    public func fetchExportIndex(accountId: UUID) async throws -> [MessageHeader] {
        let url = try makeURL(path: ["api", "export", "index"], query: [
            .init(name: "accountId", value: accountId.uuidString)
        ])
        var request = URLRequest(url: url)
        request.timeoutInterval = APITimeout.slow.seconds
        let (data, _) = try await send(request, timeout: .slow)
        return try Self.decode(ExportIndexResponse.self, from: data).messages
    }

    /// The server's answer to `/api/export/index`, decoded into headers only.
    ///
    /// The folder tallies the route also returns are not needed on this side
    /// — the export describes itself by what it actually writes — so they
    /// are decoded and dropped rather than given a second client-side type
    /// that would then have to be kept in step with the server's.
    struct ExportIndexResponse: Decodable {
        let messages: [MessageHeader]
        let totalCount: Int
        let deletedCount: Int
        let sentCount: Int
    }
}
