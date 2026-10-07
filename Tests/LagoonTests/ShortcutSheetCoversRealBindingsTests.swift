import XCTest
@testable import Lagoon

/// The cheatsheet is hand-curated, so it drifts from the code in one
/// direction only: bindings get added and the sheet never learns about them.
/// Before this file the sheet listed 20 rows against 38 real bindings, and
/// the test that was supposed to catch that —
/// `test_shortcutSheetAdvertisesTheGlobalGestures` — passed, because it
/// asserted "these ids exist in the sheet" rather than "these bindings exist
/// in the sheet". **A lock that follows the declaration cannot detect the
/// declaration being wrong.**
///
/// So this one runs the other way: enumerate every `keyboardShortcut`
/// actually bound under `Sources/Lagoon`, render each as the macOS symbol
/// string the sheet uses, and require the sheet to list it. Adding a binding
/// without a row now fails here, with the missing key in the message.
final class ShortcutSheetCoversRealBindingsTests: XCTestCase {
    /// System gestures SwiftUI provides for free inside a sheet/dialog. They
    /// are not product shortcuts and the cheatsheet should not teach them.
    private static let systemGestures: Set<String> = [
        ".keyboardShortcut(.defaultAction)",
        ".keyboardShortcut(.cancelAction)",
    ]

    /// Bindings this file deliberately does not require the sheet to list,
    /// each with the reason. Empty is the goal — an entry here is a debt.
    private static let allowlist: [String: String] = [
        // ⌘1–⌘9 is a single dynamic binding over the briefing groups; the
        // sheet teaches it as one row, keyed "⌘1–⌘9".
        "⌘1": "covered by the groupJump row (⌘1–⌘9)",
        "⌘2": "covered by the groupJump row (⌘1–⌘9)",
        "⌘3": "covered by the groupJump row (⌘1–⌘9)",
        "⌘4": "covered by the groupJump row (⌘1–⌘9)",
        "⌘5": "covered by the groupJump row (⌘1–⌘9)",
        "⌘6": "covered by the groupJump row (⌘1–⌘9)",
        "⌘7": "covered by the groupJump row (⌘1–⌘9)",
        "⌘8": "covered by the groupJump row (⌘1–⌘9)",
        "⌘9": "covered by the groupJump row (⌘1–⌘9)",
    ]

    /// `Sources/Lagoon`, recursively — the bindings live in `Views/`.
    private func clientSources() throws -> [(name: String, text: String)] {
        let root = ViewSource.url(under: "Views", "RootView")
            .deletingLastPathComponent()          // Views
            .deletingLastPathComponent()          // Lagoon
        let urls = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil
        )?.compactMap { ($0 as? URL) }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(urls.isEmpty, "no client sources found under \(root.path)")
        return try urls.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    /// Every binding in the client must appear in the cheatsheet.
    @MainActor
    func test_everyRealBindingIsDocumented() throws {
        let documented = Set(ShortcutsSheet().entries.map(\.keys))
        var missing: [String] = []

        for (name, text) in try clientSources() {
            for binding in Self.bindings(in: text) {
                guard !Self.systemGestures.contains(binding) else { continue }
                let keys = Self.symbols(forBinding: binding)
                for key in keys {
                    if Self.allowlist[key] == nil && !documented.contains(key) {
                        missing.append("\(name): \(binding) → '\(key)'")
                    }
                }
            }
        }

        XCTAssertTrue(
            missing.isEmpty,
            """
            The cheatsheet does not teach these bound shortcuts:
            \(missing.joined(separator: "\n"))

            Add a row to ShortcutsSheet.entries, or — if the key is genuinely
            not worth teaching — list it in allowlist above with the reason.
            """
        )
    }

    /// The inverse direction: a row in the sheet whose key is bound nowhere
    /// teaches a gesture that does nothing. That is the other way a
    /// hand-curated list rots, and it is the one the user hits first.
    @MainActor
    func test_everyDocumentedKeyIsReallyBound() throws {
        let real = try clientSources().reduce(into: Set<String>()) { acc, entry in
            acc.formUnion(Self.symbols(for: entry.text))
        }
        // The dynamic ⌘1–⌘9 family renders as nine separate symbols above.
        let groupJumpFamily = Set((1...9).map { "⌘\($0)" })

        var ghost: [String] = []
        for entry in ShortcutsSheet().entries {
            if entry.keys == "⌘1–⌘9" {
                if !groupJumpFamily.isSubset(of: real) {
                    ghost.append("⌘1–⌘9 (group jump)")
                }
            } else if !real.contains(entry.keys) {
                ghost.append("\(entry.keys) (\(entry.id))")
            }
        }

        XCTAssertTrue(
            ghost.isEmpty,
            "the cheatsheet advertises keys that are bound nowhere: \(ghost.joined(separator: ", "))"
        )
    }

    // MARK: - Parsing

