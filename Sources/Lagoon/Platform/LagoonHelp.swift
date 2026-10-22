import Foundation

/// Where a banner sends a user who cannot fix the failure themselves.
///
/// The product has exactly one support channel — the address the About
/// sheet's "发送反馈" button opens. Pointing a banner at the same
/// channel keeps the promise honest: the link works, and the mail that
/// arrives already says what went wrong, so the user does not have to
/// narrate the problem from scratch.
///
/// ## Why a channel is optional here
///
/// A link is a claim that the other end exists. Both channels used to be
/// compiled in: an address on a domain that is not registered, and a
/// website on that same domain. So every 「发送反馈」 button opened a mail
/// client addressed to a mailbox nobody owns, and 「访问官网」 opened a
/// page that does not exist. The buttons were live, the destinations
/// were not — the worst combination, because a dead link looks like a
/// working one until the user acts on it.
///
/// The fix is not a better URL; it is to stop claiming what the product
/// cannot deliver. A channel is **configured or it is not**, and a surface
/// renders the button only when this type hands it one. No configuration,
/// no button — never a button that lies.
///
/// ## Turning a channel back on
///
/// The values are read from the app's `Info.plist` instead of being
/// compiled in, so enabling a channel is a configuration change rather
/// than a code change — and so no address has to live in the repository:
///
/// - `LagoonSupportEmail` — the address 「发送反馈」 and a banner's
///   「帮助」 button write to.
/// - `LagoonWebsiteURL` — the site 「访问官网」 opens.
public enum LagoonHelp {
    /// `Info.plist` key holding the support address.
    public static let supportAddressKey = "LagoonSupportEmail"

    /// `Info.plist` key holding the product's website.
    public static let siteURLKey = "LagoonWebsiteURL"

    /// The address behind the About sheet's feedback button, when the
    /// product has one.
    public static var supportAddress: String? {
        configuredString(forKey: supportAddressKey)
    }

    /// The feedback link the About sheet opens, when there is an address
    /// to write to.
    ///
    /// Kept here so the banner's help link and the About sheet's feedback
    /// button reach the same inbox — one address, one place to change it.
    public static var feedbackMailto: URL? {
        guard let address = supportAddress else { return nil }
        return URL(string: "mailto:\(address)")
    }

    /// The product's own site. Used when the answer is a page rather than
    /// a person.
    public static var siteURL: URL? {
        guard let raw = configuredString(forKey: siteURLKey) else { return nil }
        return URL(string: raw)
    }

    /// A `mailto:` that opens the user's mail client with the subject and
    /// body already filled in.
    ///
    /// The address is a parameter so that the composition can be tested
    /// without a configured channel: the product's own address comes from
    /// `Info.plist`, and a test has no business shipping one.
    ///
    /// The context is not decoration: a support request that says "it
    /// broke" and one that says "archive failed on account <id>, server
    /// said archive-unavailable" are very different pieces of work. The
    /// banner is the only place that knows the context, so it writes it
    /// into the message here rather than asking the user to remember it.
    public static func supportMailto(to address: String, subject: String, body: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = address
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        return components.url
    }

    /// The link for the configured support channel.
    ///
    /// `nil` when the product has no support address — there is nothing to
    /// write to, so there is no link.
    public static func supportMailto(subject: String, body: String) -> URL? {
        guard let address = supportAddress else { return nil }
        return supportMailto(to: address, subject: subject, body: body)
    }

    /// The `mailto:` a banner's Help button opens for one specific failure.
    ///
    /// The body already says what failed and why, because the banner is the
    /// only place that knows; the footer asks for the one thing only the
    /// user knows. A report that arrives with both halves is worth ten that
    /// arrive saying "it broke" — and a Help button that opened an empty
    /// mailbox would be a dead control, which is why the link is composed
    /// rather than a constant.
    public static func bannerMailto(
        to address: String,
        failure: String,
        detail: String,
        l10n: L10n
    ) -> URL? {
        supportMailto(
            to: address,
            subject: "\(l10n.helpRequestSubject)：\(failure)",
            body: "\(failure)\n\(detail)\(l10n.helpRequestFooter)"
        )
    }

    /// The link a banner's Help button opens, for the configured channel.
    ///
    /// `nil` when the product has no support address. The banner then
    /// renders no help button at all, rather than a button that opens a
    /// message nobody will read.
    public static func bannerMailto(failure: String, detail: String, l10n: L10n) -> URL? {
        guard let address = supportAddress else { return nil }
        return bannerMailto(to: address, failure: failure, detail: detail, l10n: l10n)
    }

    /// The `Info.plist` value for `key`, trimmed, or `nil` when the key is
    /// absent or blank.
    ///
    /// A blank value is treated as absent: `LagoonSupportEmail = ""` in a
    /// plist is a channel that is switched off, not one that is broken.
    private static func configuredString(forKey key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
