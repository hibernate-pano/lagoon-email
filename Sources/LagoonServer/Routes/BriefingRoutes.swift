import Foundation
import Logging
import Hummingbird
import GRDB
import LagoonKit

/// GET /api/briefing — the Briefing Feed (spec §7.1).
///
/// Grouping always starts from the deterministic heuristic classifier. When an
/// AI classifier is supplied its answers override the heuristic for the ids it
/// returns; if it throws, the heuristics stand and the briefing still returns
/// 200 (a classifier outage must never 500 the whole feed).
public enum BriefingRoutes {
    /// The briefing's window: mail received in the last 30 days.
    ///
    /// A time window rather than a row count, because "recent" is what the
    /// user means and a fixed count answers a different question — it drops
    /// mail on a busy week and pads the feed with stale mail on a quiet one.
    public static let windowDays = 30
    /// Hard cap on rows in one response.
    ///
    /// The window is the product rule; this is a safety valve for a mailbox
    /// that receives thousands of messages a month, where one response would
    /// mean a ~1 MB payload, thousands of `List` rows, and a proportional LLM
    /// classification bill in a single pass. When it bites, the response says
    /// how many rows were left out — see `omittedCount`.
    public static let maxItems = 500
    /// How many *old* unresolved messages the briefing may carry.
    ///
    /// The backlog — mail older than the window that is still waiting — is
    /// capped separately, and lower, than the window's own cap. The window
    /// holds mail the user has plausibly seen; the backlog holds mail they
    /// have provably not (it is unread), so a backlog of thousands means a
    /// mailbox the user has been away from, and listing all of it would bury
    /// the recent mail the user came to read.
    ///
    /// The count is reported alongside, so the cap never reads as "that is
    /// all of them".
    public static let maxBacklogItems = 50
    /// How long a dismissed suggestion is kept before it is pruned.
    ///
    /// The same 30 days the undo log keeps, and for the same kind of reason:
    /// advice is derived data — the classifier can produce it again for any
    /// message inside the briefing window — so a suggestion the user has
    /// already dismissed is worth keeping only as long as the mail it is
    /// about is still in the feed.
    public static let dismissedAdviceRetentionDays = 30

    public enum ClassificationMode: Sendable {
        case synchronous
        case background
    }

