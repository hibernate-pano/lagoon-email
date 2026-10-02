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
        classificationMode: ClassificationMode = .synchronous
    ) {
        router.get("api/briefing") { request, _ -> Response in
            guard let accountId = RouteParams.accountId(from: request) else {
                return RouteJSON.error(.badRequest, "malformed-accountId")
            }
            let requested = Int(request.uri.queryParameters["limit"] ?? "100") ?? 100
            let limit = max(1, min(requested, 500))

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
            let pinned: Set<String>
            let listUnsubscribe: Set<String>
            let replied: Set<String>
            let userOverrides: [String: BriefingGroup]
            do {
                messages = try await MessageStore.recent(forAccount: accountId, limit: limit, db: db)
                pinned = try await MessageStore.pinnedIds(forAccount: accountId, db: db)
                listUnsubscribe = try await MessageStore.listUnsubscribeIds(forAccount: accountId, db: db)
                replied = try await AIActionStore.repliedRemoteIds(accountId: accountId, db: db)
                userOverrides = try await AIActionStore.overridesBySender(
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
                        Task {
                            do {
                                let fresh = try await classifier.classify(
                                    pending,
                                    accountEmail: account.email,
                                    language: language
                                )
                                await cache.store(fresh, for: pending)
                                await persistAdvice(
                                    fresh,
                                    accountId: accountId,
                                    db: db,
                                    logger: logger
                                )
                            } catch {
                                await cache.clearInFlight(pending)
                                logger.warning("briefing background classifier failed", metadata: [
                                    "accountId": .string(accountId.uuidString),
                                    "err": .string("\(error)")
                                ])
                            }
                        }
                    }
                }
                for (remoteId, outcome) in overrides where classified[remoteId] != nil {
                    classified[remoteId] = (outcome.group, .ai)
                }
            }

            // User intent has final authority over both the heuristic and AI,
            // except for a pin, which is itself an explicit user action.
            for message in messages {
                if pinned.contains(message.remoteId) {
                    classified[message.remoteId] = (.pinned, .pinned)
                } else if let override = userOverrides[message.fromAddress] {
                    classified[message.remoteId] = (override, .userOverride)
                }
            }

            let items = messages.map { message -> BriefingItem in
                let result = classified[message.remoteId] ?? (.needsReply, BriefingReason.unclassified)
                return BriefingItem(
                    message: message,
                    group: result.group,
                    reasonCode: result.reason.rawValue
                )
            }
            return RouteJSON.response(BriefingResponse(items: items))
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
}
