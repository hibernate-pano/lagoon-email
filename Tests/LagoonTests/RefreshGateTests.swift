import XCTest
import SwiftUI
@testable import Lagoon

/// `RefreshGate` is the bookkeeping both list surfaces share, and the
/// reason two defects shipped: a local mutation (archive, delete, mark
/// read) that forgot to retire the in-flight poll let the poll write its
/// pre-mutation snapshot straight back, and a refresh raised while another
/// was in flight was dropped instead of queued, so the user sat on a stale
/// snapshot until the next 30s tick.
final class RefreshGateTests: XCTestCase {
    /// F25: a poll captures the list, the user archives a row, the poll
    /// returns — the generation has moved on, so it must not commit.
    func test_invalidateRetiresTheInFlightResponse() throws {
        var gate = RefreshGate()
        let claimed = try XCTUnwrap(gate.claim())

        // The archive callback calls invalidate() before removing the row.
        gate.invalidate()

        XCTAssertNotEqual(
            claimed, gate.generation,
            "the in-flight poll would write the pre-archive snapshot back"
        )
    }

    /// The same hole existed on mark-read, which the detail view fires on
    /// open — the most common local mutation of all.
    func test_markReadAlsoRetiresTheInFlightResponse() throws {
        var gate = RefreshGate()
        let claimed = try XCTUnwrap(gate.claim())
        gate.invalidate()
        XCTAssertNotEqual(claimed, gate.generation)
    }

    /// F3: a refresh arriving mid-poll used to hit
    /// `guard !isLoading else { return }` and vanish. The gate has to
    /// remember it and report the debt on the way out.
    func test_aRefreshRaisedDuringAnInFlightOneIsNotLost() throws {
        var gate = RefreshGate()
        let first = try XCTUnwrap(gate.claim())

        // The ⌘Z notification lands while the first poll is still running.
        let second = gate.claim()
        XCTAssertNil(second, "only one refresh may run at a time")
        XCTAssertTrue(
            gate.finish(),
            "the caller that was turned away is owed a run; finishing must say so"
        )

        // …and the replay is a real, claimable run.
        let replay = try XCTUnwrap(gate.claim())
        XCTAssertNotEqual(replay, first)
        XCTAssertFalse(gate.finish(), "nothing is owed any more")
    }

    /// A burst collapses into one replay: the payload is the same for every
    /// caller, so three notifications during one poll cost one extra fetch,
    /// not three.
    func test_severalWaitingCallersCollapseIntoOneReplay() throws {
        var gate = RefreshGate()
        XCTAssertNotNil(gate.claim())
        XCTAssertNil(gate.claim())
        XCTAssertNil(gate.claim())
        XCTAssertNil(gate.claim())

        XCTAssertTrue(gate.finish())
        let replay = try XCTUnwrap(gate.claim())
        XCTAssertNotNil(replay)
        XCTAssertFalse(gate.finish(), "the replay drained the queue")
    }

    /// The gate must not let a stale response commit, and must keep
    /// working after a superseded run.
    func test_aSupersededRunCannotCommit() throws {
        var gate = RefreshGate()
        let stale = try XCTUnwrap(gate.claim())
        gate.invalidate()
        _ = gate.finish()
        let current = try XCTUnwrap(gate.claim())
        _ = gate.finish()

        XCTAssertNotEqual(stale, current, "the old run is still identifiable as stale")
        XCTAssertEqual(current, gate.generation, "the newest run may commit")
    }
}

/// F28: the 聚合规则 button sits in the always-present toolbar, so the
/// sheet that opens it has to live outside the `if !messages.isEmpty`
/// branch too. It used to hang off the `List`, and with an empty inbox the
/// button did nothing at all and the feature was unreachable.
///
/// This asserts the modifier's *placement*, not a rendered outcome: the
/// package has no UI-test target, and SwiftUI's view tree is not
/// inspectable from a unit test, so the only thing a test can pin is where
/// the modifier is attached. Indentation is the honest proxy — the
/// modifiers inside the conditional are indented two levels deeper than the
/// ones on the always-present `VStack`.
final class MessageListSheetPlacementTests: XCTestCase {
    func test_stackListSheetIsNotInsideTheEmptyListBranch() throws {
        let url = try XCTUnwrap(Self.sourceURL())
        let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")

        let index = try XCTUnwrap(
            lines.firstIndex { $0.contains(".sheet(isPresented: $showStackList)") },
            "the 聚合规则 sheet modifier is gone; it must stay reachable from the toolbar"
        )
        let indent = lines[index].prefix { $0 == " " }.count
        XCTAssertEqual(
            indent, 12,
            """
            the sheet is attached \(indent) spaces in — i.e. inside the \
            `if !messages.isEmpty` branch, where an empty list makes the \
            toolbar button do nothing.
            """
        )
    }

