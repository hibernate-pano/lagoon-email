import SwiftUI

/// A persistent strip that says the machine is offline.
///
/// ## Why this is not a banner
///
/// The notice banner is for a *failure* — something the user tried that did
/// not work. Being offline is a *state*, and a state that is not the
/// product's fault: the mail on screen is real, complete, and readable; it
/// is only not being updated. Rendering that in the error banner (red, with
/// an exclamation mark) would train the user to ignore red strips — and the
/// next one might be real.
///
/// It also must not be a banner at all: the banner slot holds one message
/// at a time (spec INV-6), and a permanently-visible offline state would
/// permanently occupy it. So it is a separate, quieter strip that sits
/// above the content and states what is true.
struct OfflineStrip: View {
    @Environment(\.l10n) private var l10n

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.slash")
                .accessibilityHidden(true)
            Text(l10n.offlineNotice)
                .font(.caption)
            Spacer(minLength: 0)
        }
        .foregroundStyle(LagoonTheme.Severity.warning.color)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LagoonTheme.Severity.warning.color.opacity(0.12))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(LagoonTheme.Severity.warning.color.opacity(0.4))
                .frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(l10n.offlineNotice)
    }
}

public extension View {
    /// Show the offline strip while the machine has no network path.
    ///
    /// `monitor` is injected rather than read from a global so a test can
    /// drive both states without touching the real network stack.
    func offlineStrip(_ monitor: NetworkMonitor) -> some View {
        modifier(OfflineStripModifier(monitor: monitor))
    }
}

private struct OfflineStripModifier: ViewModifier {
    @ObservedObject var monitor: NetworkMonitor

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            // `hasReported` gates the strip: before the path monitor has
            // spoken, "offline" would be a guess, and a strip that flashes
            // for a frame at launch is worse than no strip.
            if monitor.hasReported, !monitor.isOnline {
                OfflineStrip()
            }
            content
        }
    }
}
