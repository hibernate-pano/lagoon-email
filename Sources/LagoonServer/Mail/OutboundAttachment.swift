import Foundation

/// A file the user picked to send, or a whole message being forwarded.
///
/// ## Why the forwarded message is an attachment
///
/// A forward is not a new message that happens to quote an old one. RFC
/// 5322 §3.6.4 says a forwarded message travels as a `message/rfc822`
/// part: the *original message*, headers and body and all, wrapped as a
/// single part inside the new message.
///
/// The difference is visible to the recipient. A quoted forward flattens
/// the original into plain text — the HTML formatting is gone, the
/// original's attachments are gone, the original's headers are gone, and
/// the recipient sees a wall of `>` characters. A `message/rfc822` forward
/// keeps all of it: the recipient's client renders the original as it
/// was, and offers the original's attachments as attachments of the
/// original.
///
/// So the forwarded message is carried as an attachment whose media type
/// is `message/rfc822` and whose bytes are the original RFC 5322 message
/// verbatim. The `Content-Disposition` is `inline`, not `attachment`,
/// because the recipient's client should *show* the original rather than
/// offer it as a file to save.
public struct OutboundAttachment: Sendable, Equatable {
    public let filename: String
    public let mimeType: String
    public let data: Data
    /// Largest single attachment, in bytes.
    public static let maxBytes = 25 * 1024 * 1024

    /// Whether the recipient's client should *show* this part or offer it
    /// as a file to save.
    ///
    /// `inline` is the right disposition for a forwarded message
    /// (`message/rfc822`): the point of a forward is that the recipient
    /// reads the original, so it is rendered, not offered as a download.
    /// Everything the user picked from their own disk is `attachment`.
    public enum Disposition: String, Sendable, Equatable {
        case attachment
        case inline
    }

    public let disposition: Disposition

    public init(
        filename: String,
        mimeType: String,
        data: Data,
        disposition: Disposition = .attachment
    ) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
        self.disposition = disposition
    }

    /// Whether this attachment may be sent.
    public var isSendable: Bool { !data.isEmpty && data.count <= Self.maxBytes }
}
