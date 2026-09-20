import XCTest
@testable import Lagoon

/// SoundEffects is gated on a UserDefaults flag so a user can mute the
/// app without losing the architectural plumbing. Verifying the gate
/// alone is enough — actually playing audio in CI would be flaky.
@MainActor
final class SoundEffectsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Start each test from the default (sound on) state.
        UserDefaults.standard.removeObject(forKey: SoundEffects.enabledDefaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: SoundEffects.enabledDefaultsKey)
        super.tearDown()
    }

    /// Missing key reads as on — the spec calls for sound on by default
    /// since the user just opted in to it.
    func test_isEnabled_defaultsToTrue() {
        XCTAssertTrue(SoundEffects.isEnabled)
    }

    /// `isEnabled` setter persists across reads so the toolbar toggle
    /// reflects the live state when the user reopens the menu.
    func test_isEnabled_roundTripsThroughUserDefaults() {
        SoundEffects.isEnabled = false
        XCTAssertFalse(SoundEffects.isEnabled)
        SoundEffects.isEnabled = true
        XCTAssertTrue(SoundEffects.isEnabled)
    }

    /// The constants that callers see are stable: an enum-style accessor
    /// keeps the public surface readable.
    func test_defaultsKey_isStable() {
        XCTAssertEqual(SoundEffects.enabledDefaultsKey, "lagoon.sound.enabled")
    }

    /// `send` / `archive` / `syncRecovered` must all be callable without
    /// crashing when sound is enabled. With no audio hardware in CI the
    /// NSSound returns nil and the call silently no-ops — but we want to
    /// know the entry points exist and don't trap.
    func test_playEntryPoints_existAndDoNotCrash() {
        // Enable and disable both run without exceptions in the test runner.
        SoundEffects.isEnabled = true
        SoundEffects.send()
        SoundEffects.archive()
        SoundEffects.syncRecovered()
        SoundEffects.isEnabled = false
        SoundEffects.send()
        SoundEffects.archive()
        SoundEffects.syncRecovered()
    }
}