import XCTest
import Foundation
import Network
import Hummingbird
import HummingbirdTesting
import Logging
import GRDB
import LagoonKit
@testable import LagoonServer

/// Route-level tests for the one-click unsubscribe resolution chain:
/// live header → stored candidates → body scan → 422, plus the fixes for
/// both P1 classes (a header-read failure must not mask stored links; bare
/// unbracketed header URLs must resolve; a `mailto:` in one stage must not
/// short-circuit an https link in a later stage) and for the transport
/// (a 3xx is never a completed unsubscribe). The resolution chain is stubbed
/// through `UnsubscribeEndpoint.hitUnsubscribeProbe`; the transport is driven over a
/// stub `URLProtocol` (status/body classification) and a loopback server
/// (a real 302 hop), so the suite stays offline.
final class UnsubscribeRouteTests: XCTestCase {
    private static let logger = Logger(label: "unsubscribe-route-tests")

    override func tearDown() {
        UnsubscribeEndpoint.hitUnsubscribeProbe = nil
        super.tearDown()
    }

    // MARK: - Harness

    private func makeAccount() -> Account {
        Account(
            id: UUID(),
            provider: .qq,
            oauthUser: "unsub-\(UUID().uuidString)",
            email: "unsub-\(UUID().uuidString)@qq.com",
            credentials: nil
        )
    }

    private func cleanup(_ account: Account) -> @Sendable (LagoonDB) async -> Void {
        { conn in
            try? await TestDatabase.deleteMessages(accountId: account.id, db: conn)
            try? await TestDatabase.deleteAccount(id: account.id, db: conn)
        }
    }

    private func header(accountId: UUID, remoteId: String) -> MessageHeader {
        MessageHeader(
            id: UUID(),
            accountId: accountId,
            remoteId: remoteId,
            threadId: "t-\(remoteId)",
            fromAddress: "alice@example.com",
            fromName: nil,
            subject: "news",
            snippet: nil,
            receivedAt: Date(),
            isRead: false,
            isArchived: false
        )
    }

    private static func makeRouter(
        provider: any MailProvider, db: LagoonDB
    ) -> Router<BasicRequestContext> {
        let router = Router<BasicRequestContext>()
        ActionsRoutes.register(
            on: router, db: db,
            logger: logger, makeProvider: { _ in provider }
        )
        return router
    }

    /// Records every URL the endpoint actually tried to hit.
    private final class URLRecorder: @unchecked Sendable {
        private(set) var urls: [URL] = []
        func append(_ url: URL) { urls.append(url) }
    }

    /// Header reads fine and offers nothing, but the body fetch dies: the
    /// route must report the transport failure, never "no unsubscribe link".
    private actor BodyFailingProvider: MailProvider {
        let kind: MailProviderKind = .qq
        func capabilities() async -> MailCapabilities {
            MailCapabilities(archiveFolder: true, idle: false, move: true, serverSnippet: false)
        }
        func pullChanges(after cursor: MailSyncState, waitUpTo: Duration) async throws -> MailChangeSet {
            MailChangeSet(upserts: [], resetRequired: false, cursor: cursor)
        }
        func fetchBody(remoteId: String) async throws -> FetchedBody {
            throw MailError.unreachable("imap down")
        }
        func fetchAttachment(remoteId: String, attachmentId: String) async throws -> FetchedAttachmentBytes {
            throw AttachmentError.notFound
        }
        func fetchRawMessage(remoteId: String) async throws -> Data { Data() }
        func fetchRawHeaderValues(remoteId: String) async throws -> [String: String] { [:] }
        func setRead(remoteId: String, isRead: Bool) async throws {}
        func archive(remoteId: String) async throws {}
        func unarchive(remoteId: String) async throws {}
        func trash(remoteId: String) async throws {}
        func restoreFromTrash(remoteId: String) async throws {}
        func permanentlyDelete(remoteId: String) async throws {}
        func emptyTrash() async throws {}
        /// R2: folders `listFolders` returns and moves the stub recorded.
        var folderRows: [MailFolder] = []
        var moveCalls: [(remoteId: String, folder: String, createIfMissing: Bool)] = []
        var moveFailure: MailError?
        func listFolders() async throws -> [MailFolder] { folderRows }
        @discardableResult
        func move(remoteId: String, to folder: String, createIfMissing: Bool) async throws -> Bool {
            moveCalls.append((remoteId, folder, createIfMissing))
            if let moveFailure { throw moveFailure }
            return true
        }
        func listSent(limit: Int) async throws -> [MessageHeader] { [] }
        func send(_ outbound: OutboundMessage) async throws -> String? { nil }
        func probe() async throws {}
    }

    // MARK: - Transport (real session, stubbed protocol)

    /// A `URLProtocol` that answers from a script and records every request it
    /// is asked to make. Scope: what `hitUnsubscribe` does with a status code
    /// and a body. It CANNOT drive `RedirectGuard` — a 302 returned from a
    /// `URLProtocol` never reaches the task delegate, and its data never
    /// reaches the data delegate (see `LocalHTTPServer` / the guard unit tests).
    final class StubURLProtocol: URLProtocol {
        struct Reply {
            var status: Int
            var headers: [String: String] = [:]
            var body: Data = Data()
        }

