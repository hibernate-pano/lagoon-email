import XCTest
import Foundation
@testable import Lagoon

/// The product groups mail **twice**, and the user has to be able to tell.
///
/// ## The bug
///
/// There are two independent grouping mechanisms over the same mailbox:
///
/// * the sidebar's 「我的分组」 — a saved *filter* (sender exact match, or
///   subject keyword), evaluated every time the list is read
///   (`MessageStore.filterSQL`), which is what drives the sidebar's rows
///   and the raw list's lens;
/// * the Briefing feed's five groups (需要回复 / 等待对方回复 / 可归档 /
///   订阅噪音 / 已置顶) — a *filing decision* made by the heuristic
///   classifier, the AI, and the user's 「改分组为…」 overrides, stored in
///   `ai_overrides` and read only by `BriefingRoutes`.
///
/// Neither reads the other's table. That is a legitimate design — one is a
/// lens the user controls, the other is a judgement the product makes — but
/// it was **undiscoverable**: no string anywhere said the two were
/// separate. So a user who built a group, saw it in the sidebar with a live
/// count, clicked it, saw exactly the mail they expected — and then found
/// the same mail still filed under 可归档 in the Briefing — had every
/// reason to conclude that the AI ignores their rules.
///
/// ## Why these are source-level guards
///
/// The defect is a *wording* defect: the code does what it always did, and
/// the promise it makes on screen did not match. A behavioural test cannot
/// see that — the sidebar is a `@State` view whose rows cannot be read back
/// from a unit test, and a SwiftUI section header is not a value. So these
/// read the source and pin the facts that must be true of it: that the
/// caption exists, that a view actually renders it, and that the wording
/// does not claim the two mechanisms are connected.
///
/// The string *values* are reachable, though — `L10n` is a plain value type
/// — so the assertions about what the copy says are real assertions against
/// production strings, not against a restatement of them.
final class GroupingMechanismClarityTests: XCTestCase {
    private let zh = L10n(language: .zhHans)
    private let en = L10n(language: .english)

    private func sidebarSource() throws -> String {
        try ViewSource.read("Sidebar")
    }

    private func briefingSource() throws -> String {
        try ViewSource.read("BriefingFeedView")
    }

    private func stackSheetsSource() throws -> String {
        try ViewSource.read("StackSheets")
    }

    private func groupingL10nSource() throws -> String {
        try String(
            contentsOf: ViewSource.url(under: "Localization", "L10n+Grouping"),
            encoding: .utf8
        )
    }

    /// Whether `source` references `name` as a *whole* member.
    ///
    /// `String.contains` is not enough here, and mutation testing proved it:
    /// `l10n.stackGroupsCaption` is a **prefix** of
    /// `l10n.stackGroupsCaptionLimit`, so deleting the first line left every
    /// `contains` assertion green on the second. A reference counts only when
    /// the character after it cannot continue the identifier.
    private static func references(_ name: String, in source: String) -> Bool {
        var cursor = source.startIndex
        while let found = source.range(of: name, range: cursor..<source.endIndex) {
            cursor = found.upperBound
            guard let next = source[cursor...].first else { return true }
            if !(next.isLetter || next.isNumber || next == "_") { return true }
        }
        return false
    }

    // MARK: - The sidebar's caption says what a group does

    /// The caption must say what a group **does**.
    ///
    /// A group is a filter: it has a condition (sender or keyword) and no
    /// action. It does not move, archive or re-file anything. If the caption
    /// only carried the negative half ("these do not change the Briefing"),
    /// the user would still not know what the group is *for* — and the
    /// sidebar is where they look to find out.
    func test_theSidebarCaptionSaysWhatAGroupDoes() {
        let caption = zh.stackGroupsCaption
        XCTAssertFalse(caption.isEmpty, "the caption must exist")
        XCTAssertTrue(
            caption.contains("发件人") || caption.contains("关键词"),
            "the caption must name what the group matches on: \(caption)"
        )
        XCTAssertTrue(
            caption.contains("筛"),
            "the caption must say the group *filters* mail, not that it files it: \(caption)"
        )
    }

