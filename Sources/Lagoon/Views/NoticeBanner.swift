import SwiftUI
import AppKit

/// A user-facing error / warning / info notice (spec §2.1).
///
/// `Equatable` ignores the `action` closure so SwiftUI's diffing
/// identifies the banner by `id`. `title` and `detail` are already-
/// resolved strings (the view layer is the only place that can read
/// `L10n.current`, and the banner is constructed at call sites).
public struct ErrorBanner: Identifiable, Equatable, Sendable {
    public enum Severity: String, Equatable, Sendable {
        case info
        /// A confirmation, not a problem.
        ///
        /// It used to be spelled `.info` for every success — archive, send,
        /// "已彻底删除 N 封" — which drew them all in blue with an
        /// `info.circle.fill`. A user glancing at a blue banner reads it as
        /// "something went wrong", because that is what blue banners are in
        /// every other app on the system. A success has its own colour and
        /// its own symbol, so "did it work?" and "did it break?" never look
        /// the same.
        case success
        case warning
        case error

        /// Maps onto the one severity scale in `LagoonTheme`.
        var theme: LagoonTheme.Severity {
            switch self {
            case .info: return .info
            case .success: return .success
            case .warning: return .warning
            case .error: return .error
            }
        }
    }

    public let id = UUID()
    public let severity: Severity
    public let title: String
    public let detail: String?
    public let actionLabel: String?
    public let action: (@Sendable () async -> Void)?
    /// Where to send the user when retrying cannot help (spec INV-5).
    ///
    /// A failure the user cannot fix by trying again — "the server
    /// negotiated no archive-capable folder" — must not offer a retry
    /// button, because pressing it cannot work. It must offer a way out
    /// instead, or the user is left staring at a failure with no next
    /// step. This is that way out.
    public let helpURL: URL?
    public let dismissible: Bool
    public let autoDismissAfter: Duration?

    public init(
        severity: Severity,
        title: String,
        detail: String? = nil,
        actionLabel: String? = nil,
        action: (@Sendable () async -> Void)? = nil,
        helpURL: URL? = nil,
        dismissible: Bool = true,
        autoDismissAfter: Duration? = nil
    ) {
        self.severity = severity
        self.title = title
        self.detail = detail
        self.actionLabel = actionLabel
        self.action = action
        self.helpURL = helpURL
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
                        // Two lines: enough for a sentence that says what
                        // failed and why, capped so a stack trace cannot
                        // push the mail off the screen.
                        .lineLimit(2)
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
            if let helpURL = banner.helpURL {
                // The escape hatch for failures retrying cannot fix. It sits
                // next to the action button rather than replacing it, so a
                // banner can offer both ("try again" and "ask for help").
                Button {
                    NSWorkspace.shared.open(helpURL)
                } label: {
                    Text(l10n.help)
                }
                .controlSize(.small)
                .help(l10n.help)
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
        // The height adapts; the old fixed 36pt could not hold a title *and* a
        // detail, so the reason a failure happened was always cut off — which
        // is the one thing the detail exists to say. The floor keeps a
        // title-only banner at the height the spec asked for, and the detail
        // is capped at two lines so a long sentence cannot push the content
        // down the screen.
        .frame(minHeight: 36)
        .background(severityColor.opacity(0.12))
        .overlay(
            Rectangle()
                .fill(severityColor)
                .frame(width: 3),
            alignment: .leading
        )
        // INV-9: Esc dismisses the banner. Without it, a failure the user
        // has read sits on screen until they find the ✕ with the mouse —
        // and the ✕ is a 12pt target in a 36pt strip.
        .onExitCommand { onDismiss() }
    }

    private var severityIcon: String {
        LagoonTheme.severityIcon(banner.severity.theme)
    }

    private var severityColor: Color {
        LagoonTheme.severityColor(banner.severity.theme)
    }
}

/// Wraps content with a top-of-viewport banner slot. Bind to
/// `ErrorCenter.shared.banner` at the root of the app.
struct NoticeBannerModifier: ViewModifier {
    @Binding var banner: ErrorBanner?
    /// Held so a replaced banner's timer cannot dismiss its successor. The
    /// handle is the only thing distinguishing "one banner waiting out its
    /// auto-dismiss" from "an orphan timer that will clear someone else's
    /// banner 6s from now".
    @State private var dismissTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            if let banner {
                NoticeBannerView(banner: banner, onDismiss: { self.banner = nil })
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            content
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: banner?.id)
        // Keyed on `id`, not `autoDismissAfter`: two consecutive banners with
        // the same duration (two 6s info toasts, say) share a Duration value,
        // so keying on it fired no onChange and the second banner inherited —
        // and inherited back the deadline of — the first one's timer.
        .onChange(of: banner?.id) { _, _ in
            dismissTask?.cancel()
            guard let duration = banner?.autoDismissAfter else { return }
            dismissTask = Task { @MainActor in
                try? await Task.sleep(for: duration)
                guard !Task.isCancelled else { return }
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
