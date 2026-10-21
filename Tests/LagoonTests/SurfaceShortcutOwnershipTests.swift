import XCTest
@testable import Lagoon

/// One key, one owner — for the keys that are bound twice on purpose.
///
/// The Briefing and the raw list are **both mounted at all times**:
/// `RootView` keeps them alive in a ZStack so their scroll position and
/// poll loops survive a surface switch. That means a shortcut bound in
/// both of them is bound twice, at the same time, in the same window.
///
/// The only thing standing between the user and a double action is
/// `.disabled(!isVisible)`. SwiftUI stops a disabled view's keyboard
/// shortcut from firing — if it did not, pressing `J` in the Briefing
/// would move the selection in the hidden list as well, and the list
/// would come back with a selection the user never made.
///
/// That is a real dependency, and it was an *unwritten* one: nothing
/// failed if someone dropped the `.disabled(...)` line. These tests make
/// the dependency explicit, so the next person who moves one of these
/// bindings learns that the other copy is still there.
final class SurfaceShortcutOwnershipTests: XCTestCase {
    /// The keys the two mail surfaces both bind, and the file each lives in.
    ///
    /// `SearchSheet`'s ⌘[ is a third binding of the same key, but it is a
    /// *sheet*: it exists only while the search panel is open, and then it
    /// is the only one of the three that can be focused. It is left alone.
    private static let sharedKeys: [(file: String, key: String)] = [
        ("BriefingFeedView", #"keyboardShortcut("j", modifiers: [])"#),
        ("BriefingFeedView", #"keyboardShortcut("k", modifiers: [])"#),
        ("BriefingFeedView", #"keyboardShortcut("[", modifiers: .command)"#),
        ("BriefingFeedView", #"keyboardShortcut("a", modifiers: .command)"#),
        ("BriefingFeedView", #"keyboardShortcut(.delete, modifiers: .command)"#),
        ("MessageListView", #"keyboardShortcut("j", modifiers: [])"#),
        ("MessageListView", #"keyboardShortcut("k", modifiers: [])"#),
        ("MessageListView", #"keyboardShortcut("[", modifiers: .command)"#),
        ("MessageListView", #"keyboardShortcut("a", modifiers: .command)"#),
        ("MessageListView", #"keyboardShortcut(.delete, modifiers: .command)"#),
    ]

    /// Every shared binding must be switched off while its surface is not
    /// the visible one.
    ///
    /// The gate is matched on *containing* `!isVisible`, not on being
    /// exactly `.disabled(!isVisible)`: a shortcut may carry a second
    /// condition (the delete shortcut is also gated on the account having a
    /// trash folder), and the two must be **one** `.disabled` call —
    /// SwiftUI's `.disabled` overwrites the environment value rather than
    /// composing with it, so two stacked calls would silently drop the
    /// first.
    func test_sharedSurfaceShortcutsAreGatedOnVisibility() throws {
        var ungated: [String] = []
        for entry in Self.sharedKeys {
            let source = try ViewSource.read(entry.file)
            let lines = source.split(separator: "\n").map(String.init)
            guard let index = lines.firstIndex(where: { $0.contains(entry.key) }) else {
                XCTFail("\(entry.file): \(entry.key) is no longer bound")
                continue
            }
            // The gate belongs on the same view as the binding — within a
            // few lines of it, before the chain moves on to another view.
            let window = lines[index..<min(index + 6, lines.count)].joined(separator: "\n")
            let gated = window.contains(".disabled(") && window.contains("!isVisible")
            if !gated {
                ungated.append("\(entry.file): \(entry.key) (line \(index + 1))")
            }
        }
        XCTAssertTrue(
            ungated.isEmpty,
            """
            These bindings are live on both surfaces at once. Each one has to \
            be switched off while its surface is hidden, or one key press \
            moves two lists:
            \(ungated.joined(separator: "\n"))
            """
        )
    }

    /// The menu bar owns ⌥⌘R, and only the menu bar.
    ///
    /// The refresh button in each surface used to carry ⌥⌘R as well. Two
    /// owners for one key means one of two things, both bad: the surface's
    /// copy is dead code that looks alive, or a key press refreshes twice.
    /// The menu's version is the complete one — it re-reads the list, the
    /// counts and the account state — so the menu is the single owner.
    /// Reads a source file by its path under `Sources/Lagoon`.
    ///
    /// `ViewSource.read` resolves against `Views/`, which is not where the
    /// menu bar lives — the commands are in `Platform/`.
    private func read(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LagoonTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Sources/Lagoon")
        return try String(
            contentsOf: root.appendingPathComponent(relativePath + ".swift"),
            encoding: .utf8
        )
    }

    func test_theRefreshShortcutHasExactlyOneOwner() throws {
        var owners: [String] = []
        for file in ["Views/BriefingFeedView", "Views/MessageListView", "Platform/LagoonAppCommands"] {
            let source = try read(file)
            let lines = source.split(separator: "\n").map(String.init)
            for (index, line) in lines.enumerated() where line.contains(#"keyboardShortcut("r","#) {
                owners.append("\(file):\(index + 1)")
            }
        }
        XCTAssertEqual(
            owners.count, 1,
            "⌥⌘R must have exactly one owner; found \(owners.joined(separator: ", "))"
        )
        XCTAssertTrue(
            owners.first?.hasPrefix("Platform/LagoonAppCommands") ?? false,
            "the menu bar should own ⌥⌘R; found \(owners.joined(separator: ", "))"
        )
    }
}
