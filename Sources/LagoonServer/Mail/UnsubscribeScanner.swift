import Foundation

/// Unsubscribe link discovery for one-click unsubscribe (一键退订).
///
/// Two sources, in the order the endpoint tries them:
/// 1. The `List-Unsubscribe` header (RFC 2369 / RFC 8058) — harvested at
///    sync time into `message_headers.unsubscribe_links`, plus a live
///    provider read at click time (the pre-existing primary path).
/// 2. The HTML body — anchors (and, as a second pass, bare URLs) whose text
///    or URL smells like an unsubscribe target. Harvested the first time
///    the body is fetched, extracted on demand at click time.
///
/// **Security:** body URLs are attacker-controlled — any candidate handed to
/// `URLSession` must pass `isSafe(url:)` first (scheme allowlist + every
/// resolved address public). That is the SSRF guard; the header path gets
/// the same check even though it is lower-risk.
public enum UnsubscribeScanner {
    /// Keywords that make a link an unsubscribe candidate. English matches
    /// are case-insensitive via lowercasing; Chinese has no case.
    static let keywords = [
        "unsubscribe", "un-subscribe", "opt-out", "optout", "opt out",
        "list-unsubscribe", "stop receiving", "leave the program",
        "email preferences", "contact preferences",
        "退订", "退訂", "取消订阅", "取消訂閱", "撤销订阅", "不再接收", "停止接收",
    ]

    // MARK: - Header (List-Unsubscribe)

    /// A `List-Unsubscribe` header value → candidate URLs, in header order.
    /// Standard form is angle-bracketed (`<https://…>, <mailto:…>`); bare
    /// URLs are picked up too because some senders omit brackets. Header
    /// folding (CRLF + WSP) is unfolded by stripping CR/LF.
    public static func headerLinks(_ raw: String) -> [String] {
        var candidates: [String] = []
        for pattern in [#"(<[^>]+>)"#, #"(https?://[^\s<>"']+)"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let ns = raw as NSString
            regex.enumerateMatches(in: raw, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let match, match.numberOfRanges >= 2 else { return }
                var value = ns.substring(with: match.range(at: 1))
                value = value
                    .replacingOccurrences(of: "<", with: "")
                    .replacingOccurrences(of: ">", with: "")
                    .replacingOccurrences(of: "\r", with: "")
                    .replacingOccurrences(of: "\n", with: "")
                    .trimmingCharacters(in: .whitespaces)
                value = trimTrailingPunctuation(value)
                guard !value.isEmpty, let url = URL(string: value),
                      let scheme = url.scheme?.lowercased(),
                      ["http", "https", "mailto"].contains(scheme)
                else { return }
                if !candidates.contains(value) { candidates.append(value) }
            }
        }
        return Array(candidates.prefix(10))
    }

    // MARK: - Body (HTML / plain text)

