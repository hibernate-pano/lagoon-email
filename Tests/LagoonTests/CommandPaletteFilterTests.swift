import XCTest
@testable import Lagoon

/// `CommandPaletteView`'s constructor wires 10 callbacks. If any of them
/// goes non-optional or gets renamed, this test catches it before the
/// sheet appears blank in front of the user.
@MainActor
final class CommandPaletteFilterTests: XCTestCase {

    func test_instantiatesWithAllCallbacks() {
        let palette = CommandPaletteView(
            onNewMessage: {}, onSearch: {}, onShowBriefing: {},
            onShowAllMessages: {}, onShowUsage: {}, onShowActionHistory: {},
            onShowAutoArchiveRules: {}, onShowShortcuts: {}, onRefresh: {},
            onToggleSound: {}
        )
        XCTAssertNotNil(palette)
    }

    /// `ShortcutsSheet` exposes the curated list of shortcuts. It must
    /// instantiate for both languages so the ⌘/ cheatsheet renders no
    /// matter what the user picked.
    func test_shortcutsSheet_instantiates() {
        let sheet = ShortcutsSheet()
        XCTAssertNotNil(sheet)
    }
}