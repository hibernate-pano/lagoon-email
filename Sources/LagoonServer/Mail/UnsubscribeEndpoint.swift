import Foundation

/// Hits an unsubscribe endpoint and decides whether the unsubscribe actually
/// happened.
///
/// This is not a route. It is an HTTP client with an SSRF guard, a streaming
/// body cap, a per-hop redirect re-check and an outcome classifier — none of
/// which has anything to do with mapping a URL to a handler. It lived inside
/// `ActionsRoutes.swift` only because the one-click-unsubscribe feature was
/// written straight into that file, and it is why the file reached 1231 lines:
/// a quarter of it was a mail-protocol concern sitting in the HTTP-routing
/// layer.
///
/// Its natural neighbour is `Mail/UnsubscribeScanner`: the scanner finds the
/// candidate links in a message, this hits one and judges the result. They are
/// two halves of the same feature and now live in the same directory.
///
/// Moved verbatim. Three things here are load-bearing and must not drift:
///
/// * `hitUnsubscribeProbe` is inside `#if DEBUG`. That is what makes it
///   impossible to talk a release binary into skipping the SSRF-guarded
///   session. The `#if`/`#endif` pair moved with it, unedited.
/// * `RedirectGuard.urlSession(_:dataTask:didReceive:)`'s signature. An
///   earlier version of this method carried a `completionHandler:` parameter,
///   which matches no `URLSessionDataDelegate` requirement — the compiler said
///   only "nearly matches optional requirement", the method was never called,
///   and the response-body cap silently never ran (see
///   docs/质量改进计划-2026-09-29.md, W0 item 1). `scripts/warn-gate.sh`
///   exists to catch exactly that; do not let a formatter touch these labels.
/// * `guardedSession` is the only session used, and `hitUnsubscribe`'s default
///   parameter refers to it. Default arguments are resolved at the declaration
///   site, so the two have to stay in the same type.
enum UnsubscribeEndpoint {
    /// Outcome of hitting an unsubscribe endpoint — 2xx alone is NOT success:
    /// a tracking link can 302 to a "how to leave" page that merely *offers*
    /// an unsubscribe entry, and recording that as done would archive the
    /// mail and leave the user subscribed.
    enum Hit {
        case completed
        case landingPage
        case failed
    }

    /// Best-effort unsubscribe against the chosen endpoint. When the sender
    /// advertised RFC 8058 one-click support, a POST with the standard body
    /// *is* the unsubscribe — no page, no extra click. Otherwise a single GET
    /// (the tokenized tracking-link unsubscribe, by far the most common).
    ///
    /// The old blind POST-before-GET is gone: POSTing a GET-shaped link
    /// usually returned a 200 landing page whose "manage preferences" footer
    /// then made `classifyHit` report "needs manual" — and the GET, the one
    /// request that would actually have unsubscribed, never ran.
    ///
    /// Redirects go through the session's delegate: EVERY hop is re-checked
    /// against the SSRF guard, because a public URL that 302s to loopback or
    /// 169.254.169.254 would otherwise defeat `isSafe`. An unsafe hop cancels
    /// the task (fail closed).
    ///
    /// ponytail: ceiling — one wall-clock budget for ALL attempts
    /// (`unsubscribeTimeout`), a streaming body cap (`maxUnsubscribeBodyBytes`)
    /// and a per-attempt timeout. The budget is enforced by cancelling the
    /// task group, so the hard floor is "whatever URLSession still owes us":
    /// if the transport ignored cancellation the worst case degrades to
    /// per-attempt timeouts, not to an unbounded hang.
    static func hitUnsubscribe(
        url: URL, oneClick: Bool = false, session: URLSession = guardedSession
    ) async throws -> Hit {
    #if DEBUG
        // ponytail: seam for offline route tests — absent from release builds.
        if let probe = hitUnsubscribeProbe { return try await probe(url) }
    #endif
        return try await withThrowingTaskGroup(of: Hit.self) { group in
            group.addTask { try await Self.attemptUnsubscribe(url: url, oneClick: oneClick, session: session) }
            group.addTask {
                try await Task.sleep(for: Self.unsubscribeTimeout)
                throw URLError(.timedOut)
            }
            let first = try await group.next() ?? .failed
            group.cancelAll()
            return first
        }
    }

    /// RFC 8058 one-click POST when the sender advertised it (the POST body
    /// is mandated by the RFC), then one GET. 2xx only is a candidate for
    /// success; anything else is not. In particular a 3xx must NEVER be
    /// classified: with the redirect guard in place a 3xx that reaches us is
    /// either a hop the guard refused or a chain the server cut short —
    /// recording that as completed would archive the mail and tell the user
    /// they unsubscribed.
    private static func attemptUnsubscribe(
        url: URL, oneClick: Bool, session: URLSession
    ) async throws -> Hit {
        if oneClick {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 10
            request.setValue("Lagoon/1.0", forHTTPHeaderField: "User-Agent")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("List-Unsubscribe=One-Click".utf8)
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch let error as URLError where error.code == .cancelled {
                // A refused redirect hop or a body past the streaming cap:
                // a deliberate stop, not a transport fault.
                return .failed
            }
            if let http = response as? HTTPURLResponse {
                if (200..<300).contains(http.statusCode) {
                    return await classifyAndConfirm(data: data, session: session)
                }
                if (300..<400).contains(http.statusCode) { return .failed }
                // 4xx/5xx: the endpoint rejected the POST (405-style). Fall
                // through to the GET rather than reporting failure — some
                // senders advertise the header but only serve the link.
            }
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Lagoon/1.0", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            return .failed
        }
        guard let http = response as? HTTPURLResponse else { return .failed }
        if (200..<300).contains(http.statusCode) {
            return await classifyAndConfirm(data: data, session: session)
        }
        if (300..<400).contains(http.statusCode) { return .failed }
        return .failed
    }

