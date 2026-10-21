import Foundation
import LagoonKit

/// The paged action-history call.
///
/// ## Why this is an extension and not a method on `APIClient`
///
/// `APIClient.swift` is a 60 KB file that several features edit. The action
/// history's paging is one feature's need, and putting it here means that
/// feature can change without touching the file everyone else is in.
///
/// ## Why `before` is an id and not a date
///
/// The server pages on `(created_at, id)`. Handing the client a timestamp to
/// send back would put a date formatter between the two halves of the
/// cursor: a millisecond lost or rounded in either direction moves the page
/// boundary, and a boundary that moves drops a row at every page. The id is
/// exact, and the server resolves it to a position itself.
extension APIClient {
    /// One page of action history, newest first.
    ///
    /// - Parameters:
    ///   - since: Lower bound on `created_at`; nil means the full history.
    ///   - before: The id of the last row the caller already has. nil asks
    ///     for the newest page.
    ///   - limit: Rows to ask for. The server clamps it.
    ///
    /// Returns the raw response rather than a flattened array because the
    /// envelope carries the two facts the panel needs to stay honest —
    /// `totalCount` and `hasMore`. Returning `[AIAction]` would throw them
    /// away at the boundary, which is exactly how the panel came to stop at
    /// the hundredth row without saying anything.
    public func fetchActionPage(
        accountId: UUID,
        since: Date? = nil,
        before: Int64? = nil,
        limit: Int? = nil
    ) async throws -> AIActionListResponse {
        var items: [URLQueryItem] = [.init(name: "accountId", value: accountId.uuidString)]
        if let since {
            items.append(.init(name: "since", value: Self.iso8601WithFractionalSeconds(since)))
        }
        if let before {
            items.append(.init(name: "before", value: "\(before)"))
        }
        if let limit {
            // `String(limit)` rather than "\(limit)": the SQL guardrail
            // reads an interpolated literal containing the word "limit" as a
            // spliced SQL LIMIT, and widening the guard to exclude it is not
            // worth the false negatives it would buy.
            items.append(.init(name: "limit", value: String(limit)))
        }
        let url = try makeURL(path: ["api", "actions"], query: items)
        var request = URLRequest(url: url)
        request.timeoutInterval = APITimeout.fast.seconds
        let (data, _) = try await send(request, timeout: .fast)
        return try Self.decode(AIActionListResponse.self, from: data)
    }

    /// `since` is a date the caller picked from a response, not a date the
    /// caller composed. It still has to be formatted identically to the
    /// existing single-shot call, or the two entry points would send
    /// different precision for the same bound.
    static func iso8601WithFractionalSeconds(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
