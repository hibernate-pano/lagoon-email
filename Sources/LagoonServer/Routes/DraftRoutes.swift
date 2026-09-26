import Foundation
import Hummingbird
import Logging
import PostgresNIO
import LagoonKit
import LagoonAI

struct DraftListResponse: Encodable { let drafts: [DraftReply] }

/// AI-generated reply drafts. POST generates three variants and stores them;
/// POST /choose picks one (and pushes to Gmail Drafts when scope allows).
public enum DraftRoutes {
    public static func register(
        on router: Router<BasicRequestContext>,
        db: PostgresConnection,
        client: GmailClient,
        tokens: GmailTokenService,
        draftGenerator: (any MessageDrafting)?,
        logger: Logger,
        makeProvider: MailProviderFactory.Builder? = nil
    ) {
        let makeProvider = makeProvider
            ?? MailProviderFactory.factory(client: client, tokens: tokens, db: db, logger: logger)

        router.post("api/messages/:remoteId/draft") { request, context -> Response in
            return await generateHandler(
                request: request, context: context, db: db,
                makeProvider: makeProvider,
                draftGenerator: draftGenerator, logger: logger
            )
        }

        router.post("api/drafts/:id/choose") { request, context -> Response in
            return await chooseHandler(
                request: request, context: context, db: db,
                client: client, tokens: tokens, logger: logger
            )
        }

        router.get("api/messages/:remoteId/drafts") { request, context -> Response in
            return await listHandler(request: request, context: context, db: db)
        }
    }

    private static func generateHandler(
        request: Request, context: BasicRequestContext, db: PostgresConnection,
        makeProvider: MailProviderFactory.Builder,
        draftGenerator: (any MessageDrafting)?, logger: Logger
    ) async -> Response {
        guard let accountId = RouteParams.accountId(from: request) else {
            return RouteJSON.error(.badRequest, "malformed-accountId")
        }
        guard let remoteId = RouteParams.remoteId(from: context) else {
            return RouteJSON.error(.badRequest, "malformed-remoteId")
        }
        guard let draftGenerator else {
            return RouteJSON.error(.serviceUnavailable, "ai-not-configured")
        }
        let account: Account
        do {
            guard let found = try await AccountStore.find(byId: accountId, db: db) else {
                return RouteJSON.error(.notFound, "unknown-account")
            }
            account = found
        } catch {
            return errorResponse(.internalServerError, "internal-error", logger: logger, error: error)
        }

        let body: MessageBody
        do {
            guard let provider = makeProvider(account) else {
                return RouteJSON.error(.serviceUnavailable, "provider-not-configured")
            }
            body = try await MessageRoutes.fetchBody(
                account: account, remoteId: remoteId, provider: provider, db: db,
                logger: logger
            )
        } catch let error as MailError {
            return MessageRoutes.providerError(error, logger: logger, remoteId: remoteId)
        } catch {
            return errorResponse(.badGateway, "provider-unreachable", logger: logger, error: error)
        }

        let language = RouteParams.preferredLanguage(fromHeader: request.headers[.acceptLanguage])
        let variants: [String]
        do {
            variants = try await generateVariants(
                body: body,
                language: language,
                accountEmail: account.email,
                draftGenerator: draftGenerator
            )
        } catch let llmError as LLMError where llmError.code == "insufficient-credit" {
            // The provider's account is out of money / revoked. Surface a
            // distinct code so the client tells the user to top up their
            // MiniMax account instead of showing "AI error, retry".
            return errorResponse(.serviceUnavailable, "ai-credit-exhausted", logger: logger, error: llmError)
        } catch let llmError as LLMError where llmError.code == "budget-exceeded" {
            return errorResponse(.serviceUnavailable, "ai-budget-exceeded", logger: logger, error: llmError)
        } catch let llmError as LLMError where llmError.code == "circuit-open" {
            return errorResponse(.serviceUnavailable, "ai-circuit-open", logger: logger, error: llmError)
        } catch {
            return errorResponse(.badGateway, "ai-error", logger: logger, error: error)
        }

        let draft: DraftReply
        do {
            draft = try await DraftReplyStore.create(
                accountId: accountId, remoteId: remoteId, variants: variants, db: db
            )
            _ = try await AIActionStore.record(
                accountId: accountId,
                kind: .draftCreate,
                payload: ["remoteId": remoteId, "variantCount": "\(variants.count)"],
                db: db
            )
        } catch {
            return errorResponse(.internalServerError, "internal-error", logger: logger, error: error)
        }
        // Answer with the bare DraftReply APIClient.generateDrafts decodes.
        // This used to re-list every draft for the message inside a
        // server-local {"drafts":[…]} envelope, so the 200 body never matched
        // the client's type: generation succeeded (rows + action recorded)
        // while the UI reported "未能读取数据，因为数据丢失" on every click.
        return RouteJSON.response(draft)
    }

