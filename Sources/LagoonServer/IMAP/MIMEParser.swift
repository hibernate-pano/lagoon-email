import Foundation
import LagoonKit

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

    /// Hard caps on extracted content. Generous enough for almost any
    /// legitimate message, low enough to bound a hostile one. Truncation
    /// surfaces as `hasMore = true` on the returned `ParsedMessage`.
    public static let textCap = 200_000      // 200 KB
    public static let htmlCap = 5_000_000    // 5 MB

    /// Plain text of the preferred body part. Kept for the v0.2.0 surface
    /// (and the existing test suite); internally it just reads `.text` from
    /// `parse(message:)`.
    public static func plainText(from message: Data) -> String {
        parse(message: message).text
    }

    /// Extract the recipient list from a `To:` / `Cc:` header value.
    ///
    /// RFC 5322 address lists are comma-separated, but commas can legally
    /// appear inside a quoted display name (`"Smith, John" <j@x.com>`) and
    /// inside angle brackets. We split only on top-level commas (outside
    /// quotes and angle brackets) and pull the bare `addr@host` out of each
    /// piece — a bare address with no angle brackets is returned as-is.
    ///
    /// Only addresses travel: the display name is dropped because
    /// reply-all needs routable recipients, not labels. Pieces whose shape
    /// is unparseable (a stray display name with no address) are skipped
    /// rather than emitted as junk recipients.
    public static func parseAddressList(_ raw: String) -> [String] {
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
            guard !value.isEmpty else { return nil }
            if let open = value.lastIndex(of: "<"),
               let close = value.lastIndex(of: ">"),
               open < close {
                let address = value[value.index(after: open)..<close]
                    .trimmingCharacters(in: .whitespaces)
                return address.isEmpty ? nil : address
            }
            // No angle brackets: the whole piece should be a bare address.
            // Reject anything with internal whitespace.
            guard !value.contains(" ") else { return nil }
            return value
        }
    }

    /// Full parse: plain text, HTML (when present), and every attachment's
    /// *metadata*. The IMAP part path is preserved as `id` so the route
    /// layer can re-fetch a single part via `BODY[1.2]`.
    ///
    /// `decodeAttachmentBytes` defaults to `false` because the body route
    /// strips attachment bytes before the wire response — decoding them
    /// was pure waste (a 5 MB attachment decoded on every message open).
    /// The attachment download route passes `true` because it needs the
    /// bytes.
    public static func parse(
        message: Data,
        decodeAttachmentBytes: Bool = false
    ) -> ParsedMessage {
        let (header, body) = splitHeadAndBody(message)
        let headers = parseHeaderBlock(header)
        let result = parsePart(
            headers: headers,
            body: body,
            depth: 0,
            partPath: "1",
            decodeAttachmentBytes: decodeAttachmentBytes
        )
        let text = result.text ?? (result.html.map { HTMLText.strip($0) } ?? "")
        return ParsedMessage(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            html: result.html,
            attachments: result.attachments,
            hasMore: result.hasMore,
            to: parseAddressList(headers["to"] ?? ""),
            cc: parseAddressList(headers["cc"] ?? "")
        )
    }

    public struct ParsedMessage {
        public var text: String
        public var html: String?
        public var attachments: [ParsedAttachment]
        public var hasMore: Bool
        /// Recipient addresses from `To:`, addresses only.
        public var to: [String]
        /// Recipient addresses from `Cc:`, addresses only.
        public var cc: [String]

        public init(
            text: String,
            html: String?,
            attachments: [ParsedAttachment],
            hasMore: Bool,
            to: [String] = [],
            cc: [String] = []
        ) {
            self.text = text
            self.html = html
            self.attachments = attachments
            self.hasMore = hasMore
            self.to = to
            self.cc = cc
        }
    }

    /// Internal representation of a part. The route layer converts this to
    /// the wire `Attachment` by stripping `data` (the client fetches bytes
    /// via the dedicated attachment endpoint).
    public struct ParsedAttachment {
        public var id: String
        public var filename: String?
        public var mimeType: String
        public var size: Int
        public var contentId: String?
        public var disposition: Attachment.Disposition
        public var data: Data

        public init(
            id: String,
            filename: String?,
            mimeType: String,
            size: Int,
            contentId: String?,
            disposition: Attachment.Disposition,
            data: Data
        ) {
            self.id = id
            self.filename = filename
            self.mimeType = mimeType
            self.size = size
            self.contentId = contentId
            self.disposition = disposition
            self.data = data
        }
    }

    private struct ParseResult {
        var text: String?
        var html: String?
        var attachments: [ParsedAttachment] = []
        var hasMore: Bool = false
    }

    /// Recursive descent over a single MIME part. `partPath` is the IMAP
    /// dotted notation ("1", "1.2", "1.2.3") that re-fetches the same bytes
    /// via `BODY[path]`.
    private static func parsePart(
        headers: [String: String],
        body: Data,
        depth: Int,
        partPath: String,
        decodeAttachmentBytes: Bool
    ) -> ParseResult {
        guard depth < maxDepth else { return ParseResult() }
        let (mimeType, parameters) = parseContentType(headers["content-type"])
        let encoding = (headers["content-transfer-encoding"] ?? "")
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        let dispositionRaw = (headers["content-disposition"] ?? "").lowercased()
        let filename = parseFilename(headers: headers)
        let contentId = stripAngleBrackets(headers["content-id"] ?? headers["Content-ID"] ?? "")

        if mimeType == "message/rfc822" {
            let (innerHeader, innerBody) = splitHeadAndBody(body)
            return parsePart(
                headers: parseHeaderBlock(innerHeader),
                body: innerBody,
                depth: depth + 1,
                partPath: partPath,
                decodeAttachmentBytes: decodeAttachmentBytes
            )
        }

        if mimeType.hasPrefix("multipart/") {
            guard let boundary = parameters["boundary"], !boundary.isEmpty else {
                return ParseResult()
            }
            let parts = splitParts(body, boundary: boundary)
            var result = ParseResult()
            for (index, part) in parts.enumerated() {
                let childPath = "\(partPath).\(index + 1)"
                let child = parsePart(
                    headers: part.headers,
                    body: part.body,
                    depth: depth + 1,
                    partPath: childPath,
                    decodeAttachmentBytes: decodeAttachmentBytes
                )
                if result.text == nil { result.text = child.text }
                if result.html == nil { result.html = child.html }
                result.attachments.append(contentsOf: child.attachments)
                if child.hasMore { result.hasMore = true }
            }
            // For `multipart/alternative` we keep whichever text candidate we
            // saw first. The recurse order is the source-order of the parts,
            // which most clients put plain-first — but the spec lets them put
            // HTML first, so also pick text over html explicitly below.
            if mimeType == "multipart/alternative",
               result.text == nil, let html = result.html {
                result.text = HTMLText.strip(html)
            }
            return result
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

        if mimeType.hasPrefix("text/") {
            // Decide: body candidate or attachment? An explicit
            // `Content-Disposition: attachment` on a text part is still
            // treated as an attachment (rare but legal).
            if dispositionRaw.hasPrefix("attachment") {
                return attachmentResult(
                    partPath: partPath,
                    filename: filename,
                    mimeType: mimeType,
                    decoded: decoded,
                    encoded: body,
                    encoding: encoding,
                    decodeBytes: decodeAttachmentBytes,
                    contentId: contentId,
                    disposition: .attachment
                )
            }
            return textResult(
                mimeType: mimeType,
                charset: parameters["charset"],
                data: decoded,
                contentId: contentId
            )
        }

        // Non-text leaf: everything else is an attachment. Images without an
        // explicit disposition default to `.inline` so the HTML renderer
        // can resolve `cid:` references even when the sender forgot the
        // disposition.
        let disposition: Attachment.Disposition
        if dispositionRaw.hasPrefix("inline") {
            disposition = .inline
        } else if dispositionRaw.hasPrefix("attachment") {
            disposition = .attachment
        } else if mimeType.hasPrefix("image/") {
            disposition = .inline
        } else {
            disposition = .attachment
        }
        return attachmentResult(
            partPath: partPath,
            filename: filename,
            mimeType: mimeType,
            decoded: decoded,
            encoded: body,
            encoding: encoding,
            decodeBytes: decodeAttachmentBytes,
            contentId: contentId,
            disposition: disposition
        )
    }

    private static func textResult(
        mimeType: String,
        charset: String?,
        data: Data,
        contentId: String?
    ) -> ParseResult {
        var result = ParseResult()
        let charset = (charset ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let decoded = decodeCharset(data, charset: charset.isEmpty ? nil : charset)
        if mimeType == "text/html" {
            if decoded.count > htmlCap {
                result.html = String(decoded.prefix(htmlCap))
                result.hasMore = true
            } else {
                result.html = decoded
            }
        } else {
            // text/plain and any other text/* lands here.
            if decoded.count > textCap {
                result.text = String(decoded.prefix(textCap)) + "\n[…truncated, original \(decoded.count) bytes]"
                result.hasMore = true
            } else {
                result.text = decoded
            }
        }
        return result
    }

    private static func attachmentResult(
        partPath: String,
        filename: String?,
        mimeType: String,
        decoded: Data,
        encoded: Data,
        encoding: String,
        decodeBytes: Bool,
        contentId: String?,
        disposition: Attachment.Disposition
    ) -> ParseResult {
        var result = ParseResult()
        // Decoding the bytes is the expensive step (a 5 MB PDF costs a
        // few hundred ms of BASE64 work + allocation). When the caller
        // only needs metadata we skip it and estimate the size from the
        // encoded length instead.
        let data: Data
        let size: Int
        if decodeBytes {
            data = decoded
            size = decoded.count
        } else {
            data = Data()
            size = estimatedSize(encoding: encoding, encoded: encoded)
        }
        result.attachments.append(ParsedAttachment(
            id: partPath,
            filename: filename,
            mimeType: mimeType,
            size: size,
            contentId: contentId,
            disposition: disposition,
            data: data
        ))
        return result
    }

    /// Decoded byte count without paying for the decode. BASE64 is a
    /// 4→3 expansion (minus padding); QP shrinks by roughly the number
    /// of `=XX` escapes, which we cannot know without scanning — the
    /// estimate is close enough for a UI size label. 7bit/binary are
    /// stored as-is.
    static func estimatedSize(encoding: String, encoded: Data) -> Int {
        switch encoding {
        case "base64":
            let padding = encoded.suffix(2).reduce(0) { $0 + ($1 == UInt8(ascii: "=") ? 1 : 0) }
            return max(0, encoded.count * 3 / 4 - padding)
        case "quoted-printable":
            // Scan for `=` without decoding: each escape removes 2 bytes.
            var escapes = 0
            var index = encoded.startIndex
            while index < encoded.endIndex, encoded[index] == UInt8(ascii: "=") {
                escapes += 1
                index = encoded.index(index, offsetBy: 3, limitedBy: encoded.endIndex) ?? encoded.endIndex
            }
            return max(0, encoded.count - escapes * 2)
        default:
            return encoded.count
        }
    }

    /// Filename from `Content-Disposition: attachment; filename=...` or
    /// `Content-Type: ...; name=...`. The two are interchangeable per RFC 2183
    /// and the spec sample we actually see uses either one.
    private static func parseFilename(headers: [String: String]) -> String? {
        let disposition = headers["content-disposition"] ?? ""
        if let name = headerParameter(in: disposition, name: "filename") ?? headerParameter(in: disposition, name: "filename*") {
            return decodeRFC2047(name)
        }
        let type = headers["content-type"] ?? ""
        if let name = headerParameter(in: type, name: "name") {
            return decodeRFC2047(name)
        }
        return nil
    }

    /// `name="value"` / `name=value` / `name*=RFC 2047 encoded` — the value
    /// may be quoted (with backslash-escaped chars) or bare. We accept the
    /// common forms and tolerate the rest by returning nil.
    private static func headerParameter(in header: String, name: String) -> String? {
        for segment in header.split(separator: ";") {
            let trimmed = segment.trimmingCharacters(in: .whitespaces)
            let prefix = "\(name)="
            guard trimmed.lowercased().hasPrefix(prefix.lowercased()) else { continue }
            var value = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// `Content-ID: <image001@example.com>` → `image001@example.com`.
    /// Angle brackets are required by RFC 2392 but some clients omit them.
    private static func stripAngleBrackets(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("<") && trimmed.hasSuffix(">") {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
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