    public static func register(
        on router: Router<BasicRequestContext>,
        db: LagoonDB,
        logger: Logger,
        classifier: (any BriefingClassifying)? = nil,
        cache: BriefingClassificationCache = BriefingClassificationCache(),
        classificationMode: ClassificationMode = .synchronous,
        queue: BriefingClassificationQueue? = nil
    ) {
        // One queue per server. The background mode used to fire an
        // unstructured `Task` per request, which meant nothing tracked it,
        // nothing bounded it and nothing could cancel it.
        let queue = queue ?? BriefingClassificationQueue(logger: logger)
        router.get("api/briefing") { request, _ -> Response in
            guard let accountId = RouteParams.accountId(from: request) else {
                return RouteJSON.error(.badRequest, "malformed-accountId")
            }
            let requested = Int(request.uri.queryParameters["limit"] ?? "\(Self.maxItems)")
                ?? Self.maxItems
            let limit = max(1, min(requested, Self.maxItems))
            let windowStart = Date().addingTimeInterval(
                -Double(Self.windowDays) * 24 * 60 * 60
            )

            let account: Account
            do {
                guard let found = try await AccountStore.find(byId: accountId, db: db) else {
                    return RouteJSON.error(.notFound, "unknown-account")
                }
                account = found
            } catch {
                logger.error("account lookup failed", metadata: [
                    "accountId": .string(accountId.uuidString),
                    "err": .string("\(error)")
                ])
                return RouteJSON.error(.internalServerError, "internal-error")
            }

            let messages: [MessageHeader]
            let omitted: Int
            let pinned: Set<String>
            let listUnsubscribe: Set<String>
            let replied: Set<String>
            /// The user-override maps, read through the shared resolver.
            ///
            /// The resolver owns the precedence — the narrow rule before the
            /// broad one — so the feed and the 「改分组」 route cannot drift
            /// apart about which group a mail is in. The route used to keep
            /// its own copy of the precedence, and its copy was wrong.
            let resolver: BriefingGroupResolver
            /// Mail that is still waiting, but too old for the window.
            ///
            /// The window is 30 days, and mail older than that leaves the feed
            /// entirely. That is right for the bulk of a mailbox, and wrong
            /// for the mail the product's headline promise is about: a mail
            /// does not stop needing a reply because it got old, so a 35-day-
            /// old unanswered mail would never appear in the queue — and a
            /// queue that can never be cleared is not a queue.
            ///
            /// So the window bounds the noise and this reaches past it for
            /// what is still open. These rows are classified by the same
            /// heuristics as everything else, and they land in "needs reply"
            /// (or "awaiting reply") — which is exactly where they belong.
            let backlog: [MessageHeader]
            /// How many such messages exist, beyond the ones returned.
            ///
            /// A count and not just the rows, for the same reason the search
            /// has one: "here are 50" must not read as "here are all of
            /// them".
            let backlogTotal: Int
            do {
                // The rows and the numbers that describe them, from one
                // snapshot — see `snapshot`.
                let snapshot = try Self.snapshot(
                    accountId: accountId,
                    windowStart: windowStart,
                    limit: limit,
                    db: db
                )
                messages = snapshot.messages
                omitted = snapshot.omitted
                backlog = snapshot.backlog
                backlogTotal = snapshot.backlogTotal
                pinned = try await MessageStore.pinnedIds(forAccount: accountId, db: db)
                listUnsubscribe = try await MessageStore.listUnsubscribeIds(forAccount: accountId, db: db)
                replied = try await AIActionStore.repliedRemoteIds(accountId: accountId, db: db)
                // The resolver loads the pin set too, so the feed reads the
                // pins once and the resolver's copy is the same one.
                resolver = try await BriefingGroupResolver.load(
                    accountId: accountId,
                    db: db
                )
            } catch {
                logger.error("briefing query failed", metadata: [
                    "accountId": .string(accountId.uuidString),
                    "err": .string("\(error)")
                ])
                return RouteJSON.error(.internalServerError, "internal-error")
            }

            // The grouping reasons are shown to the user, so the classifier
            // has to write them in the language they are reading. The
            // sibling routes (/summary, /draft) already read this header;
            // passing nil here made the briefing the one place where the
            // model's language and the UI's could disagree.
            let language = RouteParams.preferredLanguage(
                fromHeader: request.headers[.acceptLanguage]
            )

            let heuristics = HeuristicBriefingClassifier(
                signals: .init(
                    pinnedRemoteIds: pinned,
                    listUnsubscribeRemoteIds: listUnsubscribe,
                    repliedRemoteIds: replied
                )
            )
            var classified = heuristics.classifyWithReasons(
                messages,
                accountEmail: account.email
            )

            if let classifier {
                // Only ask about messages never classified (or whose read state
                // changed): the client refreshes every 30 s and a full
                // 50-message classification costs ~8k prompt tokens.
                let (known, pending) = await cache.cached(for: messages)
                var overrides = known
                if !pending.isEmpty {
                    switch classificationMode {
                    case .synchronous:
                        do {
                            let fresh = try await classifier.classify(
                                pending,
                                accountEmail: account.email,
                                language: language
                            )
                            await cache.store(fresh, for: pending)
                            await persistAdvice(fresh, accountId: accountId, db: db, logger: logger)
                            for (remoteId, outcome) in fresh { overrides[remoteId] = outcome }
                        } catch {
                            logger.warning("briefing classifier failed; using heuristics", metadata: [
                                "accountId": .string(accountId.uuidString),
                                "err": .string("\(error)")
                            ])
                        }
                    case .background:
                        await cache.markInFlight(pending)
                        // The work goes to the queue instead of an
                        // unstructured task: it is tracked, it is bounded, and
                        // it can be cancelled. See `BriefingClassificationQueue`
                        // for what each of those buys.
                        let job = BriefingClassificationQueue.Job(
                            accountId: accountId,
                            messages: pending,
                            run: { messages in
                                let fresh = try await classifier.classify(
                                    messages,
                                    accountEmail: account.email,
                                    language: language
                                )
                                await cache.store(fresh, for: messages)
                                await persistAdvice(
                                    fresh,
                                    accountId: accountId,
                                    db: db,
                                    logger: logger
                                )
                            },
                            release: { messages in
                                // The job did not finish. Its hold on the
                                // messages goes back, so the next refresh
                                // asks about them again instead of leaving
                                // them "in flight" forever.
                                await cache.clearInFlight(messages)
                            }
                        )
                        // The job outlives the request — that is what
                        // "background" means — but not past the point where
                        // the client gave up on it. A request that was
                        // cancelled takes its job with it: a classification
                        // nobody is waiting for any more is a classification
                        // nobody asked for.
                        let jobId = job.id
                        await withTaskCancellationHandler {
                            await queue.submit(job)
                        } onCancel: {
                            Task { await queue.cancel(jobId: jobId) }
                        }
                    }
                }
                for (remoteId, outcome) in overrides where classified[remoteId] != nil {
                    classified[remoteId] = (outcome.group, .ai)
                }
            }

            // User intent has final authority over both the heuristic and AI,
            // except for a pin, which is itself an explicit user action.
            //
            // The precedence lives in `BriefingGroupResolver`, so the feed
            // and the 「改分组」 route apply the same rules to the same
            // mail: a pin wins, then the narrow rule, then the broad one.
            // The narrow scope is checked first — a message-scoped override
            // ("只改这一封") is the more specific statement, so it wins over
            // a sender-level rule for that one mail. The reverse order
            // would make the narrow option unreachable for any sender who
            // already has a broad rule — the choice would be a lie.
            for message in messages {
                let resolved = resolver.resolve(
                    for: message,
                    fallback: classified[message.remoteId]
                        ?? (.needsReply, BriefingReason.unclassified)
                )
                classified[message.remoteId] = (resolved.group, resolved.reason)
            }

            // The backlog is classified by the same heuristics as the window,
            // and merged into the same item list — so an old mail that still
            // needs a reply shows up **in the group where it belongs**, not
            // in a separate section the user has to think about.
            //
            // They are not sent to the AI classifier. The classifier's whole
            // value here is judging mail by content, and the backlog is
            // unread mail the user has not looked at; paying for a model to
            // file it — every 30 seconds, for every refresh — would be the
            // most expensive thing in the app for the least user-visible
            // gain. The heuristics are deterministic, free, and correct
            // enough for "unread mail that is not obviously noise".
            var classifiedBacklog = heuristics.classifyWithReasons(
                backlog,
                accountEmail: account.email
            )
            for message in backlog {
                // The same resolver, so a backlog mail obeys the same
                // precedence as a mail inside the window.
                let resolved = resolver.resolve(
                    for: message,
                    fallback: classifiedBacklog[message.remoteId]
                        ?? (.needsReply, BriefingReason.unclassified)
                )
                classifiedBacklog[message.remoteId] = (resolved.group, resolved.reason)
            }

            let items = (messages + backlog).map { message -> BriefingItem in
                let result = classified[message.remoteId]
                    ?? classifiedBacklog[message.remoteId]
                    ?? (.needsReply, BriefingReason.unclassified)
                return BriefingItem(
                    message: message,
                    group: result.group,
                    reasonCode: result.reason.rawValue
                )
            }
            // The advice table is the one table in the store that is safe to
            // prune: a suggestion is derived data, and the classifier can
            // produce it again for any message still inside the window.
            //
            // `AdviceStore.pruneDismissed` existed, and only the test ever
            // called it — so a suggestion the user had dismissed stayed in
            // the table forever, and the table grew with every mail the
            // account received. The briefing is where the advice is
            // produced, so it is where the pruning belongs.
            do {
                let pruned = try await AdviceStore.pruneDismissed(
                    accountId: accountId,
                    before: Date().addingTimeInterval(
                        -Double(Self.dismissedAdviceRetentionDays) * 24 * 60 * 60
                    ),
                    db: db
                )
                if pruned > 0 {
                    logger.info("briefing.prunedDismissedAdvice", metadata: [
                        "accountId": .string(accountId.uuidString),
                        "pruned": .string("\(pruned)"),
                    ])
                }
            } catch {
                // Housekeeping must never cost the user their feed.
                logger.warning("briefing.pruneFailed", metadata: [
                    "accountId": .string(accountId.uuidString),
                    "err": .string("\(error)")
                ])
            }
            // `nil` rather than 0 on the common path: the field's presence
            // means "the window overflowed", and a client that only checks
            // for a non-nil value must not show an "0 more" line.
            return RouteJSON.response(
                BriefingResponse(
                    items: items,
                    omittedCount: omitted > 0 ? omitted : nil,
                    backlogCount: backlogTotal > 0 ? backlogTotal : nil
                )
            )
        }
    }

