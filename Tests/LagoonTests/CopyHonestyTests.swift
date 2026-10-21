import XCTest
import Foundation
@testable import Lagoon
@testable import LagoonKit

/// Guards for the copy-honesty audit batch (P2-04 / P2-05 / P2-08).
///
/// ## The class of bug these guard
///
/// Every item here is the same shape: **the product says something the code
/// does not do**. A title that names a set the server never returns, a
/// heading that names a category instead of a place, an instruction buried
/// where a step should be.
///
/// These are cheap to fix and expensive to leave: a user who is told one
/// thing and gets another does not conclude "that label is wrong", they
/// conclude "this app does not tell the truth", and then they stop trusting
/// every other thing it says.
///
/// ## Why some of these are source-level
///
/// The string *values* are reachable from a unit test — `L10n` is a plain
/// value type, and `MessageListView.surfaceTitle(for:l10n:)` is a pure
/// function on purpose. So the value assertions below are real behavioural
/// tests against production code, not against a restatement of it.
///
/// The *wiring* is not: which view attaches which string to which title,
/// and whether the onboarding form still renders the instruction as a
/// labelled step, are only visible in the source. Those are asserted the
/// `ViewSource` way — the attachment of a string between anchors — and each
/// one names the failure it prevents.
final class CopyHonestyTests: XCTestCase {
    private let zh = L10n(language: .zhHans)
    private let en = L10n(language: .english)

    // MARK: - P2-04: "全部邮件" was the inbox

    /// The inbox's title must not promise more than the inbox holds.
    ///
    /// ## What it prevents
    ///
    /// The server answers this lens with `is_archived = FALSE AND
    /// is_deleted = FALSE AND is_sent = FALSE` (`MessageStore.filterSQL`) —
    /// the inbox, and *not* sent mail. So the old title 「全部邮件」 /
    /// "All messages" made a promise the content could not keep, and the
    /// question it invited ("why isn't the mail I sent in 全部邮件?") had no
    /// answer except "the title is wrong".
    ///
    /// ## Why both languages
    ///
    /// A rename that only lands in one language is still a lie in the other.
    /// The English side matters as much: "All messages" is the same broken
    /// promise, just in a different script.
    func test_theInboxIsNamedTheInboxInBothLanguages() {
        XCTAssertEqual(
            zh.allMessages, "收件箱",
            "the inbox's title must say 收件箱 — it does not hold sent mail, "
                + "archived mail, or trashed mail"
        )
        XCTAssertEqual(
            en.allMessages, "Inbox",
            "the English title must say Inbox for the same reason"
        )
        XCTAssertNotEqual(
            zh.allMessages, "全部邮件",
            "P2-04 regressed: the title is claiming to be all mail again"
        )
        XCTAssertNotEqual(
            en.allMessages, "All messages",
            "P2-04 regressed: the English title is claiming to be all mail again"
        )
    }

    /// The same rename has to hold on every surface that shows the inbox.
    ///
    /// The string is used in five places: the sidebar row, the list's
    /// toolbar title, the toolbar's surface picker, the Briefing's "show the
    /// raw list" button, and the ⌘0 menu item. Fixing one and leaving the
    /// others is how a product ends up saying 「收件箱」 in the sidebar and
    /// 「全部邮件」 in the menu bar.
    func test_everySurfaceThatNamesTheInboxUsesTheSameName() {
        // The production mapping, not a restatement of it.
        XCTAssertEqual(
            MessageListView.surfaceTitle(for: .all, l10n: zh), zh.allMessages,
            "the list's toolbar title must be the inbox's name"
        )
        XCTAssertEqual(
            MessageListView.surfaceTitle(for: nil, l10n: zh), zh.allMessages,
            "no lens yet is the inbox, and it says so"
        )
    }

    /// The strings that *describe* the inbox must not describe it as
    /// "everything" either.
    ///
    /// `surfaceHelp` is the tooltip on the surface picker and the
    /// description of the ⌘0 row in the cheatsheet; `showRawListHelp` is
    /// the Briefing's button tooltip. Each one used to say 全部邮件.
    func test_theInboxDescribingStringsDoNotPromiseEverything() {
        for string in [zh.surfaceHelp, zh.showRawListHelp, zh.menuToggleSurface, zh.toggleSurface] {
            XCTAssertFalse(
                string.contains("全部邮件"),
                "this string still calls the inbox 全部邮件: \"\(string)\""
            )
        }
        for string in [en.surfaceHelp, en.showRawListHelp, en.menuToggleSurface, en.toggleSurface] {
            XCTAssertFalse(
                string.lowercased().contains("all messages"),
                "this string still calls the inbox \"All messages\": \"\(string)\""
            )
        }
    }

