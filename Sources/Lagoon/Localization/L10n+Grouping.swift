import Foundation

/// The strings that tell the product's **two** grouping mechanisms apart.
///
/// ## Why this file exists
///
/// The product groups mail twice, with two different tables and two
/// different names:
///
/// * the sidebar's 「我的分组」 — a *filter* the user writes (sender exact
///   match, or subject keyword), evaluated every time the list is read;
/// * the Briefing feed's five groups (需要回复 / 等待对方回复 / 可归档 /
///   订阅噪音 / 已置顶) — a *filing decision* made by the heuristic
///   classifier, the AI, and the user's 「改分组为…」 overrides.
///
/// Neither mechanism reads the other's table. That is a legitimate design —
/// one is a lens the user controls, the other is a judgement the product
/// makes — but it used to be **undiscoverable**: no string anywhere told
/// the user that the two are separate, so a user who built a group, saw it
/// in the sidebar with a live count, and then watched the Briefing file the
/// same mail under 可归档 had every reason to conclude that the AI ignores
/// their rules.
///
/// So the product now says so, in the two places where the confusion
/// actually happens: the sidebar section that creates the groups, and the
/// Briefing feed that does not follow them.
///
/// These strings live in their own file rather than in `L10n.swift` so that
/// two features can each add a string without both editing the same
/// 2000-line file — the same split `L10n+Override.swift` uses.
extension L10n {
    // MARK: - The sidebar's 「我的分组」 caption

    /// What a group **does**: it filters mail by sender or subject keyword.
    ///
    /// "筛出" (filters out) rather than "归类" (files into), because a group
    /// has a condition and **no action** — it does not move, archive or
    /// re-file anything. The user guide has said this for a while; the
    /// screen had not.
    public var stackGroupsCaption: String {
        pick("按发件人或关键词筛出邮件", "Filters mail by sender or keyword")
    }

    /// What a group does **not** do: it does not change the Briefing's
    /// groups.
    ///
    /// The negative half of the caption, and the half that was missing. A
    /// caption that only said what a group does would leave the reader
    /// assuming the two mechanisms feed each other — which is exactly the
    /// assumption this copy exists to remove.
    public var stackGroupsCaptionLimit: String {
        pick("不改变简报里的分组", "Does not change the Briefing's groups")
    }

    // MARK: - The Briefing feed's note

    /// The note above the feed's five groups.
    ///
    /// It is the mirror of the sidebar's caption: the user reads it in the
    /// place where their group was *ignored*, so it says who decides these
    /// groups and that the sidebar's groups are not one of the inputs.
    ///
    /// It says 「简报里的分组」, not 「这些分组」. The note's entire job is to
    /// separate two sets of things that are both called 分组, and a pronoun
    /// leaves the reader to work out which set it means — in the one
    /// sentence that exists because that inference already went wrong once.
    ///
    /// "由 Lagoon 判定" rather than "由 AI 判定", because the decision is
    /// Lagoon's either way — the heuristic classifier decides when no AI is
    /// configured, and it decides for anything the model has not been asked
    /// about. Naming only the AI would be a promise the product does not
    /// keep.
    public var briefingGroupsNote: String {
        pick(
            "简报里的分组由 Lagoon 判定，侧边栏「我的分组」不改变它们",
            "The Briefing's groups are decided by Lagoon; the \"My groups\" in the sidebar do not change them."
        )
    }

    // MARK: - The group editor's note

    /// The note in the sheet where a group is created.
    ///
    /// This is the **creation moment** — the one point in the flow where the
    /// user is about to expect a rule to start doing something, and where
    /// they would otherwise find out (much later, in the Briefing) that it
    /// does not.
    ///
    /// It says what the group *does* and what it *does not* do, in one
    /// sentence, because the sheet is already explaining the matching
    /// condition right above it. The user does not need to be told twice
    /// that the group filters by sender or keyword — the field's own hint
    /// says that. What they cannot guess is the boundary.
    public var stackEditorScopeNote: String {
        pick(
            "这个分组在侧边栏筛出邮件，不会改变简报里的分组。",
            "This group filters mail in the sidebar; it does not change the Briefing's groups."
        )
    }
}
