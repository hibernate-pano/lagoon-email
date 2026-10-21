import SwiftUI
import LagoonKit

/// The AI's read-only suggestion, shown **inside the feed row**.
///
/// ## Why this exists
///
/// The advice queue (`AdviceSheet`) is where the AI's judgement is complete,
/// but it lives behind ⇧⌘A. The product promise is "open twice a day, ten
/// minutes to zero" — and a suggestion the user has to go looking for is a
/// suggestion that does not save any time. This view puts the two fields that
/// matter (what to do, how sure) directly on the row the user is already
/// looking at, so the decision and the advice are the same glance.
///
/// ## The three rules it keeps (constitution §2, §3)
///
/// 1. **Adjectives, not verbs in the past.** Every label reads "suggest…",
///    never "archived". The user must be able to tell from this row alone
///    that nothing has happened.
/// 2. **No mailbox buttons.** Two verbs only: reveal the message, and dismiss
///    the *suggestion*. Archive / delete / unsubscribe stay on the row and
///    detail actions the user already triages with. A second set of write
///    buttons here would duplicate that logic and invite the reading that this
///    app exists to prevent.
/// 3. **Confidence gates how loudly it speaks.** A low-confidence suggestion
///    never renders as a bare imperative — the doubt is shown, because that is
///    exactly where the user is owed it.
///
/// ## Destructiveness
///
/// `.delete` and `.unsubscribe` carry an extra "不可撤销" marker. Dismissing a
/// suggestion is reversible (it only writes the `advice` table); *acting* on
/// those two is not, and the row must not imply otherwise.
///
/// ## The 「照做」 button
///
/// The strip used to offer no way to *agree* with a suggestion. A suggestion
/// the user thinks is right could only be acted on by hunting for the action
/// somewhere else on the row — which is the entry point the constitution's
/// learning loop needs: advice → the user acts → the fact that they acted is
/// recorded → later advice is better. With no way to say "yes, do that" from
/// the strip, the loop has no way to start.
///
/// So the strip now carries a third verb, and it is the only one that touches
/// the mailbox. It does so *through the caller's ordinary user-triggered
/// route* — the same `archiveAndUndo` / `unsubscribeFrom` the swipe gesture
/// and the context menu use. The AI never triggers anything: the user
/// tapping 「照做」 does, and that tap is the write trigger the constitution
/// requires (constitution §2 rule 3, §3).
struct RowAdviceStrip: View {
    let record: AdviceRecord
    /// Reveal the message this suggestion is about.
    let onOpen: () -> Void
    /// Record a `dismissed` verdict — writes the `advice` table only.
    let onDismiss: () -> Void
    /// Set a reminder for this message.
    ///
    /// Only ever offered for a `.remind` suggestion, and only ever on a
    /// user gesture. The suggestion itself sets nothing — that is the whole
    /// point of the advisory-only constitution, and it is also what makes
    /// this button safe to have: the user decides *when*, not the model.
    var onSetReminder: (() -> Void)? = nil
    /// Perform the suggested action and record the suggestion as `accepted`.
    ///
    /// Nil when the suggestion has no action Lagoon can carry out from the
    /// strip (`.reply`, `.wait`, `.nothing`): the button is then not rendered
    /// at all rather than rendered disabled, because a dead button teaches
    /// the user that the whole row is broken.
    var onAccept: (() -> Void)? = nil
    /// Drives the inline expand/collapse.
    @Binding var isExpanded: Bool
    /// True while a dismissal request for this row is in flight.
    var isBusy: Bool = false

    @Environment(\.l10n) private var l10n

    private var advice: Advice { record.advice }

    /// `.archive` is the advice most likely to match what the user is already
    /// about to do, so it leads; `.nothing` is not worth a strip at all.
    private var isWorthShowing: Bool { advice.action != .nothing }

    /// The suggestion was already handled: acted on (`.accepted`) or rejected
    /// (`.dismissed`). Neither may be "done" a second time — the row has
    /// served its purpose, and a strip that offers to repeat a dismissed
    /// suggestion is exactly the nagging this feature is supposed to avoid.
    private var isDecided: Bool { record.decision != .pending }

    var body: some View {
        if isWorthShowing {
            VStack(alignment: .leading, spacing: 4) {
                head
                if isExpanded {
                    detail
                }
            }
            .padding(.top, 2)
        }
    }

