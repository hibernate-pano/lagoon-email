import SwiftUI
import LagoonKit

/// V1 AI settings: MiniMax key + base URL + model + monthly budget.
///
/// Reads/writes the same Keychain `lagoon.envJSON` dict the embedded server
/// boots from — editing only the 4 AI keys, preserving everything else
/// (provider config path, legacy migrates). The server reads them once at
/// launch (`setenv` in `LagoonRuntime.start`), so saving prompts a restart;
/// there is no hot-reload in V1 by design.
struct AISettingsSheet: View {
    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss
    var aiStatus: AIStatus? = nil

    @State private var apiKey = ""
    @State private var baseURL = ""
    @State private var model = ""
    @State private var budgetUSD = ""
    @State private var showKey = false
    @State private var isSaving = false
    @State private var savedBanner: String?
    @State private var errorBanner: ErrorBanner?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(l10n.aiSettingsTitle, systemImage: "sparkles").font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(l10n.dismiss)
            }

            if let status = aiStatus {
                HStack(spacing: 6) {
                    Circle()
                        .fill(status.configured ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(status.configured ? l10n.aiSettingsConfigured : l10n.aiSettingsNotConfigured)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(l10n.aiSettingsApiKey).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Group {
                        if showKey {
                            TextField(l10n.aiSettingsApiKeyPlaceholder, text: $apiKey)
                        } else {
                            SecureField(l10n.aiSettingsApiKeyPlaceholder, text: $apiKey)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    Button {
                        showKey.toggle()
                    } label: {
                        Label(
                            showKey ? l10n.hideAuthCode : l10n.showAuthCode,
                            systemImage: showKey ? "eye.slash" : "eye"
                        )
                        .labelStyle(.iconOnly)
                    }
                    .help(showKey ? l10n.hideAuthCode : l10n.showAuthCode)
                }
                Text(l10n.aiSettingsApiKeyHelp).font(.caption2).foregroundStyle(.tertiary)
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(l10n.aiSettingsBaseURL).font(.caption).foregroundStyle(.secondary)
                    TextField("https://api.minimax.chat/v1", text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(l10n.aiSettingsModel).font(.caption).foregroundStyle(.secondary)
                    TextField("MiniMax-M3", text: $model)
                        .textFieldStyle(.roundedBorder)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(l10n.aiSettingsBudget).font(.caption).foregroundStyle(.secondary)
                TextField("10", text: $budgetUSD)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 140)
                Text(l10n.aiSettingsBudgetHelp).font(.caption2).foregroundStyle(.tertiary)
            }

            if let savedBanner {
                Text(savedBanner).font(.callout).foregroundStyle(.green)
            }
            Text(l10n.aiSettingsRestartHint).font(.caption2).foregroundStyle(.tertiary)

            HStack {
                Spacer()
                Button {
                    Task { await save() }
                } label: {
                    HStack(spacing: 6) {
                        if isSaving { ProgressView().controlSize(.small) }
                        Text(l10n.aiSettingsSave)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .noticeBanner($errorBanner)
        .frame(minWidth: 460, maxWidth: 460)
        .task { load() }
    }

    private func load() {
        errorBanner = nil
        do {
            let env = try AISettingsStore.load()
            apiKey = env["LLM_PROVIDER_PRIMARY_API_KEY"] ?? ""
            baseURL = env["LLM_PROVIDER_PRIMARY_BASE_URL"] ?? ""
            model = env["LLM_PROVIDER_PRIMARY_MODEL"] ?? ""
            budgetUSD = env["LAGOON_BUDGET_USD_PER_MONTH"] ?? ""
            // Empty key + empty everything = fresh install: seed the
            // MiniMax defaults so Save writes a working config, not blanks.
            if baseURL.isEmpty { baseURL = "https://api.minimax.chat/v1" }
            if model.isEmpty { model = "MiniMax-M3" }
        } catch {
            errorBanner = ErrorBanner(severity: .error, title: error.lagoonUIMessage)
        }
    }

    private func save() async {
        errorBanner = nil
        savedBanner = nil
        isSaving = true
        defer { isSaving = false }
        do {
            try AISettingsStore.save(
                apiKey: apiKey,
                baseURL: baseURL,
                model: model,
                budgetUSD: budgetUSD
            )
            savedBanner = l10n.aiSettingsSaved
        } catch {
            errorBanner = ErrorBanner(
                severity: .error,
                title: l10n.aiSettingsSaveFailed + error.lagoonUIMessage,
                actionLabel: l10n.retry,
                action: { [self] in await self.save() }
            )
        }
    }
}

/// Keychain read/write for the 4 AI keys. The merge is a pure function
/// (`merged`) so tests pin it without touching the Keychain: Save must
/// never drop unrelated keys (provider config path, future migrates).
enum AISettingsStore {
    static let apiKeyKey = "LLM_PROVIDER_PRIMARY_API_KEY"
    static let baseURLKey = "LLM_PROVIDER_PRIMARY_BASE_URL"
    static let modelKey = "LLM_PROVIDER_PRIMARY_MODEL"
    static let budgetKey = "LAGOON_BUDGET_USD_PER_MONTH"

    static let defaultBaseURL = "https://api.minimax.chat/v1"
    static let defaultModel = "MiniMax-M3"

    /// Overlay the 4 AI keys onto the stored env dict. Empty API key means
    /// "don't touch the key" is NOT the contract — empty key clears it, so
    /// the user can disable AI by blanking the field. Empty base URL / model
    /// fall back to the MiniMax defaults; empty budget clears the cap.
    static func merged(_ stored: [String: String], apiKey: String, baseURL: String, model: String, budgetUSD: String) -> [String: String] {
        var out = stored
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            out.removeValue(forKey: apiKeyKey)
        } else {
            out[apiKeyKey] = key
        }
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        out[baseURLKey] = base.isEmpty ? defaultBaseURL : base
        let mod = model.trimmingCharacters(in: .whitespacesAndNewlines)
        out[modelKey] = mod.isEmpty ? defaultModel : mod
        let budget = budgetUSD.trimmingCharacters(in: .whitespacesAndNewlines)
        if budget.isEmpty {
            out.removeValue(forKey: budgetKey)
        } else {
            out[budgetKey] = budget
        }
        return out
    }

    static func load() throws -> [String: String] {
        let raw = try KeychainStore.loadString(service: EmbeddedServer.envService)
        guard let raw, !raw.isEmpty else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: Data(raw.utf8))) ?? [:]
    }

    static func save(apiKey: String, baseURL: String, model: String, budgetUSD: String) throws {
        // Validate the budget early: a non-numeric cap would boot-fine but
        // silently disable enforcement (`Double(...) ?? 0`). Fail in the
        // sheet, not at 2am when the bill arrives.
        let budget = budgetUSD.trimmingCharacters(in: .whitespacesAndNewlines)
        if !budget.isEmpty, Double(budget) == nil {
            throw AISettingsError.badBudget(budget)
        }
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !base.isEmpty {
            guard let url = URL(string: base.isEmpty ? defaultBaseURL : base),
                  url.scheme?.lowercased() == "https", url.host != nil
            else { throw AISettingsError.badBaseURL(base) }
        }
        let stored = try load()
        let next = merged(stored, apiKey: apiKey, baseURL: baseURL, model: model, budgetUSD: budgetUSD)
        let json = String(decoding: try JSONEncoder().encode(next), as: UTF8.self)
        try KeychainStore.saveString(json, service: EmbeddedServer.envService)
    }
}

enum AISettingsError: LocalizedError {
    case badBudget(String)
    case badBaseURL(String)

    var errorDescription: String? {
        switch self {
        case .badBudget(let v): return "每月上限不是数字：\(v)"
        case .badBaseURL(let v): return "接口地址无效（需要 https）：\(v)"
        }
    }
}
