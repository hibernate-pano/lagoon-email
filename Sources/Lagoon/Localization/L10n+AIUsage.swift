import Foundation

/// Strings for 「测试连接」 and the per-account spend breakdown (P2-07).
///
/// They live in their own file for the same reason `L10n+AI.swift` does:
/// the feature and the words it uses are edited together, and two features
/// that each add a string never have to touch the same 2000-line file.
extension L10n {
    // MARK: - 测试连接

    /// The label on the button that checks the form without saving it.
    public var aiTestConnection: String { pick("测试连接", "Test connection") }
    /// The result of a successful test.
    ///
    /// It says "press Save to keep them" on purpose. The test restores the
    /// stored configuration before it reports, so a success here means
    /// "these settings work", not "these settings are live" — and a
    /// confirmation that only said 「连接成功」 would be read as the latter.
    public var aiTestSucceeded: String {
        pick(
            "连接成功。这些设置可用——点「保存」后才会生效。",
            "Connected. These settings work — press Save to keep them."
        )
    }
    /// The result when the key field is blank.
    ///
    /// Decided on the client, without a request: a round trip that can only
    /// answer "no" teaches the user nothing.
    public var aiTestEmptyKey: String {
        pick("先填 API Key 再测试。", "Enter an API key before testing.")
    }
    /// The prefix when the test request itself did not complete.
    public var aiTestRequestFailed: String {
        pick("测试请求失败：", "The test request failed: ")
    }
    /// The result when the server took the settings and still could not use
    /// them — the key, the base URL or the model is wrong.
    public var aiTestNotConfigured: String {
        pick(
            "没连上：服务端试了这组设置，但仍然启用不了 AI。检查接口地址、模型名和 Key。",
            "Not connected: the service tried these settings and still could not enable the AI. Check the base URL, the model name and the key."
        )
    }
    /// The title of the banner shown when the stored configuration could not
    /// be put back after a test.
    ///
    /// This is the one outcome the user must not miss: the test may have
    /// left the live service running numbers that were never saved.
    public var aiTestRestoreFailed: String {
        pick(
            "测试结束，但服务没能恢复到已保存的设置。",
            "The test finished, but the saved configuration could not be restored."
        )
    }
    public var aiTestRestoreFailedDetail: String {
        pick(
            "服务可能在用刚才测试的设置。保存一次，或重新打开这个面板，让两边一致。",
            "The service may be running the settings you just tested. Save, or reopen this panel, to bring both sides back in line."
        )
    }

    // MARK: - 按账号花费

    /// The heading over the per-account rows in the usage panel.
    public var usageByAccount: String { pick("按账号分布", "Spend by account") }
    /// The note under the per-account rows.
    ///
    /// The rows are grouped from `usage_log`, so an account that has made no
    /// AI call this month has no row. Saying so stops "where is my other
    /// account?" from becoming a support question.
    public var usageByAccountHint: String {
        pick(
            "只列出本月有 AI 调用的账号。",
            "Only accounts with AI calls this month are listed."
        )
    }
    /// One account's call count, short enough for a row.
    ///
    /// The long form (`usageCallCount`) is a sentence for the panel's
    /// headline; a row needs two words.
    public func usageAccountCalls(_ count: Int) -> String {
        pick("\(count) 次", "\(count) calls")
    }
    /// The label in front of the month's spend.
    public var usageSpentLabel: String { pick("已花", "Spent") }
    /// The label in front of the monthly cap.
    public var usageCapLabel: String { pick("上限", "Cap") }
}
