import SwiftUI
import LagoonKit

/// How much mail fits on screen at once.
///
/// ## Why this is a preference and not a hardcoded layout
///
/// The Briefinging feed stacks three text lines per row (subject / sender /
/// reason or snippet). In the split layout's fixed 280–460pt list column that
/// is comfortable on a large display and cramped on a 13" laptop, and the user
/// has no way to trade the third line for one more row. Foxmail, QQ邮箱 and
/// 网易邮箱大师 all ship a density control for exactly this reason.
///
/// The three cases are named rather than numeric because the *number* of rows
/// is a property of the user's window, not of the setting. What the user chose
/// is "how much do I care about the snippet line", and only they can say.
enum ListDensity: String, CaseIterable, Identifiable {
    /// Three lines per row: subject, sender, and the reason/snippet.
    case comfortable
    /// Two lines: subject and sender, with the snippet dropped.
    /// The default — a triage tool should show one more message per screen
    /// before it shows one more line of a message you will probably archive.
    case compact
    /// One line per row: unread dot, sender, subject. For scanning hundreds of
    /// rows looking for one sender.
    case dense

    var id: String { rawValue }

    /// Whether the row shows its snippet/reason line at all.
    var showsSnippet: Bool { self != .dense }

    /// Minimum row height handed to SwiftUI's list. `nil` means the platform
    /// default, which is what comfortable mode wants.
    var minRowHeight: CGFloat? {
        switch self {
        case .comfortable: return nil
        case .compact: return 52
        case .dense: return 30
        }
    }

    /// One label for the whole setting — the menu shows these three, not three
    /// separate toggles, because they are mutually exclusive views of the same
    /// choice.
    var title: String {
        switch self {
        case .comfortable: return L10n(language: .zhHans).densityComfortable
        case .compact: return L10n(language: .zhHans).densityCompact
        case .dense: return L10n(language: .zhHans).densityDense
        }
    }
}

/// Reads and writes the shared density preference.
///
/// `@AppStorage` needs a stored property, and the value is needed by both mail
/// surfaces plus the toolbar — a small holder keeps the key string in one place
/// instead of three copies of `"lagoon.density"`, which is exactly how two
/// surfaces end up disagreeing about how dense the list is.
enum ListDensityPreference {
    static let key = "lagoon.density"

    static func current() -> ListDensity {
        ListDensity(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .compact
    }

    static func set(_ density: ListDensity) {
        UserDefaults.standard.set(density.rawValue, forKey: key)
    }
}

/// Applies a density to a list's rows.
///
/// A view modifier rather than something each row reads, because
/// `defaultMinListRowHeight` is an environment value: setting it on the list
/// is what makes *every* row resize, including the ones SwiftUI synthesizes
/// for sections and empty states.
struct ListDensityModifier: ViewModifier {
    let density: ListDensity

    func body(content: Content) -> some View {
        if let height = density.minRowHeight {
            content.environment(\.defaultMinListRowHeight, height)
        } else {
            content
        }
    }
}

extension View {
    func listDensity(_ density: ListDensity) -> some View {
        modifier(ListDensityModifier(density: density))
    }
}

/// The read-only preview shown when the pointer rests on a row.
///
/// ## Why hover at all
///
/// Opening a message is not free: it fetches the body from the server, marks
/// the mail read after a dwell, and replaces the reading pane. Foxmail, QQ邮箱
/// and 网易邮箱大师 all let the user see "what is this" without committing to
/// it, and that is the difference between scanning 50 rows and opening 50 rows.
///
/// ## What it deliberately does not include
///
/// No action buttons. A hover card that could archive would be a mutation
/// reachable by moving the mouse across the list — the opposite of
/// constitution §2 rule 3, which requires every change to come from a gesture
/// the user meant. This card is text: sender, subject, the snippet, and the
/// AI's reason if there is one. Read and nothing else.
struct RowHoverPreview: View {
    let message: MessageHeader
    /// The AI's suggestion, when the feed has one for this row.
    var advice: AdviceRecord?

    @Environment(\.l10n) private var l10n

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.subject ?? l10n.noSubject)
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(message.fromName ?? message.fromAddress)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let snippet = message.snippet {
                Text(snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let advice, advice.advice.action != .nothing {
                // The judgement travels with the preview: the question this card
                // answers is "is this worth my time", and "the AI thinks it is
                // disposable" is part of that answer.
                Text(l10n.adviceAction(advice.advice.action))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(message.receivedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(width: 300, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
        // The card must never eat the click that opens the message underneath,
        // nor the drag that selects a range of rows.
        .allowsHitTesting(false)
    }
}