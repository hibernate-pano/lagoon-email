import Foundation

/// The AI settings strings.
///
/// They live here rather than in `L10n.swift` so that the file that
/// *defines* the feature and the file that *says* what it does are
/// separate. Two features that each need a string can then work at the
/// same time without both editing the same 2000-line file.
extension L10n {
    // MARK: - AI settings

    /// The title of the AI settings sheet.
    public var aiSettingsTitle: String { pick("AI 设置", "AI Settings") }
    public var aiSettingsApiKey: String { pick("API Key", "API Key") }
    /// The placeholder in the key field.
    ///
    /// It used to say "MiniMax API Key", which made the field look like
    /// it only accepted one provider. The endpoint is configurable and
    /// the server speaks the OpenAI-compatible dialect, so the field
    /// accepts MiniMax, OpenAI and a local Ollama alike — and saying so
    /// is what stops the user from hunting for a MiniMax account when
    /// they already have an OpenAI one.
    public var aiSettingsApiKeyPlaceholder: String {
        pick("服务商 API Key", "Provider API Key")
    }
    public var aiSettingsApiKeyHelp: String {
        pick(
            "在服务商开放平台申请，仅存于本机钥匙串，不会离开这台 Mac。调用时会把邮件文本发给模型服务商："
                + "分类只发发件人、主题和正文前 200 字；摘要和草稿会发更多正文。",
            "Get one from your provider's platform. Stored only in this Mac's Keychain; it never leaves this Mac. "
                + "Calls do send mail text to the model provider: classification sends the sender, the subject "
                + "and the first 200 characters of the body; summaries and drafts send more of the body."
        )
    }
    public var aiSettingsBaseURL: String { pick("接口地址", "Base URL") }
    public var aiSettingsModel: String { pick("模型", "Model") }
    public var aiSettingsBudget: String { pick("每月上限（美元）", "Monthly cap (USD)") }
    public var aiSettingsBudgetHelp: String {
        pick("设为 0 表示不限制。", "0 means no limit.")
    }
    public var aiSettingsSave: String { pick("保存", "Save") }
    /// The confirmation after a save that reached the running server.
    ///
    /// It used to say "已保存，重启 App 后生效" — which described the old
    /// architecture, not the product. The key now takes effect on save.
    public var aiSettingsApplied: String {
        pick("已生效，AI 现在可以用了。", "Applied — the AI is live.")
    }
    /// The confirmation after a save that reached the server but left the
    /// AI unconfigured.
    ///
    /// A separate string because "saved" and "working" are different
    /// facts. The key can be stored and the provider still unusable — a
    /// wrong base URL, a wrong model name. Saying only "已生效" there
    /// would be a lie the user discovers later, in the summary panel.
    public var aiSettingsAppliedNotConfigured: String {
        pick(
            "已保存，但 AI 还是没能连上服务商：检查接口地址和模型名，再保存一次。",
            "Saved, but the AI still cannot reach the provider. Check the base URL and the model name, then save again."
        )
    }
    public var aiSettingsSaveFailed: String { pick("保存失败：", "Could not save: ") }
    /// Why a save failed — the "why" half of INV-3.
    ///
    /// The title says the key could not be written to the Keychain; the
    /// detail says the key is still in the form, so the user knows whether
    /// to try again or to look for the cause.
    public var aiSettingsSaveFailedDetail: String {
        pick("密钥保存在本机钥匙串里，写入失败时 Key 仍在上面的输入框中，不会丢失。", "The key lives in this Mac's Keychain. It is still in the field above, so nothing was lost.")
    }
    /// The title of the "could not read the saved settings" banner.
    public var aiSettingsLoadFailed: String { pick("读取 AI 设置失败", "Could not read the AI settings") }
    /// The detail of the "could not read the saved settings" banner.
    public var aiSettingsLoadFailedDetail: String {
        pick("本机钥匙串不可用（可能拒绝了访问），所以读不到上次的配置。可以重新填写并保存。", "The Keychain is unavailable — access may have been denied — so the last configuration could not be read. You can fill it in again and save.")
    }
    public var aiSettingsConfigured: String { pick("AI 已配置", "AI configured") }
    public var aiSettingsNotConfigured: String { pick("AI 未配置", "AI not configured") }
    public var aiNotConfiguredTitle: String { pick("AI 未配置", "AI not configured") }
    public var aiNotConfiguredDetail: String {
        pick(
            "填上服务商 Key 即可启用摘要和草稿，邮件不受影响。",
            "Add your provider key to enable summaries and drafts; mail is unaffected."
        )
    }
    /// The line under the fields explaining when the key takes effect.
    ///
    /// It used to say a restart was needed. The key now applies the moment
    /// 保存 is pressed, and this line says so — because a user who was
    /// told "restart to apply" once will not believe the new promise
    /// unless the product says it out loud.
    public var aiSettingsApplyHint: String {
        pick(
            "保存后立即生效，不用重启 App。Key 只存本机钥匙串。",
            "Takes effect as soon as you save — no restart needed. The key stays in this Mac's Keychain."
        )
    }
    /// The title of the "the key was stored but the server did not take it"
    /// banner.
    public var aiSettingsReloadFailed: String { pick("服务没有接受新配置：", "The service did not accept the new configuration: ") }
    /// The detail of that banner.
    ///
    /// It has to say what *is* true — the key is safe in the Keychain —
    /// otherwise the user will re-paste the key they already pasted, and
    /// think the app is broken.
    public var aiSettingsReloadFailedDetail: String {
        pick(
            "Key 已经安全存在本机钥匙串里，没有丢失。点「重试」再让服务读一次，或重启 App。",
            "The key is safe in this Mac's Keychain — nothing was lost. Press Retry to have the service read it again, or restart the app."
        )
    }
}