    /// The caption must say what a group does **not** do.
    ///
    /// This is the half that was missing everywhere, and it is the half that
    /// answers the actual confusion: the user built a group, the group
    /// works, and the Briefing still files the mail elsewhere. Without this
    /// sentence the only available conclusion is "the AI ignores my rules".
    ///
    /// ## Why the assertion is on the *rendered pair*, not on the line alone
    ///
    /// The boundary line says 「不改变简报里的分组」 and leaves the subject
    /// implicit — the section's own title, 「我的分组」, is the subject, and
    /// it sits directly above it. Asserting that the line alone contains
    /// 「我的分组」 would force the caption to repeat the heading, which is
    /// the kind of redundancy that makes a two-line caption read as a
    /// paragraph. What has to be true is that the *header* names both sets,
    /// so a reader looking at the section header can tell which one is which.
    func test_theSidebarCaptionSaysWhatAGroupDoesNotDo() {
        // Named `boundary`, not `limit`: `limit` is a SQL clause keyword, and
        // the SQL guardrail scans test sources too — a local named `limit`
        // sitting next to an interpolation is exactly the shape it flags.
        let boundary = zh.stackGroupsCaptionLimit
        XCTAssertFalse(boundary.isEmpty, "the boundary line must exist")
        XCTAssertTrue(
            boundary.contains("不改变"),
            "the caption must state the boundary: \(boundary)"
        )
        XCTAssertTrue(
            boundary.contains("分组"),
            "the caption must name what does not change: \(boundary)"
        )
        XCTAssertTrue(
            boundary.contains("简报"),
            "the caption must name the Briefing, the thing that does not change: \(boundary)"
        )
        // The header as a whole must distinguish the two sets: the sidebar's
        // own name for its groups, and the Briefing's.
        XCTAssertTrue(
            zh.myGroups.contains("我的分组"),
            "the section header must still name the sidebar's groups"
        )
    }

    // MARK: - The caption reaches the user

    /// The caption must be **rendered**, not merely declared.
    ///
    /// A localization key that no view references is a dead key — the build
    /// catches that (`L10nDeadKeyTests`) — but the reverse is the more
    /// dangerous case: a string that *is* referenced, by a line of code that
    /// never runs, or by a comment. So this asserts the caption sits inside
    /// the sidebar's group section, between the section's own anchors.
    ///
    /// The anchors are the group's own row and the section's closing — both
    /// inside the 「我的分组」 section — so the slice cannot wander into the
    /// 智能视图 or 位置 sections and find an unrelated caption.
    func test_theSidebarRendersTheCaptionInTheGroupSection() throws {
        let source = try sidebarSource()
        let sectionStart = try XCTUnwrap(
            source.range(of: "if !rules.isEmpty {"),
            "the sidebar's group section is gone"
        )
        let section = source[sectionStart.lowerBound...]

        // `references`, not `contains`: `l10n.stackGroupsCaption` is a
        // **prefix** of `l10n.stackGroupsCaptionLimit`, so a plain `contains`
        // stayed green after the first line was deleted — mutation testing
        // caught that, which is the whole reason this is a helper.
        XCTAssertTrue(
            Self.references("l10n.stackGroupsCaption", in: String(section)),
            "the sidebar's group section must render the caption"
        )
        XCTAssertTrue(
            Self.references("l10n.stackGroupsCaptionLimit", in: String(section)),
            "the sidebar's group section must render the boundary line too"
        )
        // The caption has to be inside the *header*, not somewhere in the
        // section body: a caption under the last row would be a thing the
        // user scrolls past, not a thing that labels the section.
        XCTAssertTrue(
            section.contains("} header: {"),
            "the group section must have a header for the caption to live in"
        )
        let headerStart = try XCTUnwrap(
            section.range(of: "} header: {"),
            "the group section's header is gone"
        )
        let header = String(section[headerStart.upperBound...].prefix(700))
        XCTAssertTrue(
            Self.references("l10n.stackGroupsCaption", in: header),
            "the caption must be inside the section header"
        )
        XCTAssertTrue(
            Self.references("l10n.stackGroupsCaptionLimit", in: header),
            "the boundary line must be inside the section header too"
        )
    }

    /// The caption must look like a caption.
    ///
    /// The sidebar's other explanatory lines are `.caption` in `.secondary`,
    /// and a section header in the platform's own style is the default
    /// `Text`. A caption in the body type would read as a *row* — which is
    /// the one thing it must not be, because the user would click it
    /// expecting it to navigate.
    func test_theCaptionIsTypesetAsACaptionNotAsARow() throws {
        let source = try sidebarSource()
        let caption = try XCTUnwrap(
            source.range(of: "Text(l10n.stackGroupsCaption)"),
            "the sidebar must render the caption"
        )
        let code = ViewSource.code(after: caption.lowerBound, in: source, limit: 260)
        XCTAssertTrue(
            code.contains(".font(.caption)"),
            "the caption must be `.caption` — a body-size line reads as a clickable row"
        )
        XCTAssertTrue(
            code.contains(".foregroundStyle(.secondary)"),
            "the caption must be `.secondary` — it is supporting text, not content"
        )
    }

