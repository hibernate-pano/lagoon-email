import Foundation
import Logging
import PostgresNIO
import LagoonKit

/// Builds the provider for an account row. Kept as a factory rather than a
/// provider method because construction needs server-side collaborators
/// (token service, DB, logger) that a stored account must not carry.
public enum MailProviderFactory {
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
}