    /// The two sheets that only rows can raise stay on the list. Moving
    /// them is churn, not a fix, and this keeps that decision recorded.
    func test_rowOnlySheetsStayOnTheList() throws {
        let url = try XCTUnwrap(Self.sourceURL())
        let source = try String(contentsOf: url, encoding: .utf8)

        for modifier in [".sheet(item: $senderFocus)", ".sheet(item: $stackEditor)"] {
            let index = try XCTUnwrap(
                source.range(of: modifier),
                "\(modifier) disappeared"
            )
            let line = source[source.startIndex..<index.lowerBound]
                .components(separatedBy: "\n").last ?? ""
            XCTAssertEqual(
                line.prefix { $0 == " " }.count, 20,
                "\(modifier) moved off the list; its setters are row actions"
            )
        }
    }

    private static func sourceURL() -> URL? {
        // .../Tests/LagoonTests/<file>.swift → .../Sources/Lagoon/Views/<file>
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LagoonTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Sources/Lagoon/Views/MessageListView.swift")
    }
}

/// F25: a local mutation of the list that forgets to retire the in-flight
/// poll is invisible until a row reappears in front of the user. Swift
/// cannot stop a view from writing `messages` directly, so this pins the
/// convention where it is checkable — same rationale as the sheet-placement
/// test above: no UI-test target exists, and the defect is a property of
/// the view's source, not of a rendered outcome.
///
/// **Why the matcher is anchored to the array, not to a shape.** This used to
/// match one spelling — `line.contains(".removeAll {")` — and every other
/// spelling of the same bug sailed under it. 清空废纸篓 (`emptyTrashNow`) wrote
/// `messages.removeAll()`, the empty-argument form, so an *irreversible*
/// delete of the whole trash shipped unguarded and the guard stayed green:
/// the classic failure of pinning a syntactic shape instead of the thing the
/// shape stands for. So the subject is now read off the view's own
/// `@State private var <name>: [` declaration, and every way of changing that
/// array's membership counts. Renaming `messages` to something else can no
/// longer silently blind the guard; the rename takes the guard with it.
///
/// **Why membership and not every write.** Two shapes are deliberately *not*
/// matched, and the line between them is the severity of the regression, not
/// convenience:
///
/// * `messages = resp.messages` inside `refresh()` is the poll's own commit.
///   It is the one write that must **not** invalidate — it is guarded by
///   `guard generation == refreshGate.generation` on the line above instead.
///   Matching it would make the test unsatisfiable.
/// * `messages[index] = …` rewrites a row's *content* (read dot, pin). A stale
///   poll that overwrites one makes a dot flicker and the next poll fixes it;
///   a stale poll that overwrites *membership* makes mail the user filed come
///   back, or mail they deleted reappear, which is the failure this gate
///   exists to prevent. Content writes are also already retired at every call
///   site in `MessageListView` (`setRead`, `toggleRead`, `togglePin`), so
///   there is nothing there for the guard to catch.
///
/// **What this does not prove.** The walk-back stops at the first line that
/// looks like a function declaration, so a removal inside a helper *called
/// from* an already-invalidating method is attributed to that method and its
/// `invalidate()` masks the violation — `applyPin` and `dropItem` are both
/// like this and both are genuinely safe. It is a net for the ordinary shape,
/// not a proof. The durable fix is a UI test target that archives a row while
/// a poll is in flight, which does not exist.
final class ListMutationRetiresRefreshTests: XCTestCase {
    func test_everyDirectListMutationIsPrecededByAnInvalidate() throws {
        for view in ["MessageListView", "BriefingFeedView"] {
            let source = try String(
                contentsOf: try XCTUnwrap(Self.sourceURL(view)),
                encoding: .utf8
            )
            let guarded = ListMutationScanner.guardedArrays(in: source)
            XCTAssertFalse(
                guarded.isEmpty,
                """
                \(view) declares no `@State` array. If the list was renamed or \
                retyped, this guard is now matching nothing and reporting \
                success over a file it no longer understands.
                """
            )

            let lines = source.components(separatedBy: "\n")
            var unguarded: [String] = []
            for hit in ListMutationScanner.membershipMutations(in: source, arrays: guarded) {
                // Walk back to the start of the enclosing method and look for
                // the retire call anywhere inside it: the gap between the two
                // can be a whole `await` and an animation block, and the call
                // is written *before* the mutation everywhere in these files
                // (`deleteAllMatching` says so explicitly).
                // `hit.line` is already the mutation's own index, so the walk
                // starts at the line above it — skipping that line would miss
                // the adjacent `invalidatePendingRefresh()` that every call
                // site in these two files puts *directly* above the write.
                var cursor = hit.line - 1
                var context = ""
                while cursor >= 0 {
                    if ListMutationScanner.startsAFuncDeclaration(lines[cursor]) { break }
                    context = lines[cursor] + "\n" + context
                    cursor -= 1
                }
                guard !context.contains("invalidatePendingRefresh()"),
                      !context.contains("refreshGate.invalidate()") else { continue }
                unguarded.append("line \(hit.line + 1): \(hit.text)")
            }
            XCTAssertEqual(
                unguarded, [],
                """
                \(view) changes which rows are in the list without retiring the \
                in-flight poll. A poll that captured the list before this \
                mutation writes its snapshot straight back, so rows the user \
                filed or deleted come back — and for 清空废纸篓 that is mail \
                the server has already destroyed, which cannot be undone.
                """
            )
        }
    }

