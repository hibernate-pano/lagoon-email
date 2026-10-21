import Foundation

/// Response payload of `GET /api/messages/{remoteId}/inline-images`.
///
/// ## Why this exists
///
/// A mail with inline images used to cost the client **N+1 round trips**:
/// one for the body and one per image, because the body response carried
/// only attachment *metadata* and the bytes lived behind a per-attachment
/// endpoint. The server's cost was worse — that endpoint re-fetched and
/// re-parsed the *entire* message for every single part.
///
/// The server now reads the inline parts once and hands them back together,
/// so the client asks once instead of N times.
///
/// ## The shape
///
/// The values are raw bytes, not data URLs: the client needs them as
/// `Data` to hand to the HTML renderer, which builds the `data:` URL
/// itself. The keys are Content-IDs **without** angle brackets
/// (`logo@example.com`, not `<logo@example.com>`) and lower-cased — the
/// same shape the `cid:` reference in the HTML uses, and the same way the
/// renderer compares them.
///
/// `Data` encodes as base64 in JSON, which is what the wire needs.
public struct InlineImagesResponse: Codable, Equatable, Sendable {
    /// Content-ID (lower-cased, no angle brackets) → the image's bytes.
    /// Empty when the message has no inline images.
    public let images: [String: Data]

    public init(images: [String: Data] = [:]) {
        self.images = images
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A server that predates this route does not send the field at all.
        // Decoding it as empty is the right answer: the client then falls
        // back to fetching the images the old way.
        images = try c.decodeIfPresent([String: Data].self, forKey: .images) ?? [:]
    }

    private enum CodingKeys: String, CodingKey {
        case images
    }
}