    private static func chooseHandler(
        request: Request, context: BasicRequestContext, db: PostgresConnection,
        client: GmailClient, tokens: GmailTokenService, logger: Logger
    ) async -> Response {
        guard let accountId = RouteParams.accountId(from: request) else {
            return RouteJSON.error(.badRequest, "malformed-accountId")
        }
        let rawId = context.parameters.get("id") ?? ""
        guard let draftId = Int64(rawId), draftId > 0 else {
            return RouteJSON.error(.badRequest, "malformed-draft-id")
        }
        let body: Data
        do { body = try await collectBody(request) } catch {
            return RouteJSON.error(.badRequest, "missing-body")
        }
        struct ChooseReq: Decodable {
            let variant: Int
            let pushToGmail: Bool
        }
        let req: ChooseReq
        do { req = try JSONDecoder().decode(ChooseReq.self, from: body) } catch {
            return RouteJSON.error(.badRequest, "invalid-body")
        }
        guard req.variant >= 0, req.variant < 4 else {
            return RouteJSON.error(.badRequest, "variant-out-of-range")
        }

        let draft: DraftReply
        do {
            guard let found = try await findDraft(id: draftId, db: db) else {
                return RouteJSON.error(.notFound, "unknown-draft")
            }
            draft = found
        } catch {
            return errorResponse(.internalServerError, "internal-error", logger: logger, error: error)
        }
        guard draft.accountId == accountId else {
            return RouteJSON.error(.forbidden, "draft-different-account")
        }
        guard req.variant < draft.variants.count else {
            return RouteJSON.error(.badRequest, "variant-out-of-range")
        }

        do {
            try await db.query(
                "UPDATE draft_replies SET chosen_variant = $1 WHERE id = $2",
                [PostgresData(int: req.variant), PostgresData(int64: draftId)]
            ).get()
        } catch {
            return errorResponse(.internalServerError, "internal-error", logger: logger, error: error)
        }

        var gmailDraftId = ""
        if req.pushToGmail {
            do {
                guard let account = try await AccountStore.find(byId: accountId, db: db) else {
                    throw NSError(
                        domain: "Lagoon.Drafts", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "missing-account"]
                    )
                }
                // Server-side drafts are a Gmail API feature; an IMAP account
                // keeps the chosen variant locally (SMTP has no draft concept).
                if account.provider == .gmail {
                    let token = try await tokens.validToken(for: account)
                    let headerRow = try? await db.query(
                        "SELECT thread_id, from_address, subject FROM message_headers WHERE account_id = $1 AND remote_id = $2",
                        [PostgresData(uuid: accountId), PostgresData(string: draft.remoteId)]
                    ).get()
                    if let row = headerRow?.rows.first,
                       let threadId = row.column("thread_id")?.string {
                        let from = row.column("from_address")?.string ?? ""
                        let subject = row.column("subject")?.string ?? "(no subject)"
                        let body = draft.variants[req.variant]
                        let id = try await client.createDraft(
                            accessToken: token.accessToken,
                            threadId: threadId,
                            to: from,
                            subject: subject,
                            body: body
                        )
                        gmailDraftId = id
                    }
                } else {
                    logger.info("draft.pushSkipped", metadata: [
                        "draftId": .string("\(draftId)"),
                        "provider": .string(account.provider.rawValue),
                    ])
                }
            } catch GmailClientError.http(let status, _) where status == 403 {
                logger.warning("draft.scopeMissing", metadata: ["draftId": .string("\(draftId)")])
            } catch {
                logger.error("draft.pushFailed", metadata: ["err": .string("\(error)")])
            }
        }