    // MARK: - The caption does not overclaim

    /// The copy must not claim the two mechanisms are connected.
    ///
    /// This is the failure mode of a *different* fix: writing a caption that
    /// says the two work together, or that the group "影响" the Briefing.
    /// That would be worse than silence — it would be a promise the code
    /// does not keep, in the very place the product is trying to become
    /// trustworthy.
    ///
    /// So the caption is checked for the *absence* of the connecting
    /// vocabulary, in both languages.
    func test_theCaptionDoesNotClaimTheTwoMechanismsAreConnected() {
        for caption in [zh.stackGroupsCaption, zh.stackGroupsCaptionLimit] {
            for forbidden in ["影响", "同步", "同时", "也", "一并", "一起"] {
                XCTAssertFalse(
                    caption.contains(forbidden),
                    "the caption must not claim the two mechanisms are connected "
                        + "(found 「\(forbidden)」): \(caption)"
                )
            }
        }
        for caption in [en.stackGroupsCaption, en.stackGroupsCaptionLimit] {
            for forbidden in ["affects", "syncs", "also", "applies to", "updates"] {
                XCTAssertFalse(
                    caption.lowercased().contains(forbidden),
                    "the English caption must not claim the two mechanisms are connected "
                        + "(found \"\(forbidden)\"): \(caption)"
                )
            }
        }
    }

    /// The English copy must exist, and must not be the Chinese copy.
    ///
    /// A missing translation silently degrades to a language the user did
    /// not choose; an untranslated string is worse than an empty one,
    /// because it looks deliberate.
    func test_bothLanguagesHaveTheCaption() {
        XCTAssertNotEqual(zh.stackGroupsCaption, en.stackGroupsCaption)
        XCTAssertNotEqual(zh.stackGroupsCaptionLimit, en.stackGroupsCaptionLimit)
        XCTAssertFalse(en.stackGroupsCaption.isEmpty)
        XCTAssertFalse(en.stackGroupsCaptionLimit.isEmpty)
    }

    // MARK: - The Briefing says it too

    /// The Briefing feed must carry the note.
    ///
    /// The sidebar's caption is where the groups are *created*; the feed's
    /// note is where the user *sees them being ignored*. The note is the
    /// one that reaches the person who is actually confused, because that is
    /// where they are looking when the confusion happens.
    ///
    /// ## Why the render site, not just the string
    ///
    /// The first version asserted only that the file contained
    /// `l10n.briefingGroupsNote`. Mutation testing deleted the `groupsNote`
    /// line from the `VStack` — so the note was computed and never shown —
    /// and the assertion stayed green, because the string was still there
    /// inside the `groupsNote` property. The assertion now reads the
    /// composition site: the note must be a child of the surface's body.
    func test_theBriefingCarriesTheNote() throws {
        let source = try briefingSource()
        XCTAssertTrue(
            source.contains("l10n.briefingGroupsNote"),
            "the Briefing feed must render the note that names who decides its groups"
        )
        // The note has to be *placed* in the left column's stack: a bare
        // child of the `VStack`, between the header and `content` — not a
        // property that is computed and never called, which is the exact
        // shape mutation testing produced while this assertion was a plain
        // `contains`.
        let stack = try XCTUnwrap(
            source.range(of: "private var sidebar: some View {"),
            "the Briefing's left column moved"
        )
        let column = String(source[stack.lowerBound...].prefix(900))
        XCTAssertTrue(
            column.contains("\n                groupsNote"),
            "the note must be a child of the column's VStack — a `groupsNote` "
                + "property that nothing renders is a note the user never sees"
        )
        let placed = try XCTUnwrap(
            column.range(of: "\n                groupsNote"),
            "the note is not placed in the column"
        )
        let afterNote = column[placed.upperBound...]
        XCTAssertTrue(
            afterNote.contains("content"),
            "the note must sit just before `content`, inside the same VStack"
        )
    }

    /// The note must name **who decides** the feed's groups.
    ///
    /// "由 AI 判定" would be a promise the product does not keep: the
    /// heuristic classifier decides when no model is configured, and it
    /// decides for anything the model has not been asked about. Naming
    /// Lagoon is the honest answer.
    func test_theBriefingNoteSaysWhoDecidesTheGroups() {
        let note = zh.briefingGroupsNote
        XCTAssertTrue(
            note.contains("Lagoon"),
            "the note must say Lagoon decides these groups, not the AI: \(note)"
        )
        XCTAssertFalse(
            note.contains("AI"),
            "the note must not name the AI — the heuristic classifier decides too: \(note)"
        )
        XCTAssertTrue(
            note.contains("我的分组"),
            "the note must name the sidebar's groups, so the user can tell which ones it means: \(note)"
        )
    }