    /// The sidebar's own row must carry the inbox's name.
    ///
    /// Asserted against the source because `Sidebar`'s title resolution is
    /// a private method over an environment value — there is no way to read
    /// the rendered label from a unit test. What *is* pinned here is the
    /// attachment: the sidebar's title switch must answer the `.allMessages`
    /// case with `l10n.allMessages`, so a future "let me make this row say
    /// something friendlier" edit cannot quietly reintroduce a second
    /// spelling of the inbox.
    func test_theSidebarRowForTheInboxUsesTheInboxName() throws {
        let source = try ViewSource.read("Sidebar")
        let title = try XCTUnwrap(
            source.range(of: "private func title(for destination: SidebarDestination)"),
            "Sidebar lost its title resolution"
        )
        let body = ViewSource.code(after: title.lowerBound, in: source, limit: 900)
        XCTAssertTrue(
            body.contains("case .allMessages: return l10n.allMessages"),
            "the sidebar's inbox row must use the shared inbox name"
        )
    }

    /// The user guide must say what the UI says.
    ///
    /// The guide is the other half of the promise: a user who reads
    /// 「全部邮件」 in the manual and 「收件箱」 in the app has to work out
    /// which one is lying, and the manual is not the more authoritative of
    /// the two.
    func test_theUserGuideNamesTheInboxTheInbox() throws {
        // The repo root, from this file's own path — the guide lives in
        // `docs/`, which `ViewSource.url` does not reach.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LagoonTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
        let doc = try String(
            contentsOf: repoRoot.appendingPathComponent("docs/使用说明.md"),
            encoding: .utf8
        )
        XCTAssertFalse(
            doc.contains("全部邮件"),
            "the user guide still calls the inbox 全部邮件"
        )
        XCTAssertTrue(
            doc.contains("收件箱"),
            "the user guide should name the inbox 收件箱"
        )
    }

    /// The cheatsheet's scope chip must not promise "all mail" either.
    ///
    /// The chip on the ⌘A and ⌘⌫ rows said 「仅全部邮件」 / "All mail only" —
    /// the same broken promise as the old inbox title, on a control whose
    /// whole job is to say *where* a key works. It now names the surface the
    /// user actually sees.
    func test_theShortcutScopeChipNamesTheInbox() {
        XCTAssertEqual(zh.shortcutScopeList, "仅收件箱")
        XCTAssertEqual(en.shortcutScopeList, "Inbox only")
        XCTAssertFalse(
            zh.shortcutScopeList.contains("全部邮件"),
            "the scope chip still claims the raw list is all mail"
        )
        XCTAssertFalse(
            en.shortcutScopeList.lowercased().contains("all mail"),
            "the scope chip still claims the raw list is all mail"
        )
    }

    // MARK: - P2-05: the rule lens must show the rule's name

    /// The rule lens's title is the user's own name for the rule.
    ///
    /// ## What it prevents
    ///
    /// The title used to be `l10n.stackRulesHeader` — 「分组规则」 /
    /// "Group rules" — a *category*, not a place. A user who clicked their
    /// 「工作」 group in the sidebar saw a list headed 「分组规则」 and had no
    /// way to tell which group they were looking at. The toolbar title is
    /// the one place the user confirms where they are; it cannot name a
    /// category.
    func test_theRuleLensTitleIsTheRulesOwnName() {
        typealias Lens = MessageListView.Lens
        XCTAssertEqual(
            MessageListView.surfaceTitle(for: .rule(UUID()), l10n: zh, ruleTitle: "工作"),
            "工作",
            "the rule lens must show the user's own name for the rule"
        )
        XCTAssertEqual(
            MessageListView.surfaceTitle(for: .rule(UUID()), l10n: en, ruleTitle: "Work"),
            "Work",
            "and the same in English"
        )
    }

