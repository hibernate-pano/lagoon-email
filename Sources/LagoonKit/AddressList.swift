import Foundation

/// RFC 5322 address-list parsing, in one place.
///
/// ## Why this is shared
///
/// There were three independent comma-splitters in the product, and they
/// disagreed:
///
/// - the client split the `To:` line before handing it to the server,
/// - the IMAP header builder split the same line when it wrote the header,
/// - and the SMTP path split it again to build the envelope.
///
/// A comma is not always a separator: it may sit inside a quoted display
/// name (`"Smith, John" <j@x.com>`) or inside angle brackets.
/// Splitting naively turns one recipient into two, and the second half
/// (`Wei" <wei@example.com>`) is not an address at all — the server rejects
/// it, and the user is told the send failed without being told why.
///
/// The fix is not three better splitters; it is **one** splitter, used by
/// every layer that has to read an address list. It lives in `LagoonKit`
/// because both the client and the server need it, and the server's
/// provider-neutral layer must not reach up into the IMAP layer to borrow
/// a parser.
public enum AddressList {
    /// Splits an address list into its top-level pieces, display names
    /// included.
    ///
    /// Only a comma outside quotes and angle brackets separates two
    /// addresses. The pieces come back as they were written, minus the
    /// surrounding whitespace.
    public static func split(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var pieces: [String] = []
        var current = ""
        var inQuotes = false
        var angleDepth = 0
        var escaped = false

        for char in trimmed {
            if escaped {
                current.append(char)
                escaped = false
                continue
            }
            switch char {
            case "\\" where inQuotes:
                escaped = true
                current.append(char)
            case "\"":
                inQuotes.toggle()
                current.append(char)
            case "<":
                angleDepth += 1
                current.append(char)
            case ">":
                angleDepth = max(0, angleDepth - 1)
                current.append(char)
            case "," where !inQuotes && angleDepth == 0:
                pieces.append(current)
                current = ""
            default:
                current.append(char)
            }
        }
        if !current.isEmpty { pieces.append(current) }

        return pieces.compactMap { piece -> String? in
            let value = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
    }

    /// The bare `addr@host` of every address in the list.
    ///
    /// The display name is dropped: a forward-path (RFC 5321 `RCPT TO`) and
    /// a deliverable recipient list both need routable addresses, not
    /// labels. A piece whose shape is unparseable — a display name with no
    /// address — is skipped rather than emitted as a junk recipient.
    public static func bareAddresses(_ raw: String) -> [String] {
        split(raw).compactMap { value -> String? in
            if let open = value.lastIndex(of: "<"),
               let close = value.lastIndex(of: ">"),
               open < close {
                let address = value[value.index(after: open)..<close]
                    .trimmingCharacters(in: .whitespaces)
                return address.isEmpty ? nil : address
            }
            // No angle brackets. Strip the RFC 5322 comment form
            // ("bob@example.com (Bob)") and require what is left to be an
            // address: a piece with no "@" is a display name with no
            // address, and passing it on as a recipient would be sending to
            // nothing.
            let bare = stripComment(value)
            guard bare.contains("@"), !bare.contains(" ") else { return nil }
            return bare
        }
    }

    /// Removes a trailing RFC 5322 comment: `bob@example.com (Bob)` →
    /// `bob@example.com`.
    ///
    /// Only a comment that runs to the end of the piece is removed; a
    /// parenthesis inside an address would not be a comment, and guessing
    /// would corrupt a valid address.
    private static func stripComment(_ value: String) -> String {
        guard let open = value.lastIndex(of: "("),
              value.lastIndex(of: ")") == value.index(after: open) else { return value }
        return String(value[..<open]).trimmingCharacters(in: .whitespaces)
    }
}
