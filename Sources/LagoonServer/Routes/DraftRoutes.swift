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
        } catch let cipherError as DraftCipherError {
            // The write path seals the variants, so this is the *store*
            // refusing to hold a draft it cannot encrypt (no key, or a key
            // the store does not recognise).
            //
            // It gets its own code rather than the generic
            // `internal-error`, because the two need different words in the
            // UI: "the store is broken" and "the key is missing" send the
            // user to different places. And it is a 500 rather than a 400 —
            // the request was fine; the store was not.
            logger.error("drafts.sealFailed", metadata: [
                "err": .string("\(cipherError)"),
            ])
            return RouteJSON.error(.internalServerError, "draft-seal-failed")
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
        } catch let cipherError as DraftCipherError {
            // The stored draft could not be opened — the key does not match
            // it, or the value is not an envelope. The user cannot pick a
            // variant out of a draft the store cannot read, and the store
            // will not answer with an empty list (which would look like
            // "there were no drafts").
            logger.error("drafts.openFailed", metadata: [
                "err": .string("\(cipherError)"),
            ])
            return RouteJSON.error(.internalServerError, "draft-unreadable")
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
        } catch let cipherError as DraftCipherError {
            // One unreadable draft must not cost the user the readable
            // ones — but it must not be hidden either. The list is refused
            // loudly: a list that quietly omitted the broken draft would
            // show "2 drafts" where the truth is "3, one of which is
            // broken", and the user could not tell which.
            logger.error("drafts.openFailed", metadata: [
                "err": .string("\(cipherError)"),
            ])
            return RouteJSON.error(.internalServerError, "draft-unreadable")
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
            // The account is **optional**.
            //
            // It used to be required, which made search a half-feature for
            // anyone with more than one mailbox: the query could only ever
            // reach the active account, and a user who remembers a mail in
            // their other mailbox had no way to find it.
            //
            // `accountId=all` searches every connected account, and so does
            // an absent parameter. A malformed id is still a bad request —
            // "all" is a keyword, and anything else that is not a UUID is a
            // client bug worth reporting rather than a wide search to hide
            // it behind.
            let rawAccount = request.uri.queryParameters["accountId"].map(String.init)
            guard let scope = SearchScope.parse(rawAccount) else {
                return RouteJSON.error(.badRequest, "malformed-accountId")
            }
            let q = request.uri.queryParameters["q"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !q.isEmpty else {
                return RouteJSON.response(SearchResponse(results: [], query: q, totalCount: 0, truncated: false))
            }
            let sender = request.uri.queryParameters["sender"].map(String.init)
            let since = parseSince(request.uri.queryParameters["since"].map(String.init))
            do {
                let (results, total) = try await search(
                    scope: scope,
                    q: q, sender: sender, since: since, db: db
                )
                // The count travels with the rows. A search that silently
                // stopped at its cap is indistinguishable from a search that
                // found everything, and the user has no other way to tell.
                return RouteJSON.response(SearchResponse(
                    results: results,
                    query: q,
                    totalCount: total,
                    truncated: total > results.count
                ))
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

    /// The rows and the number of rows that matched.
    ///
    /// The count is a second query over the same predicate. It is not free,
    /// and it is not free *on purpose*: the alternative was a silent cap,
    /// and a silent cap is a lie the user cannot detect. The count query
    /// skips the `LIMIT`, so it is the only way to say "there are 3,140
    /// matches; here are the first hundred".
    private static func search(
        scope: SearchScope, q: String, sender: String?, since: Date?, db: LagoonDB
    ) async throws -> ([MessageHeader], Int) {
        // LIKE specials in the query are data, not wildcards. This used to be
        // a second, hand-maintained copy of the escaping — a twin is exactly
        // what lets a fix land on one side only — so the route calls the
        // shared `MessageStore.likePattern(containing:)` now.
        let pattern = MessageStore.likePattern(containing: q)
        // One path, one recall: substrings over subject/snippet/from/body.
        // The Postgres build ORed a plainto_tsquery arm into this predicate for
        // English inflection recall; SQLite has no tsvector and the body arm
        // already covers the same text, so the arm is gone rather than
        // emulated. Optional sender/since filters are appended as static
        // fragments (never user text) so binding stays positional.
        //
        // The body and the preview are sealed at rest, so their arms are
        // `lagoon_cipher_contains(...)` rather than `LIKE` — see
        // `BodyCipher.containsFunction` for why the decision stays inside
        // SQLite instead of moving into Swift.
        //
        // What replaced it is cheaper and more honest: the `advice` arm. Lagoon
        // has already paid a model to classify every message it has seen, and
        // that verdict is stored in columns rather than prose. Matching on it
        // means searching "marketing" or "archive" finds mail by what the AI
        // *concluded* about it — which is the question a user asking "show me
        // the marketing" is really asking — with no extra inference, no
        // embedding index, and no per-query token spend.
        //
        // It deliberately does **not** match `a.rationale`: the rationale is the
        // model's own English/Chinese sentence, so a LIKE against it would be
        // accidental translation rather than a real filter. Only the enum-
        // shaped columns participate, and the UI labels them as AI-derived so
        // the user knows why the hit appeared.
        // `m.is_sent` is selected because `decode` can only carry the flag it
        // is given: without it, a sent reply opened from search results reads
        // as received mail end to end — the display lies, and its detail
        // actions resolve the UID in the INBOX scope and fail. `find()` states
        // the same reason (its column-list omission was invisible for the
        // identical reason: the nil-tolerant decode defaults it to false).
        //
        // ## One predicate, two queries
        //
        // The rows and the count are assembled from **one** list of
        // fragments and **one** list of arguments. They used to be two
        // hand-written statements, and they had already drifted: the count
        // still pinned `m.account_id = ?` while the rows had made the
        // account optional — so a cross-account search counted a mailbox
        // that was never queried, and a single-account search bound its
        // account id to the *subject* placeholder while the account
        // predicate was handed the last pattern in the list.
        //
        // A count that does not describe the rows it counts is worse than no
        // count at all: the user is told "3,140 matched" and shown a
        // different set. Sharing the fragments makes that impossible — the
        // two statements cannot disagree about a predicate they both hold.
        var predicate: [String] = []
        var arguments: [DatabaseValueConvertible?] = []

        predicate.append("WHERE m.is_deleted = FALSE")

        // The account narrows to one mailbox, or is absent for a
        // cross-account search. It comes first so the account value is the
        // account value: the position of a `?` in the statement is the
        // position of its value in the argument list, and the two are built
        // together here so they cannot drift.
        if let accountId = scope.accountId {
            predicate.append("AND m.account_id = ?")
            arguments.append(accountId)
        }

        // The two sealed columns cannot be matched with `LIKE` — the stored
        // value is ciphertext, not text — so they are matched by the
        // registered function instead, which opens the envelope and does the
        // substring test. Those two arms take the **raw** query; the `LIKE`
        // arms take the escaped pattern, which is the same substring test
        // written for SQL.
        predicate.append("""
            AND (m.subject LIKE ? ESCAPE '\\'
                 OR lagoon_cipher_contains(m.snippet_cipher, ?)
                 OR m.from_name LIKE ? ESCAPE '\\' OR m.from_address LIKE ? ESCAPE '\\'
                 OR lagoon_cipher_contains(b.body_cipher, ?)
                 OR a.category LIKE ? ESCAPE '\\'
                 OR a.action LIKE ? ESCAPE '\\')
            """)
        arguments.append(contentsOf: [
            pattern, q, pattern, pattern, q, pattern, pattern
        ])

        if let sender {
            predicate.append("AND m.from_address = ?")
            arguments.append(sender)
        }
        if let since {
            predicate.append("AND m.received_at >= ?")
            arguments.append(since)
        }

        // The statement is a list of fragments joined with a newline, not a
        // string built with `+=`. Every fragment is static text and every
        // value is bound; nothing reaches the SQL text but a literal.
        var sqlParts: [String] = [
            """
            SELECT m.id, m.account_id, m.remote_id, m.thread_id,
                   m.from_address,
                   NULLIF(m.from_name, '') as from_name,
                   NULLIF(m.subject, '') as subject,
                   NULLIF(m.snippet_cipher, '') as snippet_cipher,
                   m.received_at, m.is_read, m.is_archived, m.is_deleted, m.is_sent,
                   m.message_id_header, m.in_reply_to, m.references_header
            FROM message_headers m
            LEFT JOIN message_bodies b
              ON b.account_id = m.account_id AND b.remote_id = m.remote_id
            -- The advice table joins in for recall only. Nothing here reads the
            -- model's own words: it matches on the *structured* fields Lagoon
            -- already derived (category, action), so a search for "营销" or
            -- "archive" finds mail by what the AI concluded about it rather than
            -- only by what it happened to write. `rationale` is deliberately
            -- excluded — see the note below.
            LEFT JOIN advice a
              ON a.account_id = m.account_id AND a.remote_id = m.remote_id
            """
        ]
        sqlParts.append(contentsOf: predicate)
        sqlParts.append("ORDER BY m.received_at DESC")
        sqlParts.append("LIMIT 100")
        let sql = sqlParts.joined(separator: "\n")

        // The count runs over the same predicate without the `LIMIT`. It is
        // the only way to say "3,140 matched; here are the first hundred" —
        // and a search that silently stops at its cap is indistinguishable
        // from a search that found everything.
        //
        // The two joins cannot multiply rows: `message_bodies` is keyed by
        // (account_id, remote_id) and `advice` is UNIQUE on the same pair,
        // so every message contributes at most one row to the count.
        var countParts: [String] = [
            """
            SELECT COUNT(*)
            FROM message_headers m
            LEFT JOIN message_bodies b
              ON b.account_id = m.account_id AND b.remote_id = m.remote_id
            LEFT JOIN advice a
              ON a.account_id = m.account_id AND a.remote_id = m.remote_id
            """
        ]
        countParts.append(contentsOf: predicate)
        let countSQL = countParts.joined(separator: "\n")

        return try db.read { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
                .map { try MessageStore.decode($0) }
            let count = try Int.fetchOne(
                db, sql: countSQL, arguments: StatementArguments(arguments)
            ) ?? rows.count
            return (rows, count)
        }
    }
}

// MARK: - Budget / usage report

public enum BudgetRoutes {
    public static func register(
        on router: Router<BasicRequestContext>,
        budget: UsageBudget,
        costTrackingAvailable: Bool,
        gateway: AIGatewayHolder? = nil,
        logger: Logger = Logger(label: "lagoon.budget")
    ) {
        router.get("api/usage") { _, _ -> Response in
            let cap = await budget.capUSD
            let month = await budget.currentMonthUSD
            let calls = await budget.callCount
            // The per-account split. A failed read must not take the whole
            // panel down: the headline total is what the cap is about, and
            // it is already in hand. So a store failure degrades to "no
            // breakdown" (the client renders nothing for an empty list)
            // rather than a 500 that hides the number the user came for.
            let accounts: [UsageAccountShare]
            do {
                accounts = try await budget.accountBreakdown()
            } catch {
                logger.warning("usage.breakdownFailed", metadata: [
                    "err": .string("\(error)"),
                ])
                accounts = []
            }
            let report = UsageReport(
                monthUSD: month,
                capUSD: cap,
                callCount: calls,
                costTrackingAvailable: costTrackingAvailable,
                accounts: accounts
            )
            return RouteJSON.response(report)
        }
        // Global degraded signal for the client's banner (V2 C1). A missing
        // gateway (heuristic-only install) reports unconfigured, never down.
        //
        // The status is read through the **holder**, so a key the user just
        // saved shows up here without a restart.
        router.get("api/ai-status") { _, _ -> Response in
            let current = gateway?.current
            return RouteJSON.response(AIStatus(
                configured: current?.isConfigured ?? false,
                creditExhausted: current?.creditExhausted ?? false,
                circuitOpen: current?.circuitOpen ?? false
            ))
        }
    }
}
