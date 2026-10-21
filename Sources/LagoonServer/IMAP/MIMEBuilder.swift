import Foundation

/// Builds the RFC 5322 message the SMTP path sends verbatim. Everything is
/// CRLF-framed and the body is base64, so no line can ever need dot-stuffing
/// or folding.
public enum MIMEBuilder {
    /// A reply to `outbound`, with `messageId` used verbatim (the caller owns
    /// generating and remembering `<uuid@lagoon>`).
    public static func reply(_ outbound: OutboundMessage, messageId: String) -> Data {
        build(
            outbound,
            messageId: messageId,
            subject: subjectHeader(outbound.subject),
            includeThreading: true
        )
    }

    /// A new message keeps the subject exactly as typed and carries no thread
    /// headers.
    public static func newMessage(_ outbound: OutboundMessage, messageId: String) -> Data {
        build(
            outbound,
            messageId: messageId,
            subject: subjectHeader(outbound.subject, addReplyPrefix: false),
            includeThreading: false
        )
    }

    private static func build(
        _ outbound: OutboundMessage,
        messageId: String,
        subject: String,
        includeThreading: Bool
    ) -> Data {
        var lines: [String] = []
        lines.append("From: \(address(outbound.fromEmail, name: outbound.fromName))")
        lines.append("To: \(addressList(outbound.to))")
        // `Cc:` is omitted entirely when empty — a bare `Cc:` header is
        // technically legal but many spam filters score it.
        if !outbound.cc.isEmpty {
            lines.append("Cc: \(addressList(outbound.cc.joined(separator: ", ")))")
        }
        // `Bcc:` is **never** written. That is what makes it blind: the
        // recipients must not learn who else received the mail. The
        // addresses are in the envelope instead, where the SMTP server
        // needs them and no recipient can see them.
        lines.append("Subject: \(headerSafe(subject))")
        lines.append("Date: \(Self.dateHeader())")
        lines.append("Message-ID: \(messageId)")
        if includeThreading, let inReplyTo = outbound.inReplyTo, !inReplyTo.isEmpty {
            lines.append("In-Reply-To: \(headerSafe(inReplyTo))")
        }
        if includeThreading, let references = outbound.references, !references.isEmpty {
            lines.append("References: \(headerSafe(references))")
        }
        lines.append("MIME-Version: 1.0")

        let headers = lines.joined(separator: "\r\n")

        guard !outbound.attachments.isEmpty else {
            return plainTextBody(headers: headers, body: outbound.body)
        }
        return multipartMixed(headers: headers, outbound: outbound)
    }

    /// The single-part case: `text/plain`, base64, CRLF-framed.
    private static func plainTextBody(headers: String, body: String) -> Data {
        var message = headers
        message += "\r\nContent-Type: text/plain; charset=UTF-8"
        message += "\r\nContent-Transfer-Encoding: base64"
        message += "\r\n\r\n"
        message += base64Lines(Data(body.utf8))
        message += "\r\n"
        return Data(message.utf8)
    }

    /// The multipart case: `multipart/mixed`, the body first, then one part
    /// per attachment.
    ///
    /// `multipart/mixed` (RFC 2046 §5.1.4) is the right structure here: the
    /// first part is the body the user typed, and the rest are the files.
    /// `multipart/alternative` would be wrong — it means "the same content
    /// in several forms, pick one", not "the body plus files".
    ///
    /// The boundary is derived from the message id, which is unique per
    /// message, so it cannot collide with a line inside the body or an
    /// attachment's bytes. A boundary that collided with content is the
    /// classic way a multipart message gets truncated at the first
    /// accidental match.
    private static func multipartMixed(headers: String, outbound: OutboundMessage) -> Data {
        let boundary = "lagoon-\(boundaryToken(outbound))"
        var message = headers
        message += "\r\nContent-Type: multipart/mixed; boundary=\"\(boundary)\""
        message += "\r\n\r\n"

        // The body part.
        message += "--\(boundary)\r\n"
        message += "Content-Type: text/plain; charset=UTF-8\r\n"
        message += "Content-Transfer-Encoding: base64\r\n\r\n"
        message += base64Lines(Data(outbound.body.utf8))
        message += "\r\n"

        // One part per attachment.
        for attachment in outbound.attachments {
            message += "--\(boundary)\r\n"
            message += "Content-Type: \(contentType(attachment.mimeType))\r\n"
            message += "Content-Transfer-Encoding: base64\r\n"
            message += "Content-Disposition: \(contentDisposition(attachment))\r\n\r\n"
            message += base64Lines(attachment.data)
            message += "\r\n"
        }

        // The closing delimiter. RFC 2046 requires it, and it must be
        // preceded by CRLF.
        message += "--\(boundary)--\r\n"
        return Data(message.utf8)
    }

    /// A boundary token with no character that could be mistaken for a
    /// separator: letters, digits and dashes only.
    private static func boundaryToken(_ outbound: OutboundMessage) -> String {
        let seed = outbound.fromEmail
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
            .prefix(8)
        let suffix = UUID().uuidString.prefix(12)
        return "\(seed.isEmpty ? "lagoon" : seed)-\(suffix)"
    }

    /// A safe `Content-Type` for an attachment.
    ///
    /// The MIME type comes from the client, which read it off the user's
    /// file — but it is still remote-controlled as far as this process is
    /// concerned, and a CRLF in it would forge a header line. Anything that
    /// is not a plain token falls back to `application/octet-stream`, which
    /// every client treats as "an opaque file".
    private static func contentType(_ raw: String) -> String {
        let trimmed = headerSafe(raw).trimmingCharacters(in: .whitespaces)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/-+.=;"))
        guard !trimmed.isEmpty,
              trimmed.count <= 128,
              trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              trimmed.contains("/")
        else { return "application/octet-stream" }
        return trimmed
    }

