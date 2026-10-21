import XCTest
import SwiftUI
import LagoonKit
@testable import Lagoon

/// P2-07 (task A): 「测试连接」 must tell the user whether the key works
/// **without** saving it, and without changing what the app is running.
///
/// ## The three properties that can each fail alone
///
/// 1. **It never writes the Keychain.** A test that went through
///    `AISettingsStore.save` would persist a key the user never confirmed —
///    testing would be saving with a different label.
/// 2. **It restores the stored configuration.** The reload route has a side
///    effect: it makes the sent environment live. A test that did not put
///    the old values back would quietly reconfigure the app, and a user who
///    tested a typo'd key and cancelled the sheet would find the AI off.
/// 3. **It says which kind of failure it was.** An empty key, a request that
///    did not complete, and a server that took the settings and still could
///    not use them have three different fixes. One 「失败」 would make the
///    user guess which.
///
/// ## Why source-level for the view, behavioural for the store
///
/// A SwiftUI button's state is not reachable without a running app. The
/// *store* side is a pure function (`testEnvironment`) and is asserted
/// behaviourally: what map a test sends, and that the budget field is not
/// allowed to make it fail.
final class AITestConnectionWiringTests: XCTestCase {
    private func sheetSource() throws -> String {
        try ViewSource.read("AISettingsSheet")
    }

    // MARK: - Testing is not saving

    /// The test path must not call the saving path.
    ///
    /// `AISettingsStore.save(...)` is the only thing that writes the
    /// Keychain, so its absence from `testConnection()` is the property.
    /// The scan runs from the method's opening brace to the next method
    /// declaration, so a `save(...)` added anywhere inside is caught.
    func test_theTestPathNeverWritesTheKeychain() throws {
        let source = try sheetSource()
        let body = try XCTUnwrap(
            methodBody(named: "private func testConnection() async", in: source),
            "the sheet must have a testConnection method"
        )
        XCTAssertFalse(
            body.contains("AISettingsStore.save("),
            "a test must not write the Keychain — that is Save's job"
        )
        XCTAssertFalse(
            body.contains("KeychainStore"),
            "a test must not reach the Keychain directly either"
        )
    }

    /// The test must send the form's values through a merge that does not
    /// persist — not a re-read of the Keychain.
    func test_theTestSendsTheFormsValues() throws {
        let source = try sheetSource()
        XCTAssertTrue(
            source.contains("AISettingsStore.testEnvironment("),
            "the test must build its environment through the non-persisting merge"
        )
        let body = try XCTUnwrap(
            methodBody(named: "private func testConnection() async", in: source)
        )
        XCTAssertTrue(
            body.contains("environment: candidate"),
            "the test must send the candidate map it built from the form"
        )
    }

    // MARK: - The configuration is put back

    /// The stored configuration must be reloaded after the test.
    ///
    /// This is the whole reason the test is safe to press: the reload route
    /// applies what it is sent, so a test that did not restore would leave
    /// unsaved settings live.
    func test_theStoredConfigurationIsRestored() throws {
        let source = try sheetSource()
        let body = try XCTUnwrap(
            methodBody(named: "private func testConnection() async", in: source),
            "the sheet must have a testConnection method"
        )
        XCTAssertTrue(
            body.contains("restore(stored: stored)"),
            "the test must put the stored configuration back"
        )
        // …and on the **success** path specifically, not only in the error
        // branch. Measured, not assumed: the first version of this test
        // passed against a build where the success path's restore call had
        // been deleted, because the catch block's own restore satisfied a
        // plain `contains`. The guard has to name the branch.
        let verdictAt = try XCTUnwrap(
            body.range(of: "let final = TestResult.from(tested)"),
            "the success path must compute its verdict after the restore"
        )
        let afterVerdict = String(body[verdictAt.lowerBound...])
        XCTAssertTrue(
            afterVerdict.contains("guard await restore(stored: stored)"),
            "a successful test must still restore — testing is not saving"
        )
        let restoreAt = try XCTUnwrap(afterVerdict.range(of: "guard await restore(stored: stored)"))
        let assignVerdict = try XCTUnwrap(
            afterVerdict.range(of: "testResult = final"),
            "the verdict must be assigned after the restore"
        )
        XCTAssertLessThan(
            restoreAt.lowerBound, assignVerdict.lowerBound,
            "the verdict must not be shown before the old configuration is back"
        )
        // The restore must use the map read *before* the test ran, not a
        // second read after it — the second read could observe something
        // else and restore the wrong thing.
        XCTAssertTrue(
            body.contains("stored = try AISettingsStore.load()"),
            "the previous configuration must be captured before the test reload"
        )
        let loadAt = try XCTUnwrap(body.range(of: "AISettingsStore.load()"))
        let firstReloadAt = try XCTUnwrap(body.range(of: "api.reloadAI(environment: candidate)"))
        XCTAssertLessThan(
            loadAt.lowerBound, firstReloadAt.lowerBound,
            "the old configuration must be read before the test changes anything"
        )
    }

