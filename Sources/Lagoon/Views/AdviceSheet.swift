import SwiftUI
import LagoonKit

/// The suggestion queue — where Lagoon finally becomes visible as an advisor.
///
/// Three deliberate constraints (constitution §3):
///
/// 1. **No automatic mailbox writes here.** This sheet shows what the AI
///    suggests and offers the same verbs the inline strip offers: open the
///    message, set a reminder, dismiss the suggestion — and, for a suggestion
///    that is a mailbox action, 「照做」. That last one is the *user's* own
///    gesture, through the same route the Briefing row uses, so this panel
///    cannot act on the user's behalf; it only offers the act.
/// 2. **Adjectives, not verbs in the past.** Every label says "suggest", never
///    "archived". The user must be able to glance at this list and know nothing
///    has happened yet.
/// 3. **Confidence is visible and coarse.** A "delete this" line reads very
///    differently at "判断明确" than at "不太确定", and the second one is
///    exactly where a user is owed the doubt.
struct AdviceSheet: View {
    @EnvironmentObject private var accounts: AccountStore
    /// The single owner of undo state, injected by `RootView`. The sheet is
    /// presented from `RootView.sheetStack`, which carries this environment.
    @EnvironmentObject private var undo: UndoController
    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss

    @State private var records: [AdviceRecord] = []
    @State private var isLoading = true
    @State private var errorBanner: ErrorBanner?
    @State private var busyId: Int64?
    /// No account is connected, so there is nothing to advise on. Kept
    /// separate from "the queue is empty" — the two have different causes and
    /// the user can only act on one of them.
    @State private var isDisconnected = false
    /// The suggestion the user asked to be reminded about. The reminder sheet
    /// is presented over this one, so the queue stays where it was.
    @State private var reminderTarget: AdviceRecord?
    /// The suggestion waiting for the user to confirm an irreversible action.
    /// An unsubscribe tells the publisher, and that cannot be taken back.
    @State private var pendingIrreversibleAccept: AdviceRecord?

