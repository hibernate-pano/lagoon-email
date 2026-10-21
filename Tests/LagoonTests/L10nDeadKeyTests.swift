import XCTest
@testable import Lagoon

/// Every string the product can show should be shown.
///
/// A localization key that nothing references is not free. It is a promise
/// the code makes to a translator — "this sentence exists in both
/// languages" — and nobody keeps. Over a few release cycles the file
/// fills with copy for features that were cut, features that were
/// renamed, and copy that was replaced by a better word and never
/// deleted. The cost is not the bytes; it is that the file stops being
/// readable as "what the product says", and the next person editing it
/// cannot tell a live string from a fossil.
///
/// The scanner is the same one the reviewer used when 41 keys turned up
/// unused. It is cheap, it runs on every `swift test`, and it fails with
/// the exact key names.
final class L10nDeadKeyTests: XCTestCase {
    /// Every `public var` / `public func` the localization file declares.
    ///
    /// Deliberately a substring scan rather than a regex: the sibling test
    /// file already documents that a regex-looking pattern here would
    /// silently match nothing and make the whole test vacuous.
    private static func declaredKeys(in source: String) -> [String] {
        var keys: [String] = []
        for line in source.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("public var ") || trimmed.hasPrefix("public func ") else {
                continue
            }
            let afterKeyword = trimmed.dropFirst(trimmed.hasPrefix("public var ") ? 11 : 12)
            let name = afterKeyword.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if !name.isEmpty { keys.append(String(name)) }
        }
        return keys
    }

    /// Every identifier that appears after a dot, in one pass.
    ///
    /// `l10n.someKey` is how a string is used everywhere outside the
    /// localization file, so the set of names after a dot is the set of
    /// strings the product actually reaches for. Scanning for each key
    /// separately costs a full pass per key; this costs one pass per file.
    private static func memberNames(in source: String) -> Set<String> {
        var names = Set<String>()
        var current = ""
        var afterDot = false
        for character in source {
            if afterDot {
                if character.isLetter || character.isNumber || character == "_" {
                    current.append(character)
                    continue
                }
                // The name ended — flush it and stop looking for one until
                // the next dot.
                if !current.isEmpty { names.insert(current) }
                current = ""
                afterDot = false
            }
            if character == "." {
                afterDot = true
                current = ""
            }
        }
        if !current.isEmpty { names.insert(current) }
        return names
    }

    /// Every identifier in the source, with how often it appears.
    ///
    /// Inside the localization file a declaration may reference another by
    /// bare name — a helper that composes two strings, say — and that
    /// counts as a use.
    private static func identifierCounts(in source: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        var current = ""
        func flush() {
            if !current.isEmpty { counts[current, default: 0] += 1 }
            current = ""
        }
        for character in source {
            if character.isLetter || character.isNumber || character == "_" {
                current.append(character)
            } else {
                flush()
            }
        }
        flush()
        return counts
    }

    /// Every localization file.
    ///
    /// The strings used to live in one file, `L10n.swift`. They now live
    /// in several — `L10n.swift`, `L10n+AI.swift`, `L10n+Backup.swift` —
    /// so that two features can add a string each without both editing
    /// the same 2000-line file. The cost of that split is that a guard
    /// reading only `L10n.swift` would no longer see half the strings,
    /// and would call a string "used" when it is not.
    ///
    /// So this reads **every** file in `Sources/Lagoon/Localization/`.
    private func l10nSources() throws -> [(url: URL, text: String)] {
        let root = ViewSource.url(under: "Localization", "L10n")
            .deletingLastPathComponent()          // Localization
        let urls = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil
        )?.compactMap { ($0 as? URL) }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path } ?? []
        XCTAssertFalse(urls.isEmpty, "no localization files found under \(root.path)")
        return try urls.map { ($0, try String(contentsOf: $0, encoding: .utf8)) }
    }

    /// Every source file the client is built from.
    private func clientSources() throws -> [URL] {
        let root = ViewSource.url(under: "Views", "RootView")
            .deletingLastPathComponent()          // Views
            .deletingLastPathComponent()          // Lagoon
        let urls = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil
        )?.compactMap { ($0 as? URL) }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(urls.isEmpty, "no client sources found under \(root.path)")
        return urls
    }

    /// Every test file — a copy assertion in a test is a real use of that
    /// string.
    private func testSources() throws -> [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LagoonTests
            .deletingLastPathComponent()   // Tests
        let urls = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil
        )?.compactMap { ($0 as? URL) }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(urls.isEmpty, "no test sources found under \(root.path)")
        return urls
    }

    func test_noLocalizationKeyIsDead() throws {
        let sources = try l10nSources()
        var keys: [String] = []
        var used = Set<String>()

        for (url, text) in sources {
            let declared = Self.declaredKeys(in: text)
            keys.append(contentsOf: declared)
            // Inside a localization file a declaration may reference
            // another by bare name; count those as uses too.
            let counts = Self.identifierCounts(in: text)
            for key in declared where (counts[key] ?? 0) > 1 {
                used.insert(key)
            }
            // A declaration in one localization file is a *use* of any
            // string another file declares — the split must not turn
            // "used from a sibling file" into "dead".
            used.formUnion(Self.memberNames(in: text))
            _ = url
        }
        XCTAssertGreaterThan(keys.count, 400, "the localization files lost most of their strings")

        for url in try clientSources() + testSources() {
            // A localization file's own declaration is not a use of a
            // *different* string; the declarations were counted above.
            if sources.contains(where: { $0.url == url }) { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            used.formUnion(Self.memberNames(in: text))
        }

        let dead = keys.filter { !used.contains($0) }
        XCTAssertTrue(
            dead.isEmpty,
            """
            These localization strings are never shown. Delete them, or wire \
            them up if they were meant to reach the screen:
            \(dead.sorted().joined(separator: ", "))
            """
        )
    }
}
