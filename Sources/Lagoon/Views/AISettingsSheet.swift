import SwiftUI
import LagoonKit

/// V1 AI settings: MiniMax key + base URL + model + monthly budget.
///
/// Reads/writes the same Keychain `lagoon.envJSON` dict the embedded server
/// boots from — editing only the 4 AI keys, preserving everything else
/// (provider config path, legacy migrates).
///
/// ## Why saving applies immediately
///
/// Saving used to end with "restart the app to apply", because the server
/// built its `AIGateway` once at launch and the routes captured that
/// instance. A key is a credential; changing one does not require
/// rebuilding the process. So the server keeps its gateway behind a
/// holder, and a save posts the stored environment to
/// `POST /api/ai/reload`, which rebuilds the gateway in place.
///
/// The sheet therefore reports what actually happened: **applied**, or a
/// failure with a way out. It never claims success for a reload that did
/// not happen — the Keychain write and the reload are two separate acts,
/// and only the second one makes the key live.
struct AISettingsSheet: View {
    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss
    var aiStatus: AIStatus? = nil
    /// Called after a save that the server accepted.
    ///
    /// The parent holds the AI status the *banner* reads, and that value
    /// is polled on a 30-second cadence. Without this callback the user
    /// would save a key and still see "AI 未配置" for the next half
    /// minute — the product contradicting itself a second after it
    /// promised the key was live.
    var onApplied: (AIStatus) -> Void = { _ in }

    @State private var apiKey = ""
    @State private var baseURL = ""
    @State private var model = ""
    @State private var budgetUSD = ""
    @State private var showKey = false
    @State private var isSaving = false
    @State private var savedBanner: String?
    @State private var errorBanner: ErrorBanner?
    /// The status *after* the reload, not the one the sheet was opened
    /// with. The dot at the top of the sheet has to reflect the state the
    /// user is looking at right now — after saving a key, the old
    /// "AI 未配置" would be a lie for as long as the sheet stayed open.
    @State private var liveStatus: AIStatus?
    /// The last 「测试连接」 outcome. Nil = never tested (or the form has
    /// changed since), so the row renders nothing rather than a stale
    /// green tick for settings the user has since edited.
    @State private var testResult: TestResult?
    @State private var isTesting = false
    private let api = APIClient.shared

    /// What a 「测试连接」 run ended in.
    ///
    /// Three cases, kept apart because they have three different fixes:
    /// fill in a key, try again (the network or the server), check what
    /// was typed (the server took the settings and still could not use
    /// them). Collapsing them into one "failed" would make the user guess.
    enum TestResult: Equatable {
        case succeeded
        /// The key field was empty. Decided here, with no request sent.
        case emptyKey
        /// The request itself did not complete — network, timeout, or the
        /// server answered non-2xx.
        case requestFailed(String)
        /// The server accepted the settings and reported the AI
        /// unconfigured: the endpoint, the model name or the key is wrong.
        case notConfigured
        /// The test ran and the stored configuration could not be put back.
        /// The live service may be running the tested, unsaved settings.
        case restoreFailed

        var isSuccess: Bool {
            if case .succeeded = self { return true }
            return false
        }

        /// The verdict for a status the server reported after taking the
        /// tested settings. Pure, so the mapping is testable without a
        /// server: `configured == false` means the settings were accepted
        /// and are still unusable, which is a different failure from "the
        /// request did not complete".
        static func from(_ status: AIStatus) -> TestResult {
            status.configured ? .succeeded : .notConfigured
        }
    }

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

