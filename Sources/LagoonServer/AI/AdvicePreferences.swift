import Foundation
import Logging
import GRDB
import LagoonKit

/// The server's read-only view of "what this user actually acts on".
///
/// It answers one question — *which suggestions did the user act on, and how
/// often* — by counting the `accepted` verdicts in the `advice` table. That
/// is the learning signal constitution Phase 4 asks for: accepted and
/// rejected suggestions accumulate as **read-only** preferences used to
/// improve later suggestions.
///
/// ## Why it is a separate type
///
/// The classifier lives in `LagoonAI`, which by rule may not depend on the
/// server's storage (constitution §2 rule 1 — the AI module holds no write
/// interface, and by the same token no database handle). So the AI side
/// declares the `AdvicePreferenceProviding` *protocol* and this type, on the
/// server side, implements it. The dependency arrow still points one way:
/// server → AI. The AI module never learns that a database exists.
///
/// ## Why an actor
///
/// It holds a `LagoonDB`, which is not `Sendable` — it wraps either a GRDB
/// `DatabasePool` (safe to share) or a transaction handle (safe only inside
/// its owner's closure). Declaring the reader `@unchecked Sendable` would
/// assert a thread-safety the type does not have; making it an `actor` keeps
/// the handle inside one isolation domain, which is the same shape
/// `UsageBudget` — the other collaborator that hands a store to the AI layer
/// — already uses.
public actor AdvicePreferenceReader: AdvicePreferenceProviding {
    /// How many examples reach the prompt. Five is a handful: enough for the
    /// model to see a pattern ("this user archives newsletters"), small
    /// enough that the prompt does not grow with the user's history — a
    /// prompt that grows is a cost problem, and this codebase already keeps a
    /// classification cache for exactly that reason.
    public static let exampleLimit = 5

    private let db: LagoonDB
    private let logger: Logger

    public init(db: LagoonDB, logger: Logger = Logger(label: "lagoon.advice.preferences")) {
        self.db = db
        self.logger = logger
    }

    public func acceptedAdviceStats(accountId: UUID) async -> [AcceptedAdviceStat] {
        do {
            return try await AdviceStore.acceptedStats(
                accountId: accountId,
                limit: Self.exampleLimit,
                db: db
            )
        } catch {
            // Logged, not swallowed: a preferences read that keeps failing is
            // a real problem, and the log is where an operator would look.
            // But it does not fail the briefing — the prompt simply carries no
            // few-shot examples, which is the state the product shipped in.
            logger.warning("advice.preferencesUnavailable", metadata: [
                "accountId": .string(accountId.uuidString),
                "err": .string("\(error)"),
            ])
            return []
        }
    }
}
