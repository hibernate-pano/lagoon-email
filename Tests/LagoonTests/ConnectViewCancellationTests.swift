import XCTest
@testable import Lagoon

/// ConnectView's sheet-lifetime rule.
///
/// Why this file exists: on 2026-10-09 a user reported that reconnecting a QQ
/// mailbox with a fresh authorization code did nothing — no error, no network
/// request, no database write. Root cause was `.onDisappear { connectTask?
/// .cancel() }`: the sheet is dismissed by the system in ordinary situations
/// (Return on the focused field, window close, parent flipping `showConnect`),
/// and every one of those killed the in-flight probe *before it was sent*.
///
/// The failure was silent by construction, which is why the whole existing
/// suite stayed green: there was no server call to assert on, no row to
/// inspect, and no error copy to read. These tests pin the decision rule so
/// the regression can only come back as a red test.
final class ConnectViewCancellationTests: XCTestCase {
    /// The bug itself, pinned at the call site — not just on the helper.
    ///
    /// The helper-function tests below lock the *decision rule*, but the
    /// 2026-10-09 bug lived in the `.onDisappear` *closure*: a mutant that
    /// hard-codes the call-site arguments (or deletes the guard) changes no
    /// helper behaviour, so helper-only tests stay green — a false green we
    /// caught during mutation probing of this very file. This test reads
    /// `ConnectView.swift` itself and asserts the closure still gates the
    /// cancel on the user's intent. It follows the `ViewSource` precedent of
    /// `ColumnLayoutGuardTests` / `RowChromeAndBannerTests`.
    func test_aSystemInitiatedDisappearanceDoesNotCancelTheConnect() {
        XCTAssertFalse(
            ConnectView.shouldCancelConnectOnDisappear(isDisappearing: true, userCancelled: false),
            "A sheet can vanish without the user backing out (Return on the last "
                + "field, window close, parent flipping showConnect). Cancelling "
                + "there aborted the probe before it was ever sent — the silent "
                + "no-op this rule exists to prevent."
        )
    }

    /// The intended behaviour: an explicit Cancel (or Escape) still stops the
    /// in-flight request, so backing out really does abandon the connect.
    func test_aUserInitiatedCancelStillCancelsTheConnect() {
        XCTAssertTrue(
            ConnectView.shouldCancelConnectOnDisappear(isDisappearing: true, userCancelled: true),
            "An explicit cancel must keep cancelling the probe; otherwise a "
                + "backed-out attempt could still adopt the account."
        )
    }

    /// A mutant that deletes the guard entirely (unconditional cancel in the
    /// closure — the original bug) must fail the first test; a mutant that
    /// deletes the whole `if` (never cancel — the adopted-after-dismissal
    /// bug the guard was written for) must fail the second. The `false`
    /// branch pins the quiet path: not disappearing means nothing to cancel.
    ///
    /// NOTE for anyone adding mutants here: these three helper tests cannot see
    /// a call-site-only change, and `test_theOnDisappearClosureGatesCancelOnUserIntent`
    /// cannot see the button that SETS the flag. That blind spot is real and is
    /// covered by `test_everyConnectAttemptClearsTheCancelFlagFirst`.
    func test_theRuleHasExactlyTwoOutcomes() {
        XCTAssertFalse(
            ConnectView.shouldCancelConnectOnDisappear(isDisappearing: false, userCancelled: true),
            "Not disappearing means nothing to cancel, even with a stale cancel flag."
        )
        XCTAssertFalse(
            ConnectView.shouldCancelConnectOnDisappear(isDisappearing: false, userCancelled: false),
            "The quiet path: nothing happening, nothing to do."
        )
    }

