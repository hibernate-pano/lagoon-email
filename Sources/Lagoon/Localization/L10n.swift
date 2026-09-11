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
    public var markRead: String { pick("标为已读", "Mark read") }
    public var pinFailed: String { pick("置顶失败：", "Could not pin: ") }
    public var unpinFailed: String { pick("取消置顶失败：", "Could not unpin: ") }
    public var summaryFailed: String { pick("摘要失败：", "Summary failed: ") }

    // MARK: - Connect

    public var connectPrompt: String { pick("连接你的邮箱开始使用。", "Connect your mailbox to begin.") }
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

    // MARK: - Connect (QQ / IMAP)

    public var connectQQTab: String { pick("QQ 邮箱", "QQ Mail") }
    public var connectQQTitle: String { pick("连接 QQ 邮箱", "Connect QQ Mail") }
    public var qqEmailPlaceholder: String { pick("QQ 邮箱地址", "QQ email address") }
    public var qqAuthCodePlaceholder: String { pick("授权码", "Authorization code") }
    public var qqHelp: String {
        pick(
            "在 QQ 邮箱网页版：设置 → 账户 → POP3/IMAP/SMTP 服务，开启 IMAP/SMTP 后生成授权码（不是登录密码）。",
            "In QQ Mail: Settings → Account → POP3/IMAP/SMTP service. Enable IMAP/SMTP and generate an authorization code (not your login password)."
        )
    }
    public var qqConnectButton: String { pick("连接", "Connect") }
    public var qqMissingFields: String {
        pick("请填写邮箱地址和授权码。", "Enter both the email address and the authorization code.")
    }
    public var qqAuthFailed: String {
        pick("授权码被拒绝 —— 请重新生成后重试。", "The authorization code was rejected — generate a new one and retry.")
    }
    public var qqUnreachable: String {
        pick("无法连接 QQ 邮箱服务器，请检查网络后重试。", "Could not reach the QQ Mail servers — check your network and retry.")
    }
    public var qqAccountExists: String { pick("该 QQ 邮箱已经接入过了。", "That QQ mailbox is already connected.") }
    public var connectFailed: String { pick("连接失败：", "Connect failed: ") }

    // MARK: - Accounts directory

    public var accountsMenuHelp: String { pick("账号", "Accounts") }
    public var addAccount: String { pick("添加账号", "Add account") }
    public var activateAccount: String { pick("切换到这个账号", "Switch to this account") }
    public var activateAccountFailed: String { pick("切换账号失败：", "Could not switch account: ") }
    public var deleteAccountFailed: String { pick("删除这个账号失败：", "Could not remove this account: ") }
    public func providerName(_ kind: MailProviderKind) -> String {
        switch kind {
        case .gmail: return pick("Gmail", "Gmail")
        case .qq: return pick("QQ 邮箱", "QQ Mail")
        }
    }

    // MARK: - Sync health

    public var reconnect: String { pick("重新连接", "Reconnect") }
    public func healthStatusText(_ status: SyncHealth.Status) -> String {
        switch status {
        case .ok: return pick("同步正常", "Syncing")
        case .degraded: return pick("同步不稳定", "Sync degraded")
        case .needsReconnect: return pick("需要重新连接", "Reconnect needed")
        case .error: return pick("同步失败", "Sync failed")
        }
    }
    public var healthDegraded: String { pick("同步不稳定：", "Sync degraded: ") }
    public var healthNeedsReconnect: String {
        pick("授权已失效 —— 重新连接后继续同步。", "Authorization expired — reconnect to keep syncing.")
    }
    public var healthError: String { pick("同步失败：", "Sync failed: ") }
    public var archiveUnavailable: String {
        pick("这个邮箱没有可用的归档文件夹。", "This mailbox has no usable archive folder.")
    }

    // MARK: - Actions
    public var undo: String { pick("撤销", "Undo") }
    public var undoLastAction: String { pick("撤销上一操作", "Undo last action") }
    public var nothingToUndo: String { pick("没有可撤销的操作", "Nothing to undo") }
    public var archived: String { pick("已归档", "Archived") }
    public var archivedLocallyOnly: String { pick("已在本地归档（远端需 Gmail.modify 权限）",
                                              "Archived locally; remote needs Gmail.modify") }
    public var unsubscribed: String { pick("已退订", "Unsubscribed") }
    public var unsubscribe: String { pick("退订", "Unsubscribe") }
    public var pinning: String { pick("正在置顶…", "Pinning…") }
    public var draftVariants: String { pick("AI 草稿（3 个版本）", "AI drafts (3 variants)") }
    public var chooseAndSendToGmail: String { pick("选这个 → 存到 Gmail Drafts",
                                              "Use this → save to Gmail Drafts") }
    public var chooseOnly: String { pick("只选中", "Select only") }
    public var generatingDrafts: String { pick("正在生成 3 个草稿…", "Generating 3 drafts…") }
    public var draftFailed: String { pick("生成草稿失败：", "Draft generation failed: ") }
    public var pickOne: String { pick("选一个版本", "Pick a version") }
    public var variant: String { pick("版本", "Variant") }
    public var search: String { pick("搜索", "Search") }
    public var searchPlaceholder: String { pick("搜索邮件（发件人、主题、正文）", "Search mail (sender, subject, body)") }
    public var noResults: String { pick("没找到匹配邮件", "No matching messages") }
    public var budgetThisMonth: String { pick("本月 LLM 用量", "This month's LLM usage") }
    public var budgetCap: String { pick("上限", "Cap") }
    public var budgetDisabled: String { pick("未启用（上限设为 0）", "Disabled (cap is 0)") }
    public var overrideGroup: String { pick("改分组为…", "Change group to…") }
    public var overrideApplied: String { pick("已记录你的偏好", "Noted your preference") }
    public var newMail: String { pick("新邮件！", "New mail!") }
    public var collapse: String { pick("收起", "Collapse") }
    public var expand: String { pick("展开", "Expand") }
    public var sender: String { pick("发件人", "Sender") }
    public var newer: String { pick("更新的", "Newer") }
    public var older: String { pick("更早的", "Older") }
    public var nextInGroup: String { pick("下一封", "Next") }
    public var previousInGroup: String { pick("上一封", "Previous") }
    public var archiveAndNext: String { pick("归档并跳到下一封", "Archive & next") }
    public var markUnread: String { pick("标为未读", "Mark unread") }
    public var mailArchivedLocally: String { pick("已在本地归档（远端需要 gmail.modify scope）",
                                              "Archived locally (remote needs gmail.modify)") }
    public var opening: String { pick("正在打开…", "Opening…") }
    public var nothingHereYet: String { pick("还没有内容", "Nothing here yet") }
    public var inboxZero: String { pick("收件箱已清空 🎉", "Inbox zero 🎉") }
    public var tapGmailToSync: String { pick("点击 Gmail 让 Lagoon 开始同步。", "Connect Gmail to start syncing.") }
    public var copiedToClipboard: String { pick("已复制", "Copied") }
    public var commandPalette: String { pick("命令面板", "Command palette") }
    public var shortcutArchiveNext: String { pick("E = 归档并下一封", "E = archive & next") }
    public var shortcutJ: String { pick("J = 下一封", "J = next") }
    public var shortcutK: String { pick("K = 上一封", "K = previous") }
    public var shortcutZ: String { pick("⌘Z = 撤销", "⌘Z = undo") }
    public var shortcutRefresh: String { pick("⌘R = 刷新", "⌘R = refresh") }
    public var shortcutSummarize: String { pick("⌘D = AI 摘要", "⌘D = AI summary") }
    public var shortcutDraft: String { pick("⌘⇧D = 起草回复", "⌘⇧D = draft reply") }
    public var shortcutSearch: String { pick("⌘F = 搜索", "⌘F = search") }
    public var shortcutHelp: String { pick("? = 快捷键", "? = shortcuts") }

    // MARK: - Reply composer

    public var reply: String { pick("回复", "Reply") }
    public var replyHelp: String { pick("回复这封邮件", "Reply to this message") }
    public var replyTitle: String { pick("回复邮件", "Reply") }
    public var replyTo: String { pick("收件人", "To") }
    public var replyBodyPlaceholder: String { pick("写回复…", "Write your reply…") }
    public var send: String { pick("发送", "Send") }
    public var sending: String { pick("发送中…", "Sending…") }
    public var sendFailed: String { pick("发送失败：", "Send failed: ") }
    public var sent: String { pick("已发送", "Sent") }
    public func sentTo(_ address: String) -> String { pick("已发送给 \(address)", "Sent to \(address)") }
    public var emptyReply: String { pick("回复内容不能为空。", "The reply cannot be empty.") }
    public var cancel: String { pick("取消", "Cancel") }
    public var shortcutSend: String { pick("⌘↩ = 发送", "⌘↩ = send") }

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