    /// Writes the advice half of a classifier answer.
    ///
    /// Separate from the grouping above on purpose, and never allowed to throw:
    /// a suggestion is a derived, regenerable nicety, while the feed itself is
    /// the product. A storage failure here must cost the user a queue row, not
    /// their inbox — so failures are logged and swallowed here, and the next
    /// classifier pass (the cache TTL is 6 h) writes them again.
    ///
    /// Advice with no `action` is not stored: the heuristic returns nil for the
    /// reasons it cannot judge, and an advice row whose action is "unknown"
    /// would be a suggestion the UI cannot act on or explain.
    private static func persistAdvice(
        _ outcomes: [String: ClassificationOutcome],
        accountId: UUID,
        db: LagoonDB,
        logger: Logger
    ) async {
        guard !outcomes.isEmpty else { return }
        var written = 0
        var failed = 0
        for (remoteId, outcome) in outcomes {
            guard let advice = outcome.advice else { continue }
            do {
                // The AI gateway stamps the model on its rows; the heuristic
                // path leaves it nil. A failure for one message (its header was
                // reconciled away between classification and this write) must
                // not abandon the other eleven.
                if try await AdviceStore.upsert(
                    accountId: accountId,
                    remoteId: remoteId,
                    advice: advice,
                    source: .ai,
                    model: outcome.model,
                    db: db
                ) != nil {
                    written += 1
                }
            } catch {
                failed += 1
            }
        }
        if failed > 0 {
            logger.warning("advice.persistPartial", metadata: [
                "accountId": .string(accountId.uuidString),
                "written": .string("\(written)"),
                "failed": .string("\(failed)"),
            ])
        }
    }

