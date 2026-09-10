import Foundation
import SwiftUI
import LagoonKit

/// Persisted UI language preference (UserDefaults).
public enum LanguagePreference {
    public static let defaultsKey = "lagoon.language"

    public static var stored: AppLanguage {
        let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        return AppLanguage(rawValue: raw) ?? .zhHans
    }
}

/// Every user-visible string, in both languages.
///
/// A plain value type rather than a String Catalog: the app is a bare SwiftPM
/// executable with no resource bundle, and switching language must re-render
/// immediately without relaunching. Strings sit side by side so a translation
/// is one line to add and impossible to forget.
public struct L10n: Sendable, Equatable {
    public let language: AppLanguage

    public init(language: AppLanguage) {
        self.language = language
    }

    /// Strings for non-View code (stores, clients) that cannot read the
    /// SwiftUI environment. Views get theirs injected instead.
    public static var current: L10n { L10n(language: LanguagePreference.stored) }

    private func pick(_ zh: String, _ en: String) -> String {
        language == .zhHans ? zh : en
    }

    // MARK: - Briefing groups

    public func groupTitle(_ group: BriefingGroup) -> String {
        switch group {
        case .needsReply: pick("需要回复", "Needs reply")
        case .awaitingReply: pick("等待对方回复", "Awaiting their reply")
        case .safeToArchive: pick("可归档", "Safe to archive")
        case .subscriptionNoise: pick("订阅噪音", "Subscription noise")
        case .pinned: pick("已置顶", "Pinned")
        }
    }

    /// Display text for a server reason code. Unknown codes show nothing rather
    /// than leaking a raw identifier into the UI.
    public func reasonText(_ code: String?) -> String? {
        guard let code, let reason = BriefingReason(rawValue: code) else { return nil }
        return switch reason {
        case .pinned: pick("你置顶了这封", "Pinned by you")
        case .listUnsubscribe: pick("带有退订链接", "Has a List-Unsubscribe header")
        case .subscriptionSender: pick("订阅或免回复发件人", "Newsletter or no-reply sender")
        case .fromSelf: pick("你发出的 —— 等待对方回复", "Sent by you — awaiting their reply")
        case .readAndOld: pick("已读且超过 7 天", "Read and older than 7 days")
        case .needsReply: pick("需要你回复", "Needs your reply")
        case .ai: pick("AI 分类", "AI classification")
        case .unclassified: pick("未分类", "Unclassified")
        }
    }

    // MARK: - Shared

    public var refresh: String { pick("刷新", "Refresh") }
    public var retry: String { pick("重试", "Retry") }
    public var noSubject: String { pick("（无主题）", "(no subject)") }
    public var unknownError: String { pick("未知错误", "Unknown error") }
    public var allMessages: String { pick("全部邮件", "All messages") }
    public var briefing: String { pick("简报", "Briefing") }
    public var languageLabel: String { pick("语言", "Language") }
    public var surface: String { pick("界面", "Surface") }
    public var surfaceHelp: String {
        pick("在简报和全部邮件之间切换", "Switch between the Briefing Feed and the raw message list")
    }

    // MARK: - Briefing feed

    public var showRawListHelp: String {
        pick("查看全部邮件列表（⌘0）", "Show the raw message list (⌘0)")
    }
    public var backToBriefingHelp: String {
        pick("返回简报（⌘0）", "Back to the Briefing Feed (⌘0)")
    }
    public var loadingBriefing: String { pick("正在加载简报…", "Loading briefing…") }
    public var noBriefingYet: String { pick("还没有简报", "No briefing yet") }
    public var noBriefingYetDescription: String {
        pick(
            "服务器还没有分类任何邮件，正在后台持续同步。",
            "The server has not classified any messages yet. It keeps syncing in the background."
        )
    }
    public var briefingUnavailable: String { pick("简报不可用", "Briefing unavailable") }
    public func expandGroup(_ title: String) -> String {
        pick("展开 \(title)", "Expand \(title)")
    }
    public func collapseGroup(_ title: String) -> String {
        pick("收起 \(title)", "Collapse \(title)")
    }
    public var briefingFailed: String { pick("简报加载失败：", "Briefing failed: ") }
    public var notConnected: String { pick("未连接", "Not connected") }
    public var connectToRead: String {
        pick("请先连接 Gmail 账号以阅读邮件。", "Connect a Gmail account to read messages.")
    }

