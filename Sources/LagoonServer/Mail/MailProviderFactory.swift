import Foundation
import Logging
import GRDB
import LagoonKit

/// Builds the provider for an account row. Kept as a factory rather than a
/// provider method because construction needs server-side collaborators
/// (DB, logger) that a stored account must not carry.
public enum MailProviderFactory {
    /// Route-level construction closure. Injected so route tests can script a
    /// fake; production wires `factory(db:logger:)`.
    public typealias Builder = @Sendable (Account) -> (any MailProvider)?

    /// `nil` when the account's provider has no implementation in this build
    /// (the engine records `no-provider` and keeps the loop alive).
    public static func make(
        account: Account,
        db: LagoonDB,
        logger: Logger
    ) -> (any MailProvider)? {
        switch account.provider {
        case .qq:
            return IMAPProvider(account: account, db: db, logger: logger)
        }
    }

    /// The production `Builder`. Bound once per route so handlers share the
    /// same collaborators.
    ///
    /// Returns the builder plus the handle that lets a caller give an account
    /// back: a deleted mailbox must not keep a provider (and its live IMAP
    /// session) in the pool until the process exits.
    public static func factory(
        db: LagoonDB,
        logger: Logger
    ) -> (builder: Builder, release: @Sendable (UUID) async -> Void) {
        // Route traffic gets its own reusable provider per account. The sync
        // engine already owns a separate long-lived provider; sharing that one
        // would put IDLE and on-demand body/action commands on the same IMAP
        // connection. Caching here avoids a fresh QQ login for every message
        // open or action while keeping the two workloads isolated.
        let pool = MailProviderPool()
        return (
            builder: { account in
                PooledMailProvider(account: account, pool: pool) { _ in
                    make(account: account, db: db, logger: logger)
                }
            },
            release: { id in await pool.release(id) }
        )
    }
}

/// Reuses route-side providers for the lifetime of an account credential set.
/// The cache compares the credential blob, so re-authentication with the same
/// account id rebuilds the provider instead of keeping a stale session.
actor MailProviderPool {
    private struct Entry {
        let provider: any MailProvider
        let providerKind: MailProviderKind
        let email: String
        let credentials: Data?
    }

    private var entries: [UUID: Entry] = [:]

    func provider(
        for account: Account,
        build: @Sendable (Account) -> (any MailProvider)?
    ) async -> (any MailProvider)? {
        if let entry = entries[account.id],
           entry.providerKind == account.provider,
           entry.email == account.email,
           entry.credentials == account.credentials {
            return entry.provider
        }
        guard let provider = build(account) else { return nil }
        // Re-authentication reuses the account id, so this branch replaces a
        // provider that may still hold a live IMAP session. Hand it back
        // before it is dropped — dropping a reference is not closing it.
        let replaced = entries[account.id]?.provider
        entries[account.id] = Entry(
            provider: provider,
            providerKind: account.provider,
            email: account.email,
            credentials: account.credentials
        )
        await replaced?.shutdown()
        return provider
    }

    /// Give an account's provider back: a deleted mailbox must not keep a live
    /// IMAP session in the pool until the process exits.
    func release(_ id: UUID) async {
        let entry = entries.removeValue(forKey: id)
        await entry?.provider.shutdown()
    }
}

