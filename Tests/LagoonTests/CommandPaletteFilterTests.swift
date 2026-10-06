import XCTest
@testable import Lagoon

/// `CommandPaletteView`'s constructor wires 12 callbacks. If any of them
/// goes non-optional or gets renamed, this test catches it before the
/// sheet appears blank in front of the user.
///
/// The two lists it also pins — the palette's commands and the ⌘/
/// cheatsheet's entries — are hand-curated, so a row dropped in an edit
/// never reaches the compiler. `allCommands` and `entries` are therefore
/// internal rather than private. Both resolve `l10n` from the environment,
/// which defaults to zh-Hans outside a rendered view, so these assertions
/// cover content and structure, not per-language translation.
@MainActor
final class CommandPaletteFilterTests: XCTestCase {
    private func palette() -> CommandPaletteView {
        CommandPaletteView(
            onNewMessage: {}, onSearch: {}, onToggleSurface: {},
            onShowUsage: {}, onShowActionHistory: {},
            onShowAdvice: {}, onShowSenderRanking: {},
            onCycleDensity: {}, onShowShortcuts: {}, onShowAISettings: {},
            onRefresh: {}, onToggleSound: {}
        )
    }

    /// Every palette row must be wired to a callback that actually fires.
    /// The failure this file existed to prevent is a row whose `action` is a
    /// no-op — the row renders, takes the click, and nothing happens.
    /// The previous version of this test used `Mirror`, which cannot see
    /// stored closures at all, so it asserted nothing; driving the real
    /// commands is the version that can fail.
    func test_everyCommandRunsItsCallback() {
        var fired: [String] = []
        func record(_ name: String) -> () -> Void { { fired.append(name) } }

        let view = CommandPaletteView(
            onNewMessage: record("new-message"),
            onSearch: record("search"),
            onToggleSurface: record("toggle-surface"),
            onShowUsage: record("usage"),
            onShowActionHistory: record("history"),
            onShowAdvice: record("advice"),
            onShowSenderRanking: record("senders"),
            onCycleDensity: record("density"),
            onShowShortcuts: record("shortcuts"),
            onShowAISettings: record("ai-settings"),
            onRefresh: record("refresh"),
            onToggleSound: record("sound")
        )
        for command in view.allCommands {
            command.action()
        }
        XCTAssertEqual(
            fired, view.allCommands.map(\.id),
            "every command row must invoke exactly one distinct callback, in order"
        )
    }

    /// Pinned verbatim: adding a command means adding a callback *and* a row
    /// here, and removing one is a deliberate act rather than an accident.
    func test_paletteExposesExactlyTheTwelveCommands() {
        XCTAssertEqual(palette().allCommands.map(\.id), [
            "new-message", "search", "toggle-surface", "refresh",
            "usage", "ai-settings", "advice", "senders", "density", "history", "shortcuts", "sound"
        ])
    }

    /// ⌘0 toggles. Two rows each labelled ⌘0 — one saying "Briefing", one
    /// saying "All messages" — told the user to press ⌘0 to reach a surface,
    /// and pressing it while already there sent them the other way. Exactly
    /// one row may claim the key.
    func test_command0IsAdvertisedOnceAsAToggle() {
        let claiming = palette().allCommands.filter { $0.shortcut == "⌘0" }
        XCTAssertEqual(claiming.map(\.id), ["toggle-surface"])
    }

    /// No two rows may advertise the same key: the palette is the user's map
    /// of what a key does, and a collision makes one of the two entries a lie.
    func test_noTwoCommandsClaimTheSameShortcut() {
        let keys = palette().allCommands.compactMap(\.shortcut)
        XCTAssertEqual(Set(keys).count, keys.count, "duplicate shortcut in \(keys)")
    }

    /// The ⌘/ row must not be titled "command palette" — that is the ⌘K row.
    /// The mislabel made searching the palette for "命令面板" return two hits
    /// that open different sheets.
    func test_shortcutsRowIsNotTitledCommandPalette() {
        let commands = palette().allCommands
        let shortcuts = commands.first { $0.id == "shortcuts" }
        XCTAssertNil(commands.first { $0.id == "palette" }, "the palette does not list itself as a row")
        XCTAssertNotEqual(shortcuts?.title, l10n.commandPalette)
        XCTAssertEqual(shortcuts?.title, l10n.keyboardShortcuts)
    }

    private var l10n: L10n { L10n(language: .zhHans) }

    /// `ForEach(..., id: \.element.id)` drops duplicate keys silently, and
    /// `highlightedIndex` indexes the filtered array — a repeated id
    /// therefore mis-highlights instead of failing. Ids must be unique.
    func test_commandIdsAreUnique() {
        let ids = palette().allCommands.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate command id in \(ids)")
    }

    /// A blank title makes a row unsearchable (the user cannot type a name
    /// that is not displayed) and an empty id collapses two rows into one
    /// under `ForEach`.
    func test_everyCommandHasTitleAndIcon() {
        for command in palette().allCommands {
            XCTAssertFalse(command.title.isEmpty, "'\(command.id)' has an empty title")
            XCTAssertFalse(command.systemImage.isEmpty, "'\(command.id)' has no SF Symbol")
        }
    }

    /// The cheatsheet is a learning surface: a row with no keys or no
    /// description teaches the user nothing, and a repeated id makes
    /// `List` drop the duplicate row.
    func test_shortcutEntriesAreCompleteAndUnique() {
        let entries = ShortcutsSheet().entries
        XCTAssertFalse(entries.isEmpty, "the cheatsheet is empty")
        let ids = entries.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate entry id in \(ids)")
        for entry in entries {
            XCTAssertFalse(entry.keys.isEmpty, "'\(entry.id)' has no key combination")
            XCTAssertFalse(entry.description.isEmpty, "'\(entry.id)' has an empty description")
        }
    }

    /// Every action is undoable (spec's core promise) and ⌘Z is bound in
    /// `RootView`'s hidden background — if the cheatsheet drops the row,
    /// the promise becomes undiscoverable. Same for ⌫/⌘⌫, which are
    /// bound as zero-width buttons rather than menu items and were in fact
    /// missing from the sheet until this test started demanding them.
    func test_shortcutSheetAdvertisesTheGlobalGestures() {
        let ids = Set(ShortcutsSheet().entries.map(\.id))
        for expected in [
            "undo", "refresh", "back", "palette", "briefing",
            "archiveSelected", "deleteSelected", "groupJump", "budget", "advice",
        ] {
            XCTAssertTrue(ids.contains(expected), "cheatsheet is missing '\(expected)'")
        }
    }
}