    /// A failed restore must say so. It is the one outcome the user has to
    /// act on: the service may be running settings that were never saved.
    func test_aFailedRestoreIsReported() throws {
        let source = try sheetSource()
        let body = try XCTUnwrap(
            methodBody(named: "private func restore(stored:", in: source),
            "the sheet must have a restore method"
        )
        XCTAssertTrue(body.contains("catch"), "the restore must handle a failed reload")
        XCTAssertTrue(
            source.contains("l10n.aiTestRestoreFailed"),
            "a restore that could not run must reach the user as its own failure"
        )
    }

    // MARK: - The three states

    /// Idle / testing / result: the button must have a spinner and be
    /// disabled while the test is in flight, or two presses race two
    /// reloads over one gateway.
    func test_theButtonShowsProgressAndIsDisabledWhileTesting() throws {
        let source = try sheetSource()
        let body = try XCTUnwrap(
            methodBody(named: "private func testConnection() async", in: source)
        )
        XCTAssertTrue(
            body.contains("isTesting = true"),
            "the test must mark itself in flight"
        )
        XCTAssertTrue(
            source.contains("if isTesting { ProgressView().controlSize(.small) }"),
            "the button must show a spinner while the test runs"
        )
        XCTAssertTrue(
            source.contains(".disabled(isTesting || isSaving)"),
            "the test button must be disabled while a test or a save is in flight"
        )
    }

    /// Success and failure must be drawn in different colours from the one
    /// severity scale, and carry an icon — colour alone is not the carrier.
    func test_theResultUsesTheSeverityScaleAndAnIcon() throws {
        let source = try sheetSource()
        let body = try XCTUnwrap(
            methodBody(named: "private func testResultRow(", in: source),
            "the sheet must render the result"
        )
        XCTAssertTrue(
            body.contains("LagoonTheme.Severity.success.color"),
            "a success must use the theme's success colour"
        )
        XCTAssertTrue(
            body.contains("LagoonTheme.Severity.error.color"),
            "a failure must use the theme's error colour"
        )
        XCTAssertTrue(
            body.contains(".icon"),
            "the result must carry an icon too, so it survives colour blindness"
        )
    }

    /// The three failure causes must be three distinct results, and the
    /// empty-key one must be decided without a request.
    func test_theThreeFailureCausesAreDistinct() throws {
        let source = try sheetSource()
        XCTAssertTrue(source.contains("case emptyKey"), "an empty key is its own outcome")
        XCTAssertTrue(source.contains("case requestFailed(String)"), "a failed request is its own outcome")
        XCTAssertTrue(source.contains("case notConfigured"), "an unconfigured server is its own outcome")
        let body = try XCTUnwrap(
            methodBody(named: "private func testConnection() async", in: source)
        )
        // The guard must come before any request: an empty key answered by
        // the server would be a round trip that can only say "no".
        let guardAt = try XCTUnwrap(
            body.range(of: "testResult = .emptyKey"),
            "the empty-key case must be handled"
        )
        let firstReloadAt = try XCTUnwrap(body.range(of: "api.reloadAI("))
        XCTAssertLessThan(
            guardAt.lowerBound, firstReloadAt.lowerBound,
            "an empty key must be rejected on the client, before any request"
        )
    }

    /// The test must not report success for a status that says the AI is
    /// unconfigured. This is the mapping that decides what the user is told.
    func test_anUnconfiguredStatusIsReportedAsNotConfigured() {
        XCTAssertEqual(
            AISettingsSheet.TestResult.from(
                AIStatus(configured: true, creditExhausted: false, circuitOpen: false)
            ),
            .succeeded
        )
        XCTAssertEqual(
            AISettingsSheet.TestResult.from(
                AIStatus(configured: false, creditExhausted: false, circuitOpen: false)
            ),
            .notConfigured,
            "a server that took the settings and still cannot use them is not a success"
        )
    }

