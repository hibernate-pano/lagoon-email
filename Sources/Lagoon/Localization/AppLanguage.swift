import Foundation

/// UI language, switchable at runtime from the window toolbar.
///
/// The raw value is a BCP-47 tag so it doubles as the `Accept-Language` value
/// sent with AI requests, which is how the summary language follows the UI.
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case zhHans = "zh-Hans"
    case english = "en"

    public var id: String { rawValue }

    /// Always rendered in its own language, so the picker is readable
    /// whichever language is active.
    public var displayName: String {
        switch self {
        case .zhHans: "中文"
        case .english: "English"
        }
    }
}
