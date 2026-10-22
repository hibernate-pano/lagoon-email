import Foundation

/// The strings the triage panels say when something is about to be lost.
///
/// ## Why this file exists
///
/// Three panels in the app destroy something on a single gesture: a
/// reminder, an aggregation group, and a sender's whole mail window. Two of
/// them used to do it from a right-click menu with no confirmation at all,
/// and the third counted a number it was not acting on.
///
/// The strings here are the other half of the fix — the confirmations have
/// to *name* what is about to go, because a confirmation that says "this"
/// is not a confirmation.
///
/// They live in their own file so that a feature owner can add a string
/// without editing the 2000-line `L10n.swift` — the same split
/// `L10n+Grouping.swift` and `L10n+Reminder.swift` use.
extension L10n {
    // MARK: - Deleting a reminder

    /// The title of the reminder-deletion confirmation.
    public var reminderDeleteConfirmTitle: String {
        pick("删除这个提醒？", "Delete this reminder?")
    }

    /// Names the reminder that is about to be deleted.
    ///
    /// A delete here is a hard delete — the row is destroyed, not marked
    /// done — so the confirmation has to say *which* reminder, or it is
    /// indistinguishable from the confirmation for any other row.
    public func reminderDeleteConfirmMessage(_ subject: String) -> String {
        pick(
            "「\(subject)」的提醒会被删除，无法恢复。",
            "The reminder for 「\(subject)」 is deleted for good. It cannot be recovered."
        )
    }

    // MARK: - Deleting an aggregation group

    /// The title of the group-deletion confirmation, naming the group.
    public func stackDeleteRuleConfirmTitle(_ name: String) -> String {
        pick("删除分组「\(name)」？", "Delete the group 「\(name)」?")
    }

    /// What deleting a group actually does.
    ///
    /// The mail is *not* deleted — it goes back to the default group — so
    /// the confirmation says so, because a user who believes the opposite
    /// will not delete a group they wanted to keep.
    public func stackDeleteRuleConfirmMessage(_ name: String, _ count: Int) -> String {
        pick(
            "「\(name)」现在匹配 \(count) 封邮件。删除这个分组不会删除这些邮件——它们会回到默认分组——但分组本身无法恢复。",
            "「\(name)」matches \(count) messages. Deleting the group does not delete them — they go back to the default group — but the group itself cannot be recovered."
        )
    }

    // MARK: - Empty aggregation panels

    /// The built-in archive cabinet is empty.
    public var stackArchivedEmpty: String {
        pick("档案柜是空的", "The cabinet is empty")
    }

    /// A group the user wrote matches nothing.
    ///
    /// The group may match on a *keyword*, so it must not talk about
    /// senders: telling a user who just created a keyword group that they
    /// have no mail from a sender explains something that was never asked.
    public func stackGroupEmpty(_ name: String) -> String {
        pick(
            "「\(name)」还没有匹配的邮件",
            "「\(name)」has no matching messages yet"
        )
    }

    // MARK: - What a bulk action covers

    /// The scope of the sender panel's bulk actions.
    ///
    /// The verbs below it operate on the rows the response carried, which
    /// is not always the sender's whole history. The bar says so, in the
    /// bar — the one place the user reads before pressing a button.
    public func senderBulkScope(shown: Int, total: Int) -> String {
        pick(
            "已加载 \(shown) 封（共 \(total) 封），批量操作只作用于已加载的邮件",
            "Loaded \(shown) of \(total) — the bulk actions cover the loaded mail only"
        )
    }

    // MARK: - The sound toggle

    /// The state of the action-sound toggle, when it is on.
    public var soundOn: String {
        pick("开", "On")
    }

    /// The state of the action-sound toggle, when it is off.
    public var soundOff: String {
        pick("关", "Off")
    }
}
