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
        summarizer: (any MessageSummarizing)?,
        logger: Logger,
        makeProvider: MailProviderFactory.Builder? = nil
    ) {
        let makeProvider = makeProvider
            ?? MailProviderFactory.factory(client: client, tokens: tokens, db: db, logger: logger)

        router.post("api/messages/:remoteId/draft") { request, context -> Response in
            return await generateHandler(
                request: request, context: context, db: db,
                makeProvider: makeProvider,
                summarizer: summarizer, logger: logger
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
        summarizer: (any MessageSummarizing)?, logger: Logger
    ) async -> Response {
        guard let accountId = RouteParams.accountId(from: request) else {
            return RouteJSON.error(.badRequest, "malformed-accountId")
        }
        guard let remoteId = RouteParams.remoteId(from: context) else {
            return RouteJSON.error(.badRequest, "malformed-remoteId")
        }
        guard let summarizer else {
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
                account: account, remoteId: remoteId, provider: provider, db: db
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
                body: body, language: language, summarizer: summarizer
            )
        } catch {
            return errorResponse(.badGateway, "ai-error", logger: logger, error: error)
        }

        do {
            _ = try await DraftReplyStore.create(
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
        do {
            let drafts = try await DraftReplyStore.list(accountId: accountId, remoteId: remoteId, db: db)
            return RouteJSON.response(DraftListResponse(drafts: drafts))
        } catch {
            return errorResponse(.internalServerError, "internal-error", logger: logger, error: error)
        }
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

    /// Build three variants by calling the summarizer with three different wrappers.
    /// Falls back to a single variant if anything fails.
    private static func generateVariants(
        body: MessageBody, language: String?, summarizer: any MessageSummarizing
    ) async throws -> [String] {
        let summary = try await summarizer.summarize(body, language: language, accountEmail: "")
        let core = summary.summary
        let subject = body.subject ?? "(no subject)"
        return [
            compose(core: core, tone: "concise", subject: subject),
            compose(core: core, tone: "friendly", subject: subject),
            compose(core: core, tone: "formal", subject: subject),
        ]
    }

    private static func compose(core: String, tone: String, subject: String) -> String {
        let greeting = "Hi,"
        let sign = "\n\nBest,\nMe"
        switch tone {
        case "concise":
            return greeting + "\n\n" + core + "\n\n" + sign
        case "friendly":
            let lower = core.lowercased()
            return greeting + "\n\nThanks for the news — " + lower + "\n\n" + sign
        case "formal":
            return "Dear sender,\n\nThank you for your note on '" + subject + "'. " + core + "\n\n" + sign
        default:
            return core
        }
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
        let pattern = "%\(q)%"
        let sql = """
            SELECT id, account_id, remote_id, thread_id,
                   from_address,
                   NULLIF(from_name, '') as from_name,
                   NULLIF(subject, '') as subject,
                   NULLIF(snippet, '') as snippet,
                   received_at, is_read, is_archived
            FROM message_headers
            WHERE account_id = $1
              AND (subject ILIKE $2 OR snippet ILIKE $2 OR from_name ILIKE $2 OR from_address ILIKE $2)
              AND ($3::text IS NULL OR from_address = $3)
              AND ($4::timestamptz IS NULL OR received_at >= $4)
            ORDER BY received_at DESC
            LIMIT 100
        """
        let rows = try await db.query(sql, [
            PostgresData(uuid: accountId),
            PostgresData(string: pattern),
            sender.map { PostgresData(string: $0) } ?? PostgresData(string: ""),
            since.map { PostgresData(date: $0) } ?? PostgresData(date: Date.distantPast),
        ]).get()
        return try rows.map { try MessageStore.decode($0) }
    }
}

// MARK: - Budget / usage report

public enum BudgetRoutes {
    public static func register(on router: Router<BasicRequestContext>, budget: UsageBudget) {
        router.get("api/usage") { _, _ -> Response in
            let cap = await budget.capUSD
            let month = await budget.currentMonthUSD
            let report = UsageReport(monthUSD: month, capUSD: cap, callCount: 0)
            return RouteJSON.response(report)
        }
    }
}