    /// The guard above is only as good as its matcher, and the matcher is
    /// ordinary string matching — it can go blind without failing anything,
    /// which is precisely how `emptyTrashNow` shipped. So the matcher is
    /// itself pinned, against synthetic sources, on every shape it claims to
    /// cover. If a future edit narrows it, this goes red instead of the guard
    /// quietly reporting success over a hole.
    func test_theMatcherSeesEveryShapeItClaimsTo() throws {
        let list = "@State private var messages: [MessageHeader] = []"
        func caught(_ code: String) throws -> Bool {
            let source = ([list] + code.components(separatedBy: "\n"))
                .joined(separator: "\n")
            return !ListMutationScanner
                .membershipMutations(in: source, arrays: ["messages"])
                .isEmpty
        }

        // Every membership write the rule claims. `.removeAll()` — the shape
        // that shipped the bug — comes first precisely because it is the one
        // the old `".removeAll {"` matcher could not see, and `keepingCapacity:`
        // is here because it is the same call spelled a third way.
        XCTAssertTrue(try caught("messages.removeAll()"))
        XCTAssertTrue(try caught("messages.removeAll { $0.isRead }"))
        XCTAssertTrue(try caught("messages.removeAll(keepingCapacity: true) { $0.isRead }"))
        XCTAssertTrue(try caught("messages.insert(m, at: 0)"))
        XCTAssertTrue(try caught("messages.append(m)"))
        XCTAssertTrue(try caught("messages.remove(at: 0)"))
        XCTAssertTrue(try caught("messages.removeFirst()"))
        XCTAssertTrue(try caught("messages.removeLast()"))

        // And the things that must stay out of the net. A guard that fires on
        // these gets switched off by whoever it annoys first, which is a worse
        // outcome than never having written it.
        XCTAssertFalse(try caught("messages = resp.messages"), "the poll's own commit")
        XCTAssertFalse(try caught("messages[index] = m.withRead(true)"), "content, not membership")
        XCTAssertFalse(try caught("selection.removeAll()"), "a different array")
        XCTAssertFalse(try caught("expandedThreads.remove(threadId)"), "a Set, not the list")
        XCTAssertFalse(try caught("var ordered: [String] = []"), "a local, not the list")
        // Prose mentioning a mutation is not a mutation — this one is a real
        // comment in `BriefingFeedView`, and matching it would have been a
        // false positive on the very first run.
        XCTAssertFalse(try caught("// around the `items.removeAll` the transition"))
    }

    /// The callbacks the detail view raises for archive / delete must not
    /// hand-roll the removal. Asserting that `onArchived:` and a `dropRow`
    /// helper both *exist* proved nothing — the closure could inline
    /// `messages.removeAll { … }` while a never-called helper sat elsewhere —
    /// so this checked the closure body, and that was also wrong:
    /// `BriefingFeedView` routes through `handleArchived(…)` before reaching
    /// `dropItem(…)`, which is better code, and the check failed it.
    /// Making it pass meant teaching the test to follow one level of call
    /// indirection, at which point it is a Swift parser wearing a test's
    /// clothes. The invariant it was after is already covered by
    /// `test_everyDirectListMutationIsPrecededByAnInvalidate`, which fails on
    /// the actual defect — a removal with no `invalidate()` above it.
    /// Re-add a check here only once there is a UI-test target to back it.

    private static func sourceURL(_ view: String) -> URL? {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Lagoon/Views/\(view).swift")
    }
}

