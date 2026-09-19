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
    private var sendResult: Result<String?, MailError> = .success("stub-message-id")

    private(set) var pullCount = 0
    private(set) var lastCursor: MailSyncState?
    private(set) var sendCalls: [OutboundMessage] = []
    private(set) var archiveCalls: [String] = []
    /// When set, every archive throws this — drives the whitelist autopilot's
    /// remote-first failure paths (spec 2026-09-19 §3).
    private var archiveFailure: MailError?

    init(
        kind: MailProviderKind = .qq,
        pulls: [Result<MailChangeSet, MailError>] = [],
        persistentFailure: MailError? = nil
    ) {
        self.kind = kind
        self.pulls = pulls
        self.persistentFailure = persistentFailure
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
        FetchedBody(text: body, html: nil, attachments: [], hasMore: false)
    }

    func fetchAttachment(remoteId: String, attachmentId: String) async throws -> FetchedAttachmentBytes {
        throw AttachmentError.notFound
    }

    func fetchRawMessage(remoteId: String) async throws -> Data {
        Data(body.utf8)
    }

    func fetchRawHeaderValues(remoteId: String) async throws -> [String: String] {
        ["list-unsubscribe": "<mailto:unsubscribe@example.com>"]
    }

    func setRead(remoteId: String, isRead: Bool) async throws {}
    func archive(remoteId: String) async throws {
        archiveCalls.append(remoteId)
        if let archiveFailure { throw archiveFailure }
    }
    func unarchive(remoteId: String) async throws {}
    /// Actor-isolated knob for scripted archive failures.
    func setArchiveFailure(_ error: MailError?) {
        archiveFailure = error
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
