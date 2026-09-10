import SwiftUI

/// Top-level surface for a connected account.
///
/// Spec §7.1: the Briefing Feed is the default landing surface; the raw
/// conversation list is a secondary view reachable from the feed. The switcher
/// lives in the window toolbar and each surface also carries an explicit button
/// (⌘0) so the raw list is always reachable.
///
/// This view owns the UI language: it persists the choice, injects `L10n` into
/// the environment for every child view, and exposes the toolbar picker.
struct RootView: View {
    enum Surface: String, CaseIterable, Identifiable {
        case briefing
        case allMessages

        var id: String { rawValue }
    }

    @State private var surface: Surface = .briefing
    @AppStorage(LanguagePreference.defaultsKey) private var languageTag = AppLanguage.zhHans.rawValue

    private var language: AppLanguage { AppLanguage(rawValue: languageTag) ?? .zhHans }
    private var l10n: L10n { L10n(language: language) }

    var body: some View {
        Group {
            switch surface {
            case .briefing:
                BriefingFeedView(onShowAllMessages: { surface = .allMessages })
            case .allMessages:
                MessageListView(onShowBriefing: { surface = .briefing })
            }
        }
        .environment(\.l10n, l10n)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker(l10n.surface, selection: $surface) {
                    ForEach(Surface.allCases) { item in
                        Text(item == .briefing ? l10n.briefing : l10n.allMessages).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .help(l10n.surfaceHelp)
            }
            ToolbarItem(placement: .primaryAction) {
                Picker(l10n.languageLabel, selection: $languageTag) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .help(l10n.languageLabel)
            }
        }
    }
}