            if let status = liveStatus ?? aiStatus {
                HStack(spacing: 6) {
                    Circle()
                        // The theme's scale, not a hard-coded green: the
                        // colour means "working" / "not working" everywhere
                        // else too, and the text beside it says the same
                        // thing — so the dot is never the only carrier.
                        .fill(
                            status.configured
                                ? LagoonTheme.Severity.success.color
                                : LagoonTheme.Severity.warning.color
                        )
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
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
            if let testResult {
                testResultRow(testResult)
            }
            Text(l10n.aiSettingsApplyHint).font(.caption2).foregroundStyle(.tertiary)

            HStack {
                // 测试连接 sits on the leading side, away from 保存: they do
                // different things, and the destructive-looking one (throw
                // away the form) must not sit where the confirming one is.
                Button {
                    Task { await testConnection() }
                } label: {
                    HStack(spacing: 6) {
                        if isTesting { ProgressView().controlSize(.small) }
                        Text(l10n.aiTestConnection)
                    }
                }
                // Not disabled on an empty key: pressing it with a blank
                // field is a legitimate way to ask "is that why it is not
                // working?", and the answer is specific ("fill in a key")
                // rather than a dead button with no explanation. It stays
                // disabled mid-test, which is what prevents two reloads
                // racing over the same gateway.
                .disabled(isTesting || isSaving)
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
                .disabled(isSaving || isTesting || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .noticeBanner($errorBanner)
        .frame(minWidth: 460, maxWidth: 460)
        .task { load() }
        // A green 「连接成功」 must not survive the user editing the fields.
        // It describes the settings that were tested, and the moment one of
        // them changes it describes nothing — a stale tick next to a key the
        // user just corrected is the product confirming something it never
        // checked. The key/URL/model are the inputs the test sends; the
        // budget is not, so editing it leaves the verdict valid.
        .onChange(of: apiKey) { _, _ in testResult = nil }
        .onChange(of: baseURL) { _, _ in testResult = nil }
        .onChange(of: model) { _, _ in testResult = nil }
    }

    /// One outcome row: symbol + colour + sentence.
    ///
    /// The symbol carries the meaning as well as the colour does, so the
    /// result survives a colour-blind reader — the same rule the status
    /// dot at the top of the sheet follows.
    @ViewBuilder
    private func testResultRow(_ result: TestResult) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: result.isSuccess
                  ? LagoonTheme.Severity.success.icon
                  : LagoonTheme.Severity.error.icon)
                .foregroundStyle(result.isSuccess
                                 ? LagoonTheme.Severity.success.color
                                 : LagoonTheme.Severity.error.color)
                .accessibilityHidden(true)
            Text(testResultText(result))
                .font(.callout)
                .foregroundStyle(result.isSuccess
                                 ? LagoonTheme.Severity.success.color
                                 : LagoonTheme.Severity.error.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func testResultText(_ result: TestResult) -> String {
        switch result {
        case .succeeded: return l10n.aiTestSucceeded
        case .emptyKey: return l10n.aiTestEmptyKey
        case .requestFailed(let reason): return l10n.aiTestRequestFailed + reason
        case .notConfigured: return l10n.aiTestNotConfigured
        case .restoreFailed: return l10n.aiTestRestoreFailed
        }
    }

    private func load() {
        errorBanner = nil
        do {
            let env = try AISettingsStore.load()
            apiKey = env[AIEnvironmentKeys.apiKey] ?? ""
            baseURL = env[AIEnvironmentKeys.baseURL] ?? ""
            model = env[AIEnvironmentKeys.model] ?? ""
            budgetUSD = env[AIEnvironmentKeys.budget] ?? ""
            // Empty key + empty everything = fresh install: seed the
            // MiniMax defaults so Save writes a working config, not blanks.
            if baseURL.isEmpty { baseURL = AISettingsStore.defaultBaseURL }
            if model.isEmpty { model = AISettingsStore.defaultModel }
        } catch {
            // INV-3: a banner must say *what* failed and *why*. The raw
            // error string is neither — it is a status code with no
            // subject. And INV-4: a Keychain read is retryable, so the
            // banner offers the retry.
            errorBanner = ErrorBanner(
                severity: .error,
                title: l10n.aiSettingsLoadFailed,
                detail: l10n.aiSettingsLoadFailedDetail,
                actionLabel: l10n.retry,
                action: { [self] in await self.load() }
            )
        }
    }

    /// Check the form's settings **without keeping them**.
    ///
    /// ## Why this reuses the reload route
    ///
    /// There is no "check these settings" route, and adding one would be a
    /// second code path that builds a gateway — free to disagree with the
    /// one a save actually uses. The reload route already does exactly what
    /// a test needs: it rebuilds the gateway from a given environment and
    /// answers with the resulting `AIStatus`. A test that used a different
    /// route would be answering a different question.
    ///
    /// ## Why it restores afterwards
    ///
    /// The reload has a side effect: it makes the sent configuration live.
    /// Pressing 「测试连接」 must not change what the app is running —
    /// testing is not saving, and a user who tests a typo'd key and then
    /// closes the sheet must not have silently disabled the AI.
    ///
    /// So: reload with the form's values, read the status, then **always**
    /// reload the stored configuration back. On success the status the
    /// server just reported is real ("this key works") and the restored
    /// configuration is what the user had before. If the restore itself
    /// fails, that is reported separately and loudly — the service may be
    /// running unsaved settings, and that is the one outcome the user must
    /// not be left guessing about.
    ///
    /// Nothing here writes to the Keychain. A test that went through
    /// `AISettingsStore.save` would persist a key the user never confirmed.
    private func testConnection() async {
        errorBanner = nil
        testResult = nil
        let typedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typedKey.isEmpty else {
            testResult = .emptyKey
            return
        }
        // A malformed base URL would be rejected by the save path's
        // validation before any request; doing the same here keeps the test
        // from reporting a network failure for a typo the form can name.
        do {
            try AISettingsStore.validateBaseURL(baseURL)
        } catch {
            testResult = .requestFailed(error.lagoonUIMessage)
            return
        }
        let stored: [String: String]
        do {
            stored = try AISettingsStore.load()
        } catch {
            // Restoring after the test needs the previous map in hand. Going
            // ahead without it would mean a failed test that cannot be
            // undone — the exact side effect this method exists to avoid.
            testResult = .requestFailed(error.lagoonUIMessage)
            return
        }
        let candidate = AISettingsStore.testEnvironment(
            stored: stored,
            apiKey: apiKey,
            baseURL: baseURL,
            model: model
        )

        isTesting = true
        defer { isTesting = false }

        // The tested status is read from this call and kept separately: the
        // restore below answers with the *old* configuration's status, which
        // says nothing about whether the key under test works.
        let tested: AIStatus
        do {
            tested = try await api.reloadAI(environment: candidate)
        } catch {
            // The request failed, so the user's answer is "the request
            // failed" — whatever the server did meanwhile, this is the
            // cause and the thing to fix.
            //
            // A restore is still attempted, because a throw does not prove
            // the server was left alone: a 2xx whose body failed to decode
            // applied the reload before the client gave up on reading the
            // answer. But its failure is **not** reported as
            // `restoreFailed`. When the test request failed, a restore
            // fails for the same reason — the service is unreachable — and
            // "the service may be running your unsaved settings" would be a
            // scary claim about a server that never received anything. The
            // alarming result is reserved for the one case where it is
            // known to be true: a test that succeeded and then could not be
            // undone.
            _ = await restore(stored: stored)
            testResult = .requestFailed(error.lagoonUIMessage)
            return
        }

        // Whatever the test found, the app goes back to the configuration it
        // had before the test — testing is not saving.
        let final = TestResult.from(tested)
        guard await restore(stored: stored) else {
            testResult = .restoreFailed
            errorBanner = ErrorBanner(
                severity: .error,
                title: l10n.aiTestRestoreFailed,
                detail: l10n.aiTestRestoreFailedDetail,
                actionLabel: l10n.retry,
                action: { [self] in await self.retryRestore(stored, then: final) }
            )
            return
        }
        testResult = final
    }

    /// Try the restore again, and report the test's own outcome if it lands.
    ///
    /// The retry restores only — never saves. The alternative (a 「保存」
    /// button here) would write a key the user has not confirmed, to fix a
    /// problem they never caused.
    private func retryRestore(_ stored: [String: String], then result: TestResult) async {
        guard await restore(stored: stored) else { return }
        errorBanner = nil
        testResult = result
    }

    /// Reload the server with the configuration that was stored before the
    /// test. Returns whether that worked.
    ///
    /// ## The fresh-install case
    ///
    /// A fresh install has nothing stored. There is still something to undo:
    /// the test's own reload left the tested key live. The route rejects an
    /// empty environment as malformed — correctly, "reload with nothing" is
    /// not a request — so the way to say "no key" through it is a managed
    /// key with an empty value, which is the same statement the client's own
    /// merge makes (`AISettingsStore.merged` removes the key when the field
    /// is blank). Without this, a test on a fresh install would silently
    /// enable an AI the user never saved.
    private func restore(stored: [String: String]) async -> Bool {
        let target = stored.isEmpty
            ? [AIEnvironmentKeys.apiKey: ""]
            : stored
        do {
            let status = try await api.reloadAI(environment: target)
            // The live status is what the dot reads, and after a restore it
            // is the *stored* configuration's status again — the truth the
            // sheet should be showing.
            liveStatus = status
            onApplied(status)
            return true
        } catch {
            // Not logged and not swallowed: the caller turns `false` into a
            // banner the user reads. A second, quieter error here would be
            // the same fact told twice.
            return false
        }
    }

    private func save() async {
        errorBanner = nil
        savedBanner = nil
        isSaving = true
        defer { isSaving = false }
        // The stored map, so the reload sends exactly what was written —
        // not a re-derivation of it, which could disagree.
        var stored: [String: String]
        do {
            stored = try AISettingsStore.save(
                apiKey: apiKey,
                baseURL: baseURL,
                model: model,
                budgetUSD: budgetUSD
            )
        } catch {
            errorBanner = ErrorBanner(
                severity: .error,
                title: l10n.aiSettingsSaveFailed + error.lagoonUIMessage,
                detail: l10n.aiSettingsSaveFailedDetail,
                actionLabel: l10n.retry,
                action: { [self] in await self.save() }
            )
            return
        }

        // The Keychain write succeeded. Now make the key live.
        //
        // These are two different acts and the copy says so: the key is
        // stored, and the running server has to be told. If the reload
        // fails, the key is still safe in the Keychain and the user can
        // press 保存 again — so the banner says that, rather than
        // pretending the whole thing failed.
        do {
            let status = try await api.reloadAI(environment: stored)
            liveStatus = status
            savedBanner = status.configured
                ? l10n.aiSettingsApplied
                : l10n.aiSettingsAppliedNotConfigured
            // The parent must learn the new status now, not on its next
            // poll.
            onApplied(status)
        } catch {
            liveStatus = nil
            errorBanner = ErrorBanner(
                severity: .warning,
                title: l10n.aiSettingsReloadFailed + error.lagoonUIMessage,
                detail: l10n.aiSettingsReloadFailedDetail,
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
    static let apiKeyKey = AIEnvironmentKeys.apiKey
    static let baseURLKey = AIEnvironmentKeys.baseURL
    static let modelKey = AIEnvironmentKeys.model
    static let budgetKey = AIEnvironmentKeys.budget

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

    /// The map a test should send: this form's values laid over what is
    /// currently stored — and **not written anywhere**.
    ///
    /// Testing is not saving. A test that went through `save(...)` would put
    /// a never-confirmed key in the Keychain, where it would survive the
    /// sheet being cancelled and be used on the next launch. So the same
    /// merge is computed and handed straight to the caller, with the
    /// stored map it was built on, because the caller has to be able to put
    /// the old configuration back afterwards.
    ///
    /// The budget is deliberately taken from the *stored* map, not the
    /// field: a test asks "would this key/endpoint/model work", and the cap
    /// has no bearing on that. Sending a half-typed budget would also let a
    /// test fail on a validation the user never asked it to perform.
    static func testEnvironment(
        stored: [String: String],
        apiKey: String,
        baseURL: String,
        model: String
    ) -> [String: String] {
        merged(
            stored,
            apiKey: apiKey,
            baseURL: baseURL,
            model: model,
            // The stored cap, not the field: a test asks whether the
            // key/endpoint/model work, and the cap has no bearing on that.
            // A half-typed budget must not make the test fail on a
            // validation the user never asked it to perform.
            budgetUSD: stored[budgetKey] ?? ""
        )
    }

    /// A non-empty base URL must be an https URL with a host. Empty is fine
    /// — it means "use the default".
    ///
    /// Shared by Save and 测试连接 so the two cannot disagree about what
    /// counts as a usable endpoint: a test that accepted a URL Save rejects
    /// would report a network failure for a value the form would refuse,
    /// and the user would go looking at their network.
    static func validateBaseURL(_ baseURL: String) throws {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return }
        guard let url = URL(string: base),
              url.scheme?.lowercased() == "https", url.host != nil
        else { throw AISettingsError.badBaseURL(base) }
    }

    static func load() throws -> [String: String] {
        let raw = try KeychainStore.loadString(service: EmbeddedServer.envService)
        guard let raw, !raw.isEmpty else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: Data(raw.utf8))) ?? [:]
    }

    /// Writes the merged map to the Keychain and **returns what was
    /// written**.
    ///
    /// The return value is not a convenience: the caller reloads the
    /// server with exactly this map, and a re-read could disagree with
    /// what was just stored (a concurrent write, a partial merge). One
    /// map, written once, sent once.
    @discardableResult
    static func save(apiKey: String, baseURL: String, model: String, budgetUSD: String) throws -> [String: String] {
        // Validate the budget early: a non-numeric cap would boot-fine but
        // silently disable enforcement (`Double(...) ?? 0`). Fail in the
        // sheet, not at 2am when the bill arrives.
        let budget = budgetUSD.trimmingCharacters(in: .whitespacesAndNewlines)
        if !budget.isEmpty, Double(budget) == nil {
            throw AISettingsError.badBudget(budget)
        }
        try validateBaseURL(baseURL)
        let stored = try load()
        let next = merged(stored, apiKey: apiKey, baseURL: baseURL, model: model, budgetUSD: budgetUSD)
        let json = String(decoding: try JSONEncoder().encode(next), as: UTF8.self)
        try KeychainStore.saveString(json, service: EmbeddedServer.envService)
        return next
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
