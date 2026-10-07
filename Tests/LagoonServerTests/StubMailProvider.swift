import XCTest
import Foundation
import LagoonKit
@testable import LagoonServer

/// Scripted `MailProvider` for `SyncEngineTests`: no network, no TLS, no IMAP.
/// Pulls are consumed in order; an exhausted script returns an empty change set
/// (that is what a real provider does when nothing changed).
actor StubMailProvider: MailProvider {
    let kind: MailProviderKind

    private var pulls: [Result<MailChangeSet, MailError>]
    /// When set, every pull fails with this error — used to drive the backoff
    /// state machine across several rounds.
    private let persistentFailure: MailError?
    private var body = "stub body"
    /// Unsubscribe-route knobs (defaults preserve the original behavior).
    private var rawHeaders: [String: String] = ["list-unsubscribe": "<mailto:unsubscribe@example.com>"]
    private var headerError: MailError?
    private var bodyHTML: String?
    private(set) var bodyFetchCount = 0
    private var sendResult: Result<String?, MailError> = .success("stub-message-id")

    private(set) var pullCount = 0
    private(set) var lastCursor: MailSyncState?
    private(set) var sendCalls: [OutboundMessage] = []
    private(set) var archiveCalls: [String] = []
    private(set) var trashCalls: [String] = []
    /// 取消归档 / 从废纸篓恢复的调用记录。The restore-route tests assert these
    /// because "the local flag flipped but the remote MOVE never happened" is
    /// the exact split-brain a restore can produce, and it is invisible unless
    /// the provider is watched.
    private(set) var unarchiveCalls: [String] = []
    private(set) var restoreCalls: [String] = []
    private var unarchiveFailure: MailError?
    private var restoreFailure: MailError?
    /// Rendezvous points for the restore/unarchive routes' reconcile race.
    ///
    /// The window these routes have to survive only exists while the remote
    /// MOVE is in flight, so a test cannot observe it without parking the
    /// provider here first. Parking happens *after* the call is recorded and
    /// *before* any scripted failure is thrown, so a gated test still sees the
    /// call in `restoreCalls`/`unarchiveCalls`.
    private var unarchiveGate: RaceGate?
    private var restoreGate: RaceGate?
    /// 彻底删除的调用记录。Recorded separately from `trashCalls` because the
    /// two are opposites: `trash` is reversible via the route, `permanentlyDelete`
    /// is not, and a test that cannot tell them apart cannot assert that a
    /// permanent delete never quietly became a soft one.
    private(set) var purgeCalls: [String] = []
    /// R1: what `listSent` returns and how many times it was asked.
    private(set) var sentRows: [MessageHeader] = []
    private(set) var listSentCalls = 0
    private var sentFailure: MailError?
    private(set) var emptyTrashCalls = 0
    private var purgeFailure: MailError?
    private var emptyTrashFailure: MailError?
    /// When set, every archive throws this — drives the whitelist autopilot's
    /// remote-first failure paths (spec 2026-09-19 §3).
    private var archiveFailure: MailError?
    /// Same knob for the trash path (delete route tests).
    private var trashFailure: MailError?

    init(
        kind: MailProviderKind = .qq,
        pulls: [Result<MailChangeSet, MailError>] = [],
        persistentFailure: MailError? = nil
    ) {
        self.kind = kind
        self.pulls = pulls
        self.persistentFailure = persistentFailure
    }

    private(set) var shutdownCount = 0

    func shutdown() async {
        shutdownCount += 1
    }

    func capabilities() async -> MailCapabilities {
        MailCapabilities(archiveFolder: true, idle: true, move: true, serverSnippet: false)
    }

    func pullChanges(after cursor: MailSyncState, waitUpTo: Duration) async throws -> MailChangeSet {
        pullCount += 1
        lastCursor = cursor
        if let persistentFailure { throw persistentFailure }
        guard !pulls.isEmpty else {
            return MailChangeSet(upserts: [], resetRequired: false, cursor: cursor)
        }
        return try pulls.removeFirst().get()
    }

    func fetchBody(remoteId: String) async throws -> FetchedBody {
        bodyFetchCount += 1
        return FetchedBody(text: body, html: bodyHTML, attachments: [], hasMore: false)
    }

    func fetchAttachment(remoteId: String, attachmentId: String) async throws -> FetchedAttachmentBytes {
        throw AttachmentError.notFound
    }

    func fetchRawMessage(remoteId: String) async throws -> Data {
        Data(body.utf8)
    }

    func fetchRawHeaderValues(remoteId: String) async throws -> [String: String] {
        if let headerError { throw headerError }
        return rawHeaders
    }

    /// Configure the live-header read, its failure mode, and the body html.
    /// Used by `UnsubscribeRouteTests` to drive the resolution chain.
    func configureUnsubscribe(
        rawHeaders: [String: String],
        headerError: MailError? = nil,
        bodyHTML: String? = nil
    ) {
        self.rawHeaders = rawHeaders
        self.headerError = headerError
        self.bodyHTML = bodyHTML
    }

    func setRead(remoteId: String, isRead: Bool) async throws {}
    func archive(remoteId: String) async throws {
        archiveCalls.append(remoteId)
        if let archiveFailure { throw archiveFailure }
    }
    func unarchive(remoteId: String) async throws {
        unarchiveCalls.append(remoteId)
        if let unarchiveGate { await unarchiveGate.hold() }
        if let unarchiveFailure { throw unarchiveFailure }
    }
    func trash(remoteId: String) async throws {
        trashCalls.append(remoteId)
        if let trashFailure { throw trashFailure }
    }
    func restoreFromTrash(remoteId: String) async throws {
        restoreCalls.append(remoteId)
        if let restoreGate { await restoreGate.hold() }
        if let restoreFailure { throw restoreFailure }
    }
    func permanentlyDelete(remoteId: String) async throws {
        purgeCalls.append(remoteId)
        if let purgeFailure { throw purgeFailure }
    }
    func emptyTrash() async throws {
        emptyTrashCalls += 1
        if let emptyTrashFailure { throw emptyTrashFailure }
    }
    /// 已发送列表。Scriptable so the R1 routes can be driven without a server.
    /// R2: folders `listFolders` returns, and every move it was asked to do.
    private(set) var folderRows: [MailFolder] = []
    private(set) var moveCalls: [(remoteId: String, folder: String, createIfMissing: Bool)] = []
    private var moveFailure: MailError?
    func listFolders() async throws -> [MailFolder] { folderRows }
    @discardableResult
    func move(remoteId: String, to folder: String, createIfMissing: Bool) async throws -> Bool {
        moveCalls.append((remoteId, folder, createIfMissing))
        if let moveFailure { throw moveFailure }
        return true
    }
    func listSent(limit: Int) async throws -> [MessageHeader] {
        listSentCalls += 1
        if let sentFailure { throw sentFailure }
        return Array(sentRows.prefix(max(1, limit)))
    }
    /// Actor-isolated knob for scripted archive failures.
    func setArchiveFailure(_ error: MailError?) {
        archiveFailure = error
    }
    /// Actor-isolated knobs for the restore paths.
    /// Actor-isolated knob for the 已发送 listing.
    func setSentRows(_ rows: [MessageHeader]) {
        sentRows = rows
    }
    func setSentFailure(_ error: MailError?) {
        sentFailure = error
    }
    func setPurgeFailure(_ error: MailError?) {
        purgeFailure = error
    }
    func setEmptyTrashFailure(_ error: MailError?) {
        emptyTrashFailure = error
    }
    func setUnarchiveFailure(_ error: MailError?) {
        unarchiveFailure = error
    }
    func setRestoreFailure(_ error: MailError?) {
        restoreFailure = error
    }
    func setUnarchiveGate(_ gate: RaceGate?) {
        unarchiveGate = gate
    }
    func setRestoreGate(_ gate: RaceGate?) {
        restoreGate = gate
    }
    /// Actor-isolated knobs for scripted trash failures + observation.
    func setTrashFailure(_ error: MailError?) {
        trashFailure = error
    }

    func send(_ outbound: OutboundMessage) async throws -> String? {
        sendCalls.append(outbound)
        return try sendResult.get()
    }

    func probe() async throws {}
}

