import Foundation
import LagoonKit

/// The scoped 「改分组」 request.
///
/// It lives beside `APIClient` rather than inside it, for the same reason
/// `L10n+Override.swift` lives beside `L10n.swift`: the file that *defines*
/// the feature and the file that *carries* it stay separate, so two
/// features can each add a method without both editing the same 4000-line
/// file.
///
/// The scope travels as a plain string in the JSON body — the server reads
/// the same `OverrideScope` raw value, so there is no mapping table to
/// drift.
extension APIClient {
    /// POST /api/messages/{remoteId}/classify {fromGroup,toGroup,scope}
    ///
    /// `scope` says how far the change reaches:
    /// * `.message` — this mail only.
    /// * `.sender` — every mail from this sender.
    ///
    /// ## Why the scope is always sent
    ///
    /// The server treats a request with no scope as `.message` — the narrow
    /// one — but this client always sends it explicitly. A client that
    /// relies on the server's default is a client whose behaviour changes
    /// when the server's default does, and the whole point of the scope is
    /// that the promise is explicit.
    ///
    /// `from` is the group the mail is in *now*, used by the server to
    /// compute the counter-override that undo writes. Passing nil lets the
    /// server work it out from the stored overrides and the heuristic.
    public func overrideClassification(
        remoteId: String,
        accountId: UUID,
        from: BriefingGroup?,
        to: BriefingGroup,
        scope: OverrideScope
    ) async throws {
        let url = try makeURL(path: ["api", "messages", remoteId, "classify"], query: [
            .init(name: "accountId", value: accountId.uuidString)
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "toGroup": to.rawValue,
            "scope": scope.rawValue,
        ]
        if let from {
            body["fromGroup"] = from.rawValue
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = APITimeout.fast.seconds
        _ = try await send(request, timeout: .fast)
    }
}
