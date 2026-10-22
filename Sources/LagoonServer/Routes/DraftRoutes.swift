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
    /// How many sealed bodies one search may open.
    ///
    /// The body arm of the search is the expensive one: every candidate
    /// costs an AES-GCM open, and a body is tens of kilobytes. Without a
    /// budget, a query whose word only appears inside a body opened
    /// **every** cached body in the account — 5,000 messages is 100 MB of
    /// decryption on the request path, and it grew with the mailbox.
    ///
    /// The budget counts rows rather than bytes because a row count is the
    /// thing that can be *stated*: the response reports how many rows were
    /// left out, so a capped search never reads as a complete one.
    static let bodyScanLimit = 1000

    /// How many candidate rows one batch opens.
    ///
    /// Batches keep the memory flat: a batch of bodies is a few megabytes in
    /// flight, not the whole mailbox.
    static let bodyScanBatchSize = 200

    /// How many rows the response carries.
    static let resultLimit = 100

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
                return RouteJSON.response(SearchResponse(
                    results: [], query: q, totalCount: 0, truncated: false,
                    bodyScanSkipped: 0, bodyScanLimit: bodyScanLimit
                ))
            }
            let sender = request.uri.queryParameters["sender"].map(String.init)
            let since = parseSince(request.uri.queryParameters["since"].map(String.init))
            do {
                let outcome = try await search(
                    scope: scope,
                    q: q, sender: sender, since: since, db: db
                )
                // The count travels with the rows. A search that silently
                // stopped at its cap is indistinguishable from a search that
                // found everything, and the user has no other way to tell.
                //
                // The skipped count travels with them for the same reason:
                // a body scan that stopped at its budget would otherwise
                // read as "this word is not in my mail".
                return RouteJSON.response(SearchResponse(
                    results: outcome.results,
                    query: q,
                    totalCount: outcome.totalCount,
                    truncated: outcome.totalCount > outcome.results.count,
                    bodyScanSkipped: outcome.bodyScanSkipped,
                    bodyScanLimit: bodyScanLimit
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

    /// One row the search matched, before its header is fetched.
    private struct Match {
        var id: UUID
        var receivedAt: Date
    }

    /// The rows, the number of rows that matched, and what the body scan
    /// could not reach.
    private struct SearchOutcome {
        var results: [MessageHeader]
        var totalCount: Int
        var bodyScanSkipped: Int
    }

    /// The rows and the number of rows that matched.
    ///
    /// ## Two passes, because the arms cost wildly different amounts
    ///
    /// The old predicate ORed seven arms into one statement, two of which
    /// were `lagoon_cipher_contains(...)` — and that function is a complete
    /// AES-GCM open. SQLite evaluates an `OR` chain per row, so a query
    /// whose word only appears inside a body opened **every** cached body in
    /// the account — and the count query, which ran over the same predicate
    /// without the `LIMIT`, opened them all again.
    ///
    /// The arms are split by what they cost:
    ///
    /// * The **cheap** arms — subject, sender, and the AI's own verdict on
    ///   the message — are columns. They stay in SQL, where a comparison
    ///   costs nothing, and a row that matches one of them never has to be
    ///   opened at all.
    /// * The **sealed** arms — the preview and the body — cost an open each.
    ///   They get their own pass, in Swift, under a budget.
    ///
    /// Both passes read the same rows, so the count describes exactly what
    /// was searched. The budget is the only thing that can make the two
    /// disagree, and the response says how much it left out.
    ///
    /// ## The count
    ///
    /// The count is not a second query over the predicate any more: it is
    /// the size of the merged result of the two passes, which is exact by
    /// construction. A count that does not describe the rows it counts is
    /// worse than no count at all: the user is told "3,140 matched" and
    /// shown a different set.
    private static func search(
        scope: SearchScope, q: String, sender: String?, since: Date?, db: LagoonDB
    ) async throws -> SearchOutcome {
        // LIKE specials in the query are data, not wildcards. This used to be
        // a second, hand-maintained copy of the escaping — a twin is exactly
        // what lets a fix land on one side only — so the route calls the
        // shared `MessageStore.likePattern(containing:)` now.
        let pattern = MessageStore.likePattern(containing: q)

        // The cheap arms. Subject, sender, and the AI's own verdict on the
        // message are all columns, and a column comparison costs nothing —
        // so they stay in SQL, and a row that matches one of them never has
        // to be opened at all.
        //
        // What the full-text arm used to be is cheaper and more honest now:
        // the `advice` arm. Lagoon has already paid a model to classify
        // every message it has seen, and that verdict is stored in columns
        // rather than prose. Matching on it means searching "marketing" or
        // "archive" finds mail by what the AI *concluded* about it — which
        // is the question a user asking "show me the marketing" is really
        // asking — with no extra inference, no embedding index, and no
        // per-query token spend.
        //
        // It deliberately does **not** match `a.rationale`: the rationale is
        // the model's own English/Chinese sentence, so a LIKE against it
        // would be accidental translation rather than a real filter. Only
        // the enum-shaped columns participate, and the UI labels them as
        // AI-derived so the user knows why the hit appeared.
        let cheapArms = """
            (m.subject LIKE ? ESCAPE '\\'
             OR m.from_name LIKE ? ESCAPE '\\'
             OR m.from_address LIKE ? ESCAPE '\\'
             OR a.category LIKE ? ESCAPE '\\'
             OR a.action LIKE ? ESCAPE '\\')
            """
        let cheapArguments: [DatabaseValueConvertible?] = [
            pattern, pattern, pattern, pattern, pattern
        ]

        // The filters both passes share. They narrow the mailbox before any
        // arm is evaluated, so a scoped search never even looks at another
        // account's mail. Optional sender/since filters are appended as
        // static fragments (never user text) so binding stays positional.
        var filters = ["m.is_deleted = FALSE"]
        var filterArguments: [DatabaseValueConvertible?] = []
        // The account narrows to one mailbox, or is absent for a
        // cross-account search.
        if let accountId = scope.accountId {
            filters.append("AND m.account_id = ?")
            filterArguments.append(accountId)
        }
        if let sender {
            filters.append("AND m.from_address = ?")
            filterArguments.append(sender)
        }
        if let since {
            filters.append("AND m.received_at >= ?")
            filterArguments.append(since)
        }
        let whereClause = filters.joined(separator: "\n")

        return try db.read { db in
            // Pass A — the cheap arms, in SQL.
            //
            // The advice table joins in for recall only. Nothing here reads
            // the model's own words: it matches on the *structured* fields
            // Lagoon already derived (category, action). `advice` is UNIQUE
            // on (account_id, remote_id), so the join cannot multiply rows.
            let cheapSQL = """
                SELECT m.id, m.received_at
                FROM message_headers m
                LEFT JOIN advice a
                  ON a.account_id = m.account_id AND a.remote_id = m.remote_id
                WHERE \(whereClause)
                  AND \(cheapArms)
                """
            let cheapHits = try Row.fetchAll(
                db, sql: cheapSQL,
                arguments: StatementArguments(filterArguments + cheapArguments)
            ).map { Match(id: $0["id"], receivedAt: $0["received_at"]) }

            // Pass B — the sealed arms, in Swift, under a budget.
            //
            // The candidates are the rows the cheap arms did **not** match:
            // a row that already matched is in the result set, and opening
            // its body would only cost time.
            //
            // `COALESCE(..., 0)` matters. A subject, a sender name or an AI
            // verdict can be NULL, and NULL propagates through an OR chain:
            // the chain would be NULL rather than false, `NOT NULL` is not
            // true, and the row would drop out of the scan and never be
            // searched at all.
            let scanSQL = """
                SELECT m.id, m.received_at,
                       NULLIF(m.snippet_cipher, '') AS snippet_cipher,
                       NULLIF(b.body_cipher, '') AS body_cipher
                FROM message_headers m
                LEFT JOIN message_bodies b
                  ON b.account_id = m.account_id AND b.remote_id = m.remote_id
                WHERE \(whereClause)
                  AND COALESCE(\(cheapArms), 0) = 0
                  AND (NULLIF(m.snippet_cipher, '') IS NOT NULL
                       OR NULLIF(b.body_cipher, '') IS NOT NULL)
                ORDER BY m.received_at DESC, m.id DESC
                LIMIT ? OFFSET ?
                """
            var sealedHits: [Match] = []
            var scanned = 0
            var reachedTheEnd = false
            while scanned < bodyScanLimit {
                let batchSize = min(bodyScanBatchSize, bodyScanLimit - scanned)
                var arguments = filterArguments + cheapArguments
                arguments.append(batchSize)
                arguments.append(scanned)
                let rows = try Row.fetchAll(
                    db, sql: scanSQL, arguments: StatementArguments(arguments)
                )
                for row in rows {
                    if try Self.matchesSealedText(row: row, needle: q) {
                        sealedHits.append(
                            Match(id: row["id"], receivedAt: row["received_at"])
                        )
                    }
                }
                scanned += rows.count
                if rows.count < batchSize {
                    // The mailbox ended before the budget did: nothing was
                    // left out.
                    reachedTheEnd = true
                    break
                }
            }

            // How much of the mailbox the budget did not reach.
            //
            // The count is only needed when the budget actually cut the scan
            // short. When the mailbox ended first, nothing was skipped and
            // the answer is zero.
            var bodyScanSkipped = 0
            if !reachedTheEnd {
                let candidateSQL = """
                    SELECT COUNT(*)
                    FROM message_headers m
                    LEFT JOIN message_bodies b
                      ON b.account_id = m.account_id AND b.remote_id = m.remote_id
                    WHERE \(whereClause)
                      AND COALESCE(\(cheapArms), 0) = 0
                      AND (NULLIF(m.snippet_cipher, '') IS NOT NULL
                           OR NULLIF(b.body_cipher, '') IS NOT NULL)
                    """
                let candidates = try Int.fetchOne(
                    db, sql: candidateSQL,
                    arguments: StatementArguments(filterArguments + cheapArguments)
                ) ?? scanned
                bodyScanSkipped = max(0, candidates - scanned)
            }

            // The two passes found disjoint sets — the scan skips the rows
            // the cheap arms already matched — so the merge is a sort.
            var seen = Set<UUID>()
            var ordered: [Match] = []
            for hit in (cheapHits + sealedHits).sorted(by: Self.isNewer) {
                if seen.insert(hit.id).inserted {
                    ordered.append(hit)
                }
            }

            // The rows themselves, in one statement.
            //
            // The placeholder list is built from the number of ids — no user
            // text reaches the SQL, only the count of the `?`s.
            //
            // `m.is_sent` is selected because `decode` can only carry the
            // flag it is given: without it, a sent reply opened from search
            // results reads as received mail end to end — the display lies,
            // and its detail actions resolve the UID in the INBOX scope and
            // fail. `find()` states the same reason (its column-list
            // omission was invisible for the identical reason: the
            // nil-tolerant decode defaults it to false).
            let top = Array(ordered.prefix(resultLimit))
            guard !top.isEmpty else {
                return SearchOutcome(
                    results: [], totalCount: ordered.count,
                    bodyScanSkipped: bodyScanSkipped
                )
            }
            let placeholders = Array(repeating: "?", count: top.count)
                .joined(separator: ", ")
            let headerSQL = """
                SELECT m.id, m.account_id, m.remote_id, m.thread_id,
                       m.from_address,
                       NULLIF(m.from_name, '') as from_name,
                       NULLIF(m.subject, '') as subject,
                       NULLIF(m.snippet_cipher, '') as snippet_cipher,
                       m.received_at, m.is_read, m.is_archived, m.is_deleted, m.is_sent,
                       m.message_id_header, m.in_reply_to, m.references_header
                FROM message_headers m
                WHERE m.id IN (\(placeholders))
                ORDER BY m.received_at DESC, m.id DESC
                """
            let rows = try Row.fetchAll(
                db, sql: headerSQL, arguments: StatementArguments(top.map(\.id))
            )
            let results = try rows.map { try MessageStore.decode($0) }
            return SearchOutcome(
                results: results,
                totalCount: ordered.count,
                bodyScanSkipped: bodyScanSkipped
            )
        }
    }

    /// Whether the sealed text of one row contains the needle.
    ///
    /// The preview is checked first and the body second, the same order the
    /// old OR chain used: a preview that matches ends the row, so the body
    /// is not opened for nothing.
    ///
    /// Each envelope is opened once, and only for a row the scan actually
    /// reached. A preview or a body that will not open is a broken store,
    /// not a row that does not match — the error travels up rather than
    /// being swallowed into a quiet "no results".
    private static func matchesSealedText(row: Row, needle: String) throws -> Bool {
        if let preview = row.optionalText("snippet_cipher"),
           BodyCipher.matches(try BodyCipher.open(preview), needle) {
            return true
        }
        if let body = row.optionalText("body_cipher"),
           BodyCipher.matches(try BodyCipher.open(body), needle) {
            return true
        }
        return false
    }

    /// Newest first, with the id as the tiebreaker so two rows that arrived
    /// in the same millisecond keep a stable order.
    private static func isNewer(_ lhs: Match, _ rhs: Match) -> Bool {
        lhs.receivedAt == rhs.receivedAt
            ? lhs.id.uuidString > rhs.id.uuidString
            : lhs.receivedAt > rhs.receivedAt
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
