import Foundation

/// Turns the server's machine-readable failure labels into something a person
/// can act on.
///
/// ## Why this exists
///
/// The sync engine records failures as short, stable, log-safe labels
/// (`MailError.logLabel`: `auth-failed`, `unreachable`, `not-configured`, …).
/// That is the right thing to *store* — a label never carries a credential or
/// a server payload — but it is the wrong thing to *show*.
///
/// Before this, the health banner read:
///
///     授权码错误或已失效：not-configured
///
/// The user is told their authorization code expired, and then handed an
/// internal identifier that means nothing to them. The label is a debugging
/// artifact; the sentence in front of it is the actual message.
///
/// So the label is translated here, at the edge, and anything unknown falls
/// back to a generic sentence rather than leaking the raw token. An
/// unrecognised label is not shown to the user at all — it goes to the
/// generic branch, because a string the product does not understand is a
/// string the product has no business printing.
public enum SyncErrorReason {
    /// A human sentence for a server failure label.
    ///
    /// `nil` means "this label is not one we know" — the caller then shows a
    /// generic message instead of the label.
    public static func humanReadable(_ label: String, l10n: L10n) -> String? {
        switch label {
        case "auth-failed":
            return l10n.reasonAuthFailed
        case "unreachable":
            return l10n.reasonUnreachable
        case "protocol-error":
            return l10n.reasonProtocolError
        case "message-gone":
            return l10n.reasonMessageGone
        case "archive-unavailable":
            return l10n.reasonArchiveUnavailable
        case "trash-unavailable":
            return l10n.reasonTrashUnavailable
        case "sent-unavailable":
            return l10n.reasonSentUnavailable
        case "not-configured":
            return l10n.reasonNotConfigured
        case "account-missing":
            return l10n.reasonAccountMissing
        case "no-provider":
            return l10n.reasonNoProvider
        default:
            return nil
        }
    }

    /// The sentence to show the user, never the label itself.
    ///
    /// Unknown labels collapse to a generic reason: the point of the label
    /// scheme is that the *server* stays terse and log-safe, not that the
    /// user has to decode it.
    public static func sentence(for label: String?, l10n: L10n) -> String {
        guard let label, !label.isEmpty else { return l10n.reasonUnknown }
        return humanReadable(label, l10n: l10n) ?? l10n.reasonUnknown
    }
}