    /// Candidate unsubscribe URLs in a message body, best first: anchors
    /// whose text or href matches a keyword score higher than a bare URL
    /// that merely sits near one. Relative URLs and foreign schemes are
    /// dropped; HTML entities in hrefs are decoded (`&amp;` is ubiquitous).
    public static func bodyLinks(in html: String) -> [String] {
        var scored: [(url: String, score: Int, order: Int)] = []

        // Pass 1: <a href="…">text</a>
        let anchorPattern = #"<a\b[^>]*?href\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>"#
        if let regex = try? NSRegularExpression(
            pattern: anchorPattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) {
            let ns = html as NSString
            regex.enumerateMatches(in: html, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let match, match.numberOfRanges >= 3 else { return }
                let href = decodeEntities(
                    ns.substring(with: match.range(at: 1))
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                let text = stripTags(
                    ns.substring(with: match.range(at: 2))
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let url = normalizedWebURL(href) else { return }
                var score = 0
                if containsKeyword(text) { score = 2 }
                if score == 0, containsKeyword(href) { score = 1 }
                guard score > 0 else { return }
                scored.append((url, score, scored.count))
            }
        }

        // Pass 2: bare URLs with a keyword within ±80 characters — plain-text
        // newsletters put the link next to the sentence, not in an anchor.
        let barePattern = #"https?://[^\s<>"']+"#
        if let regex = try? NSRegularExpression(pattern: barePattern, options: [.caseInsensitive]) {
            let ns = html as NSString
            regex.enumerateMatches(in: html, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let match else { return }
                let raw = ns.substring(with: match.range)
                guard let url = normalizedWebURL(decodeEntities(raw)) else { return }
                // Keyword window around the match (±80 utf-16 units, clamped).
                let loc = max(0, match.range.location - 80)
                let end = min(ns.length, match.range.location + match.range.length + 80)
                let window = ns.substring(with: NSRange(location: loc, length: end - loc)).lowercased()
                guard containsKeyword(window) else { return }
                scored.append((url, 1, scored.count))
            }
        }

        let ranked = scored.sorted { lhs, rhs in
            lhs.score != rhs.score ? lhs.score > rhs.score : lhs.order < rhs.order
        }
        var seen = Set<String>()
        var out: [String] = []
        for item in ranked where !seen.contains(item.url) && out.count < 10 {
            seen.insert(item.url)
            out.append(item.url)
        }
        return out
    }

    // MARK: - Safety (SSRF guard)

    /// Whether the server may fetch this URL to complete an unsubscribe.
    /// http(s) only; loopback / RFC1918 / link-local / CGNAT / ULA /
    /// multicast IPv4+v6 (literal or via DNS) are rejected. Every resolved
    /// address must be public.
    ///
    /// ponytail: DNS is checked once at decision time, not pinned for the
    /// connection — a rebind window remains, acceptable because the server
    /// binds loopback-only in this deployment.
    public static func isSafe(url: URL) async -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        let bare = host.hasPrefix("[") && host.hasSuffix("]")
            ? String(host.dropFirst().dropLast())
            : host
        if bare == "localhost" || bare.hasSuffix(".localhost") || bare.hasSuffix(".local") {
            return false
        }
        if let literal = parseIP(bare) {
            return isPublicAddress(literal)
        }
        let resolved = await resolve(bare)
        guard !resolved.isEmpty else { return false }
        return resolved.allSatisfy { isPublicAddress($0) }
    }

    // MARK: - Internals

    static func normalizedWebURL(_ raw: String) -> String? {
        let trimmed = trimTrailingPunctuation(
            raw.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false
        else { return nil }
        return trimmed
    }

    /// Sentence-final punctuation a greedy URL regex swallows (`…/u.` or
    /// `…/u),`); unsubscribe URLs are token-shaped so this is safe.
    static func trimTrailingPunctuation(_ s: String) -> String {
        var out = s
        while let last = out.last, ".,;:!?)]}".contains(last) {
            out.removeLast()
        }
        return out
    }

    static func containsKeyword(_ s: String) -> Bool {
        let lower = s.lowercased()
        return keywords.contains { lower.contains($0) }
    }

    static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
    }

    /// Minimal HTML entity decoding — enough to recover an href that used
    /// `&amp;` (universal in real newsletter links). `&amp;` runs last so a
    /// literal `&amp;lt;` decodes once, not twice.
    static func decodeEntities(_ s: String) -> String {
        var out = s
        let named = [
            ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"), ("&#x27;", "'"),
            ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"),
        ]
        for (entity, chars) in named {
            out = out.replacingOccurrences(of: entity, with: chars)
        }
        // Numeric character references: &#NN; / &#xHH;
        if let regex = try? NSRegularExpression(pattern: #"&#x([0-9a-fA-F]+);"#) {
            out = regexReplacing(in: out, regex: regex) { digits in
                guard let v = UInt32(digits, radix: 16), let s = Unicode.Scalar(v) else { return nil }
                return String(s)
            }
        }
        if let regex = try? NSRegularExpression(pattern: #"&#([0-9]+);"#) {
            out = regexReplacing(in: out, regex: regex) { digits in
                guard let v = UInt32(digits), let s = Unicode.Scalar(v) else { return nil }
                return String(s)
            }
        }
        out = out.replacingOccurrences(of: "&amp;", with: "&")
        return out
    }

    private static func regexReplacing(
        in string: String,
        regex: NSRegularExpression,
        transform: (String) -> String?
    ) -> String {
        let ns = string as NSString
        var out = ""
        var cursor = 0
        regex.enumerateMatches(in: string, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            let digits = ns.substring(with: match.range(at: 1))
            guard let replacement = transform(digits) else { return }
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            out += replacement
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// Literal IPv4/IPv6 → address bytes (4 or 16); nil if not a literal.
    static func parseIP(_ host: String) -> [UInt8]? {
        var v4 = [UInt8](repeating: 0, count: 4)
        if host.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 { return v4 }
        var v6 = [UInt8](repeating: 0, count: 16)
        if host.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 { return v6 }
        return nil
    }

    static func isPublicAddress(_ bytes: [UInt8]) -> Bool {
        if bytes.count == 4 {
            let (a, b) = (bytes[0], bytes[1])
            if a == 0 || a == 127 { return false } // unspecified / loopback
            if a == 10 { return false } // RFC 1918
            if a == 172 && (16...31).contains(b) { return false }
            if a == 192 && b == 168 { return false }
            if a == 169 && b == 254 { return false } // link-local, incl. cloud metadata
            if a == 100 && (64...127).contains(b) { return false } // CGNAT
            // RFC 6890 special-purpose: IETF protocol assignments and the
            // TEST-NET / benchmarking blocks — never valid targets.
            if a == 192 && b == 0 && bytes[2] == 0 { return false } // 192.0.0.0/24
            if a == 192 && b == 0 && bytes[2] == 2 { return false } // TEST-NET-1
            if a == 198 && (b == 18 || b == 19) { return false } // benchmarking
            if a == 198 && b == 51 && bytes[2] == 100 { return false } // TEST-NET-2
            if a == 203 && b == 0 && bytes[2] == 113 { return false } // TEST-NET-3
            if a >= 224 { return false } // multicast + reserved + broadcast
            return true
        }
        if bytes.count == 16 {
            if bytes[10] == 0xff, bytes[11] == 0xff { // ::ffff:a.b.c.d
                return isPublicAddress(Array(bytes[12...15]))
            }
            let headZero = bytes[0...7].allSatisfy { $0 == 0 }
            if headZero {
                let tail = bytes[8...15]
                if tail.allSatisfy({ $0 == 0 }) { return false } // ::
                if tail.dropLast().allSatisfy({ $0 == 0 }), tail.last == 1 { return false } // ::1
            }
            if bytes[0] == 0xfe, (bytes[1] & 0xc0) == 0x80 { return false } // fe80::/10
            if bytes[0] == 0xfe, (bytes[1] & 0xc0) == 0xc0 { return false } // fec0::/10 site-local
            if (bytes[0] & 0xfe) == 0xfc { return false } // fc00::/7 ULA
            if bytes[0] == 0xff { return false } // multicast
            // Embedding prefixes (smuggle an inner v4 target) and
            // documentation space — fail closed.
            if bytes[0] == 0x00, bytes[1] == 0x64, bytes[2] == 0xff, bytes[3] == 0x9b {
                return false // 64:ff9b::/96 + 64:ff9b:1::/48 NAT64
            }
            if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x0d, bytes[3] == 0xb8 {
                return false // 2001:db8::/32 documentation
            }
            if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x00, bytes[3] == 0x00 {
                return false // 2001::/32 teredo (embeds v4)
            }
            if bytes[0] == 0x20, bytes[1] == 0x02 { return false } // 2002::/16 6to4 (embeds v4)
            if bytes[0] == 0x01, bytes[1] == 0x00, bytes[2] == 0x00, bytes[3] == 0x00,
               bytes[4] == 0x00, bytes[5] == 0x00, bytes[6] == 0x00, bytes[7] == 0x00 {
                return false // 100::/64 discard
            }
            return true
        }
        return false
    }

    /// Resolve A/AAAA off the event loop; empty on any failure (the caller
    /// treats unresolvable as unsafe). Returns one entry per address.
    ///
    /// The injectable seam below changes nothing about *what* this decides —
    /// it only lets a test supply the address list that a real `getaddrinfo`
    /// would return, because the multi-address rule (every address must be
    /// public) is impossible to exercise offline: fixtures use literal IPs
    /// and no public host's A records can be pinned in a hermetic test.
    static func resolve(_ host: String) async -> [[UInt8]] {
        #if DEBUG
        if let override = resolveOverride { return await override(host) }
        #endif
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var hints = addrinfo()
                hints.ai_family = AF_UNSPEC
                hints.ai_socktype = SOCK_STREAM
                var result: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
                    continuation.resume(returning: [])
                    return
                }
                defer { freeaddrinfo(result) }
                var addresses: [[UInt8]] = []
                var cursor: UnsafeMutablePointer<addrinfo>? = first
                while let info = cursor {
                    cursor = info.pointee.ai_next
                    guard let sa = info.pointee.ai_addr else { continue }
                    switch info.pointee.ai_family {
                    case AF_INET:
                        let addr = UnsafeRawPointer(sa)
                            .assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                        var out = [UInt8](repeating: 0, count: 4)
                        withUnsafeBytes(of: addr) { raw in
                            for i in 0..<4 { out[i] = raw[i] }
                        }
                        addresses.append(out)
                    case AF_INET6:
                        let addr = UnsafeRawPointer(sa)
                            .assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
                        var out = [UInt8](repeating: 0, count: 16)
                        withUnsafeBytes(of: addr) { raw in
                            for i in 0..<16 { out[i] = raw[i] }
                        }
                        addresses.append(out)
                    default:
                        continue
                    }
                }
                continuation.resume(returning: addresses)
            }
        }
    }

    #if DEBUG
    /// ponytail: seam for offline tests of the DNS branch; nil in production,
    /// so the released binary always goes through `getaddrinfo`. Drop it if a
    /// real resolver abstraction ever becomes necessary.
    static var resolveOverride: (@Sendable (String) async -> [[UInt8]])?
    #endif
}
