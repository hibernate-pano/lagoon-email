import Foundation
import LagoonKit

/// The rules the three composers share.
///
/// A reply, a new message and a forward are three windows, but the user
/// only knows one verb — "write a mail and send it". When the three
/// disagree about what a failure says, whether the work survives closing
/// the window, and what a number next to a label means, the product reads
/// as three products.
///
/// The rules that have to be identical live here, once.
enum ComposeFlow {

    // MARK: - Drafts

    /// The writable half of a compose sheet.
    ///
    /// The reply composer fills only `body` — its recipients and its
    /// subject come from the message being replied to — while the other
    /// two fill all five. One shape for all three is what makes "the draft
    /// is kept" a promise the product can keep three times over.
    struct Draft: Codable, Equatable {
        var to = ""
        var cc = ""
        var bcc = ""
        var subject = ""
        var body = ""

        /// True when there is nothing worth keeping.
        var isEmpty: Bool {
            to.isEmpty && cc.isEmpty && bcc.isEmpty && subject.isEmpty && body.isEmpty
        }
    }

    /// A draft slot on disk.
    ///
    /// The key is per account *and* per message, so a reply to one message
    /// never overwrites the reply to another, and two accounts never
    /// overwrite each other's work.
    ///
    /// The store is injectable so the behaviour can be tested without
    /// touching the user's own defaults.
    struct DraftSlot {
        let key: String
        let defaults: UserDefaults

        init(key: String, defaults: UserDefaults = .standard) {
            self.key = key
            self.defaults = defaults
        }

        /// The saved draft, or nil when there is none (or it is unreadable).
        func load() -> Draft? {
            guard let data = defaults.data(forKey: key) else { return nil }
            return try? JSONDecoder().decode(Draft.self, from: data)
        }

        /// Keeps the draft. An empty draft is removed rather than stored,
        /// so a slot never holds a fossil of a mail the user deleted.
        func save(_ draft: Draft) {
            if draft.isEmpty {
                defaults.removeObject(forKey: key)
            } else if let data = try? JSONEncoder().encode(draft) {
                defaults.set(data, forKey: key)
            }
        }

        /// Throws the draft away. The user asked for it; nothing else
        /// decides this.
        func clear() {
            defaults.removeObject(forKey: key)
        }

        /// True when there is a draft on disk.
        var hasDraft: Bool { load() != nil }
    }

    // MARK: - Why a send failed

    /// Why a send did not go out, in terms the user can act on.
    ///
    /// The server distinguishes these carefully — an expired authorization
    /// code and a mail server that is briefly unreachable need opposite
    /// answers — and the client used to flatten all of them into "HTTP
    /// 401:" with no next step.
    enum Failure: Equatable {
        /// The sending server rejected the authorization code. Retrying
        /// cannot help; the code has to be re-entered.
        case authFailed
        /// The account has no sending server configured.
        case notConfigured
        /// The message is gone from the server — there is nothing to reply
        /// to or forward.
        case messageGone
        /// The account row is gone.
        case accountMissing
        /// The recipient list did not parse.
        case malformedRecipient
        /// An attachment did not survive the trip.
        case malformedAttachment
        /// The original is too large to forward.
        case forwardTooLarge
        /// The same request is already on the wire.
        case inFlight
        /// The server answered 200 but says it did not send.
        case rejected
        /// The server could not reach the mail server, or the connection
        /// broke on the way.
        case transport
        /// Something we do not have a name for.
        case unknown

        /// Whether pressing "try again" can change the outcome.
        ///
        /// A failure the user cannot fix by trying again must not offer a
        /// retry — the app's own rule for failure banners. An expired
        /// authorization code is the clearest case: the second attempt
        /// fails exactly like the first.
        var canRetry: Bool {
            switch self {
            case .transport, .unknown, .inFlight, .rejected:
                return true
            case .authFailed, .notConfigured, .messageGone, .accountMissing,
                 .malformedRecipient, .malformedAttachment, .forwardTooLarge:
                return false
            }
        }

        /// Reads the server's error code.
        ///
        /// The codes are the server's, not ours: `MessageRoutes` answers
        /// `smtp-auth-failed`, `provider-not-configured`, `message-gone`
        /// and friends, and the client names them rather than inventing
        /// its own.
        static func classify(_ error: Error) -> Failure {
            if let apiError = error as? APIError {
                switch apiError.serverErrorCode {
                case "smtp-auth-failed": return .authFailed
                case "provider-not-configured": return .notConfigured
                case "message-gone", "forward-original-unavailable": return .messageGone
                case "unknown-account": return .accountMissing
                case "malformed-recipient": return .malformedRecipient
                case "malformed-attachment": return .malformedAttachment
                case "forward-too-large": return .forwardTooLarge
                case "send-in-flight": return .inFlight
                default: break
                }
                if case .badStatus(let code, _) = apiError {
                    // 5xx is the server's own trouble: the same request may
                    // well work a second later. 4xx is the request's
                    // trouble, and repeating it changes nothing.
                    return code >= 500 ? .transport : .unknown
                }
                return .transport
            }
            if error is URLError { return .transport }
            return .unknown
        }
    }

    // MARK: - What a 200 actually meant

    /// The outcome of a send, once the server's own answer is read.
    ///
    /// `SendResponse` carries an `ok` flag so the client can tell "the
    /// server accepted this" from "the server answered 200 but did not
    /// send". The client used to ignore the flag and announce "Sent to …"
    /// either way — an irreversible promise made on a response that never
    /// promised it.
    enum Outcome: Equatable {
        /// The server took the mail, and reports this provider id.
        case accepted(String?)
        /// The server answered, but says it did not send.
        case rejected
    }

    /// Reads the server's answer.
    static func outcome(of response: SendResponse) -> Outcome {
        response.ok ? .accepted(response.providerMessageId) : .rejected
    }

    // MARK: - Attachments

    /// The attachment ceilings, mirrored from the server.
    ///
    /// The server caps a *single* file at `OutgoingAttachment.maxBytes`
    /// and the *total* at four times that. Mirroring only the single-file
    /// cap is how four 24 MB files reached the server and came back as
    /// an unexplained failure.
    enum Attachments {
        /// The largest total the server will accept, in bytes.
        static let maxTotalBytes = OutgoingAttachment.maxBytes * 4

        /// The size of the attachments as a whole.
        static func totalBytes(_ attachments: [OutgoingAttachment]) -> Int {
            attachments.reduce(0) { $0 + $1.data.count }
        }

        /// Whether a file of `size` bytes still fits alongside the ones
        /// already picked.
        static func fits(_ size: Int, alongside attachments: [OutgoingAttachment]) -> Bool {
            totalBytes(attachments) + size <= maxTotalBytes
        }
    }
}
