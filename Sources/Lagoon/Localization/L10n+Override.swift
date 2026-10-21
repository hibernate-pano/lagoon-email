import Foundation
import LagoonKit

/// The 「改分组」 strings.
///
/// They live here rather than in `L10n.swift` so that the file that
/// *defines* the feature and the file that *says* what it does are
/// separate — the same split `L10n+AI.swift` uses.
extension L10n {
    // MARK: - 改分组 (override)

    /// The sheet's title.
    ///
    /// It used to be the same string as the menu item — 「改分组为…」 — which
    /// read as a per-mail action. The title now names what the sheet does,
    /// and the sheet's body names the scope the user is about to choose.
    public var overrideScopeTitle: String {
        pick("改分组", "Change group")
    }

    /// Where the mail is now.
    ///
    /// It answers "what am I moving it out of", which is a different
    /// question from "what am I moving it to" — and the one the user is
    /// more likely to be thinking about, since the reason they opened the
    /// sheet is that the mail is in the wrong group.
    public func overrideCurrentGroup(_ group: String) -> String {
        pick(
            "当前分组：\(group)",
            "Currently in: \(group)"
        )
    }

    /// The line that says what the **broad** change will do.
    ///
    /// ## Why this sentence exists
    ///
    /// The override was stored per sender while the interface read as a
    /// per-mail action: the user moved one mail, and every mail from that
    /// sender moved too, with nothing on screen saying so. The interface has
    /// to tell the truth about the blast radius before the user commits —
    /// otherwise the product is asking for trust it has not earned.
    ///
    /// The sender's address is interpolated, because "every mail from this
    /// sender" is only meaningful if the user can see *which* sender.
    public func overrideSenderScopeBody(sender: String) -> String {
        pick(
            "将把 \(sender) 的所有邮件移到所选分组。",
            "Every mail from \(sender) will move to the group you pick."
        )
    }

    /// The line that says what the **narrow** change will do.
    public func overrideMessageScopeBody(sender: String) -> String {
        pick(
            "只把这封邮件移到所选分组，\(sender) 的其他邮件不受影响。",
            "Only this mail moves to the group you pick. Other mail from \(sender) is unaffected."
        )
    }

    /// The heading of the scope choice.
    ///
    /// It names the dimension, so the user sees that a scope is being
    /// chosen at all.
    public var overrideScopePrompt: String {
        pick("适用范围", "Applies to")
    }

    /// The narrow option: this mail only.
    public var overrideScopeMessageOnly: String {
        pick("只改这一封", "This mail only")
    }

    /// The broad option: every mail from this sender.
    public var overrideScopeSenderAll: String {
        pick("改这个发件人的所有邮件", "All mail from this sender")
    }

    /// The button that applies the change.
    ///
    /// Its own string rather than the shared 「完成」, because "Done" means
    /// "stop editing" and this button means "make this change now" — and
    /// the difference is the whole point of the sheet.
    public var overrideScopeConfirm: String {
        pick("应用", "Apply")
    }

    /// The scope detail appended to the confirmation notice.
    ///
    /// It says **how far** the change reached, because 「已记录你的偏好」
    /// alone does not distinguish "one mail moved" from "the sender's whole
    /// mailbox moved" — and those are different facts the user is entitled
    /// to know about.
    public func overrideScopeDetail(_ scope: OverrideScope) -> String {
        switch scope {
        case .message:
            pick("只影响这一封邮件", "only this mail is affected")
        case .sender:
            pick("影响这个发件人的所有邮件", "every mail from this sender is affected")
        }
    }

    /// The toast shown after the change is stored.
    ///
    /// It is the shared 「已记录你的偏好」 plus the scope, because the shared
    /// half says *that* the change happened and the scope half says *how
    /// far* it reached. The two together are the fact; either alone is
    /// half a fact.
    public func overrideAppliedToast(scope: OverrideScope) -> String {
        // `self.` is load-bearing, not style: the dead-key scanner counts a
        // string as used only when it appears after a dot (or twice in the
        // file that declares it), and `overrideApplied` is declared in
        // `L10n.swift` — a file this change deliberately does not edit. A
        // bare reference here reads as "declared once, never used" and the
        // build fails.
        "\(self.overrideApplied) · \(overrideScopeDetail(scope))"
    }

    /// The note that connects this feature to the sidebar's own groups.
    ///
    /// ## Why it is here
    ///
    /// 「改分组」 and the sidebar's 「我的分组」 are two different mechanisms
    /// that both group mail by sender, with two different tables and two
    /// different names. The user has no way to know they are related. This
    /// line says where the *other* one lives, so the two stop being two
    /// mysteries — without pretending they are the same thing, which they
    /// are not.
    ///
    /// It says 「筛出」 rather than 「归类」 for the same reason the sidebar's
    /// caption does: a group is a saved *filter*, and it files nothing.
    /// Calling it a 规则 would also contradict the naming decision the
    /// product already made — a group has a condition and no action.
    public var overrideSidebarGroupsNote: String {
        pick(
            "侧边栏「我的分组」是另一套筛出邮件的条件，可以随时改名或删除。",
            "The \"My groups\" in the sidebar are a separate set of conditions that filter mail, and you can rename or delete them at any time."
        )
    }
}
