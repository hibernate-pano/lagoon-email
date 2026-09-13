import Foundation

/// Self-contained RFC 5322 / MIME reader: enough of the format to turn an IMAP
/// `BODY[]` fetch into readable plain text, and nothing more (spec §3.6).
///
/// Nothing here throws. Mailboxes contain truncated, mislabeled and outright
/// broken messages, and the contract is that the worst case is a shorter
/// string — never a failed request.
public enum MIMEParser {
    /// Hard stop on nesting depth: malformed input can otherwise recurse
    /// forever (a part claiming itself as its own child).
    private static let maxDepth = 6

    // MARK: - Headers

    /// Header block → lowercase name → decoded value. Keys of repeated headers
    /// collapse to the last occurrence; RFC 2047 encoded words are decoded and
    /// continuation lines are unfolded.
    public static func decodeHeaders(_ raw: Data) -> [String: String] {
        let (header, _) = splitHeadAndBody(raw)
        return parseHeaderBlock(header).mapValues(decodeRFC2047)
    }

    /// Header block → lowercase name → raw value (unfolded, not decoded).
    /// Structural headers (Content-Type, boundary) must be read from here.
    static func parseHeaderBlock(_ data: Data) -> [String: String] {
        var headers: [String: String] = [:]
        var name: String?
        var value = ""

        func flush() {
            if let field = name {
                headers[field] = value.trimmingCharacters(in: .whitespaces)
            }
            name = nil
            value = ""
        }

        for line in headerText(data).split(whereSeparator: \.isNewline) {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                if name != nil {
                    value += " " + line.trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            flush()
            guard let colon = line.firstIndex(of: ":") else { continue }
            let field = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !field.isEmpty else { continue }
            name = field
            value = String(line[line.index(after: colon)...])
        }
        flush()
        return headers
    }

    /// Header bytes → text without ever losing bytes: UTF-8 when it is valid
    /// (raw 8-bit UTF-8 headers are common), otherwise byte-preserving Latin-1.
    private static func headerText(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
    }

    /// RFC 2047 `=?charset?B|Q?...?=` words: decoded in place, with the
    /// whitespace between two adjacent encoded words dropped (RFC 2047 §6.2).
    public static func decodeRFC2047(_ value: String) -> String {
        guard value.contains("=?") else { return value }
        guard let regex = try? NSRegularExpression(
            pattern: "=\\?([^?\\s]+)\\?([BbQq])\\?([^?]*)\\?="
        ) else { return value }

        let ns = value as NSString
        let matches = regex.matches(in: value, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return value }

        var result = ""
        var cursor = value.startIndex
        var previousWasEncoded = false
        for match in matches {
            guard let full = Range(match.range, in: value) else { continue }
            let gap = String(value[cursor..<full.lowerBound])
            let isFoldingGap = previousWasEncoded
                && gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !isFoldingGap {
                result += gap
            }
            let charset = ns.substring(with: match.range(at: 1))
            let encoding = ns.substring(with: match.range(at: 2))
            let payload = ns.substring(with: match.range(at: 3))
            result += decodeEncodedWord(payload, encoding: encoding, charset: charset)
                ?? String(value[full])
            cursor = full.upperBound
            previousWasEncoded = true
        }
        result += String(value[cursor...])
        return result
    }

    private static func decodeEncodedWord(_ payload: String, encoding: String, charset: String) -> String? {
        let bytes: Data?
        switch encoding.uppercased() {
        case "B":
            bytes = base64Decode(payload)
        case "Q":
            // In Q-encoding `_` stands for a space; anything literal is `=5F`.
            let spaced = payload.replacingOccurrences(of: "_", with: " ")
            bytes = decodeQuotedPrintable(Data(spaced.utf8))
        default:
            return nil
        }
        guard let bytes else { return nil }
        return decodeCharset(bytes, charset: charset)
    }

    // MARK: - Body

    /// Plain text of the preferred body part (spec §3.6). `text/plain` wins
    /// over `text/html`; anything unreadable degrades to "".
    public static func plainText(from message: Data) -> String {
        let (header, body) = splitHeadAndBody(message)
        let headers = parseHeaderBlock(header)
        guard let candidate = preferredContent(headers: headers, body: body, depth: 0) else {
            return ""
        }
        let text = candidate.isHTML ? HTMLText.strip(candidate.text) : candidate.text
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct Candidate {
        var text: String
        var isHTML: Bool
    }

    private static func preferredContent(
        headers: [String: String],
        body: Data,
        depth: Int
    ) -> Candidate? {
        guard depth < maxDepth else { return nil }
        // Attachments are out of scope: skip them rather than summarize a PDF.
        if (headers["content-disposition"] ?? "").lowercased().hasPrefix("attachment") {
            return nil
        }

        let (mimeType, parameters) = parseContentType(headers["content-type"])
        let encoding = (headers["content-transfer-encoding"] ?? "")
            .trimmingCharacters(in: .whitespaces)
            .lowercased()

        if mimeType == "message/rfc822" {
            let (innerHeader, innerBody) = splitHeadAndBody(body)
            return preferredContent(
                headers: parseHeaderBlock(innerHeader),
                body: innerBody,
                depth: depth + 1
            )
        }

        if mimeType.hasPrefix("multipart/") {
            guard let boundary = parameters["boundary"], !boundary.isEmpty else { return nil }
            let parts = splitParts(body, boundary: boundary)
            var htmlFallback: Candidate?
            for part in parts {
                guard let candidate = preferredContent(
                    headers: part.headers,
                    body: part.body,
                    depth: depth + 1
                ) else { continue }
                guard mimeType == "multipart/alternative" else { return candidate }
                if !candidate.isHTML { return candidate }
                if htmlFallback == nil { htmlFallback = candidate }
            }
            return htmlFallback
        }

        let decoded: Data
        switch encoding {
        case "base64":
            decoded = base64Decode(data: body) ?? body
        case "quoted-printable":
            decoded = decodeQuotedPrintable(body)
        default:
            decoded = body
        }

        switch mimeType {
        case "text/plain":
            return Candidate(text: decodeCharset(decoded, charset: parameters["charset"]), isHTML: false)
        case "text/html":
            return Candidate(text: decodeCharset(decoded, charset: parameters["charset"]), isHTML: true)
        default:
            return nil
        }
    }

    /// First blank line splits headers from body; LF-only messages are accepted
    /// alongside CRLF ones.
    static func splitHeadAndBody(_ data: Data) -> (header: Data, body: Data) {
        for separator in [Data("\r\n\r\n".utf8), Data("\n\n".utf8)] {
            if let range = data.range(of: separator) {
                return (data[data.startIndex..<range.lowerBound], data[range.upperBound...])
            }
        }
        return (data, Data())
    }

    /// `multipart` body → its parts, split on `--boundary` delimiters.
    /// The preamble and epilogue are discarded; a missing closing delimiter is
    /// tolerated (the last part is returned as-is).
    private static func splitParts(
        _ body: Data,
        boundary: String
    ) -> [(headers: [String: String], body: Data)] {
        var parts: [(headers: [String: String], body: Data)] = []
        var normalized = Data("\r\n".utf8)
        normalized.append(body)
        let delimiter = Data("\r\n--\(boundary)".utf8)

        var searchStart = normalized.startIndex
        var partStart: Data.Index?
        while let range = normalized.range(of: delimiter, options: [], in: searchStart..<normalized.endIndex) {
            if let start = partStart {
                parts.append(makePart(Data(normalized[start..<range.lowerBound])))
                partStart = nil
            }
            // `--boundary--` is the closing delimiter, `--boundary` alone the
            // start of the next part: the two bytes after the match decide.
            if normalized[range.upperBound...].starts(with: Data("--".utf8)) {
                break
            }
            var contentStart = range.upperBound
            if normalized[contentStart...].starts(with: Data("\r\n".utf8)) {
                contentStart = normalized.index(contentStart, offsetBy: 2)
            } else if normalized[contentStart...].starts(with: Data("\n".utf8)) {
                contentStart = normalized.index(after: contentStart)
            }
            partStart = contentStart
            searchStart = contentStart
        }
        if let start = partStart {
            parts.append(makePart(Data(normalized[start...])))
        }
        return parts
    }

    private static func makePart(_ data: Data) -> (headers: [String: String], body: Data) {
        let (header, body) = splitHeadAndBody(data)
        return (parseHeaderBlock(header), body)
    }

    /// `text/plain; charset="utf-8"; boundary=x` → (`text/plain`, params).
    /// Parameters are split on `;`, so a quoted value containing a semicolon
    /// would be misread — no sender in practice does that, and guessing wrong
    /// only costs a charset or a boundary.
    static func parseContentType(_ value: String?) -> (mimeType: String, parameters: [String: String]) {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else {
            return ("text/plain", [:])
        }
        let segments = value.split(separator: ";")
        let mimeType = segments.first?
            .trimmingCharacters(in: .whitespaces)
            .lowercased() ?? "text/plain"
        var parameters: [String: String] = [:]
        for segment in segments.dropFirst() {
            let pair = segment.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let name = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            let parameterValue = pair[1]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !name.isEmpty else { continue }
            parameters[name] = parameterValue
        }
        return (mimeType, parameters)
    }

    // MARK: - Transfer encodings and charsets

    /// Tolerant base64: whitespace (including folded lines) is ignored and
    /// missing padding is added. Returns nil for padding-only input, which
    /// `Data(base64Encoded:)` would otherwise turn into a NUL byte.
    static func base64Decode(_ value: String) -> Data? {
        var normalized = value.components(separatedBy: .whitespacesAndNewlines).joined()
        guard normalized.contains(where: { $0 != "=" }) else { return nil }
        let remainder = normalized.count % 4
        if remainder > 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: normalized)
    }

    static func base64Decode(data: Data) -> Data? {
        base64Decode(String(decoding: data, as: UTF8.self))
    }

    /// `=XX` hex escapes and soft line breaks (`=` at end of line). Invalid
    /// escapes are passed through as literal text.
    static func decodeQuotedPrintable(_ data: Data) -> Data {
        var output = Data()
        var index = data.startIndex
        while index < data.endIndex {
            let byte = data[index]
            guard byte == UInt8(ascii: "=") else {
                output.append(byte)
                index = data.index(after: index)
                continue
            }
            let next = data.index(after: index)
            guard next < data.endIndex else {
                output.append(byte)
                index = next
                continue
            }
            if data[next] == UInt8(ascii: "\n") {
                index = data.index(after: next)
                continue
            }
            if data[next] == UInt8(ascii: "\r") {
                let afterCR = data.index(after: next)
                if afterCR < data.endIndex, data[afterCR] == UInt8(ascii: "\n") {
                    index = data.index(after: afterCR)
                    continue
                }
            }
            let high = data.index(after: next)
            if high < data.endIndex,
               let first = hexValue(data[next]),
               let second = hexValue(data[high]) {
                output.append(first << 4 | second)
                index = data.index(after: high)
                continue
            }
            output.append(byte)
            index = next
        }
        return output
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        default: return nil
        }
    }