        private static let lock = NSLock()
        private static var script: [String: Reply] = [:]
        private static var seen: [URL] = []
        private static var requests: [(url: URL, method: String, body: Data)] = []

        static func reset() {
            lock.lock(); defer { lock.unlock() }
            script = [:]; seen = []; requests = []
        }
        static func script(_ reply: Reply, for url: String) {
            lock.lock(); defer { lock.unlock() }
            script[url] = reply
        }
        static var seenURLs: [URL] {
            lock.lock(); defer { lock.unlock() }
            return seen
        }
        static var seenRequests: [(url: URL, method: String, body: Data)] {
            lock.lock(); defer { lock.unlock() }
            return requests
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url else { return }
            Self.lock.lock()
            Self.seen.append(url)
            Self.requests.append((url, request.httpMethod ?? "GET", Self.requestBody(of: request)))
            let reply = Self.script["\(url) \(request.httpMethod ?? "GET")"]
                ?? Self.script[url.absoluteString]
                ?? Self.script[url.host ?? ""]
            Self.lock.unlock()
            let response = HTTPURLResponse(
                url: url, statusCode: reply?.status ?? 404,
                httpVersion: "HTTP/1.1", headerFields: reply?.headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            guard let body = reply?.body, !body.isEmpty else {
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }

        /// `URLProtocol` usually delivers a set body via `httpBodyStream`,
        /// not `httpBody` — read whichever carries it.
        private static func requestBody(of request: URLRequest) -> Data {
            if let body = request.httpBody, !body.isEmpty { return body }
            guard let stream = request.httpBodyStream else { return Data() }
            stream.open()
            defer { stream.close() }
            var body = Data()
            let size = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: size)
                guard read > 0 else { break }
                body.append(buffer, count: read)
            }
            return body
        }

        override func stopLoading() {}
    }

