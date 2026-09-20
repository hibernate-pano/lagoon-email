import Foundation
import AppKit

/// Subtle audio feedback for the actions that benefit most from a tiny
/// confirmatory "yes, it happened" — the ones the user performs once or
/// twice per minute and would otherwise wonder "did it land?":
/// - `send` plays when a reply / new message is accepted by the server.
/// - `archive` plays when a row disappears from the Briefing Feed.
/// - `syncRecovered` plays when the sync engine transitions out of a
///   degraded / error state.
///
/// The system sounds are used at low volume so they stay in the
/// background — Mail.app's classic "Pop" and "Tink" can be jarring at
/// full volume during a 200-message triage morning. The user can mute
/// via the Sound toggle in the toolbar's ⋯ menu (writes
/// `UserDefaults` key `lagoon.sound.enabled`).
///
/// Sounds are no-ops in tests (NSSound requires a real audio device and
/// CI doesn't have one).
@MainActor
public enum SoundEffects {
    /// UserDefaults key for the global sound toggle.
    public static let enabledDefaultsKey = "lagoon.sound.enabled"

    /// Default is `true` — sound on by default, since the user just opted in.
    public static var isEnabled: Bool {
        get {
            // Missing key reads as `true` (the default).
            UserDefaults.standard.object(forKey: enabledDefaultsKey) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledDefaultsKey)
        }
    }

    /// 30% volume keeps the sounds clearly audible without being
    /// intrusive on a long triage session. The system sound files are
    /// mixed loud by default.
    private static let playbackVolume: Float = 0.3

    public static func send() { play(named: "Pop") }
    public static func archive() { play(named: "Tink") }
    public static func syncRecovered() { play(named: "Glass") }

    /// Play a macOS system sound by name, gated on the user preference.
    /// `NSSound(named:)` returns nil if the sound file isn't on the system
    /// (rare, but happens in stripped-down CI / containers); we silently
    /// skip rather than crash.
    private static func play(named soundName: String) {
        guard isEnabled else { return }
        guard let sound = NSSound(named: soundName) else { return }
        sound.volume = playbackVolume
        sound.play()
    }
}