    /// The always-visible line: action · confidence, as one compact strip.
    ///
    /// Deliberately a button rather than static text: tapping it is how the
    /// user asks "why?", and a non-interactive chip would teach them that the
    /// row is not worth engaging.
    private var head: some View {
        Button {
            withAnimation(.snappy) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: iconName)
                    .font(.caption2)
                    .foregroundStyle(tint)
                Text(l10n.adviceAction(advice.action))
                    .font(.caption)
                    .foregroundStyle(tint)
                // The hedge is unconditional rather than low-confidence-only:
                // "较有把握" is information, and hiding the middle band would
                // make high read as "probably always right".
                Text(l10n.adviceConfidence(advice.confidence))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if advice.action.isIrreversible {
                    Text(l10n.adviceIrreversibleBadge)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 2)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(l10n.adviceWhyHelp)
        .accessibilityLabel(
            "\(l10n.adviceAction(advice.action))，\(l10n.adviceConfidence(advice.confidence))"
        )
        .accessibilityHint(l10n.adviceWhyHelp)
    }

    /// The expanded body: category, the model's own sentence, and the two
    /// permitted verbs.
    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let category = advice.category {
                Label(l10n.adviceCategory(category), systemImage: categoryIcon(category))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
            if let rationale = advice.rationale {
                Text(rationale)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let due = advice.dueText {
                Label(due, systemImage: "clock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                // Provenance: a paid model judgement and a free offline rule
                // do not deserve the same trust. Same wording as the sheet, so
                // the two surfaces never disagree about where a row came from.
                Text(l10n.adviceSource(record.source, model: record.model))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 4)
                Button(l10n.adviceOpenMessage) { onOpen() }
                    .buttonStyle(.link)
                    .font(.caption)
                // The one extra verb this strip carries, and it is only
                // there for a `.remind` suggestion: a suggestion with a
                // deadline and no way to act on it is the empty promise
                // this whole feature exists to remove.
                if advice.action == .remind, let onSetReminder {
                    Button(l10n.reminderSet) { onSetReminder() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                // 「照做」 — the only verb here that touches the mailbox, and
                // only ever through the caller's ordinary user-triggered
                // route. Hidden once the suggestion has been decided: a
                // dismissed suggestion must not offer to be performed, and an
                // accepted one has already been performed.
                //
                // The button is only rendered when the suggestion is
                // **mutating** — archive, delete, unsubscribe. A
                // non-mutating suggestion (reply, wait, remind, nothing)
                // has no mailbox write to perform, and offering a 「照做」
                // for it would be a button that does nothing. That was the
                // real bug behind `AdvisedAction.isMutating` sitting unused
                // in the model: the property said "the UI should ask for
                // confirmation before a mutating action", and the UI asked
                // for confirmation for *nothing*.
                if !isDecided, advice.action.isMutating, let onAccept {
                    Button(l10n.adviceAccept) { onAccept() }
                        .buttonStyle(.link)
                        .font(.caption)
                        .help(l10n.adviceAcceptHelp)
                        .disabled(isBusy)
                }
                Button(record.decision == .dismissed ? l10n.adviceDismissed : l10n.adviceDismiss) {
                    onDismiss()
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(isBusy || record.decision == .dismissed)
            }
        }
        .padding(.leading, 2)
    }

    /// Low-saturation so the strip reads as annotation on the mail rather than
    /// as a second, competing call to action. `.secondary` would vanish against
    /// a selected row; `.tertiary` survives both.
    private var tint: Color { advice.confidence == .low ? .secondary : .accentColor }

    private var iconName: String {
        switch advice.action {
        case .reply: return "arrowshape.turn.up.left"
        case .wait: return "clock"
        case .archive: return "archivebox"
        case .delete: return "trash"
        case .unsubscribe: return "bell.slash"
        case .remind: return "bell"
        case .nothing: return "circle"
        }
    }

    private func categoryIcon(_ category: ContentCategory) -> String {
        switch category {
        case .personal: return "person"
        case .work: return "briefcase"
        case .marketing, .newsletter: return "megaphone"
        case .spam: return "exclamationmark.triangle"
        case .notification: return "bell"
        case .transactional, .financial: return "creditcard"
        case .logistics: return "shippingbox"
        case .other: return "tag"
        }
    }
}