    // MARK: - Message list

    public var noMessagesYet: String {
        pick("还没有邮件 —— 服务器仍在同步。", "No messages yet — the server is still syncing.")
    }
    public var syncFailed: String { pick("同步失败：", "Sync failed: ") }
    public var isServerRunning: String { pick("服务器在运行吗？", "Is the server running?") }

    // MARK: - Message detail

    public var summarizing: String { pick("正在生成摘要…", "Summarizing…") }
    public var summarize: String { pick("生成摘要", "Summarize") }
    public var summarizeHelp: String {
        pick("让服务器生成 AI 摘要和行动项", "Ask the server for an AI summary and action items")
    }
    public func recipient(_ value: String) -> String { pick("收件人 \(value)", "to \(value)") }
    public var loadingMessage: String { pick("正在加载邮件…", "Loading message…") }
    public var couldNotLoadMessage: String { pick("无法加载这封邮件", "Could not load this message") }
    public var noPlainTextBody: String {
        pick("这封邮件没有纯文本正文。", "This message has no plain-text body.")
    }
    public var actionItems: String { pick("行动项", "Action items") }
    public func viaProvider(_ provider: String) -> String { pick("由 \(provider) 生成", "via \(provider)") }
    public var aiSummary: String { pick("AI 摘要", "AI summary") }
    public var aiNotConfigured: String {
        pick(
            "AI 未配置（缺少 LLM_PROVIDER_PRIMARY_API_KEY）",
            "AI not configured (missing LLM_PROVIDER_PRIMARY_API_KEY)"
        )
    }
    public var unknownSender: String { pick("未知发件人", "Unknown sender") }
    public var pin: String { pick("置顶", "Pin") }
    public var unpin: String { pick("取消置顶", "Unpin") }
    public var pinHelp: String { pick("置顶这封邮件", "Pin this message") }
    public var unpinHelp: String { pick("取消置顶这封邮件", "Unpin this message") }
    public var markReadFailed: String { pick("标记已读失败：", "Could not mark as read: ") }
    public var pinFailed: String { pick("置顶失败：", "Could not pin: ") }
    public var unpinFailed: String { pick("取消置顶失败：", "Could not unpin: ") }
    public var summaryFailed: String { pick("摘要失败：", "Summary failed: ") }

    // MARK: - Connect

    public var connectPrompt: String { pick("连接你的 Gmail 开始使用。", "Connect your Gmail to begin.") }
    public var connectGmail: String { pick("连接 Gmail", "Connect Gmail") }
    public var waitingForApproval: String {
        pick("等待浏览器授权…", "waiting for browser approval…")
    }
    public var afterApproval: String {
        pick("在浏览器中完成授权后回到这里。", "After approving in the browser, return here.")
    }
    public var stillNotConnected: String { pick("仍未连接 —— 请重试", "still not connected — try again") }
    public var saveAccountFailed: String { pick("保存账号失败：", "Could not save account: ") }
    public var checkConnectionFailed: String {
        pick("检查连接失败：", "Could not check connection: ")
    }

    // MARK: - Infrastructure errors

    public var readSavedAccountFailed: String {
        pick("读取已保存账号失败：", "Could not read saved account: ")
    }
    public var invalidServerURL: String { pick("服务器地址无效：", "Invalid server URL: ") }
    public var nonHTTPResponse: String {
        pick("服务器返回了非 HTTP 响应。", "The server returned a non-HTTP response.")
    }
    public func httpStatus(_ code: Int) -> String {
        pick("服务器返回 HTTP \(code)：", "Server returned HTTP \(code): ")
    }
    public var keychainError: String { pick("钥匙串错误：", "Keychain error: ") }
    public var unknownKeychainError: String { pick("未知的钥匙串错误", "unknown keychain error") }
    public var corruptAccountID: String {
        pick(
            "钥匙串错误：已保存的账号 ID 不是合法的 UUID。",
            "Keychain error: stored account id is not a valid UUID."
        )
    }
}

// MARK: - SwiftUI environment

private struct L10nEnvironmentKey: EnvironmentKey {
    static let defaultValue = L10n(language: .zhHans)
}

public extension EnvironmentValues {
    var l10n: L10n {
        get { self[L10nEnvironmentKey.self] }
        set { self[L10nEnvironmentKey.self] = newValue }
    }
}