    /// The rule lens must NOT collapse back onto a generic title.
    ///
    /// This is the mutation that the previous test would not have caught: if
    /// the `.rule` branch ignored `ruleTitle` and returned the header
    /// anyway, the test above would fail too — but a *later* edit that
    /// dropped the `ruleTitle` parameter from the call would pass a
    /// "title is not empty" check while showing the wrong thing. So the
    /// fallback is pinned separately: the header is only allowed when
    /// there is genuinely no name to show.
    func test_theRuleLensFallsBackOnlyWhenThereIsNoName() {
        typealias Lens = MessageListView.Lens
        // No name yet (the rule list has not loaded): the rules header is
        // the honest stand-in — better than a blank heading.
        XCTAssertEqual(
            MessageListView.surfaceTitle(for: .rule(UUID()), l10n: zh, ruleTitle: nil),
            zh.stackRulesHeader
        )
        XCTAssertEqual(
            MessageListView.surfaceTitle(for: .rule(UUID()), l10n: zh, ruleTitle: ""),
            zh.stackRulesHeader,
            "an empty name is not a name"
        )
        // But a real name is never replaced by the generic header.
        XCTAssertNotEqual(
            MessageListView.surfaceTitle(for: .rule(UUID()), l10n: zh, ruleTitle: "工作"),
            zh.stackRulesHeader,
            "the rule's own name must win over the generic header"
        )
    }

    /// Every *other* lens must keep its own title.
    ///
    /// The rule lens gaining a real name must not cost another lens its
    /// name — a shared branch that served two lenses would show 「工作」 in
    /// the trash as well.
    func test_theOtherLensesKeepTheirOwnTitles() {
        typealias Lens = MessageListView.Lens
        XCTAssertEqual(MessageListView.surfaceTitle(for: .sent, l10n: zh, ruleTitle: "工作"), zh.sidebarSent)
        XCTAssertEqual(MessageListView.surfaceTitle(for: .archived, l10n: zh, ruleTitle: "工作"), zh.stackArchivedRow)
        XCTAssertEqual(MessageListView.surfaceTitle(for: .deleted, l10n: zh, ruleTitle: "工作"), zh.sidebarDeleted)
        XCTAssertEqual(MessageListView.surfaceTitle(for: .unread, l10n: zh, ruleTitle: "工作"), zh.sidebarUnread)
        XCTAssertEqual(MessageListView.surfaceTitle(for: .pinned, l10n: zh, ruleTitle: "工作"), zh.sidebarPinned)
        XCTAssertEqual(MessageListView.surfaceTitle(for: .all, l10n: zh, ruleTitle: "工作"), zh.allMessages)
    }

    /// The name has to be *wired* from the parent's rule list.
    ///
    /// Two things are pinned here, because either one alone is insufficient:
    ///
    /// 1. `RootView` must look the name up from the rule list it already
    ///    holds (`/api/stacks`) and hand it to the list. A list that
    ///    fetched the name itself would be a second copy of the rule list.
    /// 2. `MessageListView` must have a `ruleTitle` property to receive
    ///    it. A `ruleTitle` that exists but is never passed is the classic
    ///    "the parameter was added and then nobody used it" state, and the
    ///    title would silently keep showing the generic header.
    func test_theRuleNameIsWiredFromTheParentsRuleList() throws {
        let root = try ViewSource.read("RootView")
        // The lookup: by id, against the list `/api/stacks` returned.
        XCTAssertTrue(
            root.contains("private var currentRuleName: String?"),
            "RootView must resolve the current rule's name"
        )
        XCTAssertTrue(
            root.contains("sidebarRules.first { $0.rule.id == id }?.rule.name"),
            "the name must come from the same rule list the sidebar renders"
        )
        // And the hand-off.
        XCTAssertTrue(
            root.contains("ruleTitle: currentRuleName"),
            "RootView must pass the rule's name to the list"
        )

        let list = try ViewSource.read("MessageListView")
        XCTAssertTrue(
            list.contains("var ruleTitle: String?"),
            "MessageListView must have a place to receive the rule's name"
        )
        // The title must actually read it.
        XCTAssertTrue(
            list.contains("Self.surfaceTitle(for: lens, l10n: l10n, ruleTitle: ruleTitle)"),
            "the toolbar title must pass the rule's name into the mapping"
        )
    }

    /// The sidebar's rule row must show the rule's own name too.
    ///
    /// The sidebar used to take the name as a `customTitle` override, which
    /// left its own `.rule` branch as dead code returning 「分组规则」 — a
    /// branch that would have shown the wrong thing the moment a rule row
    /// was built without the override. One place resolves the name now, so
    /// the branch is live and correct.
    func test_theSidebarResolvesTheRuleNameInOneLivePlace() throws {
        let source = try ViewSource.read("Sidebar")
        XCTAssertFalse(
            source.contains("title customTitle: String?"),
            "the customTitle override is back — the rule name has one home, and it "
                + "is the title resolution, not a parameter beside it"
        )
        XCTAssertTrue(
            source.contains("rules.first { $0.rule.id == id }?.rule.name"),
            "the sidebar must resolve the rule's name from the rule list"
        )
    }

