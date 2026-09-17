import SwiftUI

/// A user-facing error / warning / info notice (spec §2.1).
///
/// `Equatable` ignores the `action` closure so SwiftUI's diffing
/// identifies the banner by `id`. `title` and `detail` are already-
/// resolved strings (the view layer is the only place that can read
/// `L10n.current`, and the banner is constructed at call sites).
public struct ErrorBanner: Identifiable, Equatable, Sendable {
    public enum Severity: String, Equatable, Sendable {
        case info
        case warning
        case error
    }

    public let id = UUID()
    public let severity: Severity
    public let title: String
    public let detail: String?
    public let actionLabel: String?
    public let action: (@Sendable () async -> Void)?
    public let dismissible: Bool
    public let autoDismissAfter: Duration?

    public init(
        severity: Severity,
        title: String,
        detail: String? = nil,
        actionLabel: String? = nil,
        action: (@Sendable () async -> Void)? = nil,
        dismissible: Bool = true,
        autoDismissAfter: Duration? = nil
    ) {
        self.severity = severity
        self.title = title
        self.detail = detail
        self.actionLabel = actionLabel
        self.action = action
        self.dismissible = dismissible
        self.autoDismissAfter = autoDismissAfter
    }

    public static func == (lhs: ErrorBanner, rhs: ErrorBanner) -> Bool {
        lhs.id == rhs.id
    }
}

/// Renders one banner. Fixed 36pt height keeps the UI from reflowing
/// when a long `detail` shows up (spec INV-7).
struct NoticeBannerView: View {
    let banner: ErrorBanner
    let onDismiss: () -> Void
    @State private var actionInFlight = false
    @Environment(\.l10n) private var l10n

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: severityIcon)
                .foregroundStyle(severityColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title)
                    .font(.callout)
                    .bold()
                if let detail = banner.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let label = banner.actionLabel, let action = banner.action {
                Button {
                    Task {
                        actionInFlight = true
                        await action()
                        actionInFlight = false
                    }
                } label: {
                    if actionInFlight {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(label)
                    }
                }
                .disabled(actionInFlight)
                .controlSize(.small)
            }
            if banner.dismissible {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(l10n.dismiss)
                .help(l10n.dismiss)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minHeight: 36, maxHeight: 36)
        .background(severityColor.opacity(0.12))
        .overlay(
            Rectangle()
                .fill(severityColor)
                .frame(width: 3),
            alignment: .leading
        )
    }

    private var severityIcon: String {
        switch banner.severity {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "exclamationmark.octagon.fill"
        }
    }

    private var severityColor: Color {
        switch banner.severity {
        case .info: .blue
        case .warning: .orange
        case .error: .red
        }
    }
}

/// Wraps content with a top-of-viewport banner slot. Bind to
/// `ErrorCenter.shared.banner` at the root of the app.
struct NoticeBannerModifier: ViewModifier {
    @Binding var banner: ErrorBanner?

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            if let banner {
                NoticeBannerView(banner: banner, onDismiss: { self.banner = nil })
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            content
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: banner?.id)
        .onChange(of: banner?.autoDismissAfter) { _, duration in
            guard let duration else { return }
            Task { @MainActor in
                try? await Task.sleep(for: duration)
                withAnimation { self.banner = nil }
            }
        }
    }
}

public extension View {
    /// Apply at the highest view that should be covered by an error
    /// banner. Most apps want exactly one — at the top of `RootView`.
    func noticeBanner(_ banner: Binding<ErrorBanner?>) -> some View {
        modifier(NoticeBannerModifier(banner: banner))
    }
}
