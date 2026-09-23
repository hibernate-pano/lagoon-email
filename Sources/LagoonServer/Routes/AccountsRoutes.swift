import Foundation
import Logging
import Hummingbird
import NIOCore
import PostgresNIO
import LagoonKit

public enum AccountsRoutes {
    /// Request body of `POST /api/accounts/imap`.
    private struct IMAPConnectRequest: Decodable {
        let provider: String
        let email: String
        let authCode: String
    }

    /// GET /api/accounts — every connected account with the fields the client
    /// needs (M0 handshake + health/capabilities + cached unread count).
    /// `isActive` identifies the one account currently syncing. Credentials are
    /// never part of this payload.
    ///
    /// `makeProvider` is the route's provider seam: production passes
    /// `MailProviderFactory.factory(...)`, tests script a fake.
    public static func register(
        on router: Router<BasicRequestContext>,
        db: PostgresConnection,
        logger: Logger,
        sync: SyncEngine? = nil,
        makeProvider: @escaping MailProviderFactory.Builder
    ) {
        router.get("api/accounts") { _, _ -> Response in
            do {
                let accounts = try await AccountStore.all(db: db)
                var connected: [ConnectedAccount] = []
                connected.reserveCapacity(accounts.count)
                for account in accounts {
                    // A count failure must not break the whole directory: the
                    // client uses this payload for health and the toolbar too.
                    let unread = (try? await MessageStore.unreadCount(
                        forAccount: account.id, db: db
                    )) ?? 0
                    connected.append(ConnectedAccount(
                        id: account.id,
                        provider: account.provider,
                        email: account.email,
                        isActive: account.isActive,
                        unreadCount: unread,
                        syncHealth: account.syncHealth,
                        capabilities: account.capabilities
                    ))
                }
                return RouteJSON.response(connected)
            } catch {
                logger.error("accounts.listFailed", metadata: ["err": .string("\(error)")])
                return RouteJSON.error(.internalServerError, "internal-error")
            }
        }

        // POST /api/accounts/imap {provider:"qq", email, authCode}
        // 201 ConnectedAccount | 400 missing-field | 401 imap-auth-failed
        // | 502 imap-unreachable | 409 account-exists
        //
        // Existing-row rules — what `account-exists` means:
        //   1. row exists AND `syncHealth.status == .ok` → the account is
        //      already connected and working: return 409 `account-exists`
        //      *before* any network work (the probe is never called; the user
        //      is asked to switch to the working account instead).
        //   2. row exists but `syncHealth.status != .ok` (needsReconnect /
        //      degraded / error) → do not lock the user out. Probe with *this
        //      request's* auth code first:
        //        • probe fails → 401/502 (same mapping as a new account) and
        //          the existing row is left completely untouched — no
        //          credentials, sync_state, capabilities, is_active or
        //          sync_status write happens.
        //        • probe succeeds → persist against the existing row id (never
        //          a fresh UUID): replace credentials, capabilities and
        //          sync_state, reset health to `.ok` with `lastError = nil`
        //          (so the client's red banner clears).
        //   3. no row → the original create path.
        //
        // The auth code travels request body → TLS → provider, and is stored
        // sealed; it is never logged and never echoed (spec §5.2).
        router.post("api/accounts/imap") { request, _ -> Response in
            let body: Data
            do {
                body = try await collectBody(request)
            } catch {
                return RouteJSON.error(.badRequest, "missing-body")
            }
            guard let connect = try? JSONDecoder().decode(IMAPConnectRequest.self, from: body) else {
                return RouteJSON.error(.badRequest, "missing-field")
            }
            let email = connect.email.trimmingCharacters(in: .whitespacesAndNewlines)
            // Clipboard copies of a QQ authorization code routinely carry a
            // trailing newline/space; trim it or a valid code 401s.
            let authCode = connect.authCode.trimmingCharacters(in: .whitespacesAndNewlines)
            let providerKind = MailProviderKind(rawValue: connect.provider)
            guard !email.isEmpty, !authCode.isEmpty, providerKind == .qq else {
                return RouteJSON.error(.badRequest, "missing-field")
            }

            let existing: Account?
            do {
                existing = try await AccountStore.find(byOAuthUser: email, provider: .qq, db: db)
            } catch {
                logger.error("accounts.lookupFailed", metadata: ["err": .string("\(error)")])
                return RouteJSON.error(.internalServerError, "internal-error")
            }
            // Rule 1: a healthy account is reported before any network work.
            if let existing, existing.syncHealth.status == .ok {
                return RouteJSON.error(.conflict, "account-exists")
            }

            // The sealed blob exists in memory only until `probe` passes, so a
            // rejected authorization code never leaves a row behind. For a
            // re-auth this seals the new code and the row is not touched until
            // the probe succeeds.
            let sealed: Data
            do {
                sealed = try CredentialVault.seal(
                    .imap(username: email, authCode: authCode)
                )
            } catch {
                logger.error("accounts.sealFailed", metadata: ["err": .string("\(error)")])
                return RouteJSON.error(.internalServerError, "internal-error")
            }
            // The probe provider must use the submitted auth code: an existing
            // row's stored blob is deliberately ignored here.
            let account = Account(
                id: existing?.id ?? UUID(),
                provider: .qq,
                oauthUser: email,
                email: existing?.email ?? email,
                credentials: sealed,
                syncState: existing?.syncState ?? MailSyncState(),
                capabilities: existing?.capabilities ?? .unknown,
                isActive: existing?.isActive ?? false,
                syncHealth: existing?.syncHealth ?? SyncHealth(status: .ok)
            )
            guard let provider = makeProvider(account) else {
                return RouteJSON.error(.serviceUnavailable, "provider-not-configured")
            }
            do {
                try await provider.probe()
            } catch let error as MailError {
                logger.warning("imap.probeFailed", metadata: ["label": .string(error.logLabel)])
                switch error {
                case .authFailed:
                    return RouteJSON.error(.unauthorized, "imap-auth-failed")
                default:
                    return RouteJSON.error(.badGateway, "imap-unreachable")
                }
            } catch {
                logger.warning("imap.probeFailed", metadata: ["label": .string("\(type(of: error))")])
                return RouteJSON.error(.badGateway, "imap-unreachable")
            }

            let capabilities = await provider.capabilities()
            let archiveFolder = await (provider as? any ArchiveFolderResolving)?.archiveFolder()
            do {
                if let existing {
                    // In-place re-authentication (rule 2, probe passed): only
                    // the code, capabilities, archive folder and health move;
                    // the id, cursor and other read state stay put.
                    try await AccountStore.updateCredentials(
                        accountId: existing.id, credentials: sealed, db: db
                    )
                    try await AccountStore.updateCapabilities(
                        accountId: existing.id, capabilities: capabilities, db: db
                    )
                    var syncState = existing.syncState
                    syncState.archiveFolder = archiveFolder ?? syncState.archiveFolder
                    try await AccountStore.updateSyncState(
                        accountId: existing.id, syncState: syncState, db: db
                    )
                    // `lastError = nil` clears the client's red reconnect banner.
                    try await AccountStore.updateHealth(
                        accountId: existing.id, health: SyncHealth(status: .ok), db: db
                    )
                } else {
                    try await AccountStore.upsert(account, credentials: sealed, db: db)
                    try await AccountStore.updateCapabilities(
                        accountId: account.id, capabilities: capabilities, db: db
                    )
                    try await AccountStore.updateSyncState(
                        accountId: account.id,
                        syncState: MailSyncState(archiveFolder: archiveFolder),
                        db: db
                    )
                }
            } catch {
                logger.error("accounts.imapPersistFailed", metadata: ["err": .string("\(error)")])
                return RouteJSON.error(.internalServerError, "internal-error")
            }
            // `upsert`'s `ON CONFLICT ... DO UPDATE` keeps the *existing* row's
            // id, so under concurrent double-POSTs the locally generated UUID
            // can be one the server never stored (every later request would
            // 404). Re-read the authoritative row and echo its id/email.
            let persisted: Account?
            do {
                persisted = try await AccountStore.find(byOAuthUser: email, provider: .qq, db: db)
            } catch {
                logger.error("accounts.readbackFailed", metadata: ["err": .string("\(error)")])
                persisted = nil
            }
            let connectedId = persisted?.id ?? account.id
            do {
                // Connecting or re-authenticating a mailbox selects it. This
                // moves the single sync owner; every other account goes dormant.
                try await AccountStore.setActive(accountId: connectedId, db: db)
            } catch {
                logger.error("accounts.activateAfterConnectFailed", metadata: [
                    "err": .string("\(error)"),
                ])
                return RouteJSON.error(.internalServerError, "internal-error")
            }
            // Start the selected account's loop immediately without waiting for
            // its first potentially long mailbox backfill.
            await sync?.refresh()
            return RouteJSON.response(
                ConnectedAccount(
                    id: connectedId,
                    provider: .qq,
                    email: persisted?.email ?? account.email,
                    isActive: true,
                    unreadCount: 0,
                    syncHealth: SyncHealth(status: .ok),
                    capabilities: capabilities
                ),
                status: .created
            )
        }

        // POST /api/accounts/{id}/activate -> 204 | 404 unknown-account
        // Selects the mailbox the client shows. Sync is unaffected: every
        // stored account owns its loop, so this only restarts the selected
        // account's loop (recovers a parked loop after reconnect).
        router.post("api/accounts/:id/activate") { _, context -> Response in
            guard let accountId = UUID(uuidString: context.parameters.get("id") ?? "") else {
                return RouteJSON.error(.notFound, "unknown-account")
            }
            do {
                guard try await AccountStore.find(byId: accountId, db: db) != nil else {
                    return RouteJSON.error(.notFound, "unknown-account")
                }
                try await AccountStore.setActive(accountId: accountId, db: db)
            } catch {
                logger.error("accounts.activateFailed", metadata: ["err": .string("\(error)")])
                return RouteJSON.error(.internalServerError, "internal-error")
            }
            // Restart the selected account's loop without disturbing the
            // other accounts' connections.
            await sync?.refreshAccount(accountId)
            return Response(status: .noContent)
        }

        // DELETE /api/accounts/{id} -> 204 | 404 unknown-account
        // Foreign keys cascade to messages, pins and drafts.
        router.delete("api/accounts/:id") { _, context -> Response in
            guard let accountId = UUID(uuidString: context.parameters.get("id") ?? "") else {
                return RouteJSON.error(.notFound, "unknown-account")
            }
            do {
                guard try await AccountStore.find(byId: accountId, db: db) != nil else {
                    return RouteJSON.error(.notFound, "unknown-account")
                }
                try await AccountStore.delete(accountId: accountId, db: db)
                try await AccountStore.reconcileActive(db: db)
            } catch {
                logger.error("accounts.deleteFailed", metadata: ["err": .string("\(error)")])
                return RouteJSON.error(.internalServerError, "internal-error")
            }
            // Restart against the promoted account, or stop when none remain.
            await sync?.refresh()
            return Response(status: .noContent)
        }
    }

    private static func collectBody(_ request: Request) async throws -> Data {
        var bytes: [UInt8] = []
        for try await chunk in request.body {
            bytes.append(contentsOf: Array(buffer: chunk))
        }
        return Data(bytes)
    }
}