    /// ponytail: a 2xx body is "completed" unless it re-offers unsubscribe
    /// links (same scanner as the email body) — a confirmation page with a
    /// preferences-center footer must not auto-complete as a false success.
    /// Success phrases are checked FIRST: the typical confirmation page ends
    /// with "you have been unsubscribed" while still linking to a preferences
    /// centre, and the old link-only rule read that as "needs manual" — the
    /// single largest source of "明明退订了却提示失败".
    static func classifyHit(data: Data) -> Hit {
        guard let body = String(data: data, encoding: .utf8) else { return .completed }
        if containsSuccessSignal(body) { return .completed }
        if UnsubscribeScanner.bodyLinks(in: body).isEmpty { return .completed }
        return .landingPage
    }

    /// English phrases are worded so a confirmation *ask* ("you are about to
    /// be unsubscribed") does not match — it lacks the completed tense.
    private static let successSignals = [
        "successfully unsubscribed", "have been unsubscribed",
        "has been unsubscribed", "you've been unsubscribed",
        "you are unsubscribed", "you're unsubscribed", "you're now unsubscribed",
        "no longer subscribed", "removed from our mailing list",
        "removed from our list", "removed you from",
        "退订成功", "已退订", "已为您退订", "已成功退订", "已取消订阅", "取消订阅成功",
    ]

    static func containsSuccessSignal(_ body: String) -> Bool {
        let lower = body.lowercased()
        return successSignals.contains { lower.contains($0) }
    }

    /// 2xx but judged a landing page → follow the page's own confirm entry
    /// ONCE and judge that response by the same rules. This is the click the
    /// user used to have to make by hand ("链接点进去还需要再点一次"); now the
    /// server makes it. Depth is capped at one: a page that is still ambiguous
    /// after the follow-up is honestly manual, never a guessed success.
    static func classifyAndConfirm(data: Data, session: URLSession) async -> Hit {
        let first = classifyHit(data: data)
        guard first == .landingPage else { return first }
        guard let body = String(data: data, encoding: .utf8),
              let candidate = UnsubscribeScanner.confirmLink(in: body),
              let url = URL(string: candidate),
              await UnsubscribeScanner.isSafe(url: url)
        else { return .landingPage }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Lagoon/1.0", forHTTPHeaderField: "User-Agent")
        let data2: Data
        let response2: URLResponse
        do {
            (data2, response2) = try await session.data(for: request)
        } catch {
            return .landingPage
        }
        guard let http = response2 as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { return .landingPage }
        return classifyHit(data: data2)
    }

    /// Streaming cap on the unsubscribe response: `data(for:)` would buffer
    /// an attacker-chosen body whole before we ever regex it. Past the cap the
    /// task is failed, which the attempt loop reports as `.failed`.
    static let maxUnsubscribeBodyBytes = 256 * 1024
    /// Wall-clock budget covering both the POST and the GET attempt.
    static let unsubscribeTimeout: Duration = .seconds(30)

#if DEBUG
    /// ponytail: seam for offline route tests; absent from release builds, so
    /// the production binary cannot be talked into skipping the SSRF-guarded
    /// session.
    static var hitUnsubscribeProbe: (@Sendable (URL) async throws -> Hit)?
#endif

    private static let guardedSession: URLSession = makeProbeSession()

    /// The one session the unsubscribe probe uses: SSRF-checked redirects and
    /// a streaming body cap in one delegate. Internal so tests can build the
    /// same session over a stub `URLProtocol`.
    static func makeProbeSession(maxBodyBytes: Int = maxUnsubscribeBodyBytes) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        return URLSession(
            configuration: config,
            delegate: RedirectGuard(maxBodyBytes: maxBodyBytes),
            delegateQueue: nil
        )
    }

    /// Re-validates each redirect hop against the SSRF guard — the P0 fix
    /// for "public URL redirects to an internal target" — and caps how much of
    /// the response we are willing to buffer.
    final class RedirectGuard: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
        private let maxBodyBytes: Int
        private let lock = NSLock()
        private var received: [Int: Int] = [:]

        init(maxBodyBytes: Int) {
            self.maxBodyBytes = maxBodyBytes
            super.init()
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let url = request.url else {
                task.cancel()
                completionHandler(nil)
                return
            }
            Task {
                if await UnsubscribeScanner.isSafe(url: url) {
                    completionHandler(request)
                } else {
                    task.cancel()
                    completionHandler(nil)
                }
            }
        }

        /// This must match `URLSessionDataDelegate`'s requirement exactly.
        /// There is no `completionHandler:` variant of this method in the
        /// protocol: a signature that merely *resembles* it compiles with a
        /// "nearly matches optional requirement" warning and is then never
        /// called by URLSession at all, which silently disables the cap.
        func urlSession(
            _ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data
        ) {
            lock.lock()
            let total = (received[dataTask.taskIdentifier] ?? 0) + data.count
            received[dataTask.taskIdentifier] = total
            lock.unlock()
            if total > maxBodyBytes {
                // Cancelling is the only way to stop a `data(for:)` read: the
                // call then throws `.cancelled`, which the attempt loop
                // reports as `.failed`.
                dataTask.cancel()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock()
            received[task.taskIdentifier] = nil
            lock.unlock()
        }
    }
}