    /// A `URLSessionTask` stand-in — the guard's only move on a task is
    /// `cancel()`, and a real task cannot be constructed outside `URLSession`.
    final class ProbeTask: URLSessionDataTask, @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        override func cancel() {
            lock.lock(); cancelled = true; lock.unlock()
        }
    }

    /// The production session shape (SSRF-checked redirect hops + body cap)
    /// over a stub protocol: no network, no DNS.
    private static func stubProbeSession(
        maxBodyBytes: Int = UnsubscribeEndpoint.maxUnsubscribeBodyBytes
    ) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(
            configuration: config,
            delegate: UnsubscribeEndpoint.RedirectGuard(maxBodyBytes: maxBodyBytes),
            delegateQueue: nil
        )
    }

    /// A loopback HTTP server that answers every request with one canned
    /// response and counts what it was asked. `URLProtocol` stubs bypass
    /// `URLSession`'s redirect machinery (a 302 handed back by a
    /// `URLProtocol` is never handed to the task delegate, and its data never
    /// reaches the data delegate), so the only honest way to assert "a refused
    /// hop issues NO second request" is a real socket.
    final class LocalHTTPServer: @unchecked Sendable {
        private let location: @Sendable () -> String?
        private let lock = NSLock()
        private var count = 0
        private var listener: NWListener?
        private var port: Int?

        /// - Parameter location: the `Location` header to answer with; nil
        ///   answers 204 instead.
        init(location: @escaping @Sendable () -> String?) {
            self.location = location
        }

        var requestCount: Int { withLock { count } }
        var boundPort: Int? { withLock { port } }
        var url: URL? { boundPort.map { URL(string: "http://127.0.0.1:\($0)/unsub")! } }

        private func withLock<T>(_ body: () -> T) -> T {
            lock.lock(); defer { lock.unlock() }; return body()
        }
        private func recordRequest() { withLock { count += 1 } }
        private func recordPort(_ value: Int) { withLock { port = value } }

        func start() async throws {
            let listener = try NWListener(using: .tcp, on: .any)
            self.listener = listener
            let ready = AsyncStream<Int> { continuation in
                listener.stateUpdateHandler = { state in
                    if case .ready = state, let port = listener.port {
                        continuation.yield(Int(port.rawValue))
                        continuation.finish()
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                self?.handle(conn)
            }
            listener.start(queue: .global(qos: .utility))
            var iterator = ready.makeAsyncIterator()
            guard let bound = await iterator.next() else {
                throw CancellationError()
            }
            recordPort(bound)
        }

        private func handle(_ conn: NWConnection) {
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
                        _, _, _, _ in
                        self.recordRequest()
                        let head: String
                        if let target = self.location() {
                            head = "HTTP/1.1 302 Found\r\nLocation: \(target)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                        } else {
                            head = "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                        }
                        conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in
                            conn.cancel()
                        })
                    }
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .utility))
        }
    }

    private static func body(of response: TestResponse) -> String {
        String(decoding: Data(buffer: response.body), as: UTF8.self)
    }

    // MARK: - Tests

    /// Nothing anywhere → 422 with the exact code the client renders as
    /// "未检测到退订链接"; the body scan must have been attempted and no
    /// HTTP hit may fire.
    func test_nothingFound_returnsUnavailable() async throws {
        let account = makeAccount()
        let provider = StubMailProvider()
        await provider.configureUnsubscribe(rawHeaders: [:], bodyHTML: "<p>hello reader</p>")
        let recorder = URLRecorder()
        UnsubscribeEndpoint.hitUnsubscribeProbe = { url in
            recorder.append(url)
            return .failed
        }

        try await TestDatabase.withConnection(cleanup: cleanup(account)) { conn in
            try await AccountStore.upsert(account, credentials: Data([1, 2, 3]), db: conn)
            try await MessageStore.upsert(
                self.header(accountId: account.id, remoteId: "u-none"), db: conn
            )
            let app = Application(router: Self.makeRouter(provider: provider, db: conn))
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/messages/u-none/unsubscribe?accountId=\(account.id.uuidString)",
                    method: .post
                ) { response in
                    XCTAssertEqual(response.status, .unprocessableContent)
                    XCTAssertTrue(Self.body(of: response).contains("unsubscribe-unavailable"))
                }
            }
            let bodyFetches = await provider.bodyFetchCount
            XCTAssertEqual(bodyFetches, 1, "the body scan is the last resort and must run")
            XCTAssertEqual(recorder.urls.count, 0, "no candidate → nothing may be fetched")
        }
    }

    /// Stored candidates resolve WITHOUT touching the body, hit exactly the
    /// stored URL, and apply the local effects (read + archived + action row).
    func test_storedLink_resolvesWithoutBodyFetch() async throws {
        let account = makeAccount()
        let provider = StubMailProvider()
        await provider.configureUnsubscribe(rawHeaders: [:])
        let recorder = URLRecorder()
        UnsubscribeEndpoint.hitUnsubscribeProbe = { url in
            recorder.append(url)
            return .completed
        }

        try await TestDatabase.withConnection(cleanup: cleanup(account)) { conn in
            try await AccountStore.upsert(account, credentials: Data([1, 2, 3]), db: conn)
            try await MessageStore.upsert(
                self.header(accountId: account.id, remoteId: "u-stored"), db: conn
            )
            try await MessageStore.mergeUnsubscribeLinks(
                remoteId: "u-stored", accountId: account.id,
                // Literal public IP: the SSRF guard resolves hostnames, and
                // test fixtures must stay offline-deterministic (a bare
                // example.com subdomain does not resolve → rejected).
                links: ["https://8.8.8.8/unsubscribe?u=1"], db: conn
            )
            let app = Application(router: Self.makeRouter(provider: provider, db: conn))
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/messages/u-stored/unsubscribe?accountId=\(account.id.uuidString)",
                    method: .post
                ) { response in
                    XCTAssertEqual(response.status, .ok, Self.body(of: response))
                    XCTAssertTrue(Self.body(of: response).contains("\"unsubscribed\":true"))
                }
            }
            let bodyFetches = await provider.bodyFetchCount
            XCTAssertEqual(bodyFetches, 0, "stored candidates must short-circuit the body fetch")
            XCTAssertEqual(
                recorder.urls.map(\.absoluteString),
                ["https://8.8.8.8/unsubscribe?u=1"]
            )

            let row = try await MessageStore.find(
                remoteId: "u-stored", accountId: account.id, db: conn
            )
            XCTAssertEqual(row?.isRead, true, "success marks the message read")
            XCTAssertEqual(row?.isArchived, true, "success archives locally")
            let n = try conn.read { db in
                guard let row = try Row.fetchOne(
                    db,
                    sql: "SELECT count(*) AS n FROM ai_actions WHERE account_id = ? AND kind = 'unsubscribe'",
                    arguments: [account.id]
                ) else { return 0 }
                return row["n"]
            }
            XCTAssertEqual(n, 1, "the action must be recorded for undo history")
        }
    }

    /// A bare (unbracketed) List-Unsubscribe header URL — the pre-fix
    /// angle-bracket-only parser dropped these.
    func test_bareHeaderURL_resolves() async throws {
        let account = makeAccount()
        let provider = StubMailProvider()
        await provider.configureUnsubscribe(
            rawHeaders: ["list-unsubscribe": "https://1.1.1.1/unsubscribe"]
        )
        let recorder = URLRecorder()
        UnsubscribeEndpoint.hitUnsubscribeProbe = { url in
            recorder.append(url)
            return .completed
        }

        try await TestDatabase.withConnection(cleanup: cleanup(account)) { conn in
            try await AccountStore.upsert(account, credentials: Data([1, 2, 3]), db: conn)
            try await MessageStore.upsert(
                self.header(accountId: account.id, remoteId: "u-bare"), db: conn
            )
            let app = Application(router: Self.makeRouter(provider: provider, db: conn))
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/messages/u-bare/unsubscribe?accountId=\(account.id.uuidString)",
                    method: .post
                ) { response in
                    XCTAssertEqual(response.status, .ok, Self.body(of: response))
                }
            }
            XCTAssertEqual(
                recorder.urls.map(\.absoluteString),
                ["https://1.1.1.1/unsubscribe"]
            )
        }
    }

    /// mailto-only header AND a link-free body stays "manual required" — the
    /// contract, now reached only after every stage has been exhausted.
    func test_mailtoHeader_requiresManual() async throws {
        let account = makeAccount()
        let provider = StubMailProvider()
        await provider.configureUnsubscribe(
            rawHeaders: ["list-unsubscribe": "<mailto:bye@example.com>"]
        )
        UnsubscribeEndpoint.hitUnsubscribeProbe = { _ in
            XCTFail("mailto must never be fetched")
            return .failed
        }

        try await TestDatabase.withConnection(cleanup: cleanup(account)) { conn in
            try await AccountStore.upsert(account, credentials: Data([1, 2, 3]), db: conn)
            try await MessageStore.upsert(
                self.header(accountId: account.id, remoteId: "u-mailto"), db: conn
            )
            let app = Application(router: Self.makeRouter(provider: provider, db: conn))
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/messages/u-mailto/unsubscribe?accountId=\(account.id.uuidString)",
                    method: .post
                ) { response in
                    XCTAssertEqual(response.status, .unprocessableContent)
                    XCTAssertTrue(Self.body(of: response).contains("unsubscribe-manual-required"))
                }
            }
        }
    }

    /// A `mailto:` in the header must NOT short-circuit the chain: the body
    /// offers a real https unsubscribe link, so the endpoint must use it.
    /// (Pre-fix this 422'd `unsubscribe-manual-required` at the header stage —
    /// IMAP now persists mailto entries into `unsubscribe_links`, so the header
    /// stage alone could never decide.)
    func test_mailtoHeader_fallsThroughToBodyHTTPSLink() async throws {
        let account = makeAccount()
        let provider = StubMailProvider()
        await provider.configureUnsubscribe(
            rawHeaders: ["list-unsubscribe": "<mailto:bye@example.com>"],
            bodyHTML: #"<a href="https://8.8.8.8/unsubscribe?id=1">Unsubscribe</a>"#
        )
        let recorder = URLRecorder()
        UnsubscribeEndpoint.hitUnsubscribeProbe = { url in
            recorder.append(url)
            return .completed
        }

        try await TestDatabase.withConnection(cleanup: cleanup(account)) { conn in
            try await AccountStore.upsert(account, credentials: Data([1, 2, 3]), db: conn)
            try await MessageStore.upsert(
                self.header(accountId: account.id, remoteId: "u-mailto-body"), db: conn
            )
            let app = Application(router: Self.makeRouter(provider: provider, db: conn))
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/messages/u-mailto-body/unsubscribe?accountId=\(account.id.uuidString)",
                    method: .post
                ) { response in
                    XCTAssertEqual(response.status, .ok, Self.body(of: response))
                }
            }
            XCTAssertEqual(
                recorder.urls.map(\.absoluteString),
                ["https://8.8.8.8/unsubscribe?id=1"],
                "the body link must win over the header's mailto"
            )
        }
    }

    /// A stored `mailto:` (the sync-time writers persist one) must likewise
    /// fall through to the body scan before we tell the user to unsubscribe
    /// by hand.
    func test_storedMailto_fallsThroughToBodyHTTPSLink() async throws {
        let account = makeAccount()
        let provider = StubMailProvider()
        await provider.configureUnsubscribe(
            rawHeaders: [:],
            bodyHTML: #"<a href="https://1.1.1.1/optout">stop receiving</a>"#
        )
        let recorder = URLRecorder()
        UnsubscribeEndpoint.hitUnsubscribeProbe = { url in
            recorder.append(url)
            return .completed
        }

        try await TestDatabase.withConnection(cleanup: cleanup(account)) { conn in
            try await AccountStore.upsert(account, credentials: Data([1, 2, 3]), db: conn)
            try await MessageStore.upsert(
                self.header(accountId: account.id, remoteId: "u-stored-mailto"), db: conn
            )
            try await MessageStore.mergeUnsubscribeLinks(
                remoteId: "u-stored-mailto", accountId: account.id,
                links: ["mailto:bye@example.com"], db: conn
            )
            let app = Application(router: Self.makeRouter(provider: provider, db: conn))
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/messages/u-stored-mailto/unsubscribe?accountId=\(account.id.uuidString)",
                    method: .post
                ) { response in
                    XCTAssertEqual(response.status, .ok, Self.body(of: response))
                }
            }
            XCTAssertEqual(recorder.urls.map(\.absoluteString), ["https://1.1.1.1/optout"])
        }
    }

    /// The reported publisher is the host of the URL we actually fetched, not
    /// the first URL in the header (which may have been skipped as unsafe).
    func test_publisherIsHostOfChosenURLNotFirstHeaderURL() async throws {
        let account = makeAccount()
        let provider = StubMailProvider()
        await provider.configureUnsubscribe(
            // 10.0.0.5 is rejected by the SSRF guard, so the chosen URL is the
            // second one — the pre-fix code still reported 10.0.0.5.
            rawHeaders: [
                "list-unsubscribe": "<http://10.0.0.5/u>, <https://8.8.8.8/unsubscribe>"
            ]
        )
        let recorder = URLRecorder()
        UnsubscribeEndpoint.hitUnsubscribeProbe = { url in
            recorder.append(url)
            return .completed
        }

        try await TestDatabase.withConnection(cleanup: cleanup(account)) { conn in
            try await AccountStore.upsert(account, credentials: Data([1, 2, 3]), db: conn)
            try await MessageStore.upsert(
                self.header(accountId: account.id, remoteId: "u-pub"), db: conn
            )
            let app = Application(router: Self.makeRouter(provider: provider, db: conn))
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/messages/u-pub/unsubscribe?accountId=\(account.id.uuidString)",
                    method: .post
                ) { response in
                    XCTAssertEqual(response.status, .ok, Self.body(of: response))
                    XCTAssertTrue(
                        Self.body(of: response).contains("\"publisher\":\"8.8.8.8\""),
                        Self.body(of: response)
                    )
                }
            }
            XCTAssertEqual(recorder.urls.map(\.absoluteString), ["https://8.8.8.8/unsubscribe"])
        }
    }

    /// The body fetch failing is a transport failure, not "no unsubscribe
    /// link": the client renders 422 unsubscribe-unavailable as
    /// "未检测到退订链接", which would be a lie.
    func test_bodyFetchFails_doesNotReportNoLink() async throws {
        let account = makeAccount()
        let provider = BodyFailingProvider()
        UnsubscribeEndpoint.hitUnsubscribeProbe = { _ in
            XCTFail("no candidate may be fetched")
            return .failed
        }

        try await TestDatabase.withConnection(cleanup: cleanup(account)) { conn in
            try await AccountStore.upsert(account, credentials: Data([1, 2, 3]), db: conn)
            try await MessageStore.upsert(
                self.header(accountId: account.id, remoteId: "u-bodyfail"), db: conn
            )
            let app = Application(router: Self.makeRouter(provider: provider, db: conn))
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/messages/u-bodyfail/unsubscribe?accountId=\(account.id.uuidString)",
                    method: .post
                ) { response in
                    XCTAssertEqual(response.status, .badGateway, Self.body(of: response))
                    XCTAssertTrue(Self.body(of: response).contains("provider-unreachable"))
                    XCTAssertFalse(
                        Self.body(of: response).contains("unsubscribe-unavailable"),
                        "a failed body fetch must never render as 未检测到退订链接"
                    )
                }
            }
        }
    }

    // MARK: - Transport (real session, stubbed protocol)

    /// A 2xx ack is a completed unsubscribe.
    func test_hitUnsubscribe_2xxCompletes() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.script(
            .init(status: 200, body: Data("You are unsubscribed".utf8)),
            for: "https://8.8.8.8/u"
        )
        let hit = try await UnsubscribeEndpoint.hitUnsubscribe(
            url: URL(string: "https://8.8.8.8/u")!, session: Self.stubProbeSession()
        )
        XCTAssertEqual(hit, .completed)
        XCTAssertEqual(StubURLProtocol.seenURLs.map(\.absoluteString), ["https://8.8.8.8/u"])
    }

    /// A 3xx that reaches classification (no followable hop — refused, or a
    /// chain the server cut short) is NOT a completed unsubscribe. Pre-fix the
    /// `(200..<400)` check recorded success, archived the mail and told the
    /// user they had unsubscribed.
    func test_hitUnsubscribe_3xxIsNotSuccess() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.script(.init(status: 302), for: "https://8.8.8.8/u")
        let hit = try await UnsubscribeEndpoint.hitUnsubscribe(
            url: URL(string: "https://8.8.8.8/u")!, session: Self.stubProbeSession()
        )
        XCTAssertEqual(hit, .failed, "a redirect stub must never classify as completed")
    }

    /// The SSRF redirect guard, end to end: a "public" endpoint that 302s to
    /// an internal target must issue NO second request, and must not be
    /// recorded as a completed unsubscribe. Both ends are loopback servers —
    /// the guard refuses the hop for the same reason it refuses
    /// 169.254.169.254 (not a public address), and the count proves the
    /// second socket was never touched.
    func test_refusedRedirectIssuesNoSecondRequest() async throws {
        let metadata = LocalHTTPServer(location: { nil })
        try await metadata.start()
        guard let metadataPort = metadata.boundPort else { throw CancellationError() }
        let entry = LocalHTTPServer(location: {
            "http://127.0.0.1:\(metadataPort)/latest/meta-data/"
        })
        try await entry.start()
        guard let url = entry.url else { throw CancellationError() }

        let hit = try await UnsubscribeEndpoint.hitUnsubscribe(
            url: url, session: UnsubscribeEndpoint.makeProbeSession()
        )
        XCTAssertEqual(hit, .failed, "a refused redirect must never classify as completed")
        XCTAssertEqual(entry.requestCount, 1, "only the first hop may be requested")
        XCTAssertEqual(metadata.requestCount, 0, "the internal target must never be contacted")
    }

    /// The guard's decision itself, unit-level: an unsafe hop is cancelled and
    /// not followed; a public one is handed on.
    func test_redirectGuard_decidesPerHop() async throws {
        let guardDelegate = UnsubscribeEndpoint.RedirectGuard(
            maxBodyBytes: UnsubscribeEndpoint.maxUnsubscribeBodyBytes
        )
        let task = ProbeTask()

        let followed = expectation(description: "unsafe hop refused")
        guardDelegate.urlSession(
            URLSession.shared, task: task,
            willPerformHTTPRedirection: HTTPURLResponse(
                url: URL(string: "https://8.8.8.8/u")!, statusCode: 302,
                httpVersion: nil, headerFields: nil
            )!,
            newRequest: URLRequest(url: URL(string: "http://169.254.169.254/creds")!),
            completionHandler: { request in
                XCTAssertNil(request, "a link-local hop must not be followed")
                followed.fulfill()
            }
        )
        await fulfillment(of: [followed], timeout: 5)
        XCTAssertTrue(task.wasCancelled, "the refused hop must cancel the task")

        let allowed = expectation(description: "public hop allowed")
        guardDelegate.urlSession(
            URLSession.shared, task: task,
            willPerformHTTPRedirection: HTTPURLResponse(
                url: URL(string: "https://8.8.8.8/u")!, statusCode: 302,
                httpVersion: nil, headerFields: nil
            )!,
            newRequest: URLRequest(url: URL(string: "https://1.1.1.1/ok")!),
            completionHandler: { request in
                XCTAssertEqual(request?.url?.absoluteString, "https://1.1.1.1/ok")
                allowed.fulfill()
            }
        )
        await fulfillment(of: [allowed], timeout: 5)
    }

    /// The streaming cap: past `maxBodyBytes` the task is cancelled instead of
    /// letting `data(for:)` buffer an attacker-chosen body whole.
    ///
    /// Dispatch goes through the `URLSessionDataDelegate` *existential* on
    /// purpose. The previous version of this test called the method directly,
    /// so it passed even though the signature carried a `completionHandler:`
    /// parameter that no protocol requirement has — URLSession never called it,
    /// and the cap was dead in production. Only protocol dispatch proves
    /// conformance.
    func test_redirectGuard_capsStreamedBody() {
        let cap = 1024
        let delegate: URLSessionDataDelegate = UnsubscribeEndpoint.RedirectGuard(maxBodyBytes: cap)
        let task = ProbeTask()
        let session = URLSession.shared

        XCTAssertNotNil(
            delegate.urlSession(_:dataTask:didReceive:),
            "the guard must satisfy the delegate requirement, or the cap never runs"
        )
        delegate.urlSession?(session, dataTask: task, didReceive: Data(count: cap))
        XCTAssertFalse(task.wasCancelled, "a body at the cap is still allowed")
        delegate.urlSession?(session, dataTask: task, didReceive: Data(count: 1))
        XCTAssertTrue(task.wasCancelled, "one byte past the cap must stop the read")
    }

    /// The blind POST is gone. The old POST-first probe burned the one
    /// request that mattered: a GET-shaped link answered the unexpected POST
    /// with a 200 landing page, classifyHit saw a re-offered link and said
    /// "needs manual" — and the GET, the thing that actually unsubscribes,
    /// never ran.
    func test_hitUnsubscribe_getOnly_noBlindPost() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.script(
            .init(status: 200, body: Data("You are unsubscribed".utf8)),
            for: "https://8.8.8.8/u GET"
        )
        let hit = try await UnsubscribeEndpoint.hitUnsubscribe(
            url: URL(string: "https://8.8.8.8/u")!, session: Self.stubProbeSession()
        )
        XCTAssertEqual(hit, .completed)
        XCTAssertEqual(StubURLProtocol.seenRequests.count, 1, "GET only — no POST probe")
        XCTAssertEqual(StubURLProtocol.seenRequests[0].method, "GET")
    }

    /// RFC 8058: when the sender advertised List-Unsubscribe-Post, the POST
    /// with the mandated body IS the unsubscribe — no page, no extra click.
    func test_hitUnsubscribe_oneClickPostsRFCBody() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.script(.init(status: 200), for: "https://8.8.8.8/u POST")
        let hit = try await UnsubscribeEndpoint.hitUnsubscribe(
            url: URL(string: "https://8.8.8.8/u")!, oneClick: true,
            session: Self.stubProbeSession()
        )
        XCTAssertEqual(hit, .completed)
        XCTAssertEqual(StubURLProtocol.seenRequests.count, 1, "the POST completes; no GET follows")
        XCTAssertEqual(StubURLProtocol.seenRequests[0].method, "POST")
        XCTAssertEqual(
            String(data: StubURLProtocol.seenRequests[0].body, encoding: .utf8),
            "List-Unsubscribe=One-Click",
            "the body is the one mandated by RFC 8058"
        )
    }

    /// A one-click POST rejected with 4xx/5xx falls back to the GET (some
    /// senders advertise the header but only serve the link).
    func test_hitUnsubscribe_oneClickRejected_fallsBackToGet() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.script(.init(status: 405), for: "https://8.8.8.8/u POST")
        StubURLProtocol.script(
            .init(status: 200, body: Data("You have been unsubscribed".utf8)),
            for: "https://8.8.8.8/u GET"
        )
        let hit = try await UnsubscribeEndpoint.hitUnsubscribe(
            url: URL(string: "https://8.8.8.8/u")!, oneClick: true,
            session: Self.stubProbeSession()
        )
        XCTAssertEqual(hit, .completed)
        XCTAssertEqual(StubURLProtocol.seenRequests.count, 2)
        XCTAssertEqual(StubURLProtocol.seenRequests.map(\.method), ["POST", "GET"])
    }

    /// The landing page's own confirm entry is followed once, server-side —
    /// the click the user used to make by hand. The success phrase on the
    /// second hop completes the unsubscribe.
    func test_landingPageConfirmFollowedAutomatically() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.script(
            .init(status: 200, body: Data(
                #"""
                <html><body>
                <p>Are you sure you want to unsubscribe from this list?</p>
                <a href="https://8.8.8.8/confirm?token=abc">Confirm unsubscribe</a>
                </body></html>
                """#.utf8
            )),
            for: "https://8.8.8.8/u GET"
        )
        StubURLProtocol.script(
            .init(status: 200, body: Data("You have been unsubscribed".utf8)),
            for: "https://8.8.8.8/confirm?token=abc GET"
        )
        let hit = try await UnsubscribeEndpoint.hitUnsubscribe(
            url: URL(string: "https://8.8.8.8/u")!, session: Self.stubProbeSession()
        )
        XCTAssertEqual(hit, .completed, "the server makes the confirm click for the user")
        XCTAssertEqual(StubURLProtocol.seenRequests.count, 2)
        XCTAssertEqual(
            StubURLProtocol.seenRequests[1].url.absoluteString,
            "https://8.8.8.8/confirm?token=abc"
        )
    }

    /// A landing page whose confirm entry is unsafe (loopback) must NOT be
    /// followed — one hop, SSRF guard respected, honest landingPage.
    func test_landingPageConfirm_unsafeLinkNotFollowed() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.script(
            .init(status: 200, body: Data(
                #"<p>Unsubscribe <a href="http://127.0.0.1:9/x">confirm here</a></p>"#.utf8
            )),
            for: "https://8.8.8.8/u GET"
        )
        let hit = try await UnsubscribeEndpoint.hitUnsubscribe(
            url: URL(string: "https://8.8.8.8/u")!, session: Self.stubProbeSession()
        )
        XCTAssertEqual(hit, .landingPage)
        XCTAssertEqual(StubURLProtocol.seenRequests.count, 1, "the unsafe confirm link is never fetched")
    }

    /// A confirmation page that STILL links a preferences centre completes:
    /// the success phrase outranks the re-offered link. The old link-only
    /// rule turned exactly this page into "退订请求未完成".
    func test_classifyHit_successPhraseBeatsFooterLinks() {
        let confirmation = #"""
        <html><body><p>You have been unsubscribed from our mailing list.</p>
        <a href="https://8.8.8.8/prefs">Manage preferences</a></body></html>
        """#
        XCTAssertEqual(
            UnsubscribeEndpoint.classifyHit(data: Data(confirmation.utf8)),
            .completed,
            "a success phrase must win over a re-offered preferences link"
        )
        let ask = #"""
        <p>Confirm you want to unsubscribe <a href="https://8.8.8.8/c">here</a></p>
        """#
        XCTAssertEqual(
            UnsubscribeEndpoint.classifyHit(data: Data(ask.utf8)),
            .landingPage,
            "a confirmation ASK (no completed tense) is still a landing page"
        )
    }

    /// Header read fails but stored links exist → still resolves (the P1
    /// fix: a provider hiccup must not mask harvestable candidates).
    func test_headerReadFails_storedStillResolves() async throws {
        let account = makeAccount()
        let provider = StubMailProvider()
        await provider.configureUnsubscribe(rawHeaders: [:], headerError: .messageGone)
        let recorder = URLRecorder()
        UnsubscribeEndpoint.hitUnsubscribeProbe = { url in
            recorder.append(url)
            return .completed
        }

        try await TestDatabase.withConnection(cleanup: cleanup(account)) { conn in
            try await AccountStore.upsert(account, credentials: Data([1, 2, 3]), db: conn)
            try await MessageStore.upsert(
                self.header(accountId: account.id, remoteId: "u-hdrfail"), db: conn
            )
            try await MessageStore.mergeUnsubscribeLinks(
                remoteId: "u-hdrfail", accountId: account.id,
                links: ["https://9.9.9.9/optout"], db: conn
            )
            let app = Application(router: Self.makeRouter(provider: provider, db: conn))
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/messages/u-hdrfail/unsubscribe?accountId=\(account.id.uuidString)",
                    method: .post
                ) { response in
                    XCTAssertEqual(response.status, .ok, Self.body(of: response))
                }
            }
            XCTAssertEqual(recorder.urls.map(\.absoluteString), ["https://9.9.9.9/optout"])
        }
    }

    /// Header read fails and nothing is stored → the provider error must
    /// surface; a 422 "未检测到退订链接" would be a lie (we could not check).
    func test_headerReadFails_nothingStored_returnsProviderError() async throws {
        let account = makeAccount()
        let provider = StubMailProvider()
        await provider.configureUnsubscribe(rawHeaders: [:], headerError: .messageGone)
        UnsubscribeEndpoint.hitUnsubscribeProbe = { _ in
            XCTFail("no candidate may be fetched")
            return .failed
        }

        try await TestDatabase.withConnection(cleanup: cleanup(account)) { conn in
            try await AccountStore.upsert(account, credentials: Data([1, 2, 3]), db: conn)
            try await MessageStore.upsert(
                self.header(accountId: account.id, remoteId: "u-hdrfail2"), db: conn
            )
            let app = Application(router: Self.makeRouter(provider: provider, db: conn))
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/messages/u-hdrfail2/unsubscribe?accountId=\(account.id.uuidString)",
                    method: .post
                ) { response in
                    XCTAssertNotEqual(response.status, .unprocessableContent)
                    XCTAssertFalse(
                        Self.body(of: response).contains("unsubscribe-unavailable"),
                        "could-not-check must not be reported as no-link"
                    )
                }
            }
        }
    }

    /// 2xx whose body still offers unsubscribe links = we only opened an
    /// instructions page (the Windows Insider case: tracking link → 302 →
    /// "how to leave" page). Must return unsubscribe-page-required and must
    /// NOT archive/record success.
    func test_landingPage_returnsPageRequiredNotSuccess() async throws {
        let account = makeAccount()
        let provider = StubMailProvider()
        await provider.configureUnsubscribe(rawHeaders: [:])
        let recorder = URLRecorder()
        UnsubscribeEndpoint.hitUnsubscribeProbe = { url in
            recorder.append(url)
            return .landingPage
        }

        try await TestDatabase.withConnection(cleanup: cleanup(account)) { conn in
            try await AccountStore.upsert(account, credentials: Data([1, 2, 3]), db: conn)
            try await MessageStore.upsert(
                self.header(accountId: account.id, remoteId: "u-page"), db: conn
            )
            try await MessageStore.mergeUnsubscribeLinks(
                remoteId: "u-page", accountId: account.id,
                links: ["https://8.8.8.8/unsubscribe?u=1"], db: conn
            )
            let app = Application(router: Self.makeRouter(provider: provider, db: conn))
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/messages/u-page/unsubscribe?accountId=\(account.id.uuidString)",
                    method: .post
                ) { response in
                    XCTAssertEqual(response.status, .unprocessableContent, Self.body(of: response))
                    XCTAssertTrue(Self.body(of: response).contains("unsubscribe-page-required"))
                }
            }
            let row = try await MessageStore.find(
                remoteId: "u-page", accountId: account.id, db: conn
            )
            XCTAssertEqual(row?.isArchived, false, "an opened page must not archive the mail")
            let n = try conn.read { db in
                guard let row = try Row.fetchOne(
                    db,
                    sql: "SELECT count(*) AS n FROM ai_actions WHERE account_id = ? AND kind = 'unsubscribe'",
                    arguments: [account.id]
                ) else { return 0 }
                return row["n"]
            }
            XCTAssertEqual(n, 0, "no success may be recorded for a landing page")
        }
    }

    /// classifyHit: empty/plain 2xx bodies complete; a body that re-offers
    /// unsubscribe links is only a landing page; non-UTF8 data completes.
    func test_classifyHit_distinguishesConfirmationFromLandingPage() {
        XCTAssertEqual(
            UnsubscribeEndpoint.classifyHit(data: Data()), .completed,
            "empty ack (one-click endpoint) is success"
        )
        XCTAssertEqual(
            UnsubscribeEndpoint.classifyHit(data: Data("OK".utf8)), .completed
        )
        XCTAssertEqual(
            UnsubscribeEndpoint.classifyHit(
                data: Data(#"<p>You have been unsubscribed.</p>"#.utf8)
            ), .completed,
            "confirmation page without a new unsubscribe entry is success"
        )
        XCTAssertEqual(
            UnsubscribeEndpoint.classifyHit(
                data: Data(#"<a href="https://ex.com/leave">Find out how to leave the program</a>"#.utf8)
            ), .landingPage,
            "a page that still offers an unsubscribe entry is not a completed unsubscribe"
        )
        XCTAssertEqual(
            UnsubscribeEndpoint.classifyHit(data: Data([0xff, 0xfe, 0x00, 0x80])), .completed,
            "non-text bodies cannot re-offer links"
        )
    }
}
