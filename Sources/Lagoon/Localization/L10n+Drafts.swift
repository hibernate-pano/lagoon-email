import Foundation

/// The 「AI 草稿」 and storage-notice strings.
///
/// They live here rather than in `L10n.swift` so that the file that
/// *defines* the feature and the file that *says* what it does are
/// separate. Two features that each need a string can then work at the
/// same time without both editing the same 2000-line file.
extension L10n {
    // MARK: - The drafts were dropped

    /// The banner title when the store had to delete drafts it could not
    /// encrypt.
    ///
    /// It says *what* happened ("草稿被清除了") and not *why* in the title:
    /// the reason is the same for every install (the encryption key was not
    /// available at the time the store was upgraded), and a headline that
    /// carries the reason reads like a bug report.
    public var draftsDroppedTitle: String {
        pick("之前的 AI 草稿被清除了", "Your earlier AI drafts were cleared")
    }

    /// The banner detail: how many, and what the user can do about it.
    ///
    /// The count is there because "some drafts" and "all of them" are
    /// different problems for the user, and because a number is the one
    /// thing that tells them whether to go and regenerate. The last
    /// sentence is the action: the drafts are *regenerable*, and saying so
    /// is what turns a loss into a task.
    public func draftsDroppedDetail(count: Int) -> String {
        pick(
            "有 \(count) 份 AI 草稿因为无法加密而被删除，避免以明文留在磁盘上。重新生成一份就行：打开那封邮件，点「生成草稿」。",
            "\(count) AI draft(s) were deleted because they could not be encrypted, rather than left in the clear on disk. Just generate them again: open the mail and choose “Generate drafts”."
        )
    }

    /// The banner detail when the count is not known.
    ///
    /// A separate string rather than a "0" in the counted one: "0 drafts
    /// were deleted" is a statement about the world, and the banner is
    /// about a loss.
    public var draftsDroppedDetailUnknownCount: String {
        pick(
            "之前的 AI 草稿因为无法加密而被删除，避免以明文留在磁盘上。重新生成一份就行：打开那封邮件，点「生成草稿」。",
            "Your earlier AI drafts were deleted because they could not be encrypted, rather than left in the clear on disk. Just generate them again: open the mail and choose “Generate drafts”."
        )
    }

    // MARK: - A draft that cannot be read

    /// The message shown when a stored draft cannot be decrypted.
    ///
    /// It names the condition and not the content: the draft is the user's
    /// mail, and an error message that carried it would put it on screen
    /// (and into a screenshot) in a place that is not the draft panel.
    public var draftUnreadable: String {
        pick(
            "这份草稿读不出来了（加密密钥对不上），可以重新生成一份。",
            "This draft could not be read (the encryption key does not match). Generate a new one."
        )
    }
}
