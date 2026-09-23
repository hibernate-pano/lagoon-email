import SwiftUI
import LagoonKit

/// Distinguishes the three refresh states a view can be in (spec §5.6).
///
/// - `idle` — no refresh in flight, button enabled.
/// - `loading` — the user just pressed refresh; disable the button so a
///   second tap is a no-op instead of stacking requests.
/// - `refreshing` — the 30s background poll is fetching; show a small
///   orange dot on the trailing edge of the button so the user knows
///   *something* is happening without blocking the UI.
public enum LoadingState: Equatable, Sendable {
    case idle
    case loading
    case refreshing
}

/// Visual treatment for a refresh button that needs to show both user-
/// initiated loading (button disabled) and background polling (small dot).
struct RefreshIndicatorModifier: ViewModifier {
    let state: LoadingState
    let language: L10n

    func body(content: Content) -> some View {
        content
            .disabled(state == .loading)
            .help(state == .refreshing ? language.alreadyRefreshing : "")
            .overlay(alignment: .topTrailing) {
                if state == .refreshing {
                    Circle()
                        .fill(.orange)
                        .frame(width: 5, height: 5)
                        .padding(4)
                        .transition(.opacity)
                        .accessibilityHidden(true)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: state)
    }
}

public extension View {
    /// Apply the `LoadingState` styling described in spec §5.6. The
    /// modifier must be applied to the button (or its container) — the
    /// trailing-edge orange dot is positioned relative to the view it
    /// wraps.
    func refreshIndicator(_ state: LoadingState, language: L10n) -> some View {
        modifier(RefreshIndicatorModifier(state: state, language: language))
    }
}
