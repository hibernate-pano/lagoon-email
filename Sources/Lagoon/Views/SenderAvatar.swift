import SwiftUI

/// A small circular avatar showing the sender's initials (or first
/// letter of the local part). The fill colour is derived from a stable
/// hash of the email address, so the same sender always shows the same
/// colour — a tiny but real affordance when scanning a list of
/// subscription-noise rows.
///
/// Initials rule:
/// 1. If a display name exists and has at least two word-like parts,
///    take the first letter of each (Jane Doe → JD).
/// 2. Else take the first letter of the local part of the email
///    (`bob@x.com` → B).
/// 3. Fallback when neither works: a generic envelope glyph, no text.
struct SenderAvatar: View {
    let email: String
    let displayName: String?
    /// Diameter in points. 28pt sits well next to a body-sized
    /// subject; the call site may override for inline rendering.
    var size: CGFloat = 28

    /// Colour palette tuned to be legible against the macOS background
    /// in both light and dark mode — saturated but not neon. Eight hues
    /// are enough: a 400-message inbox rarely has more than 4–5 distinct
    /// senders per colour band, so 8 keeps collisions rare.
    private static let palette: [Color] = [
        Color(red: 0.36, green: 0.55, blue: 0.78),  // ocean blue
        Color(red: 0.32, green: 0.66, blue: 0.46),  // lagoon green
        Color(red: 0.85, green: 0.55, blue: 0.30),  // sundown orange
        Color(red: 0.75, green: 0.40, blue: 0.62),  // reef pink
        Color(red: 0.50, green: 0.45, blue: 0.72),  // deep coral
        Color(red: 0.30, green: 0.62, blue: 0.66),  // teal
        Color(red: 0.85, green: 0.66, blue: 0.30),  // amber
        Color(red: 0.42, green: 0.50, blue: 0.62),  // slate
    ]

    /// Derive a stable palette index from the email's bytes. We don't
    /// care about cryptographic strength — we care that "alice@x.com"
    /// maps to the same slot every time, so the user's eye can pick
    /// senders by colour in the list.
    static func paletteIndex(for input: String) -> Int {
        let bytes = Array(input.utf8)
        let sum = bytes.reduce(0) { $0 &+ Int($1) }
        return abs(sum) % palette.count
    }

    /// The initials string to render. Pure function — unit-tested.
    static func initials(email: String, displayName: String?) -> String {
        if let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            // Split on whitespace and CJK punctuation so a name like
            // "李 三" or "Jane Doe" both yield two letters.
            let parts = name.split(whereSeparator: { $0.isWhitespace || $0 == "・" || $0 == "·" })
            if parts.count >= 2 {
                let first = parts[0].first.map(String.init) ?? ""
                let second = parts[1].first.map(String.init) ?? ""
                let combined = (first + second).uppercased()
                if !combined.isEmpty { return combined }
            } else if let only = parts.first?.first {
                return String(only).uppercased()
            }
        }
        // Fall back to the local part of the email.
        let local = email.split(separator: "@").first.map(String.init) ?? email
        if let first = local.first {
            return String(first).uppercased()
        }
        return "?"
    }

    var body: some View {
        ZStack {
            Circle().fill(Self.palette[Self.paletteIndex(for: email)])
            Text(Self.initials(email: email, displayName: displayName))
                .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}