    // MARK: - P2-08: getting the authorization code is a step, not small print

    /// The instruction must exist, in both languages, and be long enough to
    /// actually be an instruction.
    ///
    /// The old copy was two grey `caption2`/`tertiary` paragraphs. The
    /// content is the same; what changed is that it is now a labelled step
    /// in normal type. This assertion pins the *content*; the *presentation*
    /// is pinned below.
    func test_theAuthCodeStepHasItsOwnTitleAndInstructions() {
        XCTAssertEqual(zh.qqAuthCodeStepTitle, "第 1 步：获取授权码")
        XCTAssertEqual(en.qqAuthCodeStepTitle, "Step 1: get an authorization code")
        XCTAssertEqual(zh.qqFormStepTitle, "第 2 步：填写并连接")
        XCTAssertEqual(en.qqFormStepTitle, "Step 2: fill in and connect")

        // The path has to name the actual place. QQ Mail's own help centre
        // (help.mail.qq.com/detail/0/1087) says 设置 → 账号与安全 →
        // POP3/IMAP/SMTP/Exchange 服务 → 开启 → 验证 → 生成授权码.
        XCTAssertTrue(
            zh.qqAuthCodeHelp.contains("账号与安全"),
            "the instruction must name QQ Mail's current path: \"\(zh.qqAuthCodeHelp)\""
        )
        XCTAssertTrue(
            zh.qqAuthCodeHelp.contains("授权码"),
            "the instruction must say what the user is going to get"
        )
        XCTAssertTrue(
            en.qqAuthCodeHelp.contains("Account & Security"),
            "the English instruction must name QQ Mail's current path: \"\(en.qqAuthCodeHelp)\""
        )
    }

    /// The step must be *actionable*: a link the user can open.
    ///
    /// ## Why the link points at the mailbox, not the settings page
    ///
    /// QQ Mail's settings screen needs a signed-in session (`sid`). The
    /// app cannot have one — the user has to log in with their QQ password
    /// and a phone verification — so a deep link to the settings page
    /// bounces to the sign-in page for anyone not already in a browser
    /// session. `https://mail.qq.com` is the one URL that is always the
    /// right place: it signs the user in, and the numbered path says where
    /// to go from there.
    ///
    /// The URL was verified to resolve (HTTP 200) and to serve QQ Mail.
    func test_theAuthCodeStepOffersAWorkingLink() {
        XCTAssertEqual(
            ConnectView.qqMailURL.absoluteString, "https://mail.qq.com",
            "the link must go to QQ Mail's web interface"
        )
        XCTAssertEqual(
            ConnectView.qqMailURL.scheme, "https",
            "the link must be https"
        )
        XCTAssertEqual(
            ConnectView.qqMailURL.host(), "mail.qq.com",
            "the link must go to QQ Mail, not somewhere else"
        )
        // The button and its tooltip must both exist — a button with no
        // label, or a label with no explanation of where it goes, is half
        // a button.
        XCTAssertFalse(zh.qqAuthCodeOpenButton.isEmpty)
        XCTAssertFalse(en.qqAuthCodeOpenButton.isEmpty)
        XCTAssertFalse(zh.qqAuthCodeOpenHelp.isEmpty)
        XCTAssertFalse(en.qqAuthCodeOpenHelp.isEmpty)
    }

