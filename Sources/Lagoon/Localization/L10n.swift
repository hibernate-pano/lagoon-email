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
        case .replied: pick("你已回复 —— 可归档", "You replied — safe to archive")
        case .readAndOld: pick("已读且超过 7 天", "Read and older than 7 days")
        case .needsReply: pick("需要你回复", "Needs your reply")
        case .ai: pick("AI 分类", "AI classification")
        case .userOverride: pick("按你的分组偏好", "Uses your group preference")
        case .unclassified: pick("未分类", "Unclassified")
        }
    }

    // MARK: - Time saved (spec principle #3)

    /// The numbers are declared estimates — the bar and the detail popover
    /// both disclose it (same honesty rule as the usage panel).
    public var timeSavedEstimatedNote: String {
        pick("分钟数为按动作类型的估算值", "Minutes are per-action estimates")
    }
    public var timeSavedWeekTitle: String { pick("近 7 天", "Last 7 days") }
    public func timeSavedToday(minutes: String, handled: Int) -> String {
        pick("今天 ≈ 节省 \(minutes) 分钟 · 处理 \(handled) 封",
             "Today ≈ \(minutes) min saved · \(handled) handled")
    }
    public func timeSavedWeek(minutes: String, handled: Int) -> String {
        pick("本周 ≈ 节省 \(minutes) 分钟 · 处理 \(handled) 封",
             "This week ≈ \(minutes) min saved · \(handled) handled")
    }
    public func timeSavedWeekRow(_ day: String, minutes: String, handled: Int) -> String {
        pick("\(day)：≈ \(minutes) 分钟 · \(handled) 封",
             "\(day): ≈ \(minutes) min · \(handled) handled")
    }

    // MARK: - Auto-archive rules (whitelist autopilot, spec 2026-09-19 §3)

    public var autoArchiveSenderMenuItem: String {
        pick("自动归档此发件人", "Auto-archive this sender")
    }
    public var autoArchiveRuleFailed: String {
        pick("自动归档规则创建失败", "Could not create the auto-archive rule")
    }
    public var autoArchiveRulesTitle: String { pick("自动归档规则", "Auto-archive rules") }
    public var autoArchiveRulesEmpty: String {
        pick("还没有规则。在简报里右键一封订阅邮件，选「自动归档此发件人」即可创建。",
             "No rules yet. Right-click a subscription message in the Briefing and choose “Auto-archive this sender”.")
    }
    public var autoArchiveRulesHelp: String {
        pick("命中规则的邮件到达后自动归档，30 天内可撤销。", "Matching mail is archived on arrival and undoable for 30 days.")
    }
    public var deleteRule: String { pick("删除规则", "Delete rule") }
    public var deleteRuleFailed: String { pick("删除规则失败", "Could not delete the rule") }
    public var done: String { pick("完成", "Done") }

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
    public var back: String { pick("返回", "Back") }
    public var backHelp: String {
        pick("返回上一级（⌘[）", "Back one level (⌘[)")
    }
    public var loadingBriefing: String { pick("正在加载简报…", "Loading briefing…") }
    public var noBriefingYet: String { pick("还没有简报", "No briefing yet") }
    public var noBriefingYetDescription: String {
        pick(
            "服务器还没有分类任何邮件，正在后台持续同步。",
            "The server has not classified any messages yet. It keeps syncing in the background."
        )
    }
    public var syncingFirstTime: String {
        pick("正在首次同步邮箱…", "Syncing your mailbox for the first time…")
    }
    public func syncingFirstTimeCount(_ count: Int) -> String {
        pick("首次同步中…（已收到 \(count) 封）", "First sync in progress… (got \(count) so far)")
    }
    public var briefingUnavailable: String { pick("简报不可用", "Briefing unavailable") }
    public var emptyInboxZero: String { pick("邮箱是空的", "Inbox is empty") }
    public var briefingTimeoutTitle: String { pick("简报生成较慢", "Briefing is taking longer than usual") }
    public var briefingTimeoutDetail: String {
        pick("已自动重试一次仍未完成，请检查网络。", "One auto-retry didn't complete — check your network.")
    }
    public var viewDetails: String { pick("查看详情", "View details") }
    public var alreadyRefreshing: String { pick("已在刷新中…", "Already refreshing…") }
    public func expandGroup(_ title: String) -> String {
        pick("展开 \(title)", "Expand \(title)")
    }
    public func collapseGroup(_ title: String) -> String {
        pick("收起 \(title)", "Collapse \(title)")
    }
    public var briefingFailed: String { pick("简报加载失败：", "Briefing failed: ") }
    public var notConnected: String { pick("未连接", "Not connected") }
    public var connectToRead: String {
        pick("请先添加邮箱账号以阅读邮件。", "Add an email account to read messages.")
    }

    // MARK: - Message list

    public var noMessagesYet: String {
        pick("还没有邮件 —— 服务器仍在同步。", "No messages yet — the server is still syncing.")
    }
    public var syncFailed: String { pick("同步失败：", "Sync failed: ") }
    public var isServerRunning: String { pick("服务器在运行吗？", "Is the server running?") }
    public var lastSyncAt: String { pick("上次同步", "Last sync") }
    public var lastError: String { pick("最后错误", "Last error") }

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
    public var aiCreditExhausted: String {
        pick(
            "AI 服务余额不足 —— 请到 MiniMax 控制台充值后重试。",
            "AI provider account is out of credit — top up MiniMax and try again."
        )
    }
    public var aiBudgetExceeded: String {
        pick(
            "本月 AI 用量已达上限，请到「本月 LLM 用量」里调整。",
            "Monthly AI budget reached — adjust it under “This month's LLM usage”."
        )
    }
    public var aiCircuitOpen: String {
        pick(
            "AI 服务连续失败，已暂时熔断；几分钟后会自动重试。",
            "AI provider kept failing; the circuit is open and will retry in a few minutes."
        )
    }
    public var unknownSender: String { pick("未知发件人", "Unknown sender") }
    public var pin: String { pick("置顶", "Pin") }
    public var unpin: String { pick("取消置顶", "Unpin") }
    public var pinHelp: String { pick("置顶这封邮件", "Pin this message") }
    public var unpinHelp: String { pick("取消置顶这封邮件", "Unpin this message") }
    public var markReadFailed: String { pick("标记已读失败：", "Could not mark as read: ") }
    public var markReadFailedTitle: String { pick("标记已读失败", "Couldn't mark as read") }
    public var markReadFailedDetail: String { pick("标记已读失败，请重试。", "Mark-as-read didn't complete — retry.") }
    public var markRead: String { pick("标为已读", "Mark read") }
    public var pinFailed: String { pick("置顶失败：", "Could not pin: ") }
    public var unpinFailed: String { pick("取消置顶失败：", "Could not unpin: ") }
    public var summaryFailed: String { pick("摘要失败：", "Summary failed: ") }
    public var archiveFailedTitle: String { pick("归档失败", "Archive failed") }
    public var archiveFailedDetail: String {
        pick("归档未完成，请重试或检查网络。", "Archive didn't complete — retry or check your network.")
    }
    public var unsubscribeFailedTitle: String { pick("退订请求未完成", "Unsubscribe didn't complete") }
    public var unsubscribeFailedDetail: String {
        pick("请到原邮件里手动退订，或稍后重试。", "Try again or unsubscribe from the original email.")
    }
    public var overrideGroupFailedTitle: String { pick("分组调整未记录", "Group preference wasn't saved") }
    public var overrideGroupFailedDetail: String {
        pick("请重试，或检查网络。", "Retry or check your network.")
    }
    public var openOriginal: String { pick("打开原邮件", "Open original email") }
    public var attachments: String { pick("附件", "Attachments") }
    public var download: String { pick("下载", "Download") }
    public var downloadFailed: String { pick("下载失败", "Download failed") }
    public var downloadEml: String { pick("下载 .eml", "Download .eml") }
    public var downloadEmlHelp: String { pick("导出原始邮件文件（.eml 格式）", "Export the original message file (.eml format)") }
    public var loadingInlineImages: String { pick("正在加载内嵌图片…", "Loading inline images…") }
    public var print: String { pick("打印…", "Print…") }
    public var printHelp: String { pick("打印当前邮件（⌘P）", "Print the current message (⌘P)") }
    public var printFailed: String { pick("打印失败", "Print failed") }
    public var dateBucketToday: String { pick("今天", "Today") }
    public var dateBucketYesterday: String { pick("昨天", "Yesterday") }
    public var dateBucketThisWeek: String { pick("本周", "This week") }
    public var dateBucketThisMonth: String { pick("本月", "This month") }
    public var dateBucketEarlier: String { pick("更早", "Earlier") }
    public var markAsUnread: String { pick("标为未读", "Mark as unread") }
    public var aiCreditTitle: String { pick("AI 额度已用完", "AI credit exhausted") }
    public var aiCreditDetail: String { pick("给 MiniMax 充值后点重试。期间分类与摘要降级为本地启发式，邮件不受影响。", "Top up MiniMax, then retry. Meanwhile grouping and summaries fall back to local heuristics; mail is unaffected.") }
    public var aiCircuitTitle: String { pick("AI 服务暂时不可用", "AI temporarily unavailable") }
    public var aiCircuitDetail: String { pick("上游连续出错，稍后自动恢复。期间分类与摘要降级为本地启发式。", "Upstream errors; recovers automatically. Grouping and summaries fall back to local heuristics meanwhile.") }
    public var unreadDotLabel: String { pick("未读", "Unread") }
    public var syncStatusOk: String { pick("同步正常", "Sync OK") }
    public var syncStatusDegraded: String { pick("同步缓慢", "Sync degraded") }
    public var syncStatusNeedsReconnect: String { pick("需要重新连接", "Needs reconnect") }
    public var syncStatusInactive: String { pick("未激活", "Inactive") }
    public var markAsRead: String { pick("标为已读", "Mark as read") }
    public var markAllRead: String { pick("全部标为已读", "Mark all as read") }
    public var markAllReadHelp: String { pick("把当前简报里的未读邮件全部标为已读（⇧⌘K）", "Mark every unread message in the briefing as read (⇧⌘K)") }
    public var markAllReadPartial: String { pick("部分邮件标为已读失败", "Some messages could not be marked as read") }
    public func label(for bucket: DateBucket) -> String {
        switch bucket {
        case .today: pick("今天", "Today")
        case .yesterday: pick("昨天", "Yesterday")
        case .thisWeek: pick("本周", "This week")
        case .thisMonth: pick("本月", "This month")
        case .earlier: pick("更早", "Earlier")
        }
    }

    // MARK: - Connect

    public var connectPrompt: String { pick("连接你的邮箱开始使用。", "Connect your mailbox to begin.") }
    public var connectMethod: String { pick("连接方式", "Connection method") }
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
    public var showAuthCode: String { pick("显示授权码", "Show code") }
    public var hideAuthCode: String { pick("隐藏授权码", "Hide code") }
    public var qqEmail: String { pick("邮箱地址", "Email address") }
    public var qqAuthCode: String { pick("授权码", "Authorization code") }
    public var qqAuthCodeHelp: String {
        pick(
            "在 QQ 邮箱 → 设置 → 账户 → POP3/IMAP 服务 → 开启 → 短信验证 → 生成授权码。",
            "In QQ Mail: Settings → Account → POP3/IMAP service → Enable → SMS verify → Generate code."
        )
    }
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
        pick(
            "授权码被拒绝 —— 请填写 QQ 邮箱的授权码（不是登录密码），确认没有多余空格，并在 QQ 邮箱设置中已开启 IMAP 服务。",
            "The authorization code was rejected — enter the QQ Mail authorization code (not your login password), make sure it has no extra spaces, and confirm IMAP is enabled in QQ Mail settings."
        )
    }
    public var qqUnreachable: String {
        pick("无法连接 QQ 邮箱服务器，请检查网络后重试。", "Could not reach the QQ Mail servers — check your network and retry.")
    }
    public var qqAccountExists: String { pick("该 QQ 邮箱已经接入过了。", "That QQ mailbox is already connected.") }
    public var useThisAccount: String { pick("使用这个账号", "Use this account") }
    public var qqProviderNotConfigured: String {
        pick(
            "服务器未配置该邮箱类型，请检查服务端 providers.json。",
            "The server is not configured for this mailbox type — check providers.json on the server."
        )
    }
    public var qqInternalError: String {
        pick("服务器内部错误，请稍后重试。", "The server hit an internal error — please try again later.")
    }
    public var connectFailed: String { pick("连接失败：", "Connect failed: ") }
    public var serverTimedOut: String {
        pick(
            "服务器响应超时；账号可能其实已经接入成功，请点取消回到主界面查看，或稍后重试。",
            "The server timed out; the account may already be connected — cancel to check the main screen, or try again later."
        )
    }
    public var serverUnreachable: String {
        pick(
            "无法连接本地服务端 —— 请确认服务端正在运行（swift run LagoonServer）。",
            "Can't reach the local server — make sure it's running (swift run LagoonServer)."
        )
    }

    // MARK: - Accounts directory

    public var accountsMenuHelp: String { pick("账号", "Accounts") }
    public var addAccount: String { pick("添加账号", "Add account") }
    public var activateAccount: String { pick("切换到这个账号", "Switch to this account") }
    public var activateAccountFailed: String { pick("切换账号失败：", "Could not switch account: ") }
    public var sleepingAccount: String { pick("休眠", "Sleeping") }
    /// Unread count for one mailbox in the account menu.
    public func unreadCount(_ count: Int) -> String {
        pick("\(count) 封未读", "\(count) unread")
    }
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
    public func healthDegradedDetail(_ reason: String) -> String {
        pick("同步不稳定：\(reason)", "Sync is unstable: \(reason)")
    }
    public var healthNeedsReconnect: String {
        pick("授权已失效 —— 重新连接后继续同步。", "Authorization expired — reconnect to keep syncing.")
    }
    public func healthReconnectDetail(_ reason: String) -> String {
        pick("授权码错误或已失效：\(reason)", "Authorization code is invalid or expired: \(reason)")
    }
    public var healthError: String { pick("同步失败：", "Sync failed: ") }
    public func healthErrorDetail(_ reason: String) -> String {
        pick("同步失败：\(reason)", "Sync failed: \(reason)")
    }
    public var syncRecovered: String { pick("同步已恢复", "Sync recovered") }
    public var capabilities: String { pick("能力", "Capabilities") }
    public var idleSupported: String { pick("IDLE 推送", "IDLE push") }
    public var moveSupported: String { pick("MOVE 归档", "MOVE archive") }
    public var archiveFolderName: String { pick("归档目录", "Archive folder") }
    public var archiveUnavailable: String {
        pick("这个邮箱没有可用的归档文件夹。", "This mailbox has no usable archive folder.")
    }
    public var archiveFailed: String { pick("归档失败：", "Archive failed: ") }
    public var unsubscribeFailed: String { pick("退订失败：", "Unsubscribe failed: ") }
    public var unsubscribeManualRequired: String {
        pick(
            "这封邮件只提供邮件形式的退订地址，需要你打开原邮件手动确认。",
            "This message only offers a mail-based unsubscribe address. Open the original email to confirm manually."
        )
    }
    public var unsubscribeUnavailable: String {
        pick("这封邮件没有可用的退订链接。", "This message has no usable unsubscribe link.")
    }
    public var overrideFailed: String { pick("改分组失败：", "Could not change group: ") }
    public var searchFailed: String { pick("搜索失败：", "Search failed: ") }

    // MARK: - Actions
    public var undo: String { pick("撤销", "Undo") }
    public var undoLastAction: String { pick("撤销上一操作", "Undo last action") }
    public var nothingToUndo: String { pick("没有可撤销的操作", "Nothing to undo") }
    public var undoFailed: String { pick("撤销失败：", "Undo failed: ") }
    public var undoFailedTitle: String { pick("撤销失败", "Undo failed") }
    public var undoFailedDetail: String {
        pick("操作可能已完成，请刷新确认。", "The action may have already completed — refresh to verify.")
    }
    public var actionHistory: String { pick("最近操作", "Recent actions") }
    public var notUndoable: String { pick("不可撤销", "Not reversible") }
    public var dismiss: String { pick("关闭", "Dismiss") }
    public var searchFailedTitle: String { pick("搜索失败", "Search failed") }
    public var searchFailedDetail: String { pick("请检查网络后重试。", "Check your network and retry.") }
    public func actionTitle(_ kind: AIActionKind) -> String {
        switch kind {
        case .archive: pick("归档邮件", "Archived message")
        case .markRead: pick("标记已读", "Marked as read")
        case .pin: pick("置顶邮件", "Pinned message")
        case .unpin: pick("取消置顶", "Unpinned message")
        case .unsubscribe: pick("退订邮件", "Unsubscribed")
        case .classifyOverride: pick("调整分组", "Changed group")
        case .draftCreate: pick("生成草稿", "Generated drafts")
        case .send: pick("发送邮件", "Sent message")
        case .undo: pick("撤销操作", "Undid an action")
        }
    }
    public var archived: String { pick("已归档", "Archived") }
    public var archivedLocallyOnly: String { pick("归档未完成", "Archive did not complete") }
    public var unsubscribed: String { pick("已退订", "Unsubscribed") }
    public var unsubscribe: String { pick("退订", "Unsubscribe") }
    public var pinning: String { pick("正在置顶…", "Pinning…") }
    public var draftVariants: String { pick("AI 草稿（3 个版本）", "AI drafts (3 variants)") }
    public var pushToGmailDrafts: String { pick("保存到 Gmail 草稿", "Save to Gmail drafts") }
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
    public var soundEnabled: String { pick("操作音效", "Action sound") }
    public var soundEnabledHelp: String {
        pick("发送 / 归档 / 同步恢复时播放轻微音效", "Play a subtle sound on send, archive, and sync recovery")
    }
    public var budgetCap: String { pick("上限", "Cap") }
    public var budgetDisabled: String { pick("未启用（上限设为 0）", "Disabled (cap is 0)") }
    public func usageCallCount(_ count: Int) -> String {
        pick("本月调用 \(count) 次", "\(count) calls this month")
    }
    public var costTrackingUnavailable: String {
        pick(
            "供应商尚未配置 token 费率，当前只能统计次数，无法执行金额上限。",
            "Provider token rates are not configured; calls are counted, but the dollar cap cannot be enforced."
        )
    }
    public var overrideGroup: String { pick("改分组为…", "Change group to…") }
    public var moreActions: String { pick("更多操作", "More actions") }
    public var overrideApplied: String { pick("已记录你的偏好", "Noted your preference") }
    public var newMail: String { pick("新邮件！", "New mail!") }
    public var collapse: String { pick("收起", "Collapse") }
    public var expand: String { pick("展开", "Expand") }
    public var sender: String { pick("发件人", "Sender") }
    public var newer: String { pick("更新的", "Newer") }
    public var older: String { pick("更早的", "Older") }
    public var nextInGroup: String { pick("下一封", "Next") }
    public var previousInGroup: String { pick("上一封", "Previous") }
    public var openSelected: String { pick("打开选中的邮件", "Open selected message") }
    public var archiveAndNext: String { pick("归档并跳到下一封", "Archive & next") }
    public var markUnread: String { pick("标为未读", "Mark unread") }
    public var mailArchivedLocally: String { pick("归档未完成", "Archive did not complete") }
    public var opening: String { pick("正在打开…", "Opening…") }
    public var nothingHereYet: String { pick("还没有内容", "Nothing here yet") }
    public var inboxZero: String { pick("收件箱已清空", "Inbox zero") }
    public var tapGmailToSync: String {
        pick("添加一个邮箱账号，让 Lagoon 开始同步。", "Add an email account to start syncing.")
    }
    public var copiedToClipboard: String { pick("已复制", "Copied") }
    public var commandPalette: String { pick("命令面板", "Command palette") }
    public var commandPalettePlaceholder: String {
        pick("输入命令名称…", "Type a command…")
    }
    public var aboutTagline: String {
        pick("macOS 上的 AI 收件箱操作系统", "The AI Inbox Operating System for macOS")
    }
    public var aboutTitle: String { pick("关于 Lagoon", "About Lagoon") }
    public func aboutVersion(_ version: String) -> String {
        pick("版本 \(version)", "Version \(version)")
    }
    public var aboutFeedback: String { pick("发送反馈", "Send feedback") }
    public var aboutWebsite: String { pick("访问官网", "Visit website") }
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

    public var newMessage: String { pick("新邮件", "New message") }
    public var newMessageHelp: String { pick("写一封新邮件（⌘N）", "Write a new message (⌘N)") }
    public var newMessageTitle: String { pick("新邮件", "New message") }
    public var newMessageToPlaceholder: String { pick("收件人邮箱", "Recipient email") }
    public var newMessageToLabel: String { pick("收件人", "To") }
    public var newMessageSubjectLabel: String { pick("主题", "Subject") }
    public var newMessageBodyPlaceholder: String { pick("写邮件…", "Write your message…") }
    public var emptyRecipient: String { pick("请填写收件人。", "Enter a recipient.") }
    public var emptyMessage: String { pick("邮件内容不能为空。", "The message cannot be empty.") }

    public var reply: String { pick("回复", "Reply") }
    public var replyHelp: String { pick("回复这封邮件", "Reply to this message") }
    public var replyAll: String { pick("回复全部", "Reply all") }
    public var replyAllHelp: String { pick("回复发件人和所有收件人（⇧⌘R）", "Reply to the sender and everyone on the thread (⇧⌘R)") }
    public var replyCc: String { pick("抄送", "Cc") }
    public var forward: String { pick("转发", "Forward") }
    public var forwardHelp: String { pick("把这封邮件转发给别人（⇧⌘F）", "Forward this message to someone else (⇧⌘F)") }
    public var replyTitle: String { pick("回复邮件", "Reply") }
    public var replyTo: String { pick("收件人", "To") }
    public var replyBodyPlaceholder: String { pick("写回复…", "Write your reply…") }
    public var originalMessage: String { pick("原邮件", "Original message") }
    public var draftSaved: String { pick("草稿会自动保存", "Draft saves automatically") }
    public var closeComposer: String { pick("稍后继续", "Continue later") }
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
