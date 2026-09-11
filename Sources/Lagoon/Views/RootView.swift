import SwiftUI

/// Top-level surface for a connected account. Owns the AI action undo controller
/// and the language picker. Surfaces global shortcuts and a usage indicator.
struct RootView: View {
    @State private var surface: Surface = .briefing
    @AppStorage(LanguagePreference.defaultsKey) private var languageTag = AppLanguage.zhHans.rawValue
    @StateObject private var undo = UndoController()
    @State private var showSearch = false
    @State private var showUsage = false

    enum Surface: String, CaseIterable, Identifiable {
        case briefing
        case allMessages
        var id: String { rawValue }
    }

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
        .environmentObject(undo)
        .toolbar { toolbar }
        .sheet(isPresented: $showSearch) {
            SearchSheet()
        }
        .sheet(isPresented: $showUsage) {
            UsageSheet()
        }
        .onAppear { undo.bind(AccountStore()) }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
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
        }
        ToolbarItemGroup(placement: .automatic) {
            Button { showSearch = true } label: {
                Label(l10n.search, systemImage: "magnifyingglass")
            }
            .keyboardShortcut("f", modifiers: .command)
            .help(l10n.shortcutSearch)
            Button { showUsage = true } label: {

                Label(l10n.budgetThisMonth, systemImage: "chart.bar")

            }

            .keyboardShortcut("b", modifiers: [.command])

        }

    }

}