        struct ChooseResponse: Encodable {
            let ok: Bool
            let draftId: Int64
            let chosen: Int
            let gmailDraftId: String
        }
        return RouteJSON.response(ChooseResponse(
            ok: true, draftId: draftId, chosen: req.variant, gmailDraftId: gmailDraftId
        ))
    }

    private static func listHandler(
        request: Request, context: BasicRequestContext, db: PostgresConnection
    ) async -> Response {
        guard let accountId = RouteParams.accountId(from: request) else {
            return RouteJSON.error(.badRequest, "malformed-accountId")
        }
        guard let remoteId = RouteParams.remoteId(from: context) else {
            return RouteJSON.error(.badRequest, "malformed-remoteId")
        }
        do {
            let drafts = try await DraftReplyStore.list(accountId: accountId, remoteId: remoteId, db: db)
            return RouteJSON.response(DraftListResponse(drafts: drafts))
        } catch {
            return RouteJSON.error(.internalServerError, "internal-error")
        }
    }

    private static func findDraft(id: Int64, db: PostgresConnection) async throws -> DraftReply? {
        let rows = try await db.query(
            "SELECT id, account_id, remote_id, variants, chosen_variant, created_at FROM draft_replies WHERE id = $1",
            [PostgresData(int64: id)]
        ).get()
        return try rows.rows.first.map { try DraftReplyStore.decode($0) }
    }

    /// Ask the AI gateway for real reply variants. Summarization is a separate
    /// task and must never be recycled as a reply draft.
    private static func generateVariants(
        body: MessageBody,
        language: String?,
        accountEmail: String,
        draftGenerator: any MessageDrafting
    ) async throws -> [String] {
        let variants = try await draftGenerator.draftReplies(
            body,
            language: language,
            accountEmail: accountEmail,
            count: 3
        )
        return variants
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func collectBody(_ request: Request) async throws -> Data {
        var bytes: [UInt8] = []
        for try await chunk in request.body {
            bytes.append(contentsOf: Array(buffer: chunk))
        }
        return Data(bytes)
    }

    private static func errorResponse(
        _ status: HTTPResponse.Status, _ code: String, logger: Logger, error: Error
    ) -> Response {
        logger.error("drafts.error", metadata: ["code": .string(code), "err": .string("\(error)")])
        return RouteJSON.error(status, code)
    }
}

// MARK: - Search