    /// The instruction must be a labelled step on the form, not small print.
    ///
    /// This is the source-level part: the *rendering* of the step — that it
    /// is a headline with a body and a link under it, rather than a
    /// `caption2`/`tertiary` line — is not reachable from a unit test.
    ///
    /// What is pinned:
    ///
    /// * the step's title and body are attached to the form, between the
    ///   `authCodeStep` and `formStep` anchors;
    /// * the body is NOT `caption2`/`tertiary` — the old presentation, and
    ///   the whole point of the fix;
    /// * the link is a `Link` to the verified URL, not a bare string.
    func test_theAuthCodeStepIsALabelledStepOnTheForm() throws {
        let source = try ViewSource.read("ConnectView")

        // The step exists as its own piece of the form.
        XCTAssertTrue(
            source.contains("private var authCodeStep: some View"),
            "the authorization-code step must be a first-class part of the form"
        )

        // Its title and body are attached to it.
        let step = try XCTUnwrap(
            source.range(of: "private var authCodeStep: some View"),
            "the auth-code step moved"
        )
        let stepBody = ViewSource.code(after: step.lowerBound, in: source, limit: 1600)
        XCTAssertTrue(
            stepBody.contains("Text(l10n.qqAuthCodeStepTitle)"),
            "the step must carry its title"
        )
        XCTAssertTrue(
            stepBody.contains("Text(l10n.qqAuthCodeHelp)"),
            "the step must carry the path to the code"
        )

        // And it is a *step*, not small print: the old styling was
        // `caption2` + `tertiary`, which is what made it unreadable.
        XCTAssertFalse(
            stepBody.contains(".font(.caption2)"),
            "the instruction is small print again — it is a required step, "
                + "not a footnote"
        )
        XCTAssertFalse(
            stepBody.contains(".foregroundStyle(.tertiary)"),
            "the instruction is grey-on-grey again — it is a required step, "
                + "not a footnote"
        )

        // The link is a real, openable link.
        XCTAssertTrue(
            stepBody.contains("Link(destination: Self.qqMailURL)"),
            "the step must offer a link the user can open"
        )
    }

    /// The form step must be the *second* step, and the button must still
    /// be there.
    ///
    /// The rewrite replaced the single `qqSection` body with two steps. A
    /// rewrite that lost the connect button would be a much worse bug than
    /// the one it fixed, so the button's presence is pinned here rather
    /// than assumed.
    func test_theFormStepStillHasItsFieldsAndItsConnectButton() throws {
        let source = try ViewSource.read("ConnectView")
        XCTAssertTrue(
            source.contains("private var formStep: some View"),
            "the form must be its own step"
        )
        let form = try XCTUnwrap(
            source.range(of: "private var formStep: some View"),
            "the form step moved"
        )
        // Bounded by the *next* declaration rather than by a character
        // count: a fixed window is a guess, and a guess that is too small
        // reports a missing button for a button that is right there.
        let formEnd = try XCTUnwrap(
            source.range(
                of: "private var displayedError",
                range: form.upperBound..<source.endIndex
            ),
            "the form step's end anchor moved"
        )
        // `String.Index` is not a `Int` offset, so the slice is taken by
        // converting both ends first — subtracting two indices is not a
        // distance in characters.
        let start = source.distance(from: source.startIndex, to: form.lowerBound)
        let end = source.distance(from: source.startIndex, to: formEnd.lowerBound)
        let formBody = ViewSource.code(
            after: form.lowerBound, in: source[form.lowerBound..<formEnd.lowerBound],
            limit: end - start
        )
        for anchor in [
            "TextField(l10n.qqEmailPlaceholder, text: $qqEmail)",
            "SecureField(l10n.qqAuthCodePlaceholder, text: $qqAuthCode)",
            "Text(l10n.qqConnectButton)",
            "connectTask = Task { await connectQQ() }",
        ] {
            XCTAssertTrue(
                formBody.contains(anchor),
                "the form step lost '\(anchor)' — the rewrite must not cost the "
                    + "user the fields or the connect button"
            )
        }
    }

    /// The two old grey paragraphs must not both be back.
    ///
    /// `qqAuthCodeHelp` and `qqHelp` used to be two differently-worded
    /// copies of the same instructions, which is how two near-identical
    /// grey paragraphs ended up under the form. Two copies of one step
    /// drift apart and leave the user unsure which one is current, so the
    /// second one is now a one-line reminder about what the code *is*, and
    /// it must not restate the path.
    func test_theReminderUnderTheFieldDoesNotRestateThePath() {
        XCTAssertFalse(
            zh.qqHelp.contains("POP3"),
            "the field's reminder is a second copy of the path: \"\(zh.qqHelp)\""
        )
        XCTAssertFalse(
            zh.qqHelp.contains("设置"),
            "the field's reminder is a second copy of the path: \"\(zh.qqHelp)\""
        )
        XCTAssertFalse(
            en.qqHelp.contains("POP3"),
            "the field's reminder is a second copy of the path: \"\(en.qqHelp)\""
        )
        // But it must still say the one thing that matters: this is not the
        // password. Users paste the wrong thing here constantly.
        XCTAssertTrue(
            zh.qqHelp.contains("密码"),
            "the reminder must say this is a password, not the login password"
        )
        XCTAssertTrue(
            en.qqHelp.lowercased().contains("password"),
            "the reminder must say this is a password, not the login password"
        )
    }
}