    /// The window's rows, the backlog's rows, and the counts that describe
    /// them — read from **one** snapshot.
    ///
    /// Four queries, one transaction. A row list and the number that
    /// describes it have to come from the same snapshot: two separate reads
    /// can straddle a write, and the response would then say "另有 N 封未纳入
    /// 简报" about a feed that had nothing left out — the mail that landed in
    /// between was never left out, it simply arrived after the list was
    /// taken. The other direction is worse: a mail that left the window in
    /// between made the count smaller than the list, so a window the cap had
    /// really truncated reported no truncation at all. `AIActionStore.page` and
    /// the search route read their rows and their count this way for the same
    /// reason.
    ///
    /// The queries live here rather than in `MessageStore` because the
    /// store's `recent` and `count` are two asynchronous reads: they cannot
    /// share a `db.read` closure, and that gap *is* the bug. The predicates
    /// still come from the store (`MessageStore.filterSQL`), so the axes are
    /// authored in one place and the count below cannot describe a different
    /// set of rows than the list above shows.
    private static func snapshot(
        accountId: UUID,
        windowStart: Date,
        limit: Int,
        db: LagoonDB
    ) throws -> BriefingSnapshot {
        // The window: the inbox, and mail received since the window opened.
        let (windowClause, windowArguments) = MessageStore.filterSQL(
            accountId: accountId,
            sender: nil,
            archived: false,
            deleted: false,
            sent: false,
            stackMatch: nil,
            receivedAfter: windowStart,
            pinned: false,
            unread: false
        )
        // The backlog: the same inbox axes, unread, and older than the
        // window. `filterSQL` has no upper time bound, so the cutoff is the
        // one clause added here — the axes stay authored in one place.
        let (backlogAxes, backlogBaseArguments) = MessageStore.filterSQL(
            accountId: accountId,
            sender: nil,
            archived: false,
            deleted: false,
            sent: false,
            stackMatch: nil,
            receivedAfter: nil,
            pinned: false,
            unread: true
        )
        let backlogClause = [
            backlogAxes,
            "AND h.received_at < ?",
        ].joined(separator: "\n")

        var windowRowsArguments = windowArguments
        windowRowsArguments.append(limit)
        var backlogArguments = backlogBaseArguments
        // The cutoff the clause above binds.
        backlogArguments.append(windowStart)
        var backlogRowsArguments = backlogArguments
        backlogRowsArguments.append(maxBacklogItems)

        let windowRowsSQL = [
            Self.messageRowsSQL,
            windowClause,
            "ORDER BY h.received_at DESC",
            "LIMIT ?",
        ].joined(separator: "\n")
        let windowCountSQL = [
            "SELECT COUNT(*) FROM message_headers h",
            windowClause,
        ].joined(separator: "\n")
        let backlogRowsSQL = [
            Self.messageRowsSQL,
            backlogClause,
            "ORDER BY h.received_at ASC",
            "LIMIT ?",
        ].joined(separator: "\n")
        let backlogCountSQL = [
            "SELECT COUNT(*) FROM message_headers h",
            backlogClause,
        ].joined(separator: "\n")

        return try db.read { raw in
            let messages = try Row.fetchAll(
                raw,
                sql: windowRowsSQL,
                arguments: StatementArguments(windowRowsArguments)
            ).map { try MessageStore.decode($0) }
            // The count runs over the same predicate without the LIMIT. The
            // `message_pins` join cannot multiply rows — that table is keyed
            // by (account_id, remote_id) — so it counts the rows the list
            // above shows.
            let windowTotal = try Int.fetchOne(
                raw,
                sql: windowCountSQL,
                arguments: StatementArguments(windowArguments)
            ) ?? messages.count
            let backlog = try Row.fetchAll(
                raw,
                sql: backlogRowsSQL,
                arguments: StatementArguments(backlogRowsArguments)
            ).map { try MessageStore.decode($0) }
            let backlogTotal = try Int.fetchOne(
                raw,
                sql: backlogCountSQL,
                arguments: StatementArguments(backlogArguments)
            ) ?? backlog.count
            return BriefingSnapshot(
                messages: messages,
                windowTotal: windowTotal,
                backlog: backlog,
                backlogTotal: backlogTotal
            )
        }
    }

