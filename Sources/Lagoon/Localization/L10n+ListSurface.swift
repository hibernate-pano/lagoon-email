import Foundation

/// The strings the two list surfaces share.
///
/// `L10n.swift` is the shared file every feature appends to, and it has
/// grown past two thousand lines. The project already splits it per feature
/// (`L10n+Advice.swift`, `L10n+Backup.swift`) so two domains editing the
/// same file do not collide — this file holds the copy for the list and
/// bulk-action surfaces: the verbs the Briefing feed and the raw message
/// list both offer, and the sentences that say what a bulk action will
/// actually cover.
///
/// Every string here says **what will happen**, in the scope the action
/// really has. A bulk bar that says "40 封" has to mean forty mails the
/// server will really move, and a tooltip that describes a *failure* on a
/// button that *succeeds* teaches the user to distrust the button.
extension L10n {
    // MARK: - 批量条：动词说明

    /// 批量条上「标为已读」的说明。
    ///
    /// The tooltip used to be the *failure* title — hovering 「标为已读」
    /// said 「标记已读失败」, which reads as "this button is broken". The
    /// tooltip answers "what does this do?", not "what happens when it
    /// fails?"; the failure has its own banner, with its own words.
    public var bulkMarkReadHelp: String {
        pick("把选中的邮件标为已读", "Mark the selected messages as read")
    }

    /// 批量条上「标为未读」的说明。
    public var bulkMarkUnreadHelp: String {
        pick("把选中的邮件标为未读", "Mark the selected messages as unread")
    }

    /// 批量条上「归档」的说明。
    public var bulkArchiveHelp: String {
        pick("把选中的邮件归档", "Archive the selected messages")
    }

    /// 批量条上「移到废纸篓」的说明。
    public var bulkDeleteHelp: String {
        pick("把选中的邮件移到废纸篓", "Move the selected messages to the Trash")
    }

    // MARK: - 全部标为已读：两个列表两种口径

    /// 简报页「全部标为已读」的口径。
    ///
    /// The Briefing's 「全部」 is the whole server window it was given — the
    /// feed says so itself in 「另有 N 封未纳入简报」 — so the button can
    /// honestly say "the briefing's unread mail".
    public var markAllReadBriefingHelp: String {
        pick(
            "把当前简报里的未读邮件全部标为已读（⇧⌘K）",
            "Mark every unread message in the briefing as read (⇧⌘K)"
        )
    }

    /// 「全部标为已读」在邮件列表里的口径。
    ///
    /// The raw list loads a **window** of the mailbox; the server may hold
    /// thousands more. The button still acts on every unread message it can
    /// reach, but the sentence says how many those are — a count the user
    /// can check against the sidebar — instead of claiming "everything".
    public func markAllReadListHelp(_ count: Int) -> String {
        pick(
            "把当前列表已加载的 \(count) 封未读邮件标为已读（⇧⌘K）",
            "Mark the \(count) unread messages loaded in this list as read (⇧⌘K)"
        )
    }

    /// 速查表里那一行的说明：两个列表都是「当前列表」。
    public var markAllReadListsHelp: String {
        pick(
            "把当前列表里的未读邮件全部标为已读（⇧⌘K）",
            "Mark every unread message in the current list as read (⇧⌘K)"
        )
    }

    // MARK: - 批量失败：说清楚是哪个动词

    /// 批量归档：一部分失败。
    ///
    /// The old title was 「部分邮件处理失败」 — it named no verb, so the
    /// user could not tell whether the archive or the delete had failed.
    public var bulkArchivePartial: String {
        pick("部分邮件归档失败", "Some messages could not be archived")
    }

    /// 批量删除：一部分失败。
    public var bulkDeletePartial: String {
        pick("部分邮件删除失败", "Some messages could not be deleted")
    }

    /// 批量归档：整批失败。
    public var bulkArchiveFailed: String {
        pick("批量归档失败", "Bulk archive didn't complete")
    }

    /// 批量标记已读：整批失败。
    public var bulkMarkReadFailed: String {
        pick("批量标记已读失败", "Bulk mark-as-read didn't complete")
    }

    /// 「全部标为已读」：一封都没成功。
    ///
    /// 「部分邮件标为已读失败」 is wrong when *nothing* landed — the user
    /// would read "some failed" as "the rest worked".
    public var markAllReadFailed: String {
        pick("全部邮件标为已读失败", "Marking everything as read didn't complete")
    }

    // MARK: - 批量条的作用范围

    /// 简报页批量条的作用范围。
    ///
    /// The Briefing has no "everything on the server" scope — the server
    /// resolves the briefing window, and there is no endpoint that means
    /// "the whole window" — so the bar says which mails it will really
    /// touch: the ones on screen.
    public func briefingBulkScope(_ count: Int) -> String {
        pick(
            "只作用于已加载的 \(count) 封（简报窗口内的邮件）",
            "Only the \(count) loaded messages are affected (the briefing window)"
        )
    }

    /// 邮件列表第二段全选时，各动词能覆盖的范围。
    ///
    /// Stage two claims the server's total, and only one verb can reach it:
    /// the delete goes to the server as a query. Archiving and marking read
    /// still work on the loaded messages only, so the bar says so instead of
    /// letting a count of 3,142 travel with an action that moves 200.
    public func bulkStageTwoScope(_ loaded: Int, _ total: Int) -> String {
        pick(
            "删除作用于服务器上的全部 \(total) 封；归档和标已读只作用于已加载的 \(loaded) 封",
            "Delete covers all \(total) on the server; archive and mark-as-read cover the \(loaded) loaded ones"
        )
    }

    // MARK: - 分组计数

    /// 简报页分组标题上那个数字的口径。
    ///
    /// The number is how many mails of that group are **loaded**; the
    /// briefing is a window, so the number is a lower bound. The tooltip
    /// says which one it is.
    public func groupCountScope(_ count: Int) -> String {
        pick(
            "已加载 \(count) 封（简报窗口内）",
            "\(count) loaded messages (within the briefing window)"
        )
    }

    // MARK: - 置顶去了哪里

    /// 简报页置顶后的提示。
    ///
    /// Pinning in the Briefing moves the mail into the 已置顶 group — the
    /// row visibly leaves 需要回复 — so the toast names the destination.
    /// A toast that only said 「已置顶」 left the user wondering where the
    /// mail went.
    public var pinnedMovedToast: String {
        pick("已置顶 · 已移到「已置顶」分组", "Pinned · moved to the Pinned group")
    }
}