    /// A safe file name for `Content-Disposition`.
    ///
    /// The name comes from the user's disk, and it goes into a header, so
    /// it must not carry a newline (which would forge a header line) or a
    /// quote (which would end the parameter early). A name that cannot be
    /// made safe keeps its bytes but loses the dangerous ones.
    private static func filename(_ raw: String) -> String {
        let sanitized = raw
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\"", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "attachment" : sanitized
    }

    /// The `Content-Disposition` line for an attachment.
    ///
    /// RFC 6266 §4.1 lets the file name be carried two ways, and it wants
    /// both: `filename` for the old clients, `filename*` (RFC 5987's
    /// percent-encoded form) for the ones that understand it. Without
    /// `filename*`, a Chinese file name arrives at the recipient as
    /// mojibake — the attachment is there, and it is unusable.
    ///
    /// The percent-encoded form carries only ASCII, so it cannot forge a
    /// header line whatever the name contains.
    ///
    /// A forwarded message is `inline`: the recipient's client renders the
    /// original message in place rather than offering it as a file to
    /// save. That is the whole difference between a forward and a
    /// "here is the original as a download" — and it is the disposition
    /// that says which one this is.
    private static func contentDisposition(_ attachment: OutboundAttachment) -> String {
        let safe = filename(attachment.filename)
        let encoded = safe.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        ) ?? ""
        return "\(attachment.disposition.rawValue); filename=\"\(safe)\"; filename*=UTF-8''\(encoded)"
    }

    /// Ensures exactly one `Re:` prefix. An existing prefix is kept as the
    /// sender wrote it, so "re:" is not silently normalized.
    static func subject(_ value: String) -> String {
        let prefix = "re:"
        if value.lowercased().hasPrefix(prefix) { return value }
        return "Re: \(value)"
    }

    /// The `Re:` prefix is ASCII, so only the run from the first non-ASCII
    /// character onward becomes an encoded word — `Re: =?UTF-8?B?…?=`, which is
    /// what a receiving client renders as "Re: 会议纪要".
    static func subjectHeader(_ value: String, addReplyPrefix: Bool = true) -> String {
        let prefixed = addReplyPrefix ? subject(value) : value
        guard let firstNonASCII = prefixed.firstIndex(where: { !$0.isASCII }) else {
            return prefixed
        }
        let head = String(prefixed[..<firstNonASCII])
        let tail = String(prefixed[firstNonASCII...])
        return head + "=?UTF-8?B?\(Data(tail.utf8).base64EncodedString())?="
    }

    /// `"Name" <addr>` with RFC 2047 for a non-ASCII name, else `<addr>`.
    private static func address(_ email: String, name: String?) -> String {
        let address = headerSafe(email)
        guard let name = name.map(headerSafe), !name.isEmpty else { return "<\(address)>" }
        guard name.allSatisfy(\.isASCII) else {
            return "=?UTF-8?B?\(Data(name.utf8).base64EncodedString())?= <\(address)>"
        }
        return "\"\(name)\" <\(address)>"
    }

    /// Comma-separated address list → the bracketed form the headers use.
    ///
    /// The split is RFC 5322's, not a plain `split(separator: ",")`: a comma
    /// inside a quoted display name (`"Zhang, Wei" <wei@example.com>`) belongs
    /// to the name, and cutting there split one recipient into two — the
    /// second half a bare address that could bounce, and that a forward-path
    /// builder would read as somebody else.
    ///
    /// Already-bracketed input passes through unchanged (a caller that
    /// received `Name <a@b>` from a header keeps it verbatim).
    private static func addressList(_ raw: String) -> String {
        MIMEParser.splitAddressList(headerSafe(raw))
            .map { value in
                value.contains("<") ? value : "<\(value)>"
            }
            .joined(separator: ", ")
    }

    /// Every value interpolated above is remote-controlled on at least one
    /// path: a reply's subject, Message-ID and References are copied out of
    /// the message being answered, and RFC 2047 decoding there can turn
    /// `=0D=0A` back into the CRLF that ends a header line. RFC 5322 §2.2.3
    /// admits no CR, LF or NUL in a field value, so they are dropped here —
    /// the one place every header of every outgoing message is assembled.
    /// Folding instead would be wrong: RFC 5322 folds with SP/TAB only, so a
    /// bare CRLF has to disappear rather than become a legal-looking wrap.
    private static func headerSafe(_ value: String) -> String {
        String(value.unicodeScalars.filter { scalar in
            scalar.value != 0x0A && scalar.value != 0x0D && scalar.value != 0x00
        })
    }

    private static func base64Lines(_ data: Data) -> String {
        let encoded = data.base64EncodedString()
        var lines: [String] = []
        var index = encoded.startIndex
        while index < encoded.endIndex {
            let end = encoded.index(index, offsetBy: 76, limitedBy: encoded.endIndex) ?? encoded.endIndex
            lines.append(String(encoded[index..<end]))
            index = end
        }
        return lines.joined(separator: "\r\n")
    }

    private static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private static let months = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]

    /// RFC 5322 date-time in UTC (`11 Sep 2026 09:36:08 +0000`). Hand-rolled:
    /// `DateFormatter` is not `Sendable`, and the format is fixed-width.
    static func dateHeader(_ date: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .weekday],
            from: date
        )
        let weekday = weekdays[((parts.weekday ?? 1) - 1) % 7]
        let month = months[((parts.month ?? 1) - 1) % 12]
        return String(
            format: "%@, %02d %@ %04d %02d:%02d:%02d +0000",
            weekday,
            parts.day ?? 1,
            month,
            parts.year ?? 1970,
            parts.hour ?? 0,
            parts.minute ?? 0,
            parts.second ?? 0
        )
    }
}
