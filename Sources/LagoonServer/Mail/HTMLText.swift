import Foundation

/// HTML → text helpers shared by the Gmail payload extractor and the IMAP MIME
/// parser. Kept free of any transport concerns: pure string in, string out.
public enum HTMLText {
    /// Remove scripts/styles/tags, decode entities, collapse whitespace.
    public static func strip(_ html: String) -> String {
        var text = html
        text = text.replacingOccurrences(
            of: "(?is)<script[^>]*>.*?</script>",
            with: " ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "(?is)<style[^>]*>.*?</style>",
            with: " ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "(?is)<[^>]+>",
            with: " ",
            options: .regularExpression
        )
        text = decodeEntities(text)
        return collapseWhitespace(text)
    }

    private static let namedEntities: [String: String] = [
        "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
        "&quot;": "\"", "&apos;": "'", "&#39;": "'",
        "&mdash;": "\u{2014}", "&ndash;": "\u{2013}", "&hellip;": "\u{2026}",
        "&rsquo;": "\u{2019}", "&lsquo;": "\u{2018}",
        "&ldquo;": "\u{201C}", "&rdquo;": "\u{201D}",
        "&bull;": "\u{2022}", "&middot;": "\u{00B7}",
        "&copy;": "\u{00A9}", "&reg;": "\u{00AE}", "&trade;": "\u{2122}",
        "&euro;": "\u{20AC}", "&pound;": "\u{00A3}", "&yen;": "\u{00A5}",
        "&deg;": "\u{00B0}"
    ]

    /// Named entities plus numeric `&#123;` / `&#x1F600;` forms. Unknown
    /// entities are left untouched.
    public static func decodeEntities(_ value: String) -> String {
        var text = value
        for (entity, replacement) in namedEntities {
            text = text.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        guard let regex = try? NSRegularExpression(pattern: "&#(x?[0-9A-Fa-f]+);") else {
            return text
        }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        // Replace back-to-front so earlier ranges stay valid.
        for match in matches.reversed() {
            guard match.numberOfRanges == 2,
                  let range = Range(match.range, in: text),
                  let digitsRange = Range(match.range(at: 1), in: text)
            else { continue }
            let digits = String(text[digitsRange])
            let scalarValue: UInt32?
            if digits.lowercased().hasPrefix("x") {
                scalarValue = UInt32(digits.dropFirst(), radix: 16)
            } else {
                scalarValue = UInt32(digits)
            }
            guard let value = scalarValue, let scalar = Unicode.Scalar(value) else { continue }
            text.replaceSubrange(range, with: String(Character(scalar)))
        }
        return text
    }

    public static func collapseWhitespace(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