    private let api = APIClient.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            advisoryNotice
            Divider()
            content
        }
        // The error banner needs a home that does not depend on the list
        // being empty. It used to render only inside the `records.isEmpty`
        // branch, which meant the "忽略建议失败" error — set in `dismiss_` —
        // never appeared while the queue had rows: the user pressed 忽略,
        // nothing happened, and no explanation was ever shown. This view was
        // the only one in the app that set an `errorBanner` without a
        // `.noticeBanner` modifier to render it.
        .noticeBanner($errorBanner)
        .frame(
            width: LagoonSheetSize.standard.width,
            height: LagoonSheetSize.standard.height
        )
        .task { await load() }
        // 「设提醒」 — the same sheet the Briefing row opens, so the two
        // surfaces cannot disagree about what a reminder needs.
        .sheet(item: $reminderTarget) { record in
            if let accountId = accounts.accountId {
                ReminderSheet(
                    accountId: accountId,
                    remoteId: record.remoteId,
                    // The queue does not carry the mail's subject, and the
                    // deadline phrase is already the sheet's own hint — so
                    // no title is claimed here. The Briefing row passes the
                    // deadline phrase as the title, which reads as "remind
                    // me at 10月8日前" rather than as the mail it is about.
                    subject: nil,
                    dueText: record.advice.dueText
                ) { reminder in
                    // The confirmation names the time the user actually
                    // chose, not the moment the sheet closed.
                    errorBanner = ErrorBanner(
                        severity: .success,
                        title: l10n.reminderTitle,
                        detail: l10n.reminderSetConfirmation(reminder.dueAt)
                    )
                }
            }
        }
        // The irreversible-action confirmation. A 「照做」 on an unsubscribe
        // suggestion lands here instead of firing, because the request cannot
        // be taken back once the publisher has it.
        .confirmationDialog(
            l10n.adviceAcceptConfirmTitle,
            isPresented: Binding(
                get: { pendingIrreversibleAccept != nil },
                set: { if !$0 { pendingIrreversibleAccept = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(l10n.adviceAcceptConfirmAction, role: .destructive) {
                guard let record = pendingIrreversibleAccept else { return }
                pendingIrreversibleAccept = nil
                Task { await performAcceptedAdvice(record) }
            }
            Button(l10n.adviceAcceptConfirmCancel, role: .cancel) {
                pendingIrreversibleAccept = nil
            }
        } message: {
            Text(l10n.adviceAcceptConfirmBody)
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack {
            Label(l10n.adviceTitle, systemImage: "sparkles")
                .font(.headline)
            Spacer()
            if !records.isEmpty {
                Text(l10n.adviceCount(records.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(l10n.refresh) { Task { await load() } }
                .disabled(isLoading)
            if isLoading && !records.isEmpty {
                ProgressView().controlSize(.small)
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .padding(LagoonMetrics.spaceXS)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(l10n.dismiss)
        }
        .padding(LagoonMetrics.spaceLG)
    }

    /// The product promise, stated once, above the list. It is not
    /// dismissible and not skippable: it is the sentence that makes every row
    /// below it legible.
    private var advisoryNotice: some View {
        HStack(alignment: .top, spacing: LagoonMetrics.spaceSM) {
            Image(systemName: "hand.raised")
                .foregroundStyle(.secondary)
            Text(l10n.adviceAdvisoryOnlyNotice)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, LagoonMetrics.spaceLG)
        .padding(.vertical, LagoonMetrics.spaceMD)
        .background(.quaternary.opacity(0.35))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading, records.isEmpty {
            ProgressView().padding(LagoonMetrics.spaceXXL)
        } else if isDisconnected {
            ContentUnavailableView(
                l10n.notConnected,
                systemImage: "envelope.badge",
                description: Text(l10n.notConnectedHint)
            )
        } else if records.isEmpty {
            ContentUnavailableView(
                l10n.emptyAdvice,
                systemImage: "sparkles",
                description: Text(l10n.emptyAdviceHint)
            )
        } else {
            List {
                ForEach(records) { record in
                    row(record)
                }
            }
            .listStyle(.inset)
        }
    }

    private func row(_ record: AdviceRecord) -> some View {
        VStack(alignment: .leading, spacing: LagoonMetrics.spaceSM) {
            HStack(alignment: .firstTextBaseline, spacing: LagoonMetrics.spaceSM) {
                // "Suggest archiving" / "Suggest deleting" — the verb is the
                // advice, never a claim that it happened.
                Text(l10n.adviceAction(record.advice.action))
                    .font(.callout.weight(.medium))
                Spacer(minLength: 8)
                if record.advice.confidence == .low {
                    // The one row that gets a visible hedge. A low-confidence
                    // destructive suggestion must not read like a firm one.
                    Text(l10n.adviceConfidence(.low))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let category = record.advice.category {
                Label(l10n.adviceCategory(category), systemImage: icon(for: category))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }

            if let rationale = record.advice.rationale {
                Text(rationale)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let due = record.advice.dueText {
                Label(due, systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: LagoonMetrics.spaceMD) {
                // Provenance: a paid model judgment and a free offline rule do
                // not deserve the same trust, and hiding that would make the
                // heuristic look as confident as the model.
                Text(l10n.adviceSource(record.source, model: record.model))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(record.decision == .dismissed ? l10n.adviceDismissed : l10n.adviceOpenMessage) {
                    NotificationCenter.default.post(
                        name: .lagoonRevealMessage,
                        object: nil,
                        userInfo: ["remoteId": record.remoteId]
                    )
                    dismiss()
                }
                .buttonStyle(.link)
                .font(.caption)
                // 「设提醒」 — only for a `.remind` suggestion, and only
                // while it is still pending. A suggestion with a deadline
                // and no way to act on it is the empty promise this whole
                // feature exists to remove, and the queue is where a user
                // looks for the suggestions they have not dealt with yet.
                if record.decision == .pending, record.advice.action == .remind {
                    Button(l10n.reminderSet) { setReminder(record) }
                        .buttonStyle(.link)
                        .font(.caption)
                        .disabled(busyId != nil)
                }
                // 「照做」 — the only verb here that touches the mailbox, and
                // only ever through the user's own gesture. The row is only
                // offered for a *mutating* suggestion: archive, delete,
                // unsubscribe. A non-mutating suggestion has no mailbox
                // write to perform, and offering a button for it would be a
                // button that does nothing.
                if record.decision == .pending, record.advice.action.isMutating {
                    Button(l10n.adviceAccept) { accept(record) }
                        .buttonStyle(.link)
                        .font(.caption)
                        .help(l10n.adviceAcceptHelp)
                        .disabled(busyId != nil)
                }
                if record.decision == .pending {
                    Button(l10n.adviceDismiss) {
                        Task { await dismiss_(record) }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(busyId != nil)
                }
                if busyId == record.id {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .padding(.vertical, LagoonMetrics.spaceXS)
        .opacity(record.decision == .dismissed ? 0.55 : 1)
        // Dismissing removes the row from the queue; the server keeps the
        // verdict so re-classification cannot push it back.
        .animation(.default, value: records.map(\.id))
    }

    // MARK: - Actions

    private func load() async {
        guard let accountId = accounts.accountId else {
            // "Not connected" is not "no advice": saying the latter would
            // tell the user their mailbox has nothing to triage when the
            // truth is that Lagoon has no mailbox to look at.
            isDisconnected = true
            isLoading = false
            return
        }
        isDisconnected = false
        isLoading = records.isEmpty
        do {
            records = try await api.fetchAdvice(accountId: accountId)
            errorBanner = nil
        } catch {
            errorBanner = ErrorBanner(
                severity: .error,
                title: l10n.adviceLoadFailed,
                detail: error.lagoonUIMessage,
                actionLabel: l10n.retry,
                action: { [self] in await self.load() }
            )
        }
        isLoading = false
    }

    /// Records the verdict and drops the row locally. Best-effort on failure:
    /// the row stays put and the error surfaces, because silently removing a
    /// suggestion the server still considers pending is how a queue starts
    /// lying about its own state.
    private func dismiss_(_ record: AdviceRecord) async {
        guard let accountId = accounts.accountId else { return }
        busyId = record.id
        defer { busyId = nil }
        do {
            _ = try await api.setAdviceDecision(
                id: record.id, decision: .dismissed, accountId: accountId
            )
            records.removeAll { $0.id == record.id }
            errorBanner = nil
        } catch {
            errorBanner = ErrorBanner(
                severity: .error,
                title: l10n.adviceLoadFailed,
                detail: error.lagoonUIMessage,
                actionLabel: l10n.retry,
                action: { Task { await dismiss_(record) } }
            )
        }
    }

    /// Opens the reminder sheet for a `.remind` suggestion.
    private func setReminder(_ record: AdviceRecord) {
        // Without an account there is nowhere to store the reminder, and the
        // sheet would present itself and then fail to save.
        guard accounts.accountId != nil else { return }
        reminderTarget = record
    }

    /// Performs a suggestion. The irreversible case stops here and waits for
    /// the answer.
    private func accept(_ record: AdviceRecord) {
        if record.advice.action.isIrreversible {
            pendingIrreversibleAccept = record
            return
        }
        Task { await performAcceptedAdvice(record) }
    }

    /// Runs the advised action and records the acceptance.
    ///
    /// The action itself goes through `AdvicePerformer` — the same executor
    /// the Briefing row uses — so the two surfaces cannot disagree about
    /// what "doing it" means: what the undo toast says, whether the
    /// acceptance is recorded, and what an irreversible action does.
    private func performAcceptedAdvice(_ record: AdviceRecord) async {
        guard let accountId = accounts.accountId else { return }
        busyId = record.id
        defer { busyId = nil }
        errorBanner = nil
        do {
            let outcome = try await AdvicePerformer.perform(
                action: record.advice.action,
                remoteId: record.remoteId,
                accountId: accountId,
                api: api
            )
            undo.show(AdvicePerformer.undoItem(for: outcome, l10n: l10n))
            // The mail has moved; now say that the user agreed with the
            // suggestion. Best-effort by design — the action already
            // happened, and a failed preference write must not fail it.
            let failure = await AdviceAcceptanceRecorder.record(
                advice: record,
                performedAction: record.advice.action,
                accountId: accountId,
                api: api
            )
            if let failure {
                // The verdict is still pending on the server, so the row
                // stays in the queue — and the banner says what really
                // happened ("done, but not recorded") rather than implying
                // the whole thing failed.
                errorBanner = ErrorBanner(
                    severity: .warning,
                    title: l10n.adviceAcceptFailedTitle,
                    detail: failure.lagoonUIMessage
                )
            } else {
                records.removeAll { $0.id == record.id }
            }
        } catch {
            // The request never completed, so nothing moved and the row is
            // still here: the retry re-runs this same action.
            errorBanner = ErrorBanner(
                severity: .error,
                title: failureTitle(for: record.advice.action),
                detail: error.lagoonUIMessage,
                actionLabel: l10n.retry,
                action: { [self] in await self.performAcceptedAdvice(record) }
            )
        }
    }

    /// The title that matches the action that failed. A shared "加载失败"
    /// would tell the user the wrong thing: nothing was being loaded.
    private func failureTitle(for action: AdvisedAction) -> String {
        switch action {
        case .archive: return l10n.archiveFailed
        case .delete: return l10n.deleteFailedTitle
        case .unsubscribe: return l10n.unsubscribeFailedTitle
        case .reply, .wait, .remind, .nothing: return l10n.adviceAcceptFailedTitle
        }
    }

    private func icon(for category: ContentCategory) -> String {
        switch category {
        case .marketing, .newsletter: "megaphone"
        case .spam: "exclamationmark.triangle"
        case .work: "briefcase"
        case .financial: "dollarsign.circle"
        case .logistics: "shippingbox"
        case .personal: "person"
        case .notification: "bell"
        case .transactional: "doc.text"
        case .other: "tag"
        }
    }
}

/// Performs an advised action, and the undo that comes back with it.
///
/// ## Why this exists
///
/// Two surfaces offer 「照做」: the strip inside a Briefing row and the
/// advice panel. They have to agree about what "doing it" means — which
/// route it takes, what the undo toast says, and whether the acceptance is
/// recorded — because a user who does the same thing in two places and gets
/// two different results concludes that one of them is broken.
///
/// The *decision* already lives in the model, so both surfaces ask it the
/// same questions: `AdvisedAction.isMutating` says whether an action may be
/// performed at all, and `AdvisedAction.isIrreversible` says whether the
/// user has to confirm it first. This type is the other half — one
/// implementation of what those answers mean.
///
/// Nothing here writes without a user gesture: the caller passes a record
/// the user just pressed a button on.
enum AdvicePerformer {
    /// What the performer did.
    enum Outcome: Equatable {
        case archived(actionId: Int64)
        case deleted(actionId: Int64)
        case unsubscribed(actionId: Int64, publisher: String)
    }

    /// The suggestion names an action that performs no mailbox write.
    struct NotPerformable: Error {}

    /// Performs `action` on `remoteId`.
    ///
    /// Throws whatever the API threw: the caller owns the error banner,
    /// because the two surfaces report a failure differently — the feed
    /// keeps the row and offers a retry, this panel shows a banner.
    @discardableResult
    static func perform(
        action: AdvisedAction,
        remoteId: String,
        accountId: UUID,
        api: APIClient = .shared
    ) async throws -> Outcome {
        switch action {
        case .archive:
            let response = try await api.archiveMessage(
                remoteId: remoteId, accountId: accountId
            )
            return .archived(actionId: response.actionId)
        case .delete:
            let response = try await api.deleteMessage(
                remoteId: remoteId, accountId: accountId
            )
            return .deleted(actionId: response.actionId)
        case .unsubscribe:
            let response = try await api.unsubscribeMessage(
                remoteId: remoteId, accountId: accountId
            )
            return .unsubscribed(
                actionId: response.actionId,
                publisher: response.publisher
            )
        case .reply, .wait, .remind, .nothing:
            throw NotPerformable()
        }
    }

    /// The toast for a performed action.
    ///
    /// An unsubscribe has no inverse on the server — the publisher has
    /// already been told — so its toast must not offer Undo. A button that
    /// always errors teaches the user to ignore the toast.
    static func undoItem(for outcome: Outcome, l10n: L10n) -> UndoItem {
        switch outcome {
        case .archived(let actionId):
            return UndoItem(
                id: actionId,
                message: l10n.archivedToast,
                systemImage: "tray.and.arrow.down"
            )
        case .deleted(let actionId):
            return UndoItem(
                id: actionId,
                message: l10n.deleted,
                systemImage: "trash"
            )
        case .unsubscribed(let actionId, let publisher):
            return UndoItem(
                id: actionId,
                message: "\(l10n.unsubscribed) · \(publisher)",
                systemImage: "minus.circle",
                undoable: false
            )
        }
    }
}