    // MARK: - The copy does not claim the test saves

    /// The success line must say the settings are not live yet.
    ///
    /// The test restores the old configuration, so 「连接成功」 alone would
    /// be read as "saved and working" — and the user would close the sheet
    /// and find the old key still in place.
    func test_theSuccessCopyDoesNotClaimTheSettingsWereSaved() {
        let zh = L10n(language: .zhHans)
        XCTAssertTrue(
            zh.aiTestSucceeded.contains("保存"),
            "the success line must tell the user to press Save: \(zh.aiTestSucceeded)"
        )
    }

    // MARK: - The map a test sends

    /// The form's values are laid over the stored map, and the budget field
    /// is not sent: a test asks whether the key/endpoint/model work.
    func test_theTestEnvironmentUsesTheFormAndKeepsTheStoredBudget() {
        let stored = [
            AIEnvironmentKeys.baseURL: "https://old.invalid/v1",
            AIEnvironmentKeys.model: "old-model",
            AIEnvironmentKeys.budget: "5",
            "LAGOON_PROVIDER_CONFIG": "/bundled/providers.json",
        ]
        let out = AISettingsStore.testEnvironment(
            stored: stored,
            apiKey: "sk-new",
            baseURL: "https://new.invalid/v1",
            model: "new-model"
        )
        XCTAssertEqual(out[AIEnvironmentKeys.apiKey], "sk-new")
        XCTAssertEqual(out[AIEnvironmentKeys.baseURL], "https://new.invalid/v1")
        XCTAssertEqual(out[AIEnvironmentKeys.model], "new-model")
        XCTAssertEqual(
            out[AIEnvironmentKeys.budget], "5",
            "the cap has no bearing on whether the key works; the stored one must be kept"
        )
        XCTAssertEqual(
            out["LAGOON_PROVIDER_CONFIG"], "/bundled/providers.json",
            "unrelated keys must survive, exactly as Save preserves them"
        )
    }

    /// Blanking the key in the form is what the test sends, so the AI can be
    /// checked as "off" — the merge's existing contract.
    func test_theTestEnvironmentClearsAKeyTheUserBlanked() {
        let out = AISettingsStore.testEnvironment(
            stored: [AIEnvironmentKeys.apiKey: "sk-old"],
            apiKey: "   ",
            baseURL: "",
            model: ""
        )
        XCTAssertNil(
            out[AIEnvironmentKeys.apiKey],
            "a blanked key must be absent from the map, not the old value"
        )
    }

    /// The base-URL rule is shared with Save, so the two cannot disagree.
    func test_theTestEnvironmentBaseURLRuleMatchesSave() {
        XCTAssertThrowsError(
            try AISettingsStore.validateBaseURL("http://insecure.invalid"),
            "an http base URL must be rejected by the test path too"
        )
        XCTAssertNoThrow(try AISettingsStore.validateBaseURL(""))
        XCTAssertNoThrow(try AISettingsStore.validateBaseURL("https://ok.invalid/v1"))
    }

    // MARK: - Helper

    /// The source of one method, from its declaration to the next member
    /// declaration at the same indentation.
    ///
    /// The brace walker the rest of the suite uses does not know about
    /// method boundaries, and a fixed `limit:` is in *characters* — which
    /// is how a guard ends up scanning three unrelated methods and passing
    /// for the wrong reason.
    private func methodBody(named needle: String, in source: String) -> String? {
        guard let start = source.range(of: needle) else { return nil }
        let rest = source[start.lowerBound...]
        // A member at 4-space indentation begins with "\n    " followed by
        // a declaration keyword. The method's own body is indented deeper.
        let terminators = ["\n    private func ", "\n    private var ", "\n    @ViewBuilder", "\n}\n"]
        var end = rest.endIndex
        for terminator in terminators {
            if let found = rest.range(of: terminator), found.lowerBound > start.lowerBound {
                end = min(end, found.lowerBound)
            }
        }
        return String(source[start.lowerBound..<end])
    }
}
