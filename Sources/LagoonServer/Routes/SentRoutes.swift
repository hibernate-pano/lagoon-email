import Foundation
import Hummingbird
import Logging
import GRDB
import LagoonKit

/// R1 — the 已发送 listing.
///
/// ## Why this is its own route and not `?sent=true` on `/api/messages`
///
/// Two reasons, and the second is the one that matters.
///
/// 1. `/api/messages` is the app's hottest path — the list polls it every 30
///    seconds. Adding a branch there means every inbox poll carries a
///    conditional nobody exercises.
/// 2. **Sent is the only axis that needs the provider on the way in.** The
///    inbox, archive and trash are all answered from the local table, because
///    the sync loop keeps them current. Sent has no sync loop — the engine
///    pulls INBOX only, and its own comment says "sent mail is never stored as
///    rows". So a Sent listing that only read SQLite would return an empty list
///    forever, which looks exactly like "you have never sent anything".
///
/// Pulling from the provider on demand is therefore the feature. And because
/// the rows are then written locally, *every other surface* — search, thread
/// walk, the detail view, 批量操作 — starts working on sent mail for free,
/// which is the real payoff of storing them rather than streaming a one-off
/// response.
public enum SentRoutes {
    /// Same ceiling as the inbox list, so the two lists cannot disagree about
    /// what "a page" means.
    public static let maxRows = 1000

    public static func register(
        on router: Router<BasicRequestContext>,
        db: LagoonDB,
        logger: Logger,
        makeProvider: MailProviderFactory.Builder? = nil
    ) {
        let makeProvider = makeProvider
            ?? MailProviderFactory.factory(db: db, logger: logger).builder

        // GET /api/sent?accountId=<uuid>[&limit=]
        // 200 SentResponse | 400 malformed | 404 unknown-account / sent-unavailable
        // | 401 provider-auth-failed | 502 provider-unreachable
        router.get("api/sent") { request, _ -> Response in
            guard let accountId = RouteParams.accountId(from: request) else {
                return RouteJSON.error(.badRequest, "malformed-accountId")
            }
            let limit = max(
                1,
                min(
                    Int(request.uri.queryParameters["limit"] ?? "") ?? maxRows,
                    maxRows
                )
            )
            let account: Account
            do {
                guard let found = try await AccountStore.find(byId: accountId, db: db) else {
                    return RouteJSON.error(.notFound, "unknown-account")
                }
                account = found
            } catch {
                return RouteJSON.failure(
                    .internalServerError, "internal-error",
                    label: "sent", logger: logger, failure: error
                )
            }
            guard let provider = makeProvider(account) else {
                return RouteJSON.error(.serviceUnavailable, "provider-not-configured")
            }

            // 1. Pull from the server. A failure here is **not** fatal: whatever
            //    a previous visit already stored is still true, and showing it
            //    beats showing an error page when the user only wanted to read
            //    an old reply. The failure is logged, not swallowed.
            var refreshed = 0
            var refreshFailed: String?
            do {
                refreshed = try await refresh(
                    account: account, provider: provider, limit: limit, db: db
                )
            } catch let error as MailError {
                if case .sentUnavailable = error {
                    // No Sent folder at all is a *definitive* answer, not a
                    // transient failure: reporting it as an empty list would
                    // claim the user has sent nothing, which is a different
                    // statement and a wrong one.
                    return RouteJSON.error(.notFound, "sent-unavailable")
                }
                refreshFailed = error.logLabel
                logger.warning("sent.refreshFailed", metadata: [
                    "account": .string(account.email),
                    "label": .string(error.logLabel),
                ])
            } catch {
                refreshFailed = MessageRoutes.providerLabel(error)
                logger.warning("sent.refreshFailed", metadata: [
                    "account": .string(account.email),
                    "label": .string(refreshFailed ?? "unknown"),
                ])
            }

            // 2. Answer from the local table, through the *same* filter the
            //    inbox list uses. Two queries answering the same question is how
            //    "the list disagrees with its own count" bugs start.
            do {
                let messages = try await MessageStore.recent(
                    forAccount: accountId, limit: limit,
                    sender: nil, archived: false, deleted: false, sent: true,
                    stackMatch: nil, db: db
                )
                let total = try await MessageStore.count(
                    forAccount: accountId,
                    sender: nil, archived: false, deleted: false, sent: true,
                    stackMatch: nil, db: db
                )
                return RouteJSON.response(SentResponse(
                    messages: messages,
                    totalCount: total,
                    refreshedFromServer: refreshed,
                    // Non-nil only when the provider failed. The client shows a
                    // quiet notice rather than an empty screen, because these
                    // rows may be stale and the user deserves to know that.
                    staleReason: refreshFailed
                ))
            } catch {
                return RouteJSON.failure(
                    .internalServerError, "internal-error",
                    label: "sent", logger: logger, failure: error
                )
            }
        }
    }

    /// Fetches the Sent folder and writes the rows locally.
    ///
    /// Each row goes through `MessageStore.upsert` — the *same* insert the
    /// inbox sync uses — so a sent message ends up with its body, its threading
    /// headers and its place in search without a single extra line of code. The
    /// only thing that marks it as sent is `markSent`, and it is called
    /// separately because `upsert` deliberately never writes that column (see
    /// its doc comment: the flag comes from *which folder* a row was synced
    /// from, not from anything in the message).
    ///
    /// Returns how many rows the server handed over, which the response reports
    /// as `refreshedFromServer` so a test can tell "the server had nothing" from
    /// "we never asked".
    @discardableResult
    static func refresh(
        account: Account,
        provider: any MailProvider,
        limit: Int,
        db: LagoonDB
    ) async throws -> Int {
        let rows = try await provider.listSent(limit: limit)
        guard !rows.isEmpty else { return 0 }
        for row in rows {
            // Two steps, two transactions, on purpose. `upsert` is the shared
            // async pool write and is what the inbox sync uses; `markSent` is a
            // narrow transactional update. Folding them together would mean
            // either duplicating upsert's column list here or holding a write
            // transaction across an await — and upsert's ON CONFLICT clause
            // deliberately does not touch `is_sent`, so the two cannot be one
            // statement anyway.
            try await MessageStore.upsert(row, db: db)
            try db.write { raw in
                try MessageStore.markSent(
                    remoteId: row.remoteId, accountId: account.id, db: raw
                )
            }
        }
        return rows.count
    }
}

/// The 已发送 payload.
///
/// Shaped like `SyncResponse` on purpose — the client's list view is already
/// built around `{messages, totalCount}`, and reusing the shape means the Sent
/// surface needs no new decoding path and no second list implementation.
struct SentResponse: Encodable {
    let messages: [MessageHeader]
    /// Server-side total, independent of `limit`, so a capped list can say so
    /// rather than looking complete.
    let totalCount: Int
    /// How many rows this request pulled from the provider. Diagnostic, and
    /// what lets a test assert the refresh actually ran.
    let refreshedFromServer: Int
    /// Non-nil when the provider could not be reached. The list still renders
    /// whatever is stored; the client adds a "可能不是最新" note.
    let staleReason: String?
}