/// The route-facing provider exposes the same contract while resolving the
/// actual account provider through the pool on each call.
actor PooledMailProvider: MailProvider, ArchiveFolderResolving {
    nonisolated let kind: MailProviderKind

    private let account: Account
    private let pool: MailProviderPool
    private let build: @Sendable (Account) -> (any MailProvider)?

    init(
        account: Account,
        pool: MailProviderPool,
        build: @escaping @Sendable (Account) -> (any MailProvider)?
    ) {
        self.account = account
        self.pool = pool
        self.build = build
        self.kind = account.provider
    }

    func capabilities() async -> MailCapabilities {
        guard let provider = await resolved() else { return .unknown }
        return await provider.capabilities()
    }

    func pullChanges(
        after cursor: MailSyncState,
        waitUpTo: Duration
    ) async throws -> MailChangeSet {
        guard let provider = await resolved() else {
            throw MailError.notConfigured("provider unavailable")
        }
        return try await provider.pullChanges(after: cursor, waitUpTo: waitUpTo)
    }

    func fetchBody(remoteId: String) async throws -> FetchedBody {
        guard let provider = await resolved() else {
            throw MailError.notConfigured("provider unavailable")
        }
        return try await provider.fetchBody(remoteId: remoteId)
    }

    func fetchAttachment(remoteId: String, attachmentId: String) async throws -> FetchedAttachmentBytes {
        guard let provider = await resolved() else {
            throw MailError.notConfigured("provider unavailable")
        }
        return try await provider.fetchAttachment(remoteId: remoteId, attachmentId: attachmentId)
    }

    func fetchRawMessage(remoteId: String) async throws -> Data {
        guard let provider = await resolved() else {
            throw MailError.notConfigured("provider unavailable")
        }
        return try await provider.fetchRawMessage(remoteId: remoteId)
    }

    func fetchRawHeaderValues(remoteId: String) async throws -> [String: String] {
        guard let provider = await resolved() else {
            throw MailError.notConfigured("provider unavailable")
        }
        return try await provider.fetchRawHeaderValues(remoteId: remoteId)
    }

    func setRead(remoteId: String, isRead: Bool) async throws {
        guard let provider = await resolved() else {
            throw MailError.notConfigured("provider unavailable")
        }
        try await provider.setRead(remoteId: remoteId, isRead: isRead)
    }

    func archive(remoteId: String) async throws {
        guard let provider = await resolved() else {
            throw MailError.notConfigured("provider unavailable")
        }
        try await provider.archive(remoteId: remoteId)
    }

    func unarchive(remoteId: String) async throws {
        guard let provider = await resolved() else {
            throw MailError.notConfigured("provider unavailable")
        }
        try await provider.unarchive(remoteId: remoteId)
    }

    func trash(remoteId: String) async throws {
        guard let provider = await resolved() else {
            throw MailError.notConfigured("provider unavailable")
        }
        try await provider.trash(remoteId: remoteId)
    }

    func restoreFromTrash(remoteId: String) async throws {
        guard let provider = await resolved() else {
            throw MailError.notConfigured("provider unavailable")
        }
        try await provider.restoreFromTrash(remoteId: remoteId)
    }

    func permanentlyDelete(remoteId: String) async throws {
        guard let provider = await resolved() else {
            throw MailError.notConfigured("provider unavailable")
        }
        try await provider.permanentlyDelete(remoteId: remoteId)
    }

    func emptyTrash() async throws {
        guard let provider = await resolved() else {
            throw MailError.notConfigured("provider unavailable")
        }
        try await provider.emptyTrash()
    }

    func listFolders() async throws -> [MailFolder] {
        guard let provider = await resolved() else {
            throw MailError.notConfigured("provider unavailable")
        }
        return try await provider.listFolders()
    }

    @discardableResult
    func move(remoteId: String, to folder: String, createIfMissing: Bool) async throws -> Bool {
        guard let provider = await resolved() else {
            throw MailError.notConfigured("provider unavailable")
        }
        return try await provider.move(
            remoteId: remoteId, to: folder, createIfMissing: createIfMissing
        )
    }

    func listSent(limit: Int) async throws -> [MessageHeader] {
        guard let provider = await resolved() else {
            throw MailError.notConfigured("provider unavailable")
        }
        return try await provider.listSent(limit: limit)
    }

    func send(_ outbound: OutboundMessage) async throws -> String? {
        guard let provider = await resolved() else {
            throw MailError.notConfigured("provider unavailable")
        }
        return try await provider.send(outbound)
    }

    func probe() async throws {
        guard let provider = await resolved() else {
            throw MailError.notConfigured("provider unavailable")
        }
        try await provider.probe()
    }

    /// Releasing a route-side provider means releasing the pool's entry for
    /// this account: the next call builds a fresh one, with a fresh session.
    func shutdown() async {
        await pool.release(account.id)
    }

    func archiveFolder() async -> String? {
        guard let provider = await resolved(),
              let resolver = provider as? any ArchiveFolderResolving
        else { return nil }
        return await resolver.archiveFolder()
    }

    private func resolved() async -> (any MailProvider)? {
        await pool.provider(for: account, build: build)
    }
}