/// The string matching behind `ListMutationRetiresRefreshTests`, split out so
/// it can be tested directly — a guard that can go blind without turning red
/// is the whole failure mode this file exists to prevent, so the matcher gets
/// its own test rather than being trusted implicitly.
enum ListMutationScanner {
    struct Hit {
        /// Zero-based index into the source's lines, for reporting.
        let line: Int
        let text: String
    }

    /// The list arrays a view owns: the ones declared as `@State … : [`.
    ///
    /// Read off the declaration rather than hardcoded, so renaming the list
    /// cannot leave the guard matching a string that no longer exists —
    /// which is exactly how the original `.removeAll {` matcher went blind.
    /// Dictionaries (`[String: AdviceRecord]`) are excluded: they are lookup
    /// tables, not ordered rows, and a `removeValue(forKey:)` on one has no
    /// list position to resurrect.
    static func guardedArrays(in source: String) -> [String] {
        let pattern = #"@State\s+(?:private\s+)?var\s+(\w+):\s*\[([^\]]*)\]"#
        var names: [String] = []
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let full = NSRange(source.startIndex..., in: source)
        for match in regex.matches(in: source, range: full) {
            guard let nameRange = Range(match.range(at: 1), in: source),
                  let typeRange = Range(match.range(at: 2), in: source)
            else { continue }
            // `var ids: [String: AdviceRecord]` — a dictionary is a lookup
            // table, not an ordered list of rows, so it has no membership to
            // resurrect and must not be treated as one.
            if source[typeRange].contains(":") { continue }
            names.append(String(source[nameRange]))
        }
        return names
    }

    /// Every line that adds to, removes from, or reorders the guarded arrays.
    ///
    /// Anchored on the array name so the set-based state next to the list
    /// (`selection`, `expandedThreads`, `collapsedGroups`) can never match —
    /// they mutate constantly and none of them has rows to resurrect.
    static func membershipMutations(in source: String, arrays: [String]) -> [Hit] {
        let lines = source.components(separatedBy: "\n")
        var hits: [Hit] = []
        for (offset, line) in lines.enumerated() {
            let code = code(in: line)
            guard arrays.contains(where: { mutatesMembership(of: $0, in: code) }) else { continue }
            hits.append(Hit(line: offset, text: code.trimmingCharacters(in: .whitespaces)))
        }
        return hits
    }

    /// Whether `line` changes which rows `array` holds.
    ///
    /// `.removeAll(` covers the empty, trailing-closure and
    /// `keepingCapacity:` spellings in one rule, which is the whole point:
    /// the bug that motivated this was a *different spelling* of a rule that
    /// already existed, so the rule has to be about the call, not its
    /// arguments.
    private static func mutatesMembership(of array: String, in line: String) -> Bool {
        let calls = [
            #"\.removeAll\s*\("#,
            #"\.removeAll\s*\{"#,
            #"\.insert\s*\("#,
            #"\.append\s*\("#,
            #"\.append\s*\(\s*contentsOf"#,
            #"\.remove\s*\(\s*at\s*:"#,
            #"\.remove\s*\(\s*where\s*:"#,
            #"\.removeFirst\s*\("#,
            #"\.removeLast\s*\("#,
            #"\.removeAll\s*\(\s*at\s*:"#,
            #"\.replaceSubrange\s*\("#,
        ]
        return calls.contains { call in
            // The lookbehind stops `messages` matching inside a longer name
            // (`staleMessages`, `messagesCache`) and stops `.messages.…` from
            // matching a *different* object's property.
            let pattern = #"(?<![\w.])"# + NSRegularExpression.escapedPattern(for: array) + call
            return line.range(of: pattern,
                        options: .regularExpression) != nil
        }
    }

    /// A line with its comment removed.
    ///
    /// Safe on these two files because neither contains a `//` inside a string
    /// literal — a URL in a `help()` string would make this eat code. The
    /// trailing-comment case matters: a mutation with an explanatory comment
    /// on the same line is still a mutation, and the old all-or-nothing
    /// `!line.contains("//")` test would have skipped it.
    private static func code(in line: String) -> String {
        guard let range = line.range(of: "//") else { return line }
        return String(line[line.startIndex..<range.lowerBound])
    }

    /// A `func` / `init` declaration at any nesting depth. The old version
    /// matched exactly four spaces of indent, so a mutation inside a nested
    /// helper was credited to its caller — which let the caller's
    /// `invalidate()` mask it.
    static func startsAFuncDeclaration(_ line: String) -> Bool {
        let indent = line.prefix { $0 == " " }.count
        guard indent >= 4 else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("func ")
            || trimmed.hasPrefix("private func ")
            || trimmed.hasPrefix("fileprivate func ")
            || trimmed.hasPrefix("static func ")
            || trimmed.hasPrefix("mutating func ")
    }
}