public enum SearchRoutes {
    public static func register(on router: Router<BasicRequestContext>, db: PostgresConnection) {
        router.get("api/search") { request, _ -> Response in
            guard let accountId = RouteParams.accountId(from: request) else {
                return RouteJSON.error(.badRequest, "malformed-accountId")
            }
            let q = request.uri.queryParameters["q"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !q.isEmpty else {
                return RouteJSON.response(SearchResponse(results: [], query: q))
            }
            let sender = request.uri.queryParameters["sender"].map(String.init)
            let since = parseSince(request.uri.queryParameters["since"].map(String.init))
            do {
                let results = try await search(accountId: accountId, q: q, sender: sender, since: since, db: db)
                return RouteJSON.response(SearchResponse(results: results, query: q))
            } catch {
                return RouteJSON.error(.internalServerError, "internal-error")
            }
        }
    }

    private static func parseSince(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    private static func search(
        accountId: UUID, q: String, sender: String?, since: Date?, db: PostgresConnection
    ) async throws -> [MessageHeader] {
        // LIKE specials in the query are data, not wildcards.
        let escaped = q.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let pattern = "%\(escaped)%"
        // One path, two recalls: ILIKE substrings (precise, CJK-safe) ORed
        // with a plainto_tsquery match (English inflection recall). The
        // tsvector expression must match `message_bodies_fts_idx` exactly —
        // `coalesce(body_text, '')` here would be a *different* expression
        // from the indexed `body_text`, and the index could never be chosen.
        // `body_text` is NOT NULL (migration 015), so the left join's NULL side
        // simply fails the `@@` instead of needing a coalesce.
        // plainto_tsquery never throws on user input — the worst case is an
        // empty query that matches nothing.
        //
        // # ponytail: matching the indexed expression only makes the index
        // *eligible*; the leading-wildcard `b.body_text ILIKE '%q%'` arm of the
        // same OR still forces a sequential scan for the combined predicate, so
        // this query is not index-backed end to end. Upgrade path: split into
        // two queries (a GIN-only tsvector match UNIONed with the header/body
        // ILIKE pass) once body recall grows enough to hurt, or drop the ILIKE
        // arm behind a "match all words" mode. Deliberately not done here: the
        // brief says do not restructure the search.
        let sql = """
            SELECT m.id, m.account_id, m.remote_id, m.thread_id,
                   m.from_address,
                   NULLIF(m.from_name, '') as from_name,
                   NULLIF(m.subject, '') as subject,
                   NULLIF(m.snippet, '') as snippet,
                   m.received_at, m.is_read, m.is_archived,
                   m.message_id_header, m.in_reply_to, m.references_header
            FROM message_headers m
            LEFT JOIN message_bodies b
              ON b.account_id = m.account_id AND b.remote_id = m.remote_id
            WHERE m.account_id = $1
              AND (m.subject ILIKE $2 ESCAPE '\\' OR m.snippet ILIKE $2 ESCAPE '\\'
                   OR m.from_name ILIKE $2 ESCAPE '\\' OR m.from_address ILIKE $2 ESCAPE '\\'
                   OR b.body_text ILIKE $2 ESCAPE '\\'
                   OR to_tsvector('simple', b.body_text) @@ plainto_tsquery('simple', $5))
              AND ($3::text IS NULL OR m.from_address = $3)
              AND ($4::timestamptz IS NULL OR m.received_at >= $4)
            ORDER BY m.received_at DESC
            LIMIT 100
        """
        let rows = try await db.query(sql, [
            PostgresData(uuid: accountId),
            PostgresData(string: pattern),
            sender.map { PostgresData(string: $0) } ?? .null,
            since.map { PostgresData(date: $0) } ?? .null,
            PostgresData(string: q),
        ]).get()
        return try rows.map { try MessageStore.decode($0) }
    }
}

// MARK: - Budget / usage report

public enum BudgetRoutes {
    public static func register(
        on router: Router<BasicRequestContext>,
        budget: UsageBudget,
        costTrackingAvailable: Bool,
        gateway: AIGateway? = nil
    ) {
        router.get("api/usage") { _, _ -> Response in
            let cap = await budget.capUSD
            let month = await budget.currentMonthUSD
            let calls = await budget.callCount
            let report = UsageReport(
                monthUSD: month,
                capUSD: cap,
                callCount: calls,
                costTrackingAvailable: costTrackingAvailable
            )
            return RouteJSON.response(report)
        }
        // Global degraded signal for the client's banner (V2 C1). Nil
        // gateway (heuristic-only install) reports unconfigured, never down.
        router.get("api/ai-status") { _, _ -> Response in
            RouteJSON.response(AIStatus(
                configured: gateway?.isConfigured ?? false,
                creditExhausted: gateway?.creditExhausted ?? false,
                circuitOpen: gateway?.circuitOpen ?? false
            ))
        }
    }
}
