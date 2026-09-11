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
        { account in
            make(account: account, client: client, tokens: tokens, db: db, logger: logger)
        }
    }
}