extension StubMailProvider {
    /// A provider whose every pull fails with `error`.
    static func failing(_ error: MailError, kind: MailProviderKind = .qq) -> StubMailProvider {
        StubMailProvider(kind: kind, persistentFailure: error)
    }

    /// One change set, then empty pulls.
    static func once(_ changes: MailChangeSet, kind: MailProviderKind = .qq) -> StubMailProvider {
        StubMailProvider(kind: kind, pulls: [.success(changes)])
    }
}

extension RemoteHeader {
    /// Convenience for tests: a fully-populated header with overridable fields.
    static func stub(
        remoteId: String,
        threadId: String? = nil,
        fromAddress: String = "sender@example.com",
        fromName: String? = "Sender",
        subject: String? = "Subject",
        snippet: String? = "snippet",
        receivedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        isRead: Bool = true,
        listUnsubscribe: Bool = false,
        messageIdHeader: String? = nil,
        inReplyTo: String? = nil,
        references: String? = nil
    ) -> RemoteHeader {
        RemoteHeader(
            remoteId: remoteId,
            threadId: threadId ?? "thread-\(remoteId)",
            fromAddress: fromAddress,
            fromName: fromName,
            subject: subject,
            snippet: snippet,
            receivedAt: receivedAt,
            isRead: isRead,
            listUnsubscribe: listUnsubscribe,
            messageIdHeader: messageIdHeader ?? "<\(remoteId)@example.com>",
            inReplyTo: inReplyTo,
            references: references
        )
    }
}

/// Async form of `XCTAssertThrowsError` (its autoclosure cannot await).
/// Shared by the IMAP client/connection/provider tests.
func XCTAssertThrowsErrorAsync<T>(
    _ body: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async -> Error? {
    do {
        _ = try await body()
        XCTFail("expected an error to be thrown", file: file, line: line)
        return nil
    } catch {
        return error
    }
}
