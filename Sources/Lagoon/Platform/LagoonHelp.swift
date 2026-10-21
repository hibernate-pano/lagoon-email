import Foundation

/// Where a banner sends a user who cannot fix the failure themselves.
///
/// The product has exactly one support channel — the address the About
/// sheet's "发送反馈" button already opens. Pointing a banner at the same
/// channel keeps the promise honest: the link works, and the mail that
/// arrives already says what went wrong, so the user does not have to
/// narrate the problem from scratch.
public enum LagoonHelp {
    /// The address behind the About sheet's feedback button.
    public static let supportAddress = "feedback@lagoon.email"

    /// The feedback link the About sheet opens. Kept here so the banner's
    /// help link and the About sheet's feedback button reach the same inbox
    /// — one address, one place to change it.
    public static let feedbackMailto = URL(string: "mailto:\(supportAddress)")!

    /// The product's own site. Used when the answer is a page rather than
    /// a person.
    public static let siteURL = URL(string: "https://lagoon.email")!

    /// A `mailto:` that opens the user's mail client with the subject and
    /// body already filled in.
    ///
    /// The context is not decoration: a support request that says "it
    /// broke" and one that says "archive failed on account <id>, server
    /// said archive-unavailable" are very different pieces of work. The
    /// banner is the only place that knows the context, so it writes it
    /// into the message here rather than asking the user to remember it.
    public static func supportMailto(subject: String, body: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportAddress
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        return components.url
    }

    /// The `mailto:` a banner's Help button opens for one specific failure.
    ///
    /// The body already says what failed and why, because the banner is the
    /// only place that knows; the footer asks for the one thing only the
    /// user knows. A report that arrives with both halves is worth ten that
    /// arrive saying "it broke" — and a Help button that opened an empty
    /// mailbox would be a dead control, which is why the link is composed
    /// rather than a constant.
    public static func bannerMailto(failure: String, detail: String, l10n: L10n) -> URL? {
        supportMailto(
            subject: "\(l10n.helpRequestSubject)：\(failure)",
            body: "\(failure)\n\(detail)\(l10n.helpRequestFooter)"
        )
    }
}