    /// The columns the briefing's rows are made of.
    ///
    /// Literal, like every other query in the codebase: the CI guardrail
    /// forbids interpolation inside SQL literals, even for constants.
    private static let messageRowsSQL = """
        SELECT h.id, h.account_id, h.remote_id, h.thread_id, h.from_address,
               NULLIF(h.from_name, '') AS from_name,
               NULLIF(h.subject, '') AS subject,
               NULLIF(h.snippet_cipher, '') AS snippet_cipher,
               h.received_at, h.is_read, h.is_archived, h.is_deleted, h.is_sent,
               h.message_id_header, h.in_reply_to, h.references_header,
               (message_pins.account_id IS NOT NULL) AS is_pinned
        FROM message_headers h
        LEFT JOIN message_pins
               ON message_pins.account_id = h.account_id
              AND message_pins.remote_id = h.remote_id
        """
}

/// The briefing's rows and the numbers that describe them, from one snapshot.
private struct BriefingSnapshot {
    /// The window's rows, capped at the requested limit.
    let messages: [MessageHeader]
    /// How many rows the window holds in total.
    let windowTotal: Int
    /// The backlog's rows: old mail that is still waiting.
    let backlog: [MessageHeader]
    /// How many rows the backlog holds in total.
    let backlogTotal: Int

