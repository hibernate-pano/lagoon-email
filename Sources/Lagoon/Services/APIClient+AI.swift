import Foundation
import LagoonKit

/// The AI calls the settings panel makes.
///
/// They live in their own file for the same reason the AI strings do: the
/// panel and the requests it sends are edited together, and a feature that
/// needs one AI call does not have to touch the 1000-line client.
extension APIClient {
    /// POST /api/ai/probe → what the provider actually said.
    ///
    /// ## Why this is a request and not a configuration check
    ///
    /// The button used to reload the configuration and read the resulting
    /// status, which answered "can these settings be parsed?" — a
    /// question whose answer is `true` for a revoked key, a wrong model
    /// name and a base URL pointing at a host that does not exist. The
    /// route behind this call really contacts the provider and reports
    /// what came back, so the panel can name the cause instead of
    /// guessing.
    ///
    /// ## Why the slow timeout
    ///
    /// The provider session allows 60 seconds for the request. The
    /// client's timeout has to be the longer of the two, or the client
    /// would give up while the server was still waiting for an answer
    /// that was about to arrive — and report a timeout for a request that
    /// actually succeeded.
    public func probeAI(environment: [String: String]) async throws -> AIProbeResult {
        let url = try makeURL(path: ["api", "ai", "probe"], query: [])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "environment": environment
        ])
        request.timeoutInterval = APITimeout.slow.seconds
        let (data, _) = try await send(request, timeout: .slow)
        return try Self.decode(AIProbeResult.self, from: data)
    }
}
