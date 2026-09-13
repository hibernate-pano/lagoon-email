import Foundation

/// Builds the RFC 5322 message that both write paths send: SMTP flushes these
/// bytes verbatim, Gmail wraps them in `raw`. Everything is CRLF-framed and the
/// body is base64, so no line can ever need dot-stuffing or folding.
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
        lines.append("To: \(address(outbound.to, name: nil))")
        lines.append("Subject: \(subject)")
        lines.append("Date: \(Self.dateHeader())")
        lines.append("Message-ID: \(messageId)")
        if includeThreading, let inReplyTo = outbound.inReplyTo, !inReplyTo.isEmpty {
            lines.append("In-Reply-To: \(inReplyTo)")
        }
        if includeThreading, let references = outbound.references, !references.isEmpty {
            lines.append("References: \(references)")
        }
        lines.append("MIME-Version: 1.0")
        lines.append("Content-Type: text/plain; charset=UTF-8")
        lines.append("Content-Transfer-Encoding: base64")

        var message = lines.joined(separator: "\r\n")
        message += "\r\n\r\n"
        message += base64Lines(Data(outbound.body.utf8))
        message += "\r\n"
        return Data(message.utf8)
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
        guard let name, !name.isEmpty else { return "<\(email)>" }
        guard name.allSatisfy(\.isASCII) else {
            return "=?UTF-8?B?\(Data(name.utf8).base64EncodedString())?= <\(email)>"
        }
        return "\"\(name)\" <\(email)>"
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
