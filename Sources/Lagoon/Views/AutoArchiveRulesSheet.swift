import SwiftUI
import LagoonKit

/// Management surface for the whitelist autopilot (spec 2026-09-19 §3).
/// Rule creation happens in the Briefing row menu; this sheet lists what is
/// on file and lets the user stop a sender.
struct AutoArchiveRulesSheet: View {
    @EnvironmentObject private var accounts: AccountStore
    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss
    @State private var rules: [AutoArchiveRule] = []
    @State private var suggestions: [AutoArchiveSuggestion] = []
    @State private var isLoading = true
    @State private var errorBanner: ErrorBanner?
    private let api = APIClient()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(l10n.autoArchiveRulesTitle).font(.headline)
                Spacer()
                Button(l10n.done) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            if let errorBanner {
                NoticeBannerView(banner: errorBanner) { self.errorBanner = nil }
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            Text(l10n.autoArchiveRulesHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding()
        }
        .frame(width: 460, height: 400)
        .task { await refresh() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView().padding()
        } else {
            List {
                if !suggestions.isEmpty {
                    Section {
                        ForEach(suggestions) { suggestion in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(suggestion.fromName ?? suggestion.sender)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(l10n.suggestionHint(suggestion.archiveCount))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(l10n.suggestionCreate) {
                                    Task { await accept(suggestion) }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    } header: {
                        Text(l10n.suggestionsHeader)
                            .font(.caption)
                            .bold()
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    if rules.isEmpty {
                        Text(l10n.autoArchiveRulesEmpty)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(rules) { rule in
                        HStack {
                            Text(rule.senderAddress)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(rule.senderAddress)
                            Spacer()
                            Button(role: .destructive) {
                                Task { await delete(rule) }
                            } label: {
                                Label(l10n.deleteRule, systemImage: "trash")
                            }
                            .labelStyle(.titleOnly)
                        }
                    }
                } header: {
                    Text(l10n.autoArchiveRulesTitle)
                        .font(.caption)
                        .bold()
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
        }
    }

    private func refresh() async {
        guard let accountId = accounts.accountId else {
            isLoading = false
            return
        }
        isLoading = rules.isEmpty
        do {
            rules = try await api.fetchAutoArchiveRules(accountId: accountId)
            errorBanner = nil
        } catch {
            errorBanner = ErrorBanner(severity: .error, title: error.lagoonUIMessage)
        }
        // Suggestions are best-effort: an empty history just means no rows.
        if let accountId = accounts.accountId {
            suggestions = (try? await api.fetchAutoArchiveSuggestions(accountId: accountId))?.suggestions ?? []
        }
        isLoading = false
    }

    /// 接受推荐 = 走既有的规则创建路由（幂等），从推荐区消失。
    private func accept(_ suggestion: AutoArchiveSuggestion) async {
        guard let accountId = accounts.accountId else { return }
        do {
            _ = try await api.addAutoArchiveRule(senderAddress: suggestion.sender, accountId: accountId)
            suggestions.removeAll { $0.sender == suggestion.sender }
            await refresh()
        } catch {
            errorBanner = ErrorBanner(severity: .error, title: error.lagoonUIMessage)
        }
    }

    private func delete(_ rule: AutoArchiveRule) async {
        guard let accountId = accounts.accountId else { return }
        do {
            try await api.deleteAutoArchiveRule(id: rule.id, accountId: accountId)
            rules.removeAll { $0.id == rule.id }
        } catch {
            errorBanner = ErrorBanner(
                severity: .error,
                title: l10n.deleteRuleFailed,
                detail: error.lagoonUIMessage,
                actionLabel: l10n.retry,
                action: { await delete(rule) }
            )
        }
    }
}
