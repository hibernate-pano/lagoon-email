import Foundation
import Hummingbird
import Logging
import GRDB
import LagoonKit
import LagoonAI

struct DraftListResponse: Encodable { let drafts: [DraftReply] }

/// AI-generated reply drafts. POST generates three variants and stores them;
/// POST /choose picks one. The chosen variant is sent over SMTP.
public enum DraftRoutes {
    public static func register(
        on router: Router<BasicRequestContext>,
        db: LagoonDB,
        draftGenerator: (any MessageDrafting)?,
        logger: Logger,
        makeProvider: MailProviderFactory.Builder? = nil
    ) {
        let makeProvider = makeProvider
            ?? MailProviderFactory.factory(db: db, logger: logger).builder

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
                logger: logger
            )
        }

        router.get("api/messages/:remoteId/drafts") { request, context -> Response in
            return await listHandler(request: request, context: context, db: db, logger: logger)
        }
    }

    private static func generateHandler(
        request: Request, context: BasicRequestContext, db: LagoonDB,
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
        request: Request, context: BasicRequestContext, db: LagoonDB,
        logger: Logger
    ) async -> Response {
        guard let accountId = RouteParams.accountId(from: request) else {
            return RouteJSON.error(.badRequest, "malformed-accountId")
        }
        let rawId = context.parameters.get("id") ?? ""
        guard let draftId = Int64(rawId), draftId > 0 else {
            return RouteJSON.error(.badRequest, "malformed-draft-id")
        }
        let body: Data
        do { body = try await RouteParams.collectBody(request) } catch {
            return RouteJSON.error(.badRequest, "missing-body")
        }
        struct ChooseReq: Decodable {
            let variant: Int
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
            try db.write {
                try $0.execute(
                    sql: "UPDATE draft_replies SET chosen_variant = ? WHERE id = ?",
                    arguments: [req.variant, draftId]
                )
            }
        } catch {
            return errorResponse(.internalServerError, "internal-error", logger: logger, error: error)
        }

        struct ChooseResponse: Encodable {
            let ok: Bool
            let draftId: Int64
            let chosen: Int
        }
        return RouteJSON.response(ChooseResponse(
            ok: true, draftId: draftId, chosen: req.variant
        ))
    }

    private static func listHandler(
        request: Request, context: BasicRequestContext, db: LagoonDB, logger: Logger
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
            return RouteJSON.failure(
                .internalServerError, "internal-error",
                label: "drafts", logger: logger, failure: error
            )
        }
    }

    private static func findDraft(id: Int64, db: LagoonDB) async throws -> DraftReply? {
        return try db.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT id, account_id, remote_id, variants, chosen_variant, created_at FROM draft_replies WHERE id = ?",
                arguments: [id]
            ).map { try DraftReplyStore.decode($0) }
        }
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


    /// Delegates to `RouteJSON.failure`; the label is what makes a 500 say
    /// which domain produced it.
    private static func errorResponse(
        _ status: HTTPResponse.Status, _ code: String, logger: Logger, error: Error
    ) -> Response {
        RouteJSON.failure(status, code, label: "drafts", logger: logger, failure: error)
    }
}

// MARK: - Search

public enum SearchRoutes {
    public static func register(
        on router: Router<BasicRequestContext>, db: LagoonDB, logger: Logger
    ) {
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
                return RouteJSON.failure(
                    .internalServerError, "internal-error",
                    label: "search", logger: logger, failure: error
                )
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
        accountId: UUID, q: String, sender: String?, since: Date?, db: LagoonDB
    ) async throws -> [MessageHeader] {
        // LIKE specials in the query are data, not wildcards.
        let escaped = q.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let pattern = "%\(escaped)%"
        // One path, one recall: LIKE substrings over subject/snippet/from/body.
        // The Postgres build ORed a plainto_tsquery arm into this predicate for
        // English inflection recall; SQLite has no tsvector and the body LIKE
        // arm already covers the same text, so the arm is gone rather than
        // emulated. Optional sender/since filters are appended as static
        // fragments (never user text) so binding stays positional.
        var sql = """
            SELECT m.id, m.account_id, m.remote_id, m.thread_id,
                   m.from_address,
                   NULLIF(m.from_name, '') as from_name,
                   NULLIF(m.subject, '') as subject,
                   NULLIF(m.snippet, '') as snippet,
                   m.received_at, m.is_read, m.is_archived, m.is_deleted,
                   m.message_id_header, m.in_reply_to, m.references_header
            FROM message_headers m
            LEFT JOIN message_bodies b
              ON b.account_id = m.account_id AND b.remote_id = m.remote_id
            WHERE m.account_id = ?
              AND m.is_deleted = FALSE
              AND (m.subject LIKE ? ESCAPE '\\' OR m.snippet LIKE ? ESCAPE '\\'
                   OR m.from_name LIKE ? ESCAPE '\\' OR m.from_address LIKE ? ESCAPE '\\'
                   OR b.body_text LIKE ? ESCAPE '\\')
        """
        var arguments: [DatabaseValueConvertible?] = [
            accountId, pattern, pattern, pattern, pattern, pattern
        ]
        if let sender {
            sql += "\n              AND m.from_address = ?"
            arguments.append(sender)
        }
        if let since {
            sql += "\n              AND m.received_at >= ?"
            arguments.append(since)
        }
        sql += "\n            ORDER BY m.received_at DESC\n            LIMIT 100"
        return try db.read { db in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
                .map { try MessageStore.decode($0) }
        }
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
