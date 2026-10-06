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

    // MARK: - Shared

    public var done: String { pick("完成", "Done") }
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
    /// Shown only when the 30-day window held more mail than the response cap
    /// allows. The point is to make the boundary visible: without it the feed
    /// silently looks complete while some of the window is missing.
    public func briefingOmitted(_ count: Int) -> String {
        pick("另有 \(count) 封在近 30 天内，未纳入简报",
             "\(count) more arrived in the last 30 days and are not in this Briefing")
    }
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
    /// The reading pane's placeholder, shown until a row is selected. It
    /// states the affordance rather than apologising for emptiness: in a split
    /// layout the right column being blank before the first click is the
    /// expected state, and the copy is what teaches that clicking a row fills
    /// it.
    public var selectMessageToRead: String {
        pick("从左侧选择一封邮件开始阅读", "Select a message on the left to read it")
    }
    /// Title of the reader pane's placeholder. Kept separate from the
    /// description so the pane states the affordance ("no message selected")
    /// rather than apologising for being empty.
    public var nothingSelectedTitle: String {
        pick("未选择邮件", "No message selected")
    }
    /// Several rows highlighted at once. The pane reports the count instead of
    /// previewing one of them: the verbs that apply to a multi-selection (⌫
    /// archive, ⌘⌫ delete) are about to act on all of them, so showing a
    /// single message would describe the wrong scope.
    public func messagesSelected(_ count: Int) -> String {
        pick("已选择 \(count) 封邮件", "\(count) messages selected")
    }
    public var multiSelectionHint: String {
        pick("按 ⌫ 归档，⌘⌫ 删除", "Press ⌫ to archive, ⌘⌫ to delete")
    }
    /// The list's own honesty line: the response was capped, so what is on
    /// screen is the newest part of the mailbox and not all of it.
    ///
    /// Without this the surface reads as complete — which is exactly how a
    /// truncated list gets reported as "it stopped loading my mail". The
    /// server has always returned `totalCount` (it ignores LIMIT); the client
    /// simply never said anything with it.
    public func listTruncated(_ shown: Int, _ total: Int) -> String {
        pick("已显示最新 \(shown) 封，共 \(total) 封",
             "Showing the newest \(shown) of \(total) messages")
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
        pick("未检测到退订链接", "No unsubscribe link detected")
    }
    public var unsubscribePageRequired: String {
        pick(
            "退订需要在网页上完成确认，请打开原邮件按指引操作。",
            "This publisher requires confirmation on the web. Open the original email and follow its instructions."
        )
    }
    /// Title for the informational (not failure) banner raised when a
    /// publisher wants a web confirmation. Titled "退订" before, which read
    /// as "we tried to unsubscribe and it is your turn" when the truth is
    /// "this one needs a human, here is where to finish it".
    public var unsubscribeWebConfirmationTitle: String {
        pick("需要你在网页上确认退订", "Unsubscribe needs your confirmation")
    }
    public var overrideFailed: String { pick("改分组失败：", "Could not change group: ") }
    public var searchFailed: String { pick("搜索失败：", "Search failed: ") }

    // MARK: - Actions
    public var undo: String { pick("撤销", "Undo") }
    public var undoLastAction: String { pick("撤销上一操作", "Undo last action") }
    public var nothingToUndo: String { pick("没有可撤销的操作", "Nothing to undo") }
    public var undoFailed: String { pick("撤销失败：", "Undo failed: ") }
    /// A bulk undo that reversed fewer items than it was asked to. Reporting
    /// this as plain success would misstate the mailbox state in the one place
    /// the product promises to be honest about it.
    public func undoPartial(_ undone: Int, _ total: Int) -> String {
        pick(
            "已撤销 \(undone)/\(total) 项（其余此前已撤销或不可逆）",
            "Undid \(undone) of \(total) (the rest were already undone or not reversible)"
        )
    }
    public var markedAsReadToast: String { pick("已标记为已读", "Marked as read") }
    public var markedAsUnreadToast: String { pick("已标记为未读", "Marked as unread") }
    public func markedAllReadToast(_ count: Int) -> String {
        pick("已将 \(count) 封标为已读", "Marked \(count) as read")
    }
    public var pinnedToast: String { pick("已置顶", "Pinned") }
    public var unpinnedToast: String { pick("已取消置顶", "Unpinned") }
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
        case .delete: pick("删除邮件", "Deleted message")
        // 彻底删除. The wording says what happened, not what can be done about
        // it — this entry exists so the history never reads as though a
        // permanent deletion was a reversible one.
        case .purge: pick("彻底删除邮件", "Permanently deleted")
        }
    }
    public var archived: String { pick("已归档", "Archived") }
    public var archivedLocallyOnly: String { pick("归档未完成", "Archive did not complete") }
    public var unsubscribed: String { pick("已退订", "Unsubscribed") }
    public var unsubscribe: String { pick("退订", "Unsubscribe") }
    // MARK: 会话归集 / 发件人归集
    public func threadCount(_ count: Int) -> String { pick("\(count) 封", "\(count) messages") }
    public func threadRowLabel(_ count: Int) -> String {
        pick("会话，\(count) 封邮件，点按展开", "Conversation, \(count) messages; press to expand")
    }
    public var senderMailContext: String { pick("来自此发件人的邮件…", "Mail from this sender…") }
    public var senderMailEmpty: String { pick("没有来自此发件人的邮件", "No mail from this sender") }
    /// Bulk actions on one sender. Every label states the scope: these verbs
    /// hit *all* mail from this sender, not just the rows on screen.
    public func senderCount(_ count: Int) -> String {
        pick("\(count) 封邮件", "\(count) messages")
    }
    public var senderAllRead: String { pick("全部已读", "Mark all read") }
    public var senderAllArchive: String { pick("全部归档", "Archive all") }
    public var senderAllReadConfirm: String {
        pick("把该发件人的所有未读邮件标记为已读？", "Mark all unread mail from this sender as read?")
    }
    public var senderAllArchiveConfirm: String {
        pick("把该发件人的所有邮件归档？（可在 30 天内撤销）",
             "Archive all mail from this sender? (Undoable for 30 days)")
    }
    public var senderAllDelete: String { pick("全部删除", "Delete all") }
    /// Names the destination and the count. "移入废纸篓" is the honest verb —
    /// delete means Trash, not annihilation — and the number makes the blast
    /// radius visible before the user commits.
    public func senderAllDeleteConfirm(_ count: Int) -> String {
        pick("把该发件人的 \(count) 封邮件移入废纸篓？（30 天内可撤销）",
             "Move all \(count) messages from this sender to Trash? (Undoable for 30 days)")
    }
    public func senderAllDeleteDone(_ count: Int) -> String {
        pick("已删除 \(count) 封", "Deleted \(count) messages")
    }
    public var senderWorking: String { pick("处理中…", "Working…") }
    public var senderBulkPartial: String {
        pick("部分邮件处理失败", "Some messages failed")
    }
    public func senderAllReadDone(_ count: Int) -> String {
        pick("已标记 \(count) 封为已读", "Marked \(count) messages as read")
    }
    public func senderAllArchiveDone(_ count: Int) -> String {
        pick("已归档 \(count) 封", "Archived \(count) messages")
    }
    /// The sheet after a full archive emptied it. An empty-list line here
    /// reads as "there was never anything", which erases the action the user
    /// just took — this names the action, the undo window, and the way out.
    public func senderAllArchivedEmptyTitle(_ count: Int) -> String {
        pick("已归档 \(count) 封邮件", "Archived \(count) messages")
    }
    public var senderAllArchivedEmptyDetail: String {
        pick("来自此发件人的邮件已全部归档，30 天内可撤销。",
             "All mail from this sender is archived and undoable for 30 days.")
    }
    /// The delete twin of the two above. Without it a full delete emptied the
    /// sheet into "已归档 N 封邮件" — telling the user their mail went to the
    /// archive cabinet when it actually went to the Trash.
    public func senderAllDeletedEmptyTitle(_ count: Int) -> String {
        pick("已删除 \(count) 封邮件", "Deleted \(count) messages")
    }
    public var senderAllDeletedEmptyDetail: String {
        pick("来自此发件人的邮件已移入废纸篓，30 天内可撤销。",
             "All mail from this sender is in the Trash and undoable for 30 days.")
    }
    public var loadFailed: String { pick("加载失败", "Couldn't load") }
    public var close: String { pick("关闭", "Close") }
    public var groupingLabel: String { pick("归集", "Grouping") }
    public var groupingConversation: String { pick("会话", "Threads") }
    public var groupingSender: String { pick("发件人", "Sender") }
    public var groupingDate: String { pick("平铺", "Flat") }
    public var groupingHelp: String { pick("按会话、发件人或日期归集", "Group by conversation, sender, or date") }
    public var unreadOnly: String { pick("仅未读", "Unread") }
    public var unreadOnlyHelp: String { pick("只显示未读邮件", "Show unread messages only") }

    // MARK: - AI 建议（只读，宪法 §3）
    //
    // 措辞的唯一硬规则：任何一句都不得让用户以为 AI 已经动过这封邮件。
    // 「建议归档」不是「已归档」，「忽略了这条建议」不是「已归档」。

    public var adviceTitle: String { pick("AI 建议", "AI advice") }
    public var adviceEmpty: String {
        pick("暂无建议。AI 会在你打开简报时分析新邮件。",
             "No advice yet. Lagoon analyses new mail while you read the Briefing.")
    }
    /// 面板顶部的一句话承诺。这是整个产品最重要的一句 UI 文案。
    public var adviceAdvisoryOnlyNotice: String {
        pick("AI 只提供建议，不会自动归档、删除、退订或发送。操作由你决定。",
             "Lagoon only suggests. It never archives, deletes, unsubscribes or sends on its own — you decide.")
    }
    public func adviceCount(_ count: Int) -> String {
        pick("\(count) 条建议", "\(count) suggestions")
    }
    public var adviceOpenMessage: String { pick("查看邮件", "Open message") }
    public var adviceDismiss: String { pick("忽略这条", "Dismiss") }
    public var adviceDismissed: String { pick("已忽略", "Dismissed") }
    public var adviceLoadFailed: String { pick("建议加载失败", "Couldn't load advice") }
    /// 从建议打开一封邮件、但它已不在简报里时的提示。必须说出来：这封邮件
    /// 很可能已经被归档或退订，而用户是从一条**旧**建议点进来的。
    public var adviceMessageGoneTitle: String { pick("这封邮件已不在简报里", "Message no longer in the Briefing") }
    public var adviceMessageGoneDetail: String {
        pick("它可能已被归档、删除或退订。建议不会自动更新为已处理。",
             "It may have been archived, deleted or unsubscribed. Advice is not marked handled on its own.")
    }

    /// 建议动作。全部是「动词原形」，因为它描述的是 AI 认为你该做的事，
    /// 不是已经发生的事。
    public func adviceAction(_ action: AdvisedAction) -> String {
        switch action {
        case .reply: pick("建议回复", "Suggest replying")
        case .wait: pick("建议等待", "Suggest waiting")
        case .archive: pick("建议归档", "Suggest archiving")
        case .delete: pick("建议删除", "Suggest deleting")
        case .unsubscribe: pick("建议退订", "Suggest unsubscribing")
        case .remind: pick("建议提醒", "Suggest a reminder")
        case .nothing: pick("无需处理", "No action needed")
        }
    }

    public func adviceCategory(_ category: ContentCategory) -> String {
        switch category {
        case .personal: pick("私人", "Personal")
        case .work: pick("工作", "Work")
        case .marketing: pick("营销推广", "Marketing")
        case .spam: pick("垃圾邮件", "Spam")
        case .notification: pick("通知", "Notification")
        case .transactional: pick("交易通知", "Transactional")
        case .financial: pick("财务", "Financial")
        case .logistics: pick("物流", "Logistics")
        case .newsletter: pick("订阅资讯", "Newsletter")
        case .other: pick("其他", "Other")
        }
    }

    /// 置信度。措辞刻意保守：`.low` 不叫「大概」，叫「不太确定」——
    /// 前者像概率，后者像承认这只是猜测。
    public func adviceConfidence(_ confidence: AdviceConfidence) -> String {
        switch confidence {
        case .high: pick("判断明确", "Confident")
        case .medium: pick("较有把握", "Fairly sure")
        case .low: pick("不太确定", "Unsure")
        }
    }

    /// 来源。区分模型判断与离线规则，因为两者值得不同程度的信任，
    /// 隐藏这个差异会让启发式看起来和模型一样确定。
    public func adviceSource(_ source: AdviceSource, model: String?) -> String {
        switch source {
        case .ai:
            guard let model, !model.isEmpty else {
                return pick("来自 AI", "From AI")
            }
            return pick("来自 \(model)", "From \(model)")
        case .heuristic:
            return pick("来自本机规则", "From local rules")
        }
    }

    // MARK: 搜索
    /// 说明搜索也匹配 AI 已给出的结构化判断（分类 / 建议动作）。
    /// 必须常驻而非只在无结果时出现：用户输入「营销」却拿到正文里从没有
    /// 这个词的邮件时，他需要知道原因，否则会以为搜索坏了。
    public var searchIncludesAdvice: String {
        pick("搜索也匹配 AI 给出的分类与建议（如「营销」「newsletter」）",
             "Search also matches the AI's category and advice (e.g. “marketing”, “newsletter”)")
    }

    // MARK: 行内AI 建议条
    /// 「不可撤销」角标。只贴在退订上——退订一旦发出就已告知发布方，
    /// 删除会离开本地索引，两者都不是「点错了可以⌘Z 回来」。
    public var adviceIrreversibleBadge: String {
        pick("不可撤销", "Irreversible")
    }
    /// 行内建议条的展开提示。点它问「为什么」，所以文案是邀请而非说明。
    public var adviceWhyHelp: String {
        pick("点开看 AI 为什么这么建议", "Tap to see why the AI suggests this")
    }
    /// 行内忽略建议失败。刻意不复用 adviceLoadFailed：用户刚点了「忽略」，
    /// 告诉他「建议加载失败」会让他以为建议没加载出来，而不是没保存。
    public var adviceDismissFailedTitle: String {
        pick("忽略建议失败", "Couldn't dismiss the suggestion")
    }

    // MARK: 侧边导航栏
    public var sidebarSmartViews: String { pick("智能视图", "Smart views") }
    public var sidebarPlaces: String { pick("位置", "Places") }
    public var sidebarUnread: String { pick("未读", "Unread") }
    public var sidebarPinned: String { pick("置顶", "Pinned") }
    public var sidebarDeleted: String { pick("废纸篓", "Trash") }
    public var sidebarNavigation: String { pick("邮件位置导航", "Mail locations") }
    public var sidebarDestinationMissing: String {
        pick("这条聚合规则已不存在", "That group no longer exists")
    }

    // MARK: 列表密度
    public var densityComfortable: String { pick("舒适（三行）", "Comfortable (3 lines)") }
    public var densityCompact: String { pick("紧凑（两行）", "Compact (2 lines)") }
    public var densityDense: String { pick("密集（一行）", "Dense (1 line)") }
    public var densityTitle: String { pick("列表密度", "List density") }

    // MARK: 多选批量操作条
    public var selectionCount: String { pick("已选择", "Selected") }
    public var markReadSelected: String { pick("标为已读", "Mark read") }
    public var markUnreadSelected: String { pick("标为未读", "Mark unread") }
    public var archiveSelectedTitle: String { pick("归档选中", "Archive selected") }
    public var deleteSelectedTitle: String { pick("删除选中", "Delete selected") }
    public var clearSelection: String { pick("取消选择", "Clear selection") }

    // MARK: 发件人排行
    public var senderRankingTitle: String { pick("发件人排行", "Sender ranking") }
    /// One line stating the panel's thesis. Without it the numbers below are a
    /// table; with it they are a decision.
    public var senderRankingBlurb: String {
        pick("谁写来的邮件最多。数量多但一封未读的，往往是可以归档的订阅。",
             "Who writes the most. A lot of mail with nothing unread is often a subscription you can file.")
    }
    public var senderRankingSearch: String { pick("搜索发件人或地址", "Search sender or address") }
    public var senderRankingEmpty: String {
        pick("还没有可统计的邮件——服务器仍在同步。", "No mail to rank yet — the server is still syncing.")
    }
    public var senderRankingNoMatch: String { pick("没有匹配的发件人", "No sender matches") }
    public var senderRankingFailed: String { pick("读取发件人排行失败", "Couldn't load the sender ranking") }
    public func senderMailCount(_ n: Int) -> String { pick("\(n) 封", "\(n) messages") }
    public func senderUnreadCount(_ n: Int) -> String { pick("\(n) 封未读", "\(n) unread") }
    public var senderViewMail: String { pick("查看邮件", "View mail") }
    public var senderFile: String { pick("归档为聚合", "File into a group") }
    public var senderFiled: String { pick("已建立聚合", "Group created") }

    // MARK: 恢复与取消归档
    public var restoreFromTrash: String { pick("恢复到收件箱", "Restore to inbox") }
    public var unarchive: String { pick("取消归档", "Unarchive") }
    public var restoredToast: String { pick("已恢复到收件箱", "Restored to inbox") }
    public var movedToInboxToast: String { pick("已移回收件箱", "Moved to inbox") }
    public var unarchiveFailedTitle: String { pick("取消归档失败", "Couldn't unarchive") }
    public var restoreFailedTitle: String { pick("恢复失败", "Couldn't restore") }

    // MARK: 两段式全选
    /// ⌘A 的说明必须写明它只选已加载的——快捷键表是用户判断"这个键有多危险"
    /// 的唯一地方，泛泛的"全选"会让人以为它清空整个邮箱。
    public var shortcutSelectAll: String {
        pick("全选已加载的邮件（不包含未加载的）", "Select loaded messages (not the ones past the limit)")
    }
    /// 已选中的数量。Always states the *loaded* count, because that is what the
    /// user can see and verify.
    public func selectedCount(_ n: Int) -> String {
        pick("已选 \(n) 封", "\(n) selected")
    }
    /// 「选择全部 N 封」——只在已加载数 < 服务器总数时出现。
    ///
    /// The whole point of the two-stage design: Gmail never lets "全选" silently
    /// mean "everything", because the list is a window. This string is the
    /// explicit second step that crosses the window.
    public func selectAllOnServer(_ n: Int) -> String {
        pick("选择服务器上的全部 \(n) 封", "Choose all \(n) on the server")
    }
    public func selectAllLoaded(_ n: Int) -> String {
        pick("已加载 \(n) 封", "\(n) loaded")
    }
    public var selectAll: String { pick("全选", "Select all") }
    public func bulkDeletedToast(_ n: Int) -> String {
        pick("已将 \(n) 封邮件移入废纸篓", "Moved \(n) messages to Trash")
    }
    /// 截断必须说出来。The cap is 500 per call; saying "moved 500" and letting
    /// the user believe the sweep finished is the failure this wording exists
    /// to prevent.
    public func bulkDeleteTruncated(_ moved: Int, _ remaining: Int) -> String {
        pick(
            "已移入废纸篓 \(moved) 封，还有 \(remaining) 封未处理（单次上限 500）。",
            "Moved \(moved) to Trash; \(remaining) more were not processed (500 per call)."
        )
    }
    public func allSelected(_ n: Int) -> String {
        pick("已选中服务器上的全部 \(n) 封", "All \(n) on the server selected")
    }
    /// 批量操作会作用在比列表更多的邮件上时显示。Shown whenever the selection
    /// reaches past what is loaded — the user is about to act on mail they
    /// cannot see, and has to be told.
    public var selectionReachesUnloaded: String {
        pick("批量操作将作用于未在列表中显示的邮件", "Bulk actions will also affect messages not shown in this list")
    }

    // MARK: 已发送（R1）
    public var sidebarSent: String { pick("已发送", "Sent") }
    public var sentEmpty: String { pick("还没有已发送的邮件", "No sent messages yet") }
    public var sentEmptyHint: String {
        pick(
            "从 Lagoon 发出的邮件会自动出现在这里。",
            "Messages you send from Lagoon will show up here."
        )
    }
    /// 拉不到服务器时的提示。**不是**空列表状态——是「这些可能不是最新的」。
    public var sentStale: String {
        pick("未能连接服务器，以下内容可能不是最新", "Couldn't reach the server — this may be out of date")
    }
    public var sentUnavailable: String {
        pick("这个账户没有已发送文件夹", "This account has no Sent folder")
    }

    // MARK: 彻底删除
    public var purgeForever: String { pick("彻底删除", "Delete forever") }
    public var emptyTrash: String { pick("清空废纸篓", "Empty Trash") }
    public var emptyTrashTitle: String { pick("清空废纸篓？", "Empty Trash?") }
    /// 确认文案必须写清后果与数量。「不可撤销」四个字是这条文案存在的全部理由。
    public func emptyTrashConfirm(_ n: Int) -> String {
        pick(
            "将彻底删除 \(n) 封邮件。此操作无法撤销——邮件将从服务器和本机一并抹去，不占用任何空间。",
            "This will remove \(n) messages for good. This cannot be undone — they will be erased from both the server and this Mac."
        )
    }
    public func emptyTrashDone(_ n: Int) -> String {
        pick("已彻底删除 \(n) 封邮件", "Permanently deleted \(n) messages")
    }
    public var purgeForeverTitle: String { pick("彻底删除这封邮件？", "Delete this message forever?") }
    public func purgeForeverConfirm(_ subject: String) -> String {
        pick(
            "「\(subject)」将被从服务器和本机彻底抹去，无法撤销。",
            "“\(subject)” will be erased from the server and this Mac. This cannot be undone."
        )
    }
    public var purgeNotInTrash: String { pick("这封邮件不在废纸篓里", "This message is not in the Trash") }
    public var purgeFailedTitle: String { pick("彻底删除失败", "Couldn't delete forever") }

    // MARK: 删除
    public var deleteContext: String { pick("删除", "Delete") }
    public var deleted: String { pick("已移入废纸篓", "Moved to Trash") }
    public var deleteFailedTitle: String { pick("删除未完成", "Delete didn't complete") }

    // MARK: 聚合（用户自定义归集规则）
    public var aggregateMenu: String { pick("聚合…", "Group into…") }
    public var aggregateBySender: String { pick("按此发件人聚合", "By this sender") }
    public var aggregateByKeyword: String { pick("按主题关键词聚合…", "By subject keyword…") }
    public var stackListTitle: String { pick("聚合规则", "Groups") }
    public var stackNew: String { pick("新建聚合", "New") }
    public var stackArchivedRow: String { pick("已归档（档案柜）", "Archived (cabinet)") }
    public var stackBuiltInHeader: String { pick("内置", "Built-in") }
    public var stackEmpty: String { pick("还没有聚合规则。右键任意邮件即可创建。", "No groups yet. Right-click any message to create one.") }
    public var stackRulesHeader: String { pick("自定义聚合", "Your groups") }
    public var stackDeleteRule: String { pick("删除此聚合", "Delete this group") }
    public func stackKindLabel(_ kind: String) -> String { pick("按\(kind)", "By \(kind)") }
    public var stackEditorTitle: String { pick("新建聚合", "New group") }
    public var stackRuleKind: String { pick("匹配方式", "Match on") }
    public var stackRuleValue: String { pick("匹配内容", "Match value") }
    public var stackRuleName: String { pick("聚合名称", "Group name") }
    public var stackKindSender: String { pick("发件人", "Sender") }
    public var stackKindKeyword: String { pick("关键词", "Keyword") }
    public var stackCreate: String { pick("创建", "Create") }
    public func stackCreated(_ name: String) -> String {
        pick("聚合「\(name)」已创建，未来邮件自动归入", "Group “\(name)” created — future mail lands here automatically")
    }
    public var keywordHint: String { pick("标题包含该词的邮件（不分大小写）都会进入此聚合", "Mail whose subject contains this word joins the group") }
    public var senderHint: String { pick("来自该地址的全部邮件都会进入此聚合", "All mail from this address joins the group") }

    // MARK: 清扫
    public var sweepTitle: String { pick("归档全部", "Archive all") }
    public var sweepHelp: String { pick("把此聚合命中的邮件整批移入档案柜", "Archive every message this group matches") }
    public func sweepDone(_ count: Int) -> String {
        pick("已归档 \(count) 封", "Archived \(count) messages")
    }
    public func sweepPartial(_ ok: Int, _ failed: Int) -> String {
        pick("\(ok) 封成功，\(failed) 封失败", "\(ok) archived, \(failed) failed")
    }

    public var pinning: String { pick("正在置顶…", "Pinning…") }
    public var draftVariants: String { pick("AI 草稿（3 个版本）", "AI drafts (3 variants)") }
    public var chooseAndSend: String { pick("选这个 → 发送", "Use this → send") }
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

    // MARK: - AI settings (V1: MiniMax key entry, stored in Keychain envJSON)

    public var aiSettingsTitle: String { pick("AI 设置", "AI Settings") }
    public var aiSettingsApiKey: String { pick("API Key", "API Key") }
    public var aiSettingsApiKeyPlaceholder: String { pick("MiniMax API Key", "MiniMax API Key") }
    public var aiSettingsApiKeyHelp: String {
        pick(
            "在 MiniMax 开放平台申请，仅存于本机钥匙串，不会离开这台 Mac（调用时随邮件文本发给模型服务商）。",
            "Get one from the MiniMax platform. Stored only in this Mac's Keychain; sent to the model provider alongside mail text on each call."
        )
    }
    public var aiSettingsBaseURL: String { pick("接口地址", "Base URL") }
    public var aiSettingsModel: String { pick("模型", "Model") }
    public var aiSettingsBudget: String { pick("每月上限（美元）", "Monthly cap (USD)") }
    public var aiSettingsBudgetHelp: String {
        pick("设为 0 表示不限制。", "0 means no limit.")
    }
    public var aiSettingsSave: String { pick("保存", "Save") }
    public var aiSettingsSaved: String {
        pick("已保存，重启 App 后生效。", "Saved — restart the app to apply.")
    }
    public var aiSettingsSaveFailed: String { pick("保存失败：", "Could not save: ") }
    public var aiSettingsConfigured: String { pick("AI 已配置", "AI configured") }
    public var aiSettingsNotConfigured: String { pick("AI 未配置", "AI not configured") }
    public var aiNotConfiguredTitle: String { pick("AI 未配置", "AI not configured") }
    public var aiNotConfiguredDetail: String {
        pick(
            "填上 MiniMax Key 即可启用摘要和草稿，邮件不受影响。",
            "Add your MiniMax key to enable summaries and drafts; mail is unaffected."
        )
    }
    public var aiSettingsRestartHint: String {
        pick(
            "Key 改动需要重启 App 才能生效（内嵌服务只在启动时读取一次）。",
            "Key changes need an app restart (the embedded server reads them once at launch)."
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
    public var archiveAndNext: String { pick("归档并跳到下一封", "Archive & next") }
    public var markUnread: String { pick("标为未读", "Mark unread") }
    public var mailArchivedLocally: String { pick("归档未完成", "Archive did not complete") }
    public var opening: String { pick("正在打开…", "Opening…") }
    public var nothingHereYet: String { pick("还没有内容", "Nothing here yet") }
    public var inboxZero: String { pick("收件箱已清空", "Inbox zero") }
    public var tapToSync: String {
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
    public var shortcutRefresh: String { pick("⌥⌘R = 刷新", "⌥⌘R = refresh") }
    public var shortcutSummarize: String { pick("⌘D = AI 摘要", "⌘D = AI summary") }
    public var shortcutDraft: String { pick("⌘⇧D = 起草回复", "⌘⇧D = draft reply") }
    public var shortcutSearch: String { pick("⌘F = 搜索", "⌘F = search") }
    public var shortcutHelp: String { pick("? = 快捷键", "? = shortcuts") }
    /// Title of the ⌘/ cheatsheet, and the label of the command-palette row
    /// and the hidden ⌘/ button that open it. Distinct from `shortcutHelp`,
    /// which is a toolbar tooltip ("? = 快捷键") and reads wrong as a title.
    /// Distinct from `commandPalette`, which is the ⌘K palette itself.
    public var keyboardShortcuts: String { pick("快捷键表", "Keyboard shortcuts") }
    public var shortcutBudget: String { pick("⌘B = 本月用量", "⌘B = this month's usage") }
    public var shortcutAdvice: String { pick("⇧⌘A = AI 建议", "⇧⌘A = AI advice") }
    public var shortcutDeleteSelected: String { pick("⌘⌫ = 删除选中", "⌘⌫ = delete selected") }
    public var shortcutArchiveSelected: String { pick("⌫ = 归档选中", "⌫ = archive selected") }
    public var shortcutGroupJump: String {
        pick("⌘1–⌘9 = 跳到简报分组", "⌘1–⌘9 = jump to a briefing group")
    }
    public var toggleSurface: String {
        pick("切换简报 / 全部邮件", "Toggle Briefing / All messages")
    }

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

    // MARK: - Column resizing

    /// The separator handle's accessibility label, naming the column it
    /// resizes.
    ///
    /// An exhaustive `switch` over the noun rather than a lookup table, so a
    /// fourth column without a name is a compile error here instead of a
    /// handle that VoiceOver announces as "adjustable" with nothing to adjust.
    public func adjustColumnWidth(_ noun: String) -> String {
        switch noun {
        case "navigation": return pick("调整导航栏宽度", "Adjust the sidebar width")
        case "list": return pick("调整邮件列表宽度", "Adjust the message list width")
        case "reader": return pick("调整阅读区宽度", "Adjust the reading pane width")
        default: return pick("调整列宽度", "Adjust the column width")
        }
    }

    /// The spoken width. The unit is included because a bare number is read as
    /// a count rather than a measurement.
    public func columnWidthPoints(_ points: Int) -> String {
        pick("\(points) 点", "\(points) points")
    }

    /// The separator's VoiceOver help: what the arrow keys do.
    ///
    /// Spoken rather than left implicit, because the step sizes are otherwise
    /// invisible — a VoiceOver user would have to press increment repeatedly to
    /// discover that one press is 16pt.
    public var columnResizeHelp: String {
        pick(
            "使用上下方向键调整宽度，Page Up / Page Down 大幅调整，Home / End 跳到最小或最大宽度。",
            "Use the up and down arrows to adjust, Page Up and Page Down for large steps, Home and End for the minimum and maximum."
        )
    }

    /// The separator's tooltip.
    ///
    /// Names the column the drag moves *and* teaches the ⌥ inversion, because
    /// neither is discoverable otherwise: the handle is a 1pt line with no label
    /// until the pointer is already on it, and a modifier nobody has been told
    /// about is a feature that does not exist. Both halves are needed — "drag to
    /// resize" alone leaves the user guessing which column, and naming the column
    /// without the modifier leaves the wider reader unreachable.
    ///
    /// `noun` is the column on the handle's left, as `adjustColumnWidth` takes it.
    public func columnResizeTooltip(_ noun: String) -> String {
        // The first separator cannot invert: ⌥ there would target the list,
        // which is already the column to its left, so there would be nothing
        // left to say.
        guard noun != "navigation" else {
            return pick("拖动调整左侧栏宽", "Drag to resize the left column")
        }
        return pick(
            "拖动调整左侧栏宽，按住 ⌥ 改为调整阅读区宽度",
            "Drag to resize the left column, or hold ⌥ to resize the reading pane"
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
