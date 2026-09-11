import Foundation

/// One parsed IMAP response line.
///
/// `atoms` is the tokenized form: runs of space/tab split atoms, quoted
/// strings are unquoted and unescaped (RFC 3501 quoted-string), and
/// everything else is passed through untouched — including non-ASCII, which
/// IMAP carries as raw 8-bit text. `literal` is attached by the framing layer
/// (`IMAPConnection`), which has already read the `{N}` bytes off the wire.
public struct IMAPResponse: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case tagged(String, IMAPStatus)
        case untagged
        case continuation
    }

    public var kind: Kind
    public var atoms: [String]
    public var literal: Data?
    public var raw: String

    public init(kind: Kind, atoms: [String], literal: Data?, raw: String) {
        self.kind = kind
        self.atoms = atoms
        self.literal = literal
        self.raw = raw
    }
}

public enum IMAPStatus: String, Sendable {
    case ok = "OK"
    case no = "NO"
    case bad = "BAD"
}

/// Pure text → structure parsing for the IMAP wire format. No I/O, no state:
/// every byte here is server-controlled input and must not crash the parser.
public enum IMAPResponseParser {
    /// Parses one line (CRLF already stripped) plus an optional literal whose
    /// bytes the caller read after a `{N}` declaration. Returns nil for a
    /// blank line.
    public static func parse(line: String, literal: Data? = nil) -> IMAPResponse? {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let atoms = tokenize(line)
        guard let first = atoms.first else { return nil }

        let kind: IMAPResponse.Kind
        switch first {
        case "*":
            kind = .untagged
        case "+":
            kind = .continuation
        default:
            // The status is the token after the tag; scanning the rest is
            // strictly more forgiving and cannot misfire on untagged lines.
            let status = atoms.dropFirst()
                .lazy
                .compactMap { IMAPStatus(rawValue: $0.uppercased()) }
                .first ?? .bad
            kind = .tagged(first, status)
        }
        return IMAPResponse(kind: kind, atoms: atoms, literal: literal, raw: line)
    }

    /// Length declared by a trailing `{N}` / `{N+}` marker, or nil when the
    /// line does not end in one.
    public static func literalLength(in line: String) -> Int? {
        guard line.hasSuffix("}"), let open = line.lastIndex(of: "{") else { return nil }
        var digits = line[line.index(after: open)..<line.index(before: line.endIndex)]
        if digits.hasSuffix("+") {
            digits = digits.dropLast()
        }
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return nil
        }
        return Int(digits)
    }

    /// Splits the contents of the first `( ... )` group into atoms. Nested
    /// groups stay one atom (parens included) so `FLAGS (\Seen)` and
    /// `BODY[HEADER.FIELDS (SUBJECT)]` both survive a single pass — a
    /// bracketed section is itself an atom, so nothing inside `[ ]` splits.
    /// Nil when the line has no group.
    public static func parenthesized(_ line: String) -> [String]? {
        guard let open = line.firstIndex(of: "(") else { return nil }
        var atoms: [String] = []
        var current = ""
        var hasCurrent = false
        var depth = 1
        var bracketDepth = 0
        var inQuote = false
        var pendingEscape = false
        var index = line.index(after: open)

        while index < line.endIndex {
            let ch = line[index]
            index = line.index(after: index)

            if inQuote {
                if pendingEscape {
                    current.append(ch)
                    pendingEscape = false
                } else if ch == "\\" {
                    pendingEscape = true
                } else if ch == "\"" {
                    inQuote = false
                } else {
                    current.append(ch)
                }
                continue
            }

            switch ch {
            case "\"":
                inQuote = true
                hasCurrent = true
            case "[":
                bracketDepth += 1
                current.append(ch)
                hasCurrent = true
            case "]":
                if bracketDepth > 0 { bracketDepth -= 1 }
                current.append(ch)
                hasCurrent = true
            case "(" where bracketDepth == 0:
                depth += 1
                current.append(ch)
                hasCurrent = true
            case ")" where bracketDepth == 0:
                depth -= 1
                if depth == 0 {
                    if hasCurrent { atoms.append(current) }
                    return atoms
                }
                current.append(ch)
            case " ", "\t":
                // `where` in a multi-pattern case binds to the last pattern
                // only, so the bracket guard must be spelled out here.
                if bracketDepth > 0 {
                    current.append(ch)
                    hasCurrent = true
                } else if depth == 1 {
                    if hasCurrent {
                        atoms.append(current)
                        current = ""
                        hasCurrent = false
                    }
                } else {
                    current.append(ch)
                }
            default:
                current.append(ch)
                hasCurrent = true
            }
        }

        // Unterminated group: hand back what was parsed rather than nothing.
        if hasCurrent { atoms.append(current) }
        return atoms
    }

    private static func tokenize(_ line: String) -> [String] {
        var atoms: [String] = []
        var current = ""
        var hasCurrent = false
        var inQuote = false
        var pendingEscape = false

        for ch in line {
            if inQuote {
                if pendingEscape {
                    current.append(ch)
                    pendingEscape = false
                } else if ch == "\\" {
                    pendingEscape = true
                } else if ch == "\"" {
                    inQuote = false
                } else {
                    current.append(ch)
                }
                continue
            }
            switch ch {
            case "\"":
                inQuote = true
                hasCurrent = true
            case " ", "\t":
                if hasCurrent {
                    atoms.append(current)
                    current = ""
                    hasCurrent = false
                }
            default:
                current.append(ch)
                hasCurrent = true
            }
        }
        if pendingEscape { current.append("\\") }
        if hasCurrent { atoms.append(current) }
        return atoms
    }
}