    /// Bytes → text for the declared charset. Unknown charsets are handed to
    /// the system's IANA table; the final fallback never fails, so the caller
    /// always gets something printable.
    static func decodeCharset(_ data: Data, charset: String?) -> String {
        let name = (charset ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch name {
        case "", "utf-8", "utf8":
            if let text = String(data: data, encoding: .utf8) { return text }
            // The `BODY[]<0.N>` window is cut at an arbitrary byte, so a UTF-8
            // body can end in the middle of a multi-byte sequence. Strict
            // decoding then fails for the whole buffer, and falling straight
            // through to the Latin-1 fallback at the bottom turns every CJK
            // byte into two mojibake characters. Decode leniently (invalid
            // bytes become U+FFFD) and keep that result only when almost
            // nothing was replaced. A truncated tail costs one replacement
            // scalar; genuine Latin-1 (or binary) text replaces every
            // non-ASCII byte, so a 1% cut separates the two cleanly without
            // needing a tuned threshold.
            let lenient = String(decoding: data, as: UTF8.self)
            let scalarCount = lenient.unicodeScalars.count
            let replacementCount = lenient.unicodeScalars.reduce(0) {
                $0 + ($1.value == 0xFFFD ? 1 : 0)
            }
            if scalarCount > 0, replacementCount * 100 <= scalarCount {
                return lenient
            }
        case "gbk", "gb2312", "gb-2312", "gb_2312", "x-gbk", "cp936", "ms936", "gb18030":
            if let text = String(data: data, encoding: gb18030) { return text }
        case "iso-8859-1", "iso8859-1", "latin-1", "latin1", "us-ascii", "ascii", "windows-1252":
            if let text = String(data: data, encoding: .isoLatin1) { return text }
        default:
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cfEncoding != kCFStringEncodingInvalidId {
                let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
                if let text = String(data: data, encoding: String.Encoding(rawValue: UInt(nsEncoding))) {
                    return text
                }
            }
        }
        // Undecodable bytes: Latin-1 keeps every byte, UTF-8 decoding replaces
        // only the invalid ones.
        return String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
    }

    /// GB18030 covers GBK and GB2312 as subsets, so one decoder serves all
    /// three labels (spec §3.6).
    static let gb18030: String.Encoding = {
        // `rawValue` is a CFIndex; the conversion API wants CFStringEncoding.
        let cfEncoding = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        return String.Encoding(
            rawValue: UInt(CFStringConvertEncodingToNSStringEncoding(cfEncoding))
        )
    }()
}
