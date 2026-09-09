import SwiftUI

/// Top-level surface for a connected account.
///
/// Spec §7.1: the Briefing Feed is the default landing surface; the raw
/// conversation list is a secondary view reachable from the feed. The switcher
/// lives in the window toolbar and each surface also carries an explicit button
/// (⌘0) so the raw list is always reachable.
struct RootView: View {
    enum Surface: String, CaseIterable, Identifiable {
        case briefing = "简报"
        case allMessages = "全部邮件"

        var id: String { rawValue }
    }

    @State private var surface: Surface = .briefing

    var body: some View {
        Group {
            switch surface {
            case .briefing:
                BriefingFeedView(onShowAllMessages: { surface = .allMessages })
            case .allMessages:
                MessageListView(onShowBriefing: { surface = .briefing })
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("界面", selection: $surface) {
                    ForEach(Surface.allCases) { surface in
                        Text(surface.rawValue).tag(surface)
                    }
                }
                .pickerStyle(.segmented)
                .help("在简报和全部邮件之间切换")
            }
        }
    }
}
