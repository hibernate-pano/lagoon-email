import Foundation

/// The action-history panel's strings.
///
/// They live here rather than in `L10n.swift` so this panel can grow without
/// editing the file every other feature is also editing. `pick` is internal,
/// which is what makes the split possible.
extension L10n {
    /// The verdict on a row whose undo window has closed.
    ///
    /// Distinct from `notUndoable` on purpose. "不可撤销" is a fact about the
    /// *kind* of action (a sent message has no inverse); "已过期" is a fact
    /// about *time* (this archive could have been undone yesterday). A panel
    /// that said "不可撤销" to both told the user the product could never
    /// take the action back when the truth was that it still could for
    /// another week — the user guide promises the expired state is shown as
    /// such, and this is what makes that promise keepable.
    public var actionExpired: String { pick("已过期", "Expired") }

    /// The "load older" control at the bottom of the panel.
    ///
    /// Says "older", not "more": the list is newest-first, so the next page is
    /// always further back in time. "更多" would leave the user unsure
    /// whether the button re-sorts the list.
    public var actionHistoryLoadMoreOlder: String {
        pick("加载更早的记录", "Load older actions")
    }

    /// How many older entries exist beyond the rows on screen.
    ///
    /// The panel used to stop at the hundredth row in silence, which reads as
    /// "that is the whole history". A number is what turns the cut-off into a
    /// statement the user can act on.
    public func actionHistoryRemaining(_ count: Int) -> String {
        pick("还有 \(count) 条更早的记录", "\(count) older entries not shown")
    }

    /// Why the older rows are worth a glance even though they are near the
    /// end of their undo window.
    ///
    /// The list is `created_at DESC`, so scrolling down means scrolling
    /// toward expiry: the last rows on the last page are the ones that will
    /// stop being undoable first. Saying so is the difference between a
    /// caveat and a surprise.
    public var actionHistoryOlderNearExpiry: String {
        pick(
            "越早的记录离 30 天的撤销期限越近。",
            "The older the entry, the closer it is to the 30-day undo limit."
        )
    }

    public var actionHistoryLoadFailed: String {
        pick("操作历史加载失败", "Couldn't load the action history")
    }

    /// One sentence for both the first page and the next one: the reason is
    /// the same, and the next step (`重试`) is the same.
    public var actionHistoryLoadFailedHint: String {
        pick("请检查网络后重试。", "Check your network and retry.")
    }

    public var actionHistoryLoadMoreFailed: String {
        pick("加载更早的记录失败", "Couldn't load older entries")
    }

    /// Returned by `UndoController.undo(actionId:)` when there is no account
    /// to undo against. The panel bails out before offering the button, so
    /// this is a race, not a normal path — but a race still needs a sentence
    /// rather than a silent no-op.
    public var undoNoAccount: String {
        pick("没有已连接的账号。", "No account is connected.")
    }
}
