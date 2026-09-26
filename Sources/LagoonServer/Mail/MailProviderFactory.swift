import Foundation
import Logging
import PostgresNIO
import LagoonKit

/// Builds the provider for an account row. Kept as a factory rather than a
/// provider method because construction needs server-side collaborators
/// (token service, DB, logger) that a stored account must not carry.
public enum MailProviderFactory {
    /// Route-level construction closure. Injected so route tests can script a
    /// fake; production wires `factory(client:tokens:db:logger:)`.
    public typealias Builder = @Sendable (Account) -> (any MailProvider)?

    /// `nil` when the account's provider has no implementation in this build
    /// (the engine records `no-provider` and keeps the loop alive).
    public static func make(
        account: Account,
        client: GmailClient,
        tokens: GmailTokenService,
        db: PostgresConnection,
        logger: Logger
    ) -> (any MailProvider)? {
        switch account.provider {
        case .gmail:
            return GmailProvider(
                account: account,
                client: client,
                tokens: tokens,
                logger: logger
            )
        case .qq:
            return IMAPProvider(account: account, db: db, logger: logger)
        }
    }

    /// The production `Builder`. Bound once per route so handlers share the
    /// same collaborators.
    public static func factory(
        client: GmailClient,
        tokens: GmailTokenService,
        db: PostgresConnection,
        logger: Logger
    ) -> Builder {
        // Route traffic gets its own reusable provider per account. The sync
        // engine already owns a separate long-lived provider; sharing that one
        // would put IDLE and on-demand body/action commands on the same IMAP
        // connection. Caching here avoids a fresh QQ login for every message
        // open or action while keeping the two workloads isolated.
        let pool = MailProviderPool()
        return { account in
            PooledMailProvider(account: account, pool: pool) { _ in
                make(account: account, client: client, tokens: tokens, db: db, logger: logger)
            }
        }
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
    ) -> (any MailProvider)? {
        if let entry = entries[account.id],
           entry.providerKind == account.provider,
           entry.email == account.email,
           entry.credentials == account.credentials {
            return entry.provider
        }
        guard let provider = build(account) else { return nil }
        entries[account.id] = Entry(
            provider: provider,
            providerKind: account.provider,
            email: account.email,
            credentials: account.credentials
        )
        return provider
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
