import Foundation
import AppKit

/// The `lagoon://` URL scheme.
///
/// ## Why a URL scheme at all
///
/// A mail client that cannot be linked to is a private tool. A URL scheme is
/// what lets another application — a browser, a script, a Shortcut — say
/// "show this message in Lagoon", and it is the mechanism macOS itself uses
/// for handing a file to the app that owns its type. A product that other
/// software can call is a product other software can be built on.
///
/// ## The supported links
///
/// - `lagoon://message/<remoteId>` — open one message.
/// - `lagoon://search?q=<text>` — open the search panel with a query.
/// - `lagoon://unread` — go to the unread lens.
///
/// ## What an unknown link does
///
/// Nothing, visibly: the app activates and says nothing. That is the honest
/// outcome — a link the app cannot interpret is not an error in the *user's*
/// action, and a modal "unknown link" would be noise. The failure is logged
/// so a broken link is diagnosable without bothering the person who clicked
/// it.
@MainActor
enum LagoonURLHandler {
    /// The scheme this app answers to.
    static let scheme = "lagoon"

    /// Handles a URL. Returns whether the link was understood.
    @discardableResult
    static func handle(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == scheme else { return false }

        // `lagoon://message/abc` parses with host == "message" and path
        // == "/abc"; `lagoon:///message/abc` parses with an empty host and
        // the whole thing in the path. Both spellings are accepted, because
        // a hand-written link and a link from another app rarely agree on
        // which one to use.
        var parts: [String] = []
        if let host = url.host, !host.isEmpty { parts.append(host) }
        parts += url.path
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }

        guard let action = parts.first else {
            NSLog("lagoon: ignoring a link with no action: %@", url.absoluteString)
            return false
        }

        switch action {
        case "message":
            guard parts.count >= 2 else {
                NSLog("lagoon: ignoring a message link with no id: %@", url.absoluteString)
                return false
            }
            // The remote id is a Message-ID, which may contain characters that
            // have to survive the URL round trip. `pathComponents` decodes
            // them; re-encoding is not needed because the router passes the
            // decoded string to the app, not to the network.
            AppCommandRouter.shared.send(.showMessage(remoteId: parts[1]))
            return true

        case "search":
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "q" })?
                .value
            AppCommandRouter.shared.send(.search(query: query))
            return true

        case "unread":
            AppCommandRouter.shared.send(.showUnread)
            return true

        default:
            NSLog("lagoon: ignoring an unknown action %@", action)
            return false
        }
    }
}