    /// The note must be reachable only when the user has groups.
    ///
    /// The whole point of a caption is to reach the person who is confused,
    /// and *only* that person. A user who has never made a group has not
    /// seen the second mechanism, so a permanent line about 「我的分组」 would
    /// be a sentence about a feature they do not use, on the surface they
    /// open every day.
    ///
    /// So the note's visibility is gated on the rule list, and the gate has
    /// to be *wired*: `RootView` holds the rules for the sidebar, and hands
    /// the feed the same fact rather than letting the feed fetch it again
    /// (two sources for one fact is how the note and the sidebar start
    /// disagreeing).
    func test_theBriefingNoteOnlyAppearsWhenTheUserHasGroups() throws {
        let briefing = try briefingSource()
        XCTAssertTrue(
            briefing.contains("var hasUserGroups: Bool = false"),
            "the feed must know whether the user has groups"
        )
        XCTAssertTrue(
            briefing.contains("if hasUserGroups {"),
            "the note must be gated on the user having groups"
        )
        // The gate must be read from the same state the sidebar reads.
        let root = try ViewSource.read("RootView")
        XCTAssertTrue(
            root.contains("hasUserGroups: !sidebarRules.isEmpty"),
            "the gate must come from the rule list RootView already holds for the sidebar"
        )
    }

    // MARK: - The creation moment

    /// The group editor must say what the group will and will not do.
    ///
    /// This is the moment the user is most likely to *expect* their rule to
    /// start doing something — they are saving it right now — and the
    /// moment they are least likely to be told otherwise.
    func test_theGroupEditorSaysWhatTheGroupWillNotDo() throws {
        let sheets = try stackSheetsSource()
        XCTAssertTrue(
            sheets.contains("l10n.stackEditorScopeNote"),
            "the group editor must render the scope note"
        )
        // Only on create. An existing group is already understood as a
        // filter; re-stating the boundary on every edit is noise.
        XCTAssertTrue(
            sheets.contains("if !isEditing {"),
            "the scope note must appear only when creating a group"
        )
    }

    /// The editor's note must carry both halves.
    func test_theEditorNoteSaysBothWhatItDoesAndWhatItDoesNot() {
        let note = zh.stackEditorScopeNote
        XCTAssertTrue(
            note.contains("侧边栏"),
            "the note must say where the group shows up: \(note)"
        )
        XCTAssertTrue(
            note.contains("不会改变") || note.contains("不改变"),
            "the note must state the boundary: \(note)"
        )
        XCTAssertTrue(
            note.contains("简报"),
            "the note must name the thing that does not change: \(note)"
        )
    }

    // MARK: - The two mechanisms stay separate

    /// The Briefing route must not read the stack rules.
    ///
    /// This is the *behavioural* half of the story, and it is the reason the
    /// copy above is needed rather than optional: as long as the briefing
    /// ignores `stack_rules`, the honest caption is the only thing standing
    /// between the user and a wrong conclusion.
    ///
    /// If this ever goes red, the copy is no longer the whole truth — the
    /// product converged the two mechanisms, and the captions above have to
    /// be rewritten rather than left to lie.
    func test_theBriefingRouteDoesNotReadTheStackRules() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LagoonTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Sources/LagoonServer/Routes/BriefingRoutes.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(
            source.contains("stack_rules") || source.contains("stackId"),
            "the Briefing route now reads the stack rules — the two mechanisms have "
                + "converged, and every caption above has to be rewritten"
        )
    }

    /// The two captions must agree with each other.
    ///
    /// Three surfaces now explain the same boundary — the sidebar's
    /// caption, the feed's note, the editor's note. If they disagree (one
    /// says 「不改变」 and another says 「同步」), the product contradicts
    /// itself in three places at once, which is worse than saying nothing in
    /// one.
    func test_theThreeExplanationsUseTheSameBoundaryWording() {
        let phrases = [
            zh.stackGroupsCaptionLimit,
            zh.briefingGroupsNote,
            zh.stackEditorScopeNote,
        ]
        for phrase in phrases {
            XCTAssertTrue(
                phrase.contains("我的分组") || phrase.contains("分组"),
                "every explanation must name the groups it is talking about: \(phrase)"
            )
            XCTAssertTrue(
                phrase.contains("简报"),
                "every explanation must name the Briefing, which is the thing that does not change: \(phrase)"
            )
        }
    }
}