    /// The call-site test. Scans the actual `.onDisappear` closure in
    /// `ConnectView.swift` and requires the cancel to be gated on a
    /// user-intent flag. Any of these mutants fails here:
    /// `.onDisappear { connectTask?.cancel() }` (the original bug),
    /// `.onDisappear { if true { connectTask?.cancel() } }`,
    /// `.onDisappear { if isConnecting { ... } }` (wrong flag).
    func test_theOnDisappearClosureGatesCancelOnUserIntent() throws {
        let source = try ViewSource.read("ConnectView")
        let block = Self.onDisappearBlock(in: source)
        XCTAssertNotNil(block, "ConnectView must keep an .onDisappear handler "
            + "that owns the in-flight connect task; deleting the handler "
            + "re-opens the adopt-after-dismissal bug it was written for.")
        guard let block else { return }
        XCTAssertTrue(
            block.contains("userCancelled"),
            "The .onDisappear cancel must be gated on the user's intent flag. "
                + "An unconditional `connectTask?.cancel()` here silently kills "
                + "the probe on every system-initiated dismissal (2026-10-09)."
        )
        XCTAssertFalse(
            block.contains("if true"),
            "A hard-coded `if true` around the cancel is the original bug in disguise."
        )
        XCTAssertFalse(
            block.contains("!userCancelled"),
            "Inverting the flag would cancel exactly when the user did NOT ask to "
                + "stop — the same silent no-op from the other direction."
        )
        XCTAssertTrue(
            block.contains("userCancelled: userCancelled"),
            "The handler must pass the user's intent through unchanged. Any other "
                + "expression here (a literal, a negation, a different flag) changes "
                + "when the probe dies, and only this call-site assertion sees it."
        )
    }

    /// Every attempt must clear the flag it shares with Cancel.
    ///
    /// Mutation-probed: deleting the `userCancelled = false` line in front of
    /// `connectTask = Task { await connectQQ() }` left ALL the tests above
    /// green, because the decision rule and the `.onDisappear` closure are both
    /// still intact. But the flag is `@State` on a view that, in its
    /// non-sheet form (`LagoonApp.swift:32`, the onboarding WindowGroup with no
    /// account yet), is never dismissed. So after one Cancel the flag stays
    /// `true` forever: the next attempt sets a new task, the sheet-free view
    /// does not disappear, `connectQQ` runs, and `Task.isCancelled` is false
    /// because the NEW task was never cancelled — while the stale flag makes
    /// `.onDisappear` refuse to cancel it. The user's second "connect" then
    /// adopts the account even after they back out, which is the exact
    /// adopt-after-dismissal bug the guard was written to prevent, re-entering
    /// from the other door.
    ///
    /// Asserted against the source (the `ViewSource` precedent) because the
    /// pairing lives in a button closure and cannot be reached from a unit test.
    func test_everyConnectAttemptClearsTheCancelFlagFirst() throws {
        let lines = try ViewSource.read("ConnectView").components(separatedBy: "\n")
        var sites: [(line: Int, preceding: String)] = []
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Only the real task creations. The `@State` declaration and the
            // prose that documents this very flag are not attempts.
            guard trimmed.hasPrefix("connectTask = Task") else { continue }
            sites.append((index + 1, index > 0 ? lines[index - 1].trimmingCharacters(in: .whitespaces) : ""))
        }
        XCTAssertFalse(sites.isEmpty, "expected ConnectView to start its connect task somewhere")
        for site in sites {
            XCTAssertEqual(
                site.preceding, "userCancelled = false",
                "Every place that starts a connect attempt must reset the cancel flag "
                    + "first (line \(site.line)). Without it a stale `true` from an "
                    + "earlier Cancel survives into the next attempt and disarms "
                    + ".onDisappear for it."
            )
        }
    }

    /// Extracts the `.onDisappear { ... }` closure body from the view source
    /// by brace matching. Returns nil when no such handler exists.
    ///
    /// Only a *line-leading* `.onDisappear` counts. The view documents this
    /// handler in prose (behind `///`) above the property list, and an earlier
    /// version of this extractor anchored on that comment — so it read the
    /// documentation instead of the code and failed on the *fixed* source
    /// (caught by mutation probing, which is exactly what it is for).
    private static func onDisappearBlock(in source: String) -> String? {
        var searchStart = source.startIndex
        while let hit = source.range(of: ".onDisappear", range: searchStart..<source.endIndex) {
            let lineStart = source[source.startIndex..<hit.lowerBound].lastIndex(of: "\n")
                .map { source.index(after: $0) } ?? source.startIndex
            let indent = source[lineStart..<hit.lowerBound]
            let isCallSite = indent.allSatisfy { $0 == " " || $0 == "\t" }
            if isCallSite, let body = braceBody(in: source, from: hit.upperBound) {
                return body
            }
            searchStart = hit.upperBound
        }
        return nil
    }

    /// Brace-matches the first `{ ... }` at or after `start`.
    private static func braceBody(in source: String, from start: String.Index) -> String? {
        guard let open = source[start...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var cursor = open
        while cursor < source.endIndex {
            let ch = source[cursor]
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 {
                    return String(source[source.index(after: open)..<cursor])
                }
            }
            cursor = source.index(after: cursor)
        }
        return nil
    }
}
