import Foundation
import LagoonKit

/// The inline-image client calls, kept in its own file so the feature that
/// needs it does not have to edit `APIClient.swift` while another agent is
/// working in it.
extension APIClient {
    /// GET /api/messages/{remoteId}/inline-images?accountId= — the inline
    /// (`cid:`) image bytes of one message, keyed by lower-cased Content-ID.
    ///
    /// ## Why this replaces N per-image requests
    ///
    /// The old path asked the server for one attachment at a time, and the
    /// server answered each one by re-fetching and re-parsing the **entire**
    /// message over IMAP. A mail with 20 inline images therefore cost 20
    /// full-message IMAP fetches on the server and 20 HTTP requests on the
    /// client. This route reads the message once.
    ///
    /// The call is `.interactive` (30s) rather than `.fast` (10s) because it
    /// does real IMAP work on a cold connection — the same reason
    /// `fetchBriefing` and the summary path use it.
    ///
    /// A server that does not have this route answers 404, which surfaces
    /// as a thrown `APIError`. The caller treats that as "no images" and
    /// falls back to the per-image path, so a new client still works
    /// against an old server.
    public func fetchInlineImages(
        remoteId: String,
        accountId: UUID
    ) async throws -> InlineImagesResponse {
        let url = try makeURL(
            path: ["api", "messages", remoteId, "inline-images"],
            query: [.init(name: "accountId", value: accountId.uuidString)]
        )
        var request = URLRequest(url: url)
        request.timeoutInterval = APITimeout.interactive.seconds
        let (data, _) = try await send(request, timeout: .interactive)
        return try Self.decode(InlineImagesResponse.self, from: data)
    }
}