    /// Every `.keyboardShortcut(...)` call in a source file, captured whole
    /// so the modifier list survives. All bindings in this codebase are
    /// written on one line; a multi-line one would be missed, which is why
    /// `test_bindingsAreSingleLine` exists.
    ///
    /// Note the `seenOpen` flag: paren balance only means "done" *after* the
    /// opening paren. Without it depth is already 0 at the leading `.` and
    /// every binding parses as "." — which makes the coverage test pass
    /// vacuously, the exact shape of failure this file exists to prevent.
    static func bindings(in text: String) -> [String] {
        text.split(separator: "\n").compactMap { line in
            guard line.contains(".keyboardShortcut(") else { return nil }
            guard let start = line.range(of: ".keyboardShortcut(") else { return nil }
            let rest = line[start.lowerBound...]
            var depth = 0
            var seenOpen = false
            for (offset, ch) in rest.enumerated() {
                if ch == "(" { depth += 1; seenOpen = true }
                else if ch == ")" { depth -= 1 }
                if seenOpen && depth == 0 {
                    return String(rest[..<rest.index(rest.startIndex, offsetBy: offset + 1)])
                }
            }
            return nil
        }
    }

    /// Guards the single-line assumption the parser above relies on. If a
    /// binding ever gets reformatted across lines this fails loudly instead
    /// of silently shrinking the enumerated set — the exact failure mode that
    /// made the previous lock useless.
    func test_bindingsAreSingleLine() throws {
        for (name, text) in try clientSources() {
            for line in text.split(separator: "\n") {
                guard line.contains(".keyboardShortcut(") else { continue }
                let opens = line.filter { $0 == "(" }.count
                let closes = line.filter { $0 == ")" }.count
                XCTAssertEqual(
                    opens, closes,
                    "\(name): a .keyboardShortcut call spans lines — bindings(in:) would miss it"
                )
            }
        }
    }

    /// Guards the parser itself. `test_everyRealBindingIsDocumented` passes
    /// vacuously when `bindings(in:)` finds nothing, so pin the parse: a
    /// real file must yield real bindings, and a binding must survive with
    /// its modifier list intact.
    func test_bindingsParserActuallyParses() throws {
        let text = try ViewSource.read("MessageDetailView")
        let found = Self.bindings(in: text)
        XCTAssertGreaterThan(found.count, 5, "parser found almost nothing in MessageDetailView")
        XCTAssertTrue(
            found.contains(#".keyboardShortcut("e", modifiers: .command)"#),
            "⌘E (archive & next) was not parsed: \(found)"
        )
        XCTAssertTrue(
            found.contains(#".keyboardShortcut("f", modifiers: [.command, .shift])"#),
            "multi-modifier binding was not parsed intact: \(found)"
        )
        XCTAssertFalse(
            found.contains("."),
            "parser collapsed a binding to '.' — depth reached 0 before the opening paren"
        )
    }

    /// Every shortcut a source file really binds: the `keyboardShortcut`
    /// calls, plus the `List`/`onDeleteCommand` gestures SwiftUI binds
    /// implicitly (⌫ delete/archive, ⌘⌫ when `.delete`+`.command`). These
    /// never appear as a `.keyboardShortcut(` call, so scanning only that
    /// would report a documented ⌫ as a ghost.
    static func symbols(for text: String) -> Set<String> {
        var out = Set<String>()
        for binding in bindings(in: text) {
            out.formUnion(symbols(forBinding: binding))
        }
        if text.contains(".onDeleteCommand") {
            out.insert("⌫")
        }
        return out
    }

    /// Renders a single binding as the symbol string the sheet uses.
    /// `.keyboardShortcut("e", modifiers: .command)` → `⌘E`.
    static func symbols(forBinding binding: String) -> [String] {
        let key: String
        if let lit = binding.range(of: #"keyboardShortcut\("(.+?)", modifiers: (.*)\)"#, options: .regularExpression) {
            let body = String(binding[lit])
            let parts = body.split(separator: ",", maxSplits: 1).map(String.init)
            let k = parts[0]
                .replacingOccurrences(of: #"keyboardShortcut\(""#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "\"", with: "")
            return [render(key: k, modifiers: parts.count > 1 ? parts[1] : "")]
        }
        switch binding {
        case let b where b.contains(".keyboardShortcut(.return, modifiers: .command)"):
            key = "⌘↩"
        case let b where b.contains(".keyboardShortcut(.return"):
            key = "↩"
        case let b where b.contains(".keyboardShortcut(.delete, modifiers: .command)"):
            key = "⌘⌫"
        case let b where b.contains(".keyboardShortcut(.delete"):
            key = "⌫"
        case let b where b.contains("KeyEquivalent(Character(String(index + 1)))"):
            return (1...9).map { "⌘\($0)" }
        default:
            return []
        }
        return [key]
    }

    private static func render(key: String, modifiers: String) -> String {
        var prefix = ""
        if modifiers.contains(".control") { prefix += "⌃" }
        if modifiers.contains(".option") || modifiers.contains(".alt") { prefix += "⌥" }
        if modifiers.contains(".shift") { prefix += "⇧" }
        if modifiers.contains(".command") { prefix += "⌘" }
        let upper = key.count == 1 ? key.uppercased() : key
        return prefix + upper
    }
}
