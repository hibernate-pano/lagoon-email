import Foundation

/// What Lagoon thinks the user should do about one message.
///
/// Read-only by construction (advisory-only constitution §2 rule 1): every
/// case names something the *user* may choose to do, and no code path turns an
/// `AdvisedAction` into a mailbox write. The verb that performs an action lives
/// in the routes, reachable only from a user gesture.
public enum AdvisedAction: String, Codable, Sendable, CaseIterable {
    /// A human is waiting on the user; a reply is owed.
    case reply
    /// The user sent the last message; nothing to do until the other side
    /// answers.
    case wait
    /// Handled or low-value; safe to file away.
    case archive
    /// Marketing or spam with no residual value; the user may delete it.
    case delete
    /// Recurring sender the user keeps discarding; they may want to unsubscribe.
    /// Always a question, never a decision — unsubscribing is irreversible.
    case unsubscribe
    /// Contains a deadline or a follow-up the user asked to be reminded about.
    case remind
    /// Read-only informational mail; no action owed.
    case nothing

    /// Actions that change the mailbox if the user acts on them. Used by the UI
    /// to decide whether a suggestion needs an explicit confirmation step.
    public var isMutating: Bool {
        switch self {
        case .archive, .delete, .unsubscribe: true
        case .reply, .wait, .remind, .nothing: false
        }
    }

    /// Irreversible even through the undo system: an unsubscribe has already
    /// told the publisher, and a delete leaves the local index. Both still go
    /// through the user, but neither can be offered as "one tap, undoable".
    public var isIrreversible: Bool {
        switch self {
        case .unsubscribe: true
        case .reply, .wait, .archive, .delete, .remind, .nothing: false
        }
    }
}

/// What kind of mail this is, independent of what to do about it. The user
/// asked specifically to be told whether something is marketing or spam, so the
/// category is a first-class part of the advice rather than an implied group.
public enum ContentCategory: String, Codable, Sendable, CaseIterable {
    case personal
    case work
    case marketing
    case spam
    case notification
    case transactional
    case financial
    case logistics
    case newsletter
    case other
}

/// How sure the model is. Deliberately three coarse bands rather than a float:
/// a model's self-reported 0.87 is not meaningfully more honest than "high",
/// and a float invites the UI to sort on a number nobody calibrated.
public enum AdviceConfidence: String, Codable, Sendable, CaseIterable {
    case high
    case medium
    case low

    /// Confidence gates how loudly the UI may speak. A low-confidence deletion
    /// suggestion must not read as a confident one.
    public var rank: Int {
        switch self {
        case .high: 2
        case .medium: 1
        case .low: 0
        }
    }
}

/// One message's advice. `rationale` is the sentence shown under "Why?" — the
/// model writes it in the user's UI language, so it is display text and must
/// never be parsed.
public struct Advice: Codable, Equatable, Sendable {
    public let action: AdvisedAction
    public let category: ContentCategory?
    public let confidence: AdviceConfidence
    /// Why, in the user's language. Optional: the deterministic heuristic
    /// advice has a stable reason code instead of prose, and a model that
    /// omitted the field must not lose the rest of its answer.
    public let rationale: String?
    /// Extracted deadline phrase (e.g. "10 月 8 日前"), verbatim from the mail.
    /// Never a model-invented date — see the gateway prompt.
    public let dueText: String?

    public init(
        action: AdvisedAction,
        category: ContentCategory? = nil,
        confidence: AdviceConfidence = .medium,
        rationale: String? = nil,
        dueText: String? = nil
    ) {
        self.action = action
        self.category = category
        self.confidence = confidence
        self.rationale = rationale
        self.dueText = dueText
    }
}

/// Where an advice row came from. Shown in the UI so the user can tell a paid
/// model judgment from a free deterministic guess — the two deserve different
/// trust, and hiding the difference would make the heuristic look as confident
/// as the model.
public enum AdviceSource: String, Codable, Sendable, CaseIterable {
    /// Deterministic, offline, free (`HeuristicBriefingClassifier`).
    case heuristic
    /// The configured LLM provider.
    case ai
}

/// The user's verdict on a suggestion. `pending` is the default and the only
/// state that keeps a row in the decision queue; the other two are terminal and
/// are what Phase 4 learns from.
///
/// Recording a verdict writes to this table only. It is not a mailbox action,
/// so it needs no undo — dismissing a suggestion changes nothing about the mail.
public enum AdviceDecision: String, Codable, Sendable, CaseIterable {
    case pending
    /// The user acted on it (or agreed with it). The action itself, if any,
    /// went through the ordinary user-triggered route and has its own audit row.
    case accepted
    /// The user rejected or ignored it. Must stop the same suggestion from
    /// being re-surfaced, which is the failure mode that makes advice queues
    /// feel like nagging.
    case dismissed
}

/// One persisted advice row: the advice plus the identity and provenance the
/// queue and the audit view need. This is the wire shape of `GET /api/advice`.
public struct AdviceRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: Int64
    public let accountId: UUID
    public let remoteId: String
    public let advice: Advice
    public let source: AdviceSource
    /// Provider model that produced it, nil for heuristic advice.
    public let model: String?
    public let decision: AdviceDecision
    public let createdAt: Date
    public let decidedAt: Date?

    /// Stable identity across regenerations: advice for the same message is
    /// upserted, so the row id changes but this does not.
    public var identity: String { "\(accountId.uuidString)|\(remoteId)" }

    public init(
        id: Int64,
        accountId: UUID,
        remoteId: String,
        advice: Advice,
        source: AdviceSource,
        model: String? = nil,
        decision: AdviceDecision = .pending,
        createdAt: Date,
        decidedAt: Date? = nil
    ) {
        self.id = id
        self.accountId = accountId
        self.remoteId = remoteId
        self.advice = advice
        self.source = source
        self.model = model
        self.decision = decision
        self.createdAt = createdAt
        self.decidedAt = decidedAt
    }
}

/// `GET /api/advice?accountId=` response.
public struct AdviceListResponse: Codable, Equatable, Sendable {
    public let advice: [AdviceRecord]
    public init(advice: [AdviceRecord]) { self.advice = advice }
}

/// Which advice rows a query returns. A sum type rather than an optional
/// because `nil` would have to mean "everything", and that ambiguity is what
/// made the route need two nested branches.
public enum AdviceDecisionQuery: Equatable, Sendable {
    /// The decision queue — what the client opens.
    case pending
    /// Exactly one state.
    case exactly(AdviceDecision)
    /// Every state, for the audit view.
    case all
}
