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
    /// needs to pick one (M0 handshake + M1.5 `isActive`/`syncHealth`/
    /// `capabilities`). Credentials are never part of this payload.
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
                let connected = accounts.map {
                    ConnectedAccount(
                        id: $0.id,
                        provider: $0.provider,
                        email: $0.email,
                        isActive: $0.isActive,
                        syncHealth: $0.syncHealth,
                        capabilities: $0.capabilities
                    )
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
            let providerKind = MailProviderKind(rawValue: connect.provider)
            guard !email.isEmpty, !connect.authCode.isEmpty, providerKind == .qq else {
                return RouteJSON.error(.badRequest, "missing-field")
            }
            do {
                if try await AccountStore.find(byOAuthUser: email, provider: .qq, db: db) != nil {
                    return RouteJSON.error(.conflict, "account-exists")
                }
            } catch {
                logger.error("accounts.lookupFailed", metadata: ["err": .string("\(error)")])
                return RouteJSON.error(.internalServerError, "internal-error")
            }

            // The sealed blob exists in memory only until `probe` passes, so a
            // rejected authorization code never leaves a row behind.
            let sealed: Data
            do {
                sealed = try CredentialVault.seal(
                    .imap(username: email, authCode: connect.authCode)
                )
            } catch {
                logger.error("accounts.sealFailed", metadata: ["err": .string("\(error)")])
                return RouteJSON.error(.internalServerError, "internal-error")
            }
            let account = Account(
                id: UUID(),
                provider: .qq,
                oauthUser: email,
                email: email,
                credentials: sealed,
                isActive: false
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
                try await AccountStore.upsert(account, credentials: sealed, db: db)
                try await AccountStore.updateCapabilities(
                    accountId: account.id, capabilities: capabilities, db: db
                )
                try await AccountStore.updateSyncState(
                    accountId: account.id,
                    syncState: MailSyncState(archiveFolder: archiveFolder),
                    db: db
                )
                try await AccountStore.setActive(accountId: account.id, db: db)
            } catch {
                logger.error("accounts.imapPersistFailed", metadata: ["err": .string("\(error)")])
                return RouteJSON.error(.internalServerError, "internal-error")
            }
            // Pull once so the browser handshake finds mail already there.
            await sync?.tickOnce(waitBudget: .milliseconds(1))

            return RouteJSON.response(
                ConnectedAccount(
                    id: account.id,
                    provider: .qq,
                    email: account.email,
                    isActive: true,
                    syncHealth: SyncHealth(status: .ok),
                    capabilities: capabilities
                ),
                status: .created
            )
        }

        // POST /api/accounts/{id}/activate -> 204 | 404 unknown-account
        // The invariant is one active account (spec §2.5): every other row is
        // flipped off in the same statement.
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
            // The loop may be blocked in a long IDLE/poll for the old account.
            await sync?.accountChanged()
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
                // Deleting the active account leaves zero active rows; promote
                // the newest remaining one so the client has a target.
                try await AccountStore.reconcileActive(db: db)
            } catch {
                logger.error("accounts.deleteFailed", metadata: ["err": .string("\(error)")])
                return RouteJSON.error(.internalServerError, "internal-error")
            }
            await sync?.accountChanged()
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
