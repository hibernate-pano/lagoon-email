import Foundation

/// A file the user picked to send.
///
/// The bytes are read once, when the file is chosen, and kept in memory for
/// the life of the compose sheet. That is the trade the sheet makes: the
/// file is encoded into the request exactly once, and a file that changed on
/// disk between "attach" and "send" is sent as the user saw it, not as it
/// became.
///
/// The size cap mirrors the server's, so a file that is too big is refused
/// at pick time — with the file's name in the message — instead of failing
/// the send after the user has finished writing.
public struct OutgoingAttachment: Identifiable, Equatable {
    public let id: UUID
    /// The name shown to the recipient.
    public let filename: String
    /// The MIME type, from the file's extension.
    public let mimeType: String
    /// The file's bytes.
    public let data: Data
    /// The bytes, base64-encoded for the JSON request.
    ///
    /// Encoded once, at pick time, and kept. The composer re-reads this on
    /// every redraw, and a 10 MB file is 13 MB of base64 to push through
    /// `JSONSerialization` each time the view updates.
    public let base64: String

    public init(id: UUID = UUID(), filename: String, mimeType: String, data: Data) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
        self.base64 = data.base64EncodedString()
    }

    /// Largest single attachment, in bytes. The same number the server
    /// enforces, so the two never disagree about what is sendable.
    public static let maxBytes = 25 * 1024 * 1024

    /// The size shown next to the name.
    public var displaySize: String {
        ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
    }

    /// Whether this attachment may be sent.
    public var isSendable: Bool {
        !data.isEmpty && data.count <= Self.maxBytes
    }
}