    /// How many of the window's rows the cap left out.
    ///
    /// Zero when the window fit: the field's presence means "the window
    /// overflowed", and a client that only checks for a non-nil value must
    /// not show an "0 more" line.
    var omitted: Int { max(0, windowTotal - messages.count) }
}

/// A managed queue for the briefing's background classification.
///
/// ## Why a queue and not a `Task { }`
///
/// The background mode used to fire an unstructured task per request, and
/// three things were wrong with it. All three cost money:
///
/// 1. **Nobody tracked it.** The task was invisible: the server could not
///    say what was running, and could not stop it.
/// 2. **Nobody bounded it.** Every refresh that found unclassified mail
///    started *another* classification, so the calls piled up on the
///    gateway. Splitting one batch into several calls is not free either —
///    every call pays the system prompt again, so three small calls cost
///    more than one big one. The queue merges a submission into the job
///    already waiting for that account, so the model is asked once about
///    all of it.
/// 3. **Nobody cancelled it.** An unstructured task does not inherit the
///    request's cancellation, and a job that died without finishing used to
///    leave its messages marked "in flight" forever — after which the
///    briefing silently stopped asking about them, and the feed quietly
///    fell back to the heuristics for good.
///
/// The queue fixes all three: one job per account at a time, a bounded
/// number of jobs overall, and every job cancellable — with the messages
/// released when a job does not finish, so the next refresh asks again.
///
/// It lives next to the route that starts it rather than in `AI/`, because
/// the route owns the contract it has to honour (the in-flight marks, the
/// advice write, the account's language).
public actor BriefingClassificationQueue {
    /// One unit of work.
    public struct Job: Sendable {
        /// The job's identity, so a caller can cancel *this* job and not
        /// whatever else the account has in flight.
        public let id: UUID
        /// The account the work belongs to. Two jobs for one account never
        /// run at the same time.
        public let accountId: UUID
        /// The messages the job is responsible for.
        public let messages: [MessageHeader]
        /// The work. The queue hands it the messages it ended up with, which
        /// may be more than were submitted: a second submission for the same
        /// account is merged into the job already waiting.
        public let run: @Sendable ([MessageHeader]) async throws -> Void
        /// Releases the job's hold on the messages when the job did not
        /// finish — the in-flight marks go back, so the next refresh asks
        /// again instead of leaving those messages in limbo.
        public let release: @Sendable ([MessageHeader]) async -> Void

        public init(
            id: UUID = UUID(),
            accountId: UUID,
            messages: [MessageHeader],
            run: @escaping @Sendable ([MessageHeader]) async throws -> Void,
            release: @escaping @Sendable ([MessageHeader]) async -> Void
        ) {
            self.id = id
            self.accountId = accountId
            self.messages = messages
            self.run = run
            self.release = release
        }

        /// Folds another submission for the same account into this job.
        ///
        /// The union of the message sets, and the *newer* runner and id: the
        /// two submissions describe the same account and the same classifier,
        /// so the only thing that can differ is the request's language, and
        /// the latest one is the one the user is reading now. The id goes
        /// with it, because the merged job is the newer request's job — the
        /// older request's cancellation finds nothing to stop, which is the
        /// right answer: the work now also serves a request that is still
        /// waiting for it.
        func merged(with other: Job) -> Job {
            var seen = Set(messages.map(\.remoteId))
            var combined = messages
            for message in other.messages where seen.insert(message.remoteId).inserted {
                combined.append(message)
            }
            return Job(
                id: other.id,
                accountId: accountId,
                messages: combined,
                run: other.run,
                release: other.release
            )
        }
    }

    /// The most classifications that may run at the same time.
    ///
    /// One. The AI budget is the scarce resource, and a classification that
    /// waits a few seconds is not lost — the feed falls back to the
    /// heuristics meanwhile, and the cache keeps the answer for six hours.
    private let maxConcurrent: Int
    private let logger: Logger

    /// The job waiting for each account, and the order they arrived in.
    private var waiting: [UUID: Job] = [:]
    private var waitingOrder: [UUID] = []
    /// The job running for each account.
    private var running: [UUID: Job] = [:]
    /// The task of each running job, keyed by the job's own id.
    private var tasks: [UUID: Task<Void, Never>] = [:]

    public init(maxConcurrent: Int = 1, logger: Logger = Logger(label: "briefing.classification")) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.logger = logger
    }

    /// Submits a job. Returns as soon as it is queued — the route answers the
    /// client with the heuristic feed and the AI catches up.
    public func submit(_ job: Job) {
        if let pending = waiting[job.accountId] {
            waiting[job.accountId] = pending.merged(with: job)
        } else {
            waiting[job.accountId] = job
            waitingOrder.append(job.accountId)
        }
        drain()
    }

    /// Cancels one job.
    ///
    /// A job that never started is dropped and its messages handed back; a
    /// job that is running has its task cancelled, and it releases its own
    /// messages when it unwinds. Either way the messages go back: a job that
    /// was cancelled without that would keep them marked "in flight", and the
    /// briefing would never ask about them again.
    public func cancel(jobId: UUID) async {
        if let accountId = waiting.first(where: { $0.value.id == jobId })?.key {
            let job = waiting.removeValue(forKey: accountId)
            waitingOrder.removeAll { $0 == accountId }
            if let job { await job.release(job.messages) }
            return
        }
        tasks[jobId]?.cancel()
    }

    /// Cancels everything — the server is going down, and a classification
    /// that outlives it would spend an account's budget on answers nobody
    /// will read.
    public func cancelAll() async {
        for accountId in waitingOrder {
            guard let job = waiting.removeValue(forKey: accountId) else { continue }
            await job.release(job.messages)
        }
        waitingOrder.removeAll()
        for task in tasks.values { task.cancel() }
    }

    /// How much work is in flight. For diagnostics and for tests.
    public func load() -> (running: Int, waiting: Int) {
        (running.count, waiting.count)
    }

    /// Starts as many waiting jobs as the concurrency limit allows.
    ///
    /// An account whose job is already running is skipped rather than
    /// waited for: two classifications for one mailbox at the same time is
    /// exactly the pile-up this queue exists to prevent.
    private func drain() {
        while running.count < maxConcurrent {
            guard let index = waitingOrder.firstIndex(where: { running[$0] == nil }) else { break }
            let accountId = waitingOrder.remove(at: index)
            guard let job = waiting.removeValue(forKey: accountId) else { continue }
            start(job)
        }
    }

    private func start(_ job: Job) {
        running[job.accountId] = job
        tasks[job.id] = Task { [self] in
            await execute(job)
        }
    }

    private func execute(_ job: Job) async {
        do {
            try await job.run(job.messages)
        } catch {
            // The job did not finish. Its messages go back for the next
            // refresh: a message stuck "in flight" is a message the
            // briefing silently stops asking about.
            await job.release(job.messages)
            logger.warning("briefing background classification failed", metadata: [
                "accountId": .string(job.accountId.uuidString),
                "err": .string("\(error)")
            ])
        }
        finish(job)
    }

    private func finish(_ job: Job) {
        running.removeValue(forKey: job.accountId)
        tasks.removeValue(forKey: job.id)
        drain()
    }
}
