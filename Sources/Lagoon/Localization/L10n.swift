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
/// A plain value type rather than a String Catalog: the app ships as a plain
/// executable with no resource bundle to load strings from, and switching
/// language must re-render immediately without relaunching. Strings sit side
/// by side so a translation is one line to add and impossible to forget.
public struct L10n: Sendable, Equatable {
    public let language: AppLanguage

    public init(language: AppLanguage) {
        self.language = language
    }

    /// Strings for non-View code (stores, clients) that cannot read the
    /// SwiftUI environment. Views get theirs injected instead.
    public static var current: L10n { L10n(language: LanguagePreference.stored) }

    /// Picks the string for the current language.
    ///
    /// Internal rather than private so that a feature can add its strings
    /// in its own file — `L10n+Backup.swift`, `L10n+Advice.swift` — as an
    /// extension of this type. Two features that need a string each get
    /// their own file, and neither has to touch a 2000-line file to do
    /// it. The alternative — one agent editing the middle of
    /// `L10n.swift` while another edits the same middle — loses work
    /// silently, and the guardrail that catches dead strings cannot see
    /// strings that live in a file it does not read.
    func pick(_ zh: String, _ en: String) -> String {
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
    /// The escape hatch on a failure that retrying cannot fix (spec INV-5).
    public var help: String { pick("帮助", "Help") }
    /// The closing line of a help request the banner composed. The banner
    /// knows what failed; only the user knows what they were doing, so the
    /// message asks for that part instead of assuming it.
    public var helpRequestFooter: String {
        pick(
            "\n\n（如果可以，请补充你当时的操作步骤。）",
            "\n\n(If you can, add what you were doing when it happened.)"
        )
    }
    /// The subject line of a help request the banner composed.
    public var helpRequestSubject: String {
        pick("Lagoon 使用问题", "Lagoon problem report")
    }

    public var noSubject: String { pick("（无主题）", "(no subject)") }
    public var unknownError: String { pick("未知错误", "Unknown error") }
    /// The inbox's name.
    ///
    /// The key is still called `allMessages` — a **historical** name, kept
    /// because renaming it would ripple through the sidebar, the lens
    /// mapping and the tests for no user-visible gain. What the string says
    /// is what matters, and what it says is 收件箱 / Inbox.
    ///
    /// ## Why it is not 全部邮件 / "All messages"
    ///
    /// Because it is not all mail. The server's `filterSQL` answers this
    /// lens with `is_archived = FALSE AND is_deleted = FALSE AND is_sent =
    /// FALSE` — the inbox, and *only* the inbox: sent mail is excluded on
    /// purpose, so a reply the user sent never shows up in their own inbox.
    ///
    /// So the old title made a promise the content could not keep, and the
    /// question it invited ("why isn't the mail I sent in 全部邮件?") had no
    /// answer except "the title is wrong". A title is the one place the user
    /// looks to confirm where they are; it cannot describe a set the server
    /// never returns.
    public var allMessages: String { pick("收件箱", "Inbox") }
    public var briefing: String { pick("简报", "Briefing") }
    public var languageLabel: String { pick("语言", "Language") }
    public var surface: String { pick("界面", "Surface") }
    public var surfaceHelp: String {
        pick("在简报和收件箱之间切换", "Switch between the Briefing Feed and the raw message list")
    }

    // MARK: - Briefing feed

    public var showRawListHelp: String {
        pick("查看收件箱列表（⌘0）", "Show the raw message list (⌘0)")
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
    /// 30 天之前、仍未处理的邮件数量。
    ///
    /// 这些邮件**已经在简报里**了——它们落在「需要回复」组里，跟近 30 天的
    /// 邮件混在一起，用户不用做任何额外操作。这一行说明的是**数量**：
    /// 简报最多带 50 封这样的旧邮件，超出的部分还在后面排队。没有这个
    /// 数字，用户看到 3 封就会以为只有 3 封。
    ///
    /// 说的是「更早的邮件还没处理」，不是「有邮件被藏起来了」——后者会
    /// 让用户以为要去找一个入口，而入口不存在。
    public func briefingBacklog(_ count: Int) -> String {
        pick("另有 \(count) 封更早的邮件还没处理，已一并列在「需要回复」里",
             "\(count) older messages are still unanswered — they are listed under Needs reply too")
    }
    public var syncingFirstTime: String {
        pick("正在首次同步邮箱…", "Syncing your mailbox for the first time…")
    }
    public func syncingFirstTimeCount(_ count: Int) -> String {
        pick("首次同步中…（已收到 \(count) 封）", "First sync in progress… (got \(count) so far)")
    }
    public var briefingUnavailable: String { pick("简报不可用", "Briefing unavailable") }
    public var briefingTimeoutTitle: String { pick("简报生成较慢", "Briefing is taking longer than usual") }
    public var briefingTimeoutDetail: String {
        pick("已自动重试一次仍未完成，请检查网络。", "One auto-retry didn't complete — check your network.")
    }
    public var viewDetails: String { pick("查看详情", "View details") }
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

    // MARK: - Lens-aware empty states (MessageListView)
    //
    // Each surface gets its own title and hint. The generic "还没有邮件" is
    // wrong in five of the six: an empty trash does not mean mail is
    // missing, and an empty pinned list does not mean the inbox is empty.

    public var emptyTrashEmptyTitle: String { pick("废纸篓是空的", "The trash is empty") }
    public var emptyTrashHint: String {
        pick(
            "删除的邮件会先放到这里，可以恢复；彻底删除不可撤销。",
            "Deleted mail lands here first and can be restored; permanent delete cannot be undone."
        )
    }
    public var emptyArchiveTitle: String { pick("档案柜是空的", "The archive is empty") }
    public var emptyArchiveHint: String {
        pick(
            "归档的邮件会移到这里，随时可以移回收件箱。",
            "Archived mail moves here and can go back to the inbox at any time."
        )
    }
    public var emptyUnreadTitle: String { pick("没有未读邮件", "Nothing unread") }
    public var emptyUnreadHint: String {
        pick("收件箱清空了 —— 今天的分诊做完了。", "Inbox clear — today's triage is done.")
    }
    public var emptyPinnedTitle: String { pick("没有置顶的邮件", "Nothing pinned") }
    public var emptyPinnedHint: String {
        pick(
            "右键任意邮件可以置顶，置顶的邮件会留在简报页顶部。",
            "Right-click any message to pin it; pinned mail stays at the top of the Briefing."
        )
    }
    public var emptyRuleTitle: String { pick("这个分组是空的", "This group is empty") }
    public var emptyRuleHint: String {
        pick(
            "改「改分组」规则会改变邮件的归属；这里的邮件显示你手动指定的那个分组。",
            "Changing a sender's group moves their mail; this shows the group you pinned them to."
        )
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
    /// Why the sync failed, and what it does and does not affect.
    ///
    /// A sync failure is scary but narrow: the mail already on the screen is
    /// fine, only *new* mail is missing. Without that sentence the user
    /// assumes the app lost their mail, and the correct reaction — wait, or
    /// hit retry — never happens.
    public var syncFailedDetail: String {
        pick(
            "新的邮件暂时收不到；已经同步过来的邮件不受影响，可以照常阅读。",
            "New mail can't arrive for now. The messages already synced are unaffected and "
                + "read normally."
        )
    }

    /// The offline strip. It says the mail on screen is real but stale, so
    /// the user knows there is nothing wrong with the app — only with the
    /// network.
    public var offlineNotice: String {
        pick(
            "离线 — 显示的是最后一次同步的邮件，新的邮件暂时收不到。",
            "Offline — showing the last synced mail. New messages can't arrive until the connection is back."
        )
    }
    /// The list surface loads messages; it does not sync them. Telling the
    /// user "同步失败" sends them to check their network when the thing that
    /// failed was "the server did not answer with a list".
    public var listLoadFailed: String { pick("邮件列表加载失败", "Couldn't load the message list") }
    public var listLoadFailedDetail: String {
        pick(
            "服务器没有返回邮件列表。请检查网络后重试。",
            "The server didn't return the message list. Check your network and retry."
        )
    }
    public var lastSyncAt: String { pick("上次同步", "Last sync") }
    public var lastError: String { pick("最后错误", "Last error") }

    // MARK: - Message detail

    public var summarizing: String { pick("正在生成摘要…", "Summarizing…") }
    public var summarize: String { pick("生成摘要", "Summarize") }
    public func recipient(_ value: String) -> String { pick("收件人 \(value)", "to \(value)") }
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
    public var markReadFailedTitle: String { pick("标记已读失败", "Couldn't mark as read") }
    public var markReadFailedDetail: String { pick("标记已读失败，请重试。", "Mark-as-read didn't complete — retry.") }
    public var markRead: String { pick("标为已读", "Mark read") }
    public var pinFailed: String { pick("置顶失败：", "Could not pin: ") }
    public var unpinFailed: String { pick("取消置顶失败：", "Could not unpin: ") }
    /// The pin failed but the row was put back where it was. Saying that is
    /// the difference between "the app is broken" and "that one action did
    /// not go through".
    public var pinFailedDetail: String {
        pick("邮件已回到原来的位置，置顶没有生效。", "The message went back where it was — the pin didn't take.")
    }
    public var unpinFailedDetail: String {
        pick("邮件仍在置顶状态，取消置顶没有生效。", "The message is still pinned — the unpin didn't take.")
    }
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
    public var downloadNoWindow: String {
        pick("窗口已关闭，下载无法完成。", "The window was closed, so the download could not finish.")
    }
    public var downloadEml: String { pick("下载 .eml", "Download .eml") }
    public var downloadEmlHelp: String { pick("导出原始邮件文件（.eml 格式）", "Export the original message file (.eml format)") }
    public var loadingInlineImages: String { pick("正在加载内嵌图片…", "Loading inline images…") }
    /// 正文容器（WKWebView）的 VoiceOver 标签。The WebView's own elements are
    /// *contained* inside this region rather than merged into one opaque node,
    /// so this label is what announces what the whole region is.
    public var messageBody: String { pick("邮件正文", "Message body") }
    public var aiCreditTitle: String { pick("AI 额度已用完", "AI credit exhausted") }
    public var aiCreditDetail: String { pick("给 MiniMax 充值后点重试。期间分类与摘要降级为本地启发式，邮件不受影响。", "Top up MiniMax, then retry. Meanwhile grouping and summaries fall back to local heuristics; mail is unaffected.") }
    public var aiCircuitTitle: String { pick("AI 服务暂时不可用", "AI temporarily unavailable") }
    public var aiCircuitDetail: String { pick("上游连续出错，稍后自动恢复。期间分类与摘要降级为本地启发式。", "Upstream errors; recovers automatically. Grouping and summaries fall back to local heuristics meanwhile.") }
    public var unreadDotLabel: String { pick("未读", "Unread") }
    public var syncStatusOk: String { pick("同步正常", "Sync OK") }
    public var syncStatusDegraded: String { pick("同步缓慢", "Sync degraded") }
    public var syncStatusNeedsReconnect: String { pick("需要重新连接", "Needs reconnect") }
    public var syncStatusInactive: String { pick("未激活", "Inactive") }
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
    /// Why the account could not be written to the keychain.
    ///
    /// The title says the save failed; the consequence is what the user
    /// actually needs to know — the app will forget this account when it
    /// quits, so they may have to pick it again next launch.
    public var saveAccountFailedDetail: String {
        pick(
            "钥匙串写入失败，Lagoon 没能记住你选的账号。下次启动可能需要重新选一次。",
            "The keychain write failed, so Lagoon can't remember which account you picked. "
                + "You may have to choose it again next launch."
        )
    }
    /// Why switching the active account failed.
    ///
    /// "切换账号失败" on its own leaves the user guessing which of the two
    /// steps failed — asking the server to switch, or writing the choice to
    /// the keychain. The detail says the server refused, so the answer is
    /// "try again / check the connection", not "my password is wrong".
    public var activateAccountFailedDetail: String {
        pick(
            "服务器没有接受这次切换。账号本身没问题——多半是连接中断了，可以直接重试。",
            "The server refused the switch. The account itself is fine — most likely the "
                + "connection dropped, so retrying should work."
        )
    }

    // MARK: - Connect (QQ / IMAP)

    public var connectQQTab: String { pick("QQ 邮箱", "QQ Mail") }
    public var connectQQTitle: String { pick("连接 QQ 邮箱", "Connect QQ Mail") }
    public var qqEmailPlaceholder: String { pick("QQ 邮箱地址", "QQ email address") }
    public var qqAuthCodePlaceholder: String { pick("授权码", "Authorization code") }
    public var showAuthCode: String { pick("显示授权码", "Show code") }
    public var hideAuthCode: String { pick("隐藏授权码", "Hide code") }

    /// The heading of the "how to get the authorization code" step.
    ///
    /// This is a **step**, not a footnote: without the code the form cannot
    /// be completed at all, and the two grey lines it used to be compressed
    /// into were the hardest part of the whole onboarding to find. The
    /// heading says so.
    public var qqAuthCodeStepTitle: String {
        pick("第 1 步：获取授权码", "Step 1: get an authorization code")
    }

    /// The heading of the form step.
    ///
    /// The two steps are numbered so the order is visible: a user who
    /// arrives without a code can see that getting one comes *first*, and
    /// that the form is the second thing, not the only thing.
    public var qqFormStepTitle: String {
        pick("第 2 步：填写并连接", "Step 2: fill in and connect")
    }

    /// The path to the code, in the order the user walks it.
    ///
    /// The wording follows QQ Mail's own help centre
    /// (help.mail.qq.com/detail/0/1087): 设置 → 账号与安全 → POP3/IMAP/SMTP
    /// 服务 → 开启 → 短信验证 → 生成 16 位授权码. It used to say 设置 →
    /// 账户 → POP3/IMAP 服务, which is the path QQ Mail used to have; the
    /// current one is 账号与安全.
    public var qqAuthCodeHelp: String {
        pick(
            "登录 QQ 邮箱网页版 → 设置 → 账号与安全 → POP3/IMAP/SMTP/Exchange 服务 → 开启 → 按提示完成手机验证 → 生成 16 位授权码（不是 QQ 登录密码）。",
            "Sign in to QQ Mail → Settings → Account & Security → POP3/IMAP/SMTP/Exchange service → Enable → complete the phone verification → a 16-character authorization code is generated (this is not your QQ password)."
        )
    }

    /// The button that takes the user to QQ Mail to do step 1.
    public var qqAuthCodeOpenButton: String {
        pick("打开 QQ 邮箱设置页", "Open QQ Mail settings")
    }

    /// The button's tooltip — it must say where the button goes, because a
    /// link that silently opens a browser is a small ambush.
    public var qqAuthCodeOpenHelp: String {
        pick(
            "在浏览器里打开 QQ 邮箱，登录后按上面的路径生成授权码",
            "Opens QQ Mail in your browser — sign in and follow the steps above to generate the code"
        )
    }

    /// The short reminder under the code field.
    ///
    /// Deliberately short and deliberately *not* a second copy of the path
    /// above. It used to be a second, differently-worded copy of the same
    /// instructions, which is how two grey paragraphs of nearly-identical
    /// text ended up under the form; two copies of the same step drift apart
    /// and leave the user unsure which one is current.
    public var qqHelp: String {
        pick(
            "授权码是 QQ 邮箱给第三方客户端用的专用密码，不是你的 QQ 登录密码；重新生成后旧的立即失效。",
            "The authorization code is a dedicated password for third-party clients, not your QQ password; regenerating it invalidates the old one immediately."
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
    public var removeAccount: String { pick("移除这个账号", "Remove this account") }
    public var removeAccountConfirmTitle: String { pick("移除账号？", "Remove this account?") }
    public var removeAccountConfirmMessage: String {
        pick(
            "会删掉这个账号在 Lagoon 里的本地缓存（邮件、建议、撤销记录）。\n"
                + "**服务器上的邮件不会被删除**——它们还在 QQ 邮箱里，随时可以再连回来。",
            "This removes the account's local cache in Lagoon (mail, advice, undo history).\n"
                + "**Your mail on the server is not touched** — it stays in QQ Mail, and you can connect it again."
        )
    }
    public var removeAccountConfirmButton: String { pick("移除", "Remove") }
    public var removeAccountFailedDetail: String {
        pick(
            "账号还在。可能是网络问题，或服务器正忙——再试一次。",
            "The account is still here. It may be the network, or the server may be busy — try again."
        )
    }
    public func providerName(_ kind: MailProviderKind) -> String {
        switch kind {
        case .qq: return pick("QQ 邮箱", "QQ Mail")
        }
    }

    // MARK: - Sync health

    public var reconnect: String { pick("重新连接", "Reconnect") }
    // `healthStatusText` lives in `L10n+Account.swift` — it is a switch over
    // `SyncHealth.Status`, and every new case has to be added there too.
    // Keeping it out of this file means the account-related copy can grow
    // without editing the file every other feature is also editing.
    // The headline says *what state* the app is in; the detail says *why*,
    // in a sentence the user can act on. These used to be one string built
    // by concatenating a fixed sentence with a raw server label, which
    // produced nonsense like "授权码错误或已失效：not-configured" — a
    // headline about an expired token bolted onto a reason that had nothing
    // to do with tokens. Splitting them fixes the class of bug: the headline
    // can no longer contradict the detail, because the headline no longer
    // names a cause.

    /// Deliberately cause-free: `auth-failed` and `not-configured` both land
    /// here, and they call for different explanations.
    public var healthNeedsReconnect: String {
        pick("需要重新连接 —— 重新连接后继续同步。", "Reconnect needed — reconnect to keep syncing.")
    }
    public var healthDegradedTitle: String { pick("同步不稳定", "Sync is unstable") }
    public var healthErrorTitle: String { pick("同步失败", "Sync failed") }

    // MARK: - Sync failure reasons
    //
    // The server records a failure as a short, stable label
    // (`MailError.logLabel`) so that a log line never carries a payload.
    // That is right for storage and wrong for display: the user cannot act
    // on `not-configured`. Each label is translated here into a sentence
    // that says what happened, and — where there is one — what to do next.
    //
    // An unknown label must never be shown raw. `SyncErrorReason` maps
    // unrecognised labels to `reasonUnknown` instead.

    public var reasonAuthFailed: String {
        pick("授权码无效或已过期。", "The authorization code is invalid or has expired.")
    }
    public var reasonUnreachable: String {
        pick("连不上邮箱服务器，请检查网络后重试。",
             "Cannot reach the mail server. Check your network and try again.")
    }
    public var reasonProtocolError: String {
        pick("邮箱服务器返回了协议错误。", "The mail server returned a protocol error.")
    }
    public var reasonMessageGone: String {
        pick("这封邮件已被服务器删除，无法再操作。",
             "This message was deleted on the server and can no longer be changed.")
    }
    public var reasonArchiveUnavailable: String {
        pick("这个邮箱没有可用的归档文件夹。", "This mailbox has no usable archive folder.")
    }
    public var reasonTrashUnavailable: String {
        pick("这个邮箱没有可用的回收站文件夹。", "This mailbox has no usable trash folder.")
    }
    public var reasonSentUnavailable: String {
        pick("无法访问「已发送」文件夹。", "The sent folder is not accessible.")
    }
    public var reasonNotConfigured: String {
        pick("邮箱设置不完整，请重新连接并补全授权信息。",
             "The mail account is not fully set up. Reconnect and complete the authorization.")
    }
    public var reasonNoProvider: String {
        pick("没有可用的邮箱服务。", "No mail provider is available.")
    }
    public var reasonUnknown: String {
        pick("同步遇到了未知问题。", "Sync hit an unknown problem.")
    }
    /// The raw label, offered as copyable diagnostics in the detail sheet.
    public var technicalDetails: String { pick("技术信息", "Technical details") }
    public var syncRecovered: String { pick("同步已恢复", "Sync recovered") }
    public var capabilities: String { pick("能力", "Capabilities") }
    public var idleSupported: String { pick("IDLE 推送", "IDLE push") }
    public var moveSupported: String { pick("MOVE 归档", "MOVE archive") }
    /// Whether the server supports UIDPLUS — the precondition for
    /// deleting exactly one mail instead of risking another client's
    /// deletions.
    public var uidplusSupported: String { pick("UIDPLUS 精确删除", "UIDPLUS precise delete") }
    /// Whether the account has a Sent mailbox.
    public var sentFolderSupported: String { pick("已发送文件夹", "Sent folder") }
    /// Whether the account has a Trash mailbox.
    public var trashFolderSupported: String { pick("废纸篓文件夹", "Trash folder") }
    public var archiveFolderName: String { pick("归档目录", "Archive folder") }
    /// The tooltip on a verb the server cannot perform.
    ///
    /// Says *why* the verb is off, so the user is not left guessing whether
    /// the button is broken. The point of gating ahead of the click is that
    /// the explanation arrives with the disabled button, not as a 409 after
    /// the click.
    public var deleteUnavailable: String {
        pick(
            "这个邮箱没有废纸篓文件夹，删除不可用。",
            "This mailbox has no trash folder, so delete isn't available."
        )
    }
    /// Why 彻底删除 is off, in one sentence.
    public var purgeUnavailable: String {
        pick(
            "这个邮箱服务器不支持 UIDPLUS，无法安全地彻底删除某一封邮件（清空废纸篓同样不可用）。",
            "This mail server doesn't support UIDPLUS, so a single message can't be permanently deleted safely (emptying the trash is unavailable too)."
        )
    }
    public var archiveUnavailable: String {
        pick("这个邮箱没有可用的归档文件夹。", "This mailbox has no usable archive folder.")
    }
    /// Why archiving is unavailable, in one sentence. The title already says
    /// "no archive folder"; the detail says what that means for the user —
    /// the feature is off for this account, not temporarily broken — and the
    /// banner offers a help link, because retrying cannot change it.
    public var archiveUnavailableDetail: String {
        pick(
            "服务器没有协商出可归档的文件夹，所以这个账号不能归档。换一个账号或联系支持即可。",
            "The server negotiated no archive-capable folder, so this account can't archive. Use another account, or ask us for help."
        )
    }
    public var archiveFailed: String { pick("归档失败：", "Archive failed: ") }
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

    // MARK: - Actions
    public var undo: String { pick("撤销", "Undo") }
    public var undoLastAction: String { pick("撤销上一操作", "Undo last action") }
    public var nothingToUndo: String { pick("没有可撤销的操作", "Nothing to undo") }
    /// What "undo" is, for the moment there is nothing to undo. An empty
    /// state that only says "nothing here" is a dead end: the user does not
    /// learn what they are missing, or where undoable actions would show up.
    public var undoEmptyHint: String {
        pick(
            "归档、标为已读、置顶等操作都会记录在这里，30 天内可以撤销。",
            "Archive, mark-as-read, pin and the like are recorded here — you can undo them for 30 days."
        )
    }
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
    /// The second line of a partial undo. It says what the user can still
    /// do about it, because a count without a next step is a dead end.
    public var undoPartialDetail: String {
        pick(
            "其余操作此前已经撤销过，或本身不可逆。刷新一下可以看到现在的状态。",
            "The others were already undone, or were never reversible. Refresh to see the current state."
        )
    }
    public var markedAsReadToast: String { pick("已标记为已读", "Marked as read") }
    public var markedAsUnreadToast: String { pick("已标记为未读", "Marked as unread") }
    public func markedAllReadToast(_ count: Int) -> String {
        pick("已将 \(count) 封标为已读", "Marked \(count) as read")
    }
    public var pinnedToast: String { pick("已置顶", "Pinned") }
    public var unpinnedToast: String { pick("已取消置顶", "Unpinned") }
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
    /// 「归档」是**动作**，「已归档」是**结果**。
    ///
    /// 同一个字符串不能同时当两者用：按钮上写「已归档」是一个完成时态的
    /// 词，用户读到的是一个状态而不是一个可以按下去的动作，右键菜单里
    /// 尤其明显——「已归档」看起来像它已经归档过了。
    public var archiveAction: String { pick("归档", "Archive") }
    /// 完成态专用：出现在操作成功后的提示里。
    public var archivedToast: String { pick("已归档", "Archived") }
    public var archived: String { pick("已归档", "Archived") }
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
    /// Why a bulk action only partly succeeded (INV-3).
    ///
    /// "Some messages failed" says *what*; this says *what went wrong* and
    /// *what the user can do about it* — the rest went through, and the
    /// failures are still there to retry.
    ///
    /// The reason comes first because it is the part the user cannot guess:
    /// the second half ("retry covers exactly the failed rows") is only
    /// trustworthy because the code leaves the failed rows alone.
    public func senderBulkPartialDetail(_ reason: String) -> String {
        pick(
            "\(reason)。其余邮件已处理完成；失败的邮件仍留在列表里，点「重试」只重试这些。",
            "\(reason). The rest were processed; the ones that failed are still in the list, and Retry covers exactly those."
        )
    }
    /// Why a bulk action stopped short of the whole list.
    ///
    /// "12 封邮件" says how many are left; it does not say *why*, and a
    /// user who does not know the server caps one call will read it as
    /// "the app gave up on the rest".
    public func senderTruncatedDetail(_ count: Int) -> String {
        pick(
            "还有 \(count) 封没有处理——服务器一次最多处理这么多。点「重试」继续处理剩下的。",
            "\(count) were left behind — the server handles that many per call. "
                + "Retry to continue with the rest."
        )
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
    /// A *write* that failed. "加载失败" would send the user looking for a
    /// loading problem on a screen that was never loading anything.
    public var deleteRuleFailed: String { pick("删除分组失败", "Couldn't remove the group") }
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
    /// 命中总数。搜索曾经静默停在 100 条，用户看到的列表和「全部结果」
    /// 一模一样——现在数量摆在标题旁边。
    public func searchResultCount(_ count: Int) -> String {
        pick("\(count) 条结果", "\(count) results")
    }
    /// 命中数超过服务端上限时的说明。
    ///
    /// 说的是**发生了什么**（只显示了前 N 条）和**为什么**（服务端一次
    /// 最多返回这么多），并且给出下一步（收窄关键词）。不假装「加载更多」
    /// 存在——服务端没有这个接口。
    public func searchTruncated(_ shown: Int, _ total: Int) -> String {
        pick(
            "共 \(total) 条匹配，这里显示最近 \(shown) 条。试试更具体的关键词。",
            "\(total) matched; showing the \(shown) most recent. Try a more specific word."
        )
    }
    /// 搜索范围选择器。只有一个邮箱时不出现——那时它是同一个搜索、
    /// 更长的标签，是个什么都不做的控件。
    public var searchScopeLabel: String {
        pick("搜索范围", "Search scope")
    }
    public var searchScopeHelp: String {
        pick(
            "「全部邮箱」会同时搜索所有已连接的邮箱。",
            "“All mailboxes” searches every connected mailbox at once."
        )
    }
    /// 「当前邮箱」——正在看的那个。
    public var searchScopeCurrent: String {
        pick("当前邮箱", "This mailbox")
    }
    /// 「全部邮箱」——所有已连接的邮箱。
    public var searchScopeAll: String {
        pick("全部邮箱", "All mailboxes")
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
    /// 行内建议条上的「照做」按钮：执行 AI 建议的动作。
    ///
    /// 措辞必须读作**用户的动作**，不是 Lagoon 的动作 —— 宪法 §3 要求
    /// 用户的手势是唯一写触发源，而这个按钮点下去就是一次归档/退订。
    /// 「照做」正是用户视角的说法。
    public var adviceAccept: String { pick("照做", "Do it") }
    /// 「照做」按钮的辅助说明：动作由你执行。
    public var adviceAcceptHelp: String {
        pick("按建议执行这个动作，由你决定", "Perform the suggested action — you decide")
    }
    /// 确认「照做」这个不可撤销动作的对话框标题。
    ///
    /// 「照做」是一个按钮，用户的眼睛扫过去只会读到两个字。对归档来说
    /// 够了（可撤销），对退订来说不够——退订一旦发出，发布方就收到了，
    /// 用户的这个 App 再也收不回来。所以在真正执行之前，必须有一句
    /// 说清后果的话。
    public var adviceAcceptConfirmTitle: String {
        pick("确认退订？", "Unsubscribe for sure?")
    }
    /// 确认对话框的正文：说清会发生什么、不可逆、以及谁会收到通知。
    public var adviceAcceptConfirmBody: String {
        pick(
            "退订是**不可撤销**的：会向发布方发出请求，他们之后就不会再给你发这类的邮件了。"
                + " Lagoon 不会再替你点第二次。",
            "Unsubscribing **cannot be undone**: a request goes to the publisher, and they will stop sending you this mail. "
                + "Lagoon will not do it again for you."
        )
    }
    /// 确认对话框的取消按钮。
    public var adviceAcceptConfirmCancel: String { pick("先不", "Not now") }
    /// 确认对话框的动作按钮。
    public var adviceAcceptConfirmAction: String { pick("退订", "Unsubscribe") }
    /// 记录「已采纳」失败时的标题。
    ///
    /// 刻意不复用 adviceLoadFailed / adviceDismissFailedTitle：邮件**已经**
    /// 归档或退订成功了，失败的只是把这次采纳记下来这件事。用户看到的
    /// 必须是「动作完成了，但记录没成功」，而不是「建议加载失败」——
    /// 后者会让他以为整件事都没发生。
    public var adviceAcceptFailedTitle: String {
        pick("已执行，但未能记录这次采纳", "Done, but the suggestion could not be recorded")
    }

    // MARK: 侧边导航栏
    public var sidebarSmartViews: String { pick("智能视图", "Smart views") }
    public var sidebarPlaces: String { pick("位置", "Places") }
    public var sidebarUnread: String { pick("未读", "Unread") }
    public var sidebarPinned: String { pick("置顶", "Pinned") }
    public var sidebarDeleted: String { pick("废纸篓", "Trash") }
    public var sidebarNavigation: String { pick("邮件位置导航", "Mail locations") }
    public var sidebarDestinationMissing: String {
        pick("这个分组已不存在", "That group no longer exists")
    }

    // MARK: 列表密度
    public var densityComfortable: String { pick("舒适（三行）", "Comfortable (3 lines)") }
    public var densityCompact: String { pick("紧凑（两行）", "Compact (2 lines)") }
    public var densityDense: String { pick("密集（一行）", "Dense (1 line)") }
    public var densityTitle: String { pick("列表密度", "List density") }

    // MARK: 多选批量操作条
    public var selectionCount: String { pick("已选择", "Selected") }
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
    public var senderFile: String { pick("归入分组", "File into a group") }
    public var senderFiled: String { pick("已归入分组", "Group created") }

    // MARK: 恢复与取消归档
    public var restoreFromTrash: String { pick("恢复到收件箱", "Restore to inbox") }
    public var unarchive: String { pick("取消归档", "Unarchive") }
    public var restoredToast: String { pick("已恢复到收件箱", "Restored to inbox") }
    public var movedToInboxToast: String { pick("已移回收件箱", "Moved to inbox") }
    public var unarchiveFailedTitle: String { pick("取消归档失败", "Couldn't unarchive") }
    public var restoreFailedTitle: String { pick("恢复失败", "Couldn't restore") }
    /// 批量删除（阶段二 allMatching）失败。刻意不复用 `loadFailed`：用户刚按下
    /// 的是「删除这一整批」，而「加载失败」描述的是另一个操作——错误文案必须说出
    /// 失败的那件事，否则用户会去检查网络而问题出在删除本身。
    public var bulkDeleteFailed: String { pick("批量删除失败", "Bulk delete didn't complete") }

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
    /// Why 已发送 cannot be shown, in one sentence. The title already says
    /// "no Sent folder"; the detail says what that means — and explicitly
    /// what it does *not* mean, because "you have sent nothing" is the
    /// reading a user would otherwise take away from an empty surface.
    public var sentUnavailableDetail: String {
        pick(
            "这个邮箱没有「已发送」文件夹，所以这里看不到你发出去的邮件。这不代表你没有发过信。",
            "This mailbox has no Sent folder, so mail you sent can't be shown here. That doesn't mean you haven't sent any."
        )
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
    public var purgeFailedTitle: String { pick("彻底删除失败", "Couldn't delete forever") }

    // MARK: 删除
    /// 移入废纸篓是**可撤销**的，「彻底删除」不是。两者以前都叫「删除」，
    /// 用户按下一个自己以为可逆的键、发现邮件真的没了——所以这里必须说清
    /// 动作用的是哪一种。
    public var moveToTrash: String { pick("移到废纸篓", "Move to Trash") }
    public var deleted: String { pick("已移入废纸篓", "Moved to Trash") }
    public var deleteFailedTitle: String { pick("删除未完成", "Delete didn't complete") }

    // MARK: 聚合（用户自定义的智能文件夹）
    //
    // The word 「规则」 is deliberately absent from this section. In a mail
    // product, a 规则 means "condition + action" — Outlook's rules move mail
    // to a folder, Gmail's rules label and skip. A group here has a
    // condition and **no action**: it is a saved filter, evaluated when the
    // list is read. Calling it a rule promised an action that does not
    // exist, and the product did not even let the user fix the condition
    // afterwards.
    public var aggregateMenu: String { pick("分组…", "Group into…") }
    public var aggregateBySender: String { pick("按此发件人分组", "By this sender") }
    public var aggregateByKeyword: String { pick("按主题关键词分组…", "By subject keyword…") }
    public var stackListTitle: String { pick("我的分组", "My groups") }
    public var stackNew: String { pick("新建分组", "New") }
    public var stackArchivedRow: String { pick("已归档（档案柜）", "Archived (cabinet)") }
    public var stackBuiltInHeader: String { pick("内置", "Built-in") }
    public var stackEmpty: String { pick("还没有分组。右键任意邮件即可创建。", "No groups yet. Right-click any message to create one.") }
    /// The header of the list of the user's own groups.
    ///
    /// It names the collection, not the mechanism: the user does not think in
    /// rules, they think in groups they made.
    public var stackRulesHeader: String { pick("我的分组", "My groups") }
    /// The sidebar section that lists the user's own groups. It names the
    /// collection, not the mechanism: the user does not think in rules, they
    /// think in groups they made.
    public var myGroups: String { pick("我的分组", "My groups") }
    public var stackDeleteRule: String { pick("删除此分组", "Delete this group") }
    /// The row action that opens the editor on an existing group.
    ///
    /// Its partner in the same context menu used to be the only way to act on
    /// a group, which left "I built it on the wrong keyword" with exactly one
    /// exit: delete it and rebuild it.
    public var stackEditRule: String { pick("编辑此分组…", "Edit this group…") }
    public func stackKindLabel(_ kind: String) -> String { pick("按\(kind)", "By \(kind)") }
    /// The localized name of a group's match type.
    ///
    /// This used to come from `StackRule.Kind.displayName` in `LagoonKit`,
    /// which hardcoded Chinese — so an English user read 「按发件人」 under a
    /// group that had just been renamed. `LagoonKit` is shared by the server
    /// and the client and owns no user-facing copy, so the wording belongs
    /// here, next to every other string the product can show.
    public func stackKindName(_ kind: StackRule.Kind) -> String {
        switch kind {
        case .sender: stackKindSender
        case .keyword: stackKindKeyword
        }
    }
    public var stackEditorTitle: String { pick("新建分组", "New group") }
    /// The editor's title when it is opened on a group that already exists.
    public var stackEditorEditTitle: String { pick("编辑分组", "Edit group") }
    public var stackRuleKind: String { pick("匹配方式", "Match on") }
    public var stackRuleValue: String { pick("匹配内容", "Match value") }
    public var stackRuleName: String { pick("分组名称", "Group name") }
    public var stackKindSender: String { pick("发件人", "Sender") }
    public var stackKindKeyword: String { pick("关键词", "Keyword") }
    public var stackCreate: String { pick("创建", "Create") }
    /// The editor's primary button when it is saving an edit rather than
    /// creating a group — "创建" on a save would say the wrong thing about
    /// what just happened.
    public var stackSave: String { pick("保存", "Save") }
    public func stackCreated(_ name: String) -> String {
        pick("分组「\(name)」已创建，未来邮件自动归入", "Group “\(name)” created — future mail lands here automatically")
    }
    /// The confirmation after an edit. It says the group was **updated**, not
    /// created: the user changed something that already existed.
    public func stackUpdated(_ name: String) -> String {
        pick("分组「\(name)」已更新", "Group “\(name)” updated")
    }
    /// The failure title for an edit that did not land.
    public var updateRuleFailed: String { pick("保存分组失败", "Couldn't save the group") }
    public var keywordHint: String { pick("标题包含该词的邮件（不分大小写）都会进入此分组", "Mail whose subject contains this word joins the group") }
    public var senderHint: String { pick("来自该地址的全部邮件都会进入此分组", "All mail from this address joins the group") }

    // MARK: 清扫
    public var sweepTitle: String { pick("归档全部", "Archive all") }
    public var sweepHelp: String { pick("把此聚合命中的邮件整批移入档案柜", "Archive every message this group matches") }
    public func sweepDone(_ count: Int) -> String {
        pick("已归档 \(count) 封", "Archived \(count) messages")
    }
    public func sweepPartial(_ ok: Int, _ failed: Int) -> String {
        pick("\(ok) 封成功，\(failed) 封失败", "\(ok) archived, \(failed) failed")
    }
    /// A sweep that hit the server's per-call cap.
    ///
    /// The sweep looked complete and was not: the server archived what it
    /// could and reported the rest as `truncatedCount`. Saying "已归档 N 封"
    /// and stopping there is the one thing this wording exists to prevent —
    /// the user would believe the group is clear while messages are still
    /// sitting in the inbox.
    public func sweepTruncated(_ archived: Int, _ remaining: Int) -> String {
        pick(
            "已归档 \(archived) 封，还有 \(remaining) 封未处理（单次上限 500）。",
            "Archived \(archived); \(remaining) more were not processed (500 per call)."
        )
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

    // MARK: - Empty / error states (added 2026-10-20)
    //
    // One rule behind this block: an empty state that says "there is nothing
    // here" when the truth is "we could not ask" is worse than no empty state
    // at all — it teaches the user that the app has nothing, when it actually
    // failed. Every panel below therefore distinguishes three states:
    // loading, failed, and genuinely empty.

    /// "We have not asked yet" — the state before the first request lands.
    public var loadingMessages: String { pick("正在加载邮件…", "Loading messages…") }
    /// "We asked and it failed."
    /// (The shared `loadFailed` above is reused here.)
    /// "We asked and there is genuinely nothing."
    public var emptyAdvice: String { pick("还没有 AI 建议", "No advice yet") }
    public var emptyAdviceHint: String {
        pick(
            "打开简报页读几封邮件，Lagoon 会把分类建议放在这里。",
            "Read a few messages in the Briefing — Lagoon puts its suggestions here."
        )
    }
    public var emptyActionHistory: String { pick("没有可撤销的操作", "Nothing to undo") }
    public var emptyActionHistoryHint: String {
        pick(
            "归档、标记已读、退订这些操作都会记录在这里，30 天内可以撤销。",
            "Archive, mark-read and unsubscribe are recorded here — undoable for 30 days."
        )
    }
    public var emptyUsage: String { pick("暂时读不到用量数据", "Usage data is unavailable") }
    public var emptyUsageHint: String {
        pick(
            "这通常意味着本地服务没有响应。关闭这个面板再打开一次，或重启 Lagoon。",
            "Usually the local service is not responding. Close and reopen this panel, or restart Lagoon."
        )
    }
    public var emptySearchPrompt: String { pick("搜索邮件", "Search your mail") }
    public var emptySearchPromptHint: String {
        pick("按发件人、主题或正文搜索", "Search by sender, subject or body text")
    }
    public var emptySearchHint: String {
        pick(
            "换个更短的关键词试试 —— 搜索只匹配完整片段。",
            "Try a shorter keyword — search matches complete fragments."
        )
    }
    public var noMatchingCommands: String { pick("没有匹配的命令", "No matching commands") }
    public var noMatchingCommandsHint: String {
        pick("换个关键词试试", "Try a different keyword")
    }
    public var notConnectedHint: String {
        pick(
            "先在侧边栏连接一个邮箱账号。",
            "Connect a mailbox from the sidebar first."
        )
    }

    // MARK: - macOS platform (menu bar, settings, Dock, notifications)

    /// The Mail menu — the product's own verbs.
    ///
    /// Only this one is declared by the app. File, Edit, View, Window and
    /// Help are supplied by the system, and the app's items go *into* those
    /// menus rather than beside them: a second "File" menu next to the
    /// system's is the fastest way to look like software nobody reviewed.
    public var mailMenu: String { pick("邮件", "Mail") }

    /// Settings… in the application menu. The standard macOS spelling is
    /// "Settings…" (US) — a product that says "Preferences" is announcing
    /// that it was never reviewed by anyone who has used a Mac.
    public var settingsTitle: String { pick("设置…", "Settings…") }
    /// The tab titles of the settings window.
    public var settingsGeneral: String { pick("通用", "General") }
    public var settingsNotifications: String { pick("通知", "Notifications") }
    public var settingsAccount: String { pick("账户", "Account") }
    public var settingsAbout: String { pick("关于", "About") }

    /// "New message" as a menu item.
    public var menuNewMessage: String { pick("新邮件", "New Message") }
    /// "Get New Mail" — the macOS spelling for a manual sync.
    public var menuGetNewMail: String { pick("收取新邮件", "Get New Mail") }
    /// "Refresh" as a menu item.
    public var menuRefresh: String { pick("刷新", "Refresh") }
    /// "Search" as a menu item.
    public var menuSearch: String { pick("搜索…", "Search…") }
    /// "Toggle between the Briefing and the Inbox".
    public var menuToggleSurface: String { pick("在简报与收件箱之间切换", "Toggle Briefing / Inbox") }
    /// "Next density" as a menu item.
    public var menuCycleDensity: String { pick("切换列表密度", "Cycle List Density") }
    /// "Keyboard Shortcuts" in the Help menu.
    public var menuKeyboardShortcuts: String { pick("键盘快捷键", "Keyboard Shortcuts") }
    /// "Advice queue" as a menu item.
    public var menuAdvice: String { pick("建议队列", "Advice Queue") }
    /// "Reminders" as a menu item.
    public var menuReminders: String { pick("我的提醒", "My Reminders") }
    /// "Action history" as a menu item.
    public var menuActionHistory: String { pick("操作历史", "Action History") }
    /// "Sender ranking" as a menu item.
    public var menuSenderRanking: String { pick("发件人排行", "Sender Ranking") }
    /// "This month's usage" as a menu item.
    public var menuUsage: String { pick("本月用量", "This Month's Usage") }
    /// "AI settings" as a menu item.
    public var menuAISettings: String { pick("AI 设置", "AI Settings") }
    /// "Command palette" as a menu item.
    public var menuCommandPalette: String { pick("命令面板", "Command Palette") }

    /// The new-mail notification title.
    public func notificationNewMailTitle(_ count: Int) -> String {
        pick("\(count) 封新邮件", "\(count) new message\(count == 1 ? "" : "s")")
    }

    /// The "new mail notifications" switch in Settings.
    public var notificationsNewMail: String { pick("新邮件通知", "New mail notifications") }
    /// The explanation under that switch.
    public var notificationsNewMailHelp: String {
        pick("有新邮件到达时在系统通知中心提醒你。", "Get a system notification when new mail arrives.")
    }
    /// Shown when the system has not been asked yet.
    public var notificationsNotDetermined: String {
        pick("尚未询问系统权限", "Not yet requested")
    }
    /// Shown when the user said no.
    public var notificationsDenied: String {
        pick("系统通知已被拒绝 — 请在「系统设置 › 通知」中开启 Lagoon。", "Notifications are turned off for Lagoon in System Settings.")
    }
    /// Shown when the user said yes.
    public var notificationsAllowed: String {
        pick("系统通知已开启", "System notifications are on")
    }
    /// The button that opens the system notification settings.
    public var notificationsOpenSettings: String { pick("打开系统设置", "Open System Settings") }

    // MARK: - 提醒
    //
    // AI 可以建议「提醒你」，但只有用户自己设了时间，提醒才是真的。
    // 这一组文案讲的是**用户设的提醒**，不是模型的建议。

    /// The notification title for a reminder the user set.
    public var reminderNotificationTitle: String { pick("提醒", "Reminder") }
    /// The notification body, when the mail has no subject to name.
    public var reminderNotificationBody: String {
        pick("你设了一个提醒", "You set a reminder for yourself")
    }
    /// The label on the "set a reminder" button.
    public var reminderSet: String { pick("设提醒", "Set reminder") }
    /// The title of the reminder sheet.
    public var reminderTitle: String { pick("提醒", "Reminders") }
    /// The help text under the title.
    ///
    /// It states the *condition* rather than the hope. A reminder is
    /// delivered by the operating system, so "it will notify you" is a
    /// promise the app cannot keep on its own — the user has to have
    /// allowed notifications. Saying the condition is what makes the
    /// sentence true in every case the user can actually be in.
    public var reminderHelp: String {
        pick("开启系统通知后，你设的提醒会在到点时通知你。AI 只建议，不会替你设。", "With system notifications on, your reminders notify you when they are due. The AI only suggests — it never sets one for you.")
    }
    /// The date-and-time picker label.
    public var reminderWhen: String { pick("提醒时间", "Remind me") }
    /// The note field label.
    public var reminderNote: String { pick("备注（可选）", "Note (optional)") }
    /// The note field placeholder.
    public var reminderNotePlaceholder: String { pick("要记得做什么？", "What do you need to remember?") }
    /// The quick-pick for "tomorrow morning".
    public var reminderTomorrowMorning: String { pick("明早 9:00", "Tomorrow 9:00") }
    /// The quick-pick for "in three hours".
    public var reminderInThreeHours: String { pick("3 小时后", "In 3 hours") }
    /// The quick-pick for "next Monday".
    public var reminderNextMonday: String { pick("下周一 9:00", "Next Monday 9:00") }
    /// The button that saves the reminder.
    public var reminderSave: String { pick("设好提醒", "Set reminder") }
    /// Shown when the chosen time is already in the past.
    public var reminderDueInThePast: String {
        pick("提醒时间要选在未来。", "Pick a time in the future.")
    }
    /// The button that dismisses a reminder.
    public var reminderDismiss: String { pick("完成", "Done") }
    /// The empty-state line.
    public var reminderEmpty: String {
        pick("还没有提醒。", "No reminders yet.")
    }
    /// The empty-state help.
    ///
    /// The condition is named for the same reason as in `reminderHelp`: the
    /// system does the notifying, and the system only does it if the user
    /// allowed it.
    public var reminderEmptyHelp: String {
        pick("在邮件详情页点「设提醒」，开启系统通知后到点会提醒你。", "Use Set reminder on a message — with system notifications on, you will be reminded when it is due.")
    }
    /// The number of reminders waiting, shown next to the title.
    public func reminderCount(_ count: Int) -> String {
        pick("\(count) 个待办", "\(count) waiting")
    }
    /// The toggle that brings back the reminders the user already dismissed.
    public var reminderShowDismissed: String {
        pick("显示已完成的", "Show completed")
    }
    /// The line under a reminder that has been dismissed.
    public var reminderDismissedLabel: String {
        pick("已完成", "Done")
    }
    /// The button that brings a dismissed reminder back.
    public var reminderRestore: String { pick("恢复", "Restore") }
    /// The button that removes a reminder outright.
    public var reminderDelete: String { pick("删除", "Delete") }
    /// The tooltip on the 「完成」 button.
    public var reminderDismissHelp: String {
        pick("标记为已完成（可以随时恢复）", "Mark as done — you can restore it later")
    }
    /// Shown when marking a reminder done failed.
    public var reminderDismissFailed: String {
        pick("标记完成失败：", "Couldn't mark it done: ")
    }
    /// Shown when restoring a reminder failed.
    public var reminderRestoreFailed: String {
        pick("恢复失败：", "Couldn't restore it: ")
    }
    /// Shown when deleting a reminder failed.
    public var reminderDeleteFailed: String {
        pick("删除失败：", "Couldn't delete it: ")
    }
    /// Shown when the pending reminders could not be re-armed on launch.
    public var reminderArmFailed: String {
        pick("提醒通知未能重新安排：", "Couldn't re-arm your reminder notifications: ")
    }
    /// The subject of the mail, when the mail has one.
    public var reminderNoSubject: String {
        pick("（无主题）", "(no subject)")
    }
    /// The relative time on a reminder that is already overdue.
    public var reminderOverdue: String {
        pick("已过期", "Overdue")
    }
    public func reminderDueAt(_ date: Date) -> String {
        pick("\(Self.reminderDateFormatter.string(from: date)) 提醒", "Remind me at \(Self.reminderDateFormatter.string(from: date))")
    }
    /// The formatted date shown on a reminder row.
    static let reminderDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

    /// The badge on the account that is currently syncing.
    public var activeAccountBadge: String { pick("使用中", "Active") }
    /// The version row label in Settings.
    public var settingsVersion: String { pick("版本", "Version") }
    /// The local data location row label in Settings.
    public var settingsDataLocation: String { pick("数据位置", "Data location") }

    // MARK: - Actions, navigation and the About panel

    public var overrideGroup: String { pick("改分组为…", "Change group to…") }
    public var moreActions: String { pick("更多操作", "More actions") }
    public var overrideApplied: String { pick("已记录你的偏好", "Noted your preference") }
    public var sender: String { pick("发件人", "Sender") }
    public var nextInGroup: String { pick("下一封", "Next") }
    public var previousInGroup: String { pick("上一封", "Previous") }
    public var archiveAndNext: String { pick("归档并跳到下一封", "Archive & next") }
    public var markUnread: String { pick("标为未读", "Mark unread") }
    public var opening: String { pick("正在打开…", "Opening…") }
    public var inboxZero: String { pick("收件箱已清空", "Inbox zero") }
    public var tapToSync: String {
        pick("添加一个邮箱账号，让 Lagoon 开始同步。", "Add an email account to start syncing.")
    }
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
    public var aboutPrivacy: String { pick("你的数据与隐私", "Your data and privacy") }

    // MARK: - Data handling disclosure (the sheet behind 「你的数据与隐私」)

    public var privacyTitle: String { pick("你的数据与隐私", "Your data and privacy") }
    public var privacyLocalTitle: String { pick("数据只在这台 Mac 上", "Your data stays on this Mac") }
    public var privacyLocalBody: String {
        pick(
            "邮件、账号、设置和 AI 记录都存在本机的 SQLite 数据库里。Lagoon 不上传它们，也没有任何服务器端副本。",
            "Mail, accounts, settings and AI records live in a SQLite database on this Mac. Lagoon uploads none of "
                + "them, and there is no server-side copy."
        )
    }
    public var privacyEncryptedTitle: String { pick("正文是加密的", "The body is encrypted") }
    public var privacyEncryptedBody: String {
        pick(
            "邮件正文（纯文本和 HTML）以及列表里的正文预览，用 AES-256-GCM 加密后才落库。密钥只存在系统钥匙串里，"
                + "磁盘上没有任何含密钥的文件。",
            "The plain-text body, the HTML body and the preview in the list are sealed with AES-256-GCM before they "
                + "are written. The key lives in the system Keychain; no file on disk contains it."
        )
    }
    public var privacyPlaintextTitle: String { pick("这些是明文", "These are not encrypted") }
    public var privacyPlaintextBody: String {
        pick(
            "发件人、主题、时间、收件人、抄送和附件名是明文——它们是索引，列表渲染和侧边栏计数要靠它们。"
                + "别人拷走数据库文件就能看到这些。保护明文元数据的是系统本身：请打开 FileVault。",
            "Sender, subject, timestamps, recipients, cc and attachment names are stored in the clear — they are the "
                + "index the list renders from and the sidebar counts from. Anyone who copies the database file can "
                + "read them. What protects that metadata is the system: turn on FileVault."
        )
    }
    public var privacyLeavingTitle: String { pick("唯一会离开这台 Mac 的", "The only thing that leaves this Mac") }
    public var privacyLeavingBody: String {
        pick(
            "启用 AI 之后，邮件文本会发给你自己配置的模型服务商：分类发发件人、主题和正文前 200 字；摘要和草稿会发"
                + "更多正文。发出去之后，他们的留存与训练政策由他们决定。",
            "With AI switched on, mail text is sent to the model provider you configured: classification sends the "
                + "sender, the subject and the first 200 characters of the body; summaries and drafts send more of "
                + "the body. What they keep, and whether they train on it, is their policy, not ours."
        )
    }
    public var privacyNeverTitle: String { pick("Lagoon 不做的事", "What Lagoon does not do") }
    public var privacyNeverBody: String {
        pick(
            "没有埋点、没有行为分析、没有崩溃上报、不需要注册账号、不卖数据。",
            "No telemetry, no behavioural analytics, no crash reporting, no account to sign up for, and nothing to sell."
        )
    }
    public var shortcutArchiveNext: String { pick("E = 归档并下一封", "E = archive & next") }
    public var shortcutJ: String { pick("J = 下一封", "J = next") }
    public var shortcutK: String { pick("K = 上一封", "K = previous") }
    public var shortcutZ: String { pick("⌘Z = 撤销", "⌘Z = undo") }
    public var shortcutRefresh: String { pick("⌥⌘R = 刷新", "⌥⌘R = refresh") }
    public var shortcutSummarize: String { pick("⌘D = AI 摘要", "⌘D = AI summary") }
    public var shortcutDraft: String { pick("⇧⌘D = 起草回复", "⇧⌘D = draft reply") }
    public var shortcutSearch: String { pick("⌘F = 搜索", "⌘F = search") }
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
        pick("⌘1–⌘5 = 跳到简报分组", "⌘1–⌘5 = jump to a briefing group")
    }
    /// Where a shortcut works.
    ///
    /// A cheatsheet row that names a key without saying where it applies
    /// teaches a gesture that silently does nothing in the wrong surface —
    /// the user presses ⌫ on the Briefing, nothing happens, and the sheet
    /// is the one thing that should have told them why.
    public var shortcutScopeGlobal: String { pick("全局", "Global") }
    public var shortcutScopeBriefing: String { pick("仅简报", "Briefing only") }
    public var shortcutScopeLists: String { pick("邮件列表", "Mail lists") }
    /// The scope chip on the rows that only work on the raw list (⌘A, ⌘⌫).
    ///
    /// It used to say 「仅全部邮件」 / "All mail only" — the same broken
    /// promise as the old inbox title, on a chip whose whole job is to say
    /// *where* a key works. It now names the surface the user actually
    /// sees: 收件箱 / Inbox.
    public var shortcutScopeList: String { pick("仅收件箱", "Inbox only") }
    public var shortcutScopeReader: String { pick("仅阅读器", "Reader only") }
    public var shortcutScopeComposer: String { pick("仅写信时", "Composer only") }
    public var toggleSurface: String {
        pick("切换简报 / 收件箱", "Toggle Briefing / Inbox")
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

    // MARK: - 写邮件：多收件人 / 附件
    //
    // 一封邮件可以发给多个人，可以密送，可以带附件。这三件事在写邮件
    // 面板里是同一个问题的三面：**收件人不止一个**。

    public var newMessageCcLabel: String { pick("抄送", "Cc") }
    public var newMessageBccLabel: String { pick("密送", "Bcc") }
    public var newMessageCcPlaceholder: String { pick("抄送（多人用逗号分隔）", "Cc (comma-separated)") }
    public var newMessageBccPlaceholder: String { pick("密送（多人用逗号分隔）", "Bcc (comma-separated)") }
    public var newMessageBccHelp: String {
        pick("密送：收件人看不到这封信还发给了谁", "Bcc: other recipients cannot see who else got this mail")
    }
    public var newMessageMultipleRecipientsHelp: String {
        pick("多人用逗号分隔", "Separate several addresses with commas")
    }
    public func newMessageInvalidRecipient(address: String) -> String {
        pick("「\(address)」不是有效的邮箱地址。", "\"\(address)\" is not a valid email address.")
    }
    public var newMessageAttachments: String { pick("附件", "Attachments") }
    public var newMessageAddAttachment: String { pick("添加附件", "Add attachment") }
    public var newMessageRemoveAttachment: String { pick("移除附件", "Remove attachment") }
    public func newMessageAttachmentTooLarge(_ name: String) -> String {
        pick("「\(name)」超过 25 MB，发送不了。", "\"\(name)\" is larger than 25 MB and cannot be sent.")
    }
    public func newMessageAttachmentEmpty(_ name: String) -> String {
        pick("「\(name)」是空文件。", "\"\(name)\" is empty.")
    }
    public var newMessageAttachmentReadFailed: String {
        pick("读不了这个文件。", "This file could not be read.")
    }
    public func newMessageAttachmentCount(count: Int) -> String {
        pick("\(count) 个附件", "\(count) attachments")
    }
    public func newMessageRecipientsCount(count: Int) -> String {
        pick("\(count) 位收件人", "\(count) recipients")
    }

    public var reply: String { pick("回复", "Reply") }
    public var replyHelp: String { pick("回复这封邮件", "Reply to this message") }
    public var replyAll: String { pick("回复全部", "Reply all") }
    public var replyAllHelp: String { pick("回复发件人和所有收件人（⇧⌘R）", "Reply to the sender and everyone on the thread (⇧⌘R)") }
    public var replyCc: String { pick("抄送", "Cc") }
    public var forward: String { pick("转发", "Forward") }
    public var forwardHelp: String { pick("把这封邮件转发给别人（⇧⌘F）", "Forward this message to someone else (⇧⌘F)") }
    /// The note the user writes above a forwarded message.
    public var forwardNoteLabel: String { pick("附言（可选）", "Note (optional)") }
    /// The placeholder for that note.
    public var forwardNotePlaceholder: String {
        pick("想对收件人说的话…", "Anything you want to say…")
    }
    /// What the sheet says about the original.
    ///
    /// This line exists because the previous forward looked like a forward
    /// and was not one: it pasted the original's text into a new message,
    /// so the formatting, the attachments and the headers were all gone.
    /// The user had no way to tell. The sheet now says what happens to
    /// the original.
    public var forwardKeepsOriginal: String {
        pick(
            "原邮件会**作为原邮件**转发给收件人：格式、附件和原来的信息都保留。",
            "The original travels **as the original**: its formatting, its attachments and its headers all come along."
        )
    }
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

    // MARK: - 启动 / 内嵌服务

    /// 启动阶段的两句文案，以及内嵌服务的两条错误。启动态发生在 `RootView`
    /// 之前——而 `RootView` 才是注入 `\.l10n` 的那一层——所以这些字串按非 View
    /// 代码的既有路径读 `L10n.current`（与工具栏语言选择器写的是同一个
    /// UserDefaults 键）。英文界面下启动阶段即英文，不再硬编码中文。
    public var serverStarting: String { pick("Lagoon 正在启动…", "Lagoon is starting…") }
    public var serverStartFailed: String { pick("启动失败", "Failed to start") }
    public var keyGenerationFailed: String {
        pick(
            "无法生成加密密钥（Keychain 写入失败）",
            "Couldn't generate the encryption key (Keychain write failed)"
        )
    }
    public var embeddedServerStartFailed: String {
        pick("内嵌服务启动失败", "The embedded server couldn't start")
    }
    public var appSupportUnavailable: String {
        pick(
            "找不到应用支持目录，无法存放本地数据库。",
            "Couldn't locate the Application Support directory to store the local database."
        )
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

// MARK: - Column width

public extension L10n {
    /// What a separator is called in the accessibility tree.
    ///
    /// A noun the user can act on rather than a position they have to infer —
    /// "adjustable" with no subject announces a control that adjusts nothing.
    func columnWidthNoun(_ noun: String) -> String {
        switch noun {
        case "navigation":
            return pick("调整左侧栏宽度", "Adjust the sidebar width")
        case "list":
            return pick("调整邮件列表宽度", "Adjust the message list width")
        default:
            return pick("调整阅读区宽度", "Adjust the reading pane width")
        }
    }

    /// The spoken width. The unit is included because a bare number is read as
    /// a count rather than a measurement.
    func columnWidthPoints(_ points: Int) -> String {
        pick("\(points) 点", "\(points) points")
    }

    /// Home / End, as accessibility action names.
    var columnWidthToMin: String {
        pick("移到最小宽度", "Move to the minimum width")
    }

    var columnWidthToMax: String {
        pick("移到最大宽度", "Move to the maximum width")
    }

    /// The separator's tooltip.
    ///
    /// Names the column the drag moves *and* teaches the ⌥ inversion, because
    /// neither is discoverable otherwise: the handle is a 1pt line with no label
    /// until the pointer is already on it, and a modifier nobody has been told
    /// about is a feature that does not exist. Both halves are needed — "drag to
    /// resize" alone leaves the user guessing which column, and naming the column
    /// without the modifier leaves the wider reader unreachable.
    func columnResizeTooltip(_ noun: String) -> String {
        // The first separator cannot invert: ⌥ there would target the list,
        // which is already the column to its left, so there would be nothing
        // left to say.
        guard noun != "navigation" else {
            return pick("拖动调整左侧栏宽", "Drag to resize the sidebar")
        }
        return pick(
            "拖动调整左侧栏宽，按住 ⌥ 改为调整阅读区宽度",
            "Drag to resize the column, or hold ⌥ to resize the reading pane"
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
