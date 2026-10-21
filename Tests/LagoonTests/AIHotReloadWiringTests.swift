import XCTest
import SwiftUI
import LagoonKit
@testable import Lagoon

/// P1-01: the AI key must take effect **when it is saved**, not after a
/// restart.
///
/// ## What was wrong
///
/// The settings sheet wrote the key to the Keychain and then said
/// "已保存，重启 App 后生效" — saved, restart the app to apply. The
/// user had to quit and reopen the mail app to use the feature the app
/// had just told them about.
///
/// The cause was architectural, not a requirement: the server built its
/// `AIGateway` once at launch and the routes captured that instance in a
/// `let`. A key is a credential; changing one does not require rebuilding
/// the process.
///
/// ## What these tests pin
///
/// The fix spans three layers — the sheet, the API client, and the
/// server route — and each layer can fail in a way the others cannot
/// see:
///
/// * the sheet saves but never calls the reload route (the old
///   behaviour, spelled differently);
/// * the copy still promises a restart, or claims "applied" without
///   having applied anything;
/// * the API client posts to a route the server does not have.
///
/// A green build proves none of that. These tests do.
final class AIHotReloadWiringTests: XCTestCase {
    private func sheetSource() throws -> String {
        try ViewSource.read("AISettingsSheet")
    }

    private func apiClientSource() throws -> String {
        try String(
            contentsOf: ViewSource.url(under: "Services", "APIClient"),
            encoding: .utf8
        )
    }

    private func l10nSource() throws -> String {
        try String(
            contentsOf: ViewSource.url(under: "Localization", "L10n"),
            encoding: .utf8
        )
    }

    // MARK: - The sheet must actually apply the key

    /// The sheet must call the reload route after storing the key.
    ///
    /// Without this call the key sits in the Keychain and nothing else
    /// happens — the exact behaviour the old product shipped, and the
    /// one that made the user restart.
    func test_theSheetReloadsTheServerAfterSaving() throws {
        let source = try sheetSource()
        XCTAssertTrue(
            source.contains("reloadAI"),
            "the settings sheet must reload the AI after saving, or the key stays inert"
        )
        XCTAssertTrue(
            source.contains("api.reloadAI(environment:"),
            "the reload must send the stored environment, not a re-derivation of it"
        )
    }

    /// The reload must happen **after** the Keychain write, not before.
    ///
    /// The other order would tell the server to use a key that is not
    /// stored yet — and if the write then failed, the running server
    /// would hold a key the app never saved.
    ///
    /// Scoped to `save()` on purpose. The sheet also reloads from
    /// 「测试连接」, which deliberately runs *before* any write (testing is
    /// not saving), and a file-wide "first match" search would compare
    /// against that call instead — passing or failing for reasons that have
    /// nothing to do with the save ordering this test is about.
    func test_theReloadHappensAfterTheKeychainWrite() throws {
        let body = try saveBody()
        let saveCall = try XCTUnwrap(
            body.range(of: "AISettingsStore.save("),
            "the sheet must save through the store"
        )
        let reloadCall = try XCTUnwrap(
            body.range(of: "api.reloadAI("),
            "the sheet must reload the AI"
        )
        XCTAssertLessThan(
            saveCall.lowerBound, reloadCall.lowerBound,
            "the key must be stored before the server is told to use it"
        )
    }

    /// The body of `save()`, from its declaration to the next declaration at
    /// the same indentation.
    ///
    /// Several assertions below are about what `save()` does, and the
    /// surrounding file has other functions that call the same APIs for
    /// different reasons. Reading to the end of the function keeps each
    /// assertion about the act it names.
    private func saveBody() throws -> Substring {
        let source = try sheetSource()
        let start = try XCTUnwrap(
            source.range(of: "private func save() async"),
            "the save function must exist"
        )
        let rest = source[start.lowerBound...]
        // The next `private func` at the same level ends this one.
        if let end = rest.dropFirst().range(of: "\n    private func ") {
            return rest[..<end.lowerBound]
        }
        return rest
    }

    /// The map sent to the server must be the one that was written.
    ///
    /// `AISettingsStore.save` returns what it wrote; the sheet must send
    /// that value. Re-deriving it (loading the Keychain again) opens a
    /// window where the two disagree.
    func test_theReloadedMapIsTheOneThatWasStored() throws {
        let source = try sheetSource()
        XCTAssertTrue(
            source.contains("stored = try AISettingsStore.save("),
            "save must hand back what it wrote"
        )
        XCTAssertTrue(
            source.contains("reloadAI(environment: stored)"),
            "the reload must send exactly the stored map"
        )
    }

    // MARK: - The copy must be honest

    /// The product must not tell the user to restart the app.
    ///
    /// This is the promise the old product made, and the one thing a user
    /// remembers: "save, then quit and reopen". If any string still says
    /// it, the fix is invisible.
    func test_noCopyPromisesARestart() throws {
        let source = try sheetSource()
        XCTAssertFalse(
            source.contains("RestartHint"),
            "the restart hint must be gone — the key applies on save"
        )
        let l10n = try l10nSource()
        XCTAssertFalse(
            l10n.contains("aiSettingsRestartHint"),
            "the restart hint string must be deleted, not just unused"
        )
        // The *string* itself, not the symbol. A user reading the UI sees
        // the Chinese, so the Chinese is what must be gone.
        XCTAssertFalse(
            l10n.contains("Key 改动需要重启 App 才能生效"),
            "no localization string may promise a restart for the AI key"
        )
        XCTAssertFalse(
            l10n.contains("Key changes need an app restart"),
            "no localization string may promise a restart for the AI key"
        )
    }

    /// The confirmation must say what actually happened.
    ///
    /// "Saved" and "working" are different facts: a key can be stored and
    /// the provider still unreachable. The sheet has both strings for
    /// that reason, and the copy test asserts the second one exists.
    func test_theConfirmationDistinguishesAppliedFromStored() throws {
        let source = try sheetSource()
        XCTAssertTrue(
            source.contains("l10n.aiSettingsApplied"),
            "the sheet must confirm that the key took effect"
        )
        XCTAssertTrue(
            source.contains("l10n.aiSettingsAppliedNotConfigured"),
            "the sheet must distinguish 'applied' from 'stored but not usable'"
        )
    }

    /// A failed reload must not be reported as a successful save.
    ///
    /// The two are different events: the Keychain write succeeded, the
    /// server did not take the key. The banner says so — and says the
    /// key is safe, so the user does not re-paste it.
    func test_aFailedReloadIsReportedAsAFailure() throws {
        // Scoped to `save()`, for the same reason as the ordering test: the
        // test-connection path has its own `catch` around its own reload,
        // and a file-wide search would read that one instead.
        let body = try saveBody()
        let reloadCall = try XCTUnwrap(body.range(of: "api.reloadAI("))
        let catchBlock = try XCTUnwrap(
            body.range(of: "catch {", range: reloadCall.lowerBound..<body.endIndex),
            "the reload must be guarded"
        )
        let code = ViewSource.code(after: catchBlock.lowerBound, in: body, limit: 400)
        XCTAssertTrue(
            code.contains("aiSettingsReloadFailed"),
            "a failed reload must reach the user as a failure, not as a saved key"
        )
    }

    // MARK: - The client must talk to a route that exists

    /// The API client must post to the route the server registers.
    ///
    /// A typo in the path would make the reload a 404, and the sheet
    /// would report "the service did not accept the configuration" for
    /// every save — a confusing failure for a working feature.
    func test_theApiClientPostsToTheRouteTheServerRegisters() throws {
        let client = try apiClientSource()
        XCTAssertTrue(
            client.contains("\"api\", \"ai\", \"reload\""),
            "the client must post to api/ai/reload"
        )
        let server = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/LagoonServer/Routes/AIRoutes.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            server.contains("router.post(\"api/ai/reload\")"),
            "the server must register the route the client calls"
        )
    }

    /// The reload must be allowed to fail.
    ///
    /// A `try?` here would swallow the failure and the sheet would say
    /// "applied" while the server kept the old key — the one failure mode
    /// the user cannot see.
    ///
    /// The scan covers the whole method, not just its first lines: the
    /// swallowed error can hide in the `send` call or in the decode, and
    /// both are just as silent.
    func test_theReloadIsNotSilentlyDiscarded() throws {
        let client = try apiClientSource()
        let method = try XCTUnwrap(
            client.range(of: "public func reloadAI("),
            "the client must expose a reloadAI method"
        )
        // The method body, not a fixed number of lines: the swallowed
        // error can hide in the `send` call or in the decode, and both are
        // just as silent. The body ends at the closing brace of the
        // method, so the scan stops there.
        let after = client[method.upperBound...]
        let end = after.range(of: "\n    }")?.lowerBound ?? after.endIndex
        let body = String(after[..<end])
        XCTAssertFalse(
            body.contains("try?"),
            "the reload must not swallow its own failure"
        )
    }

    // MARK: - The status must reach the banners

    /// The parent must learn the new status immediately.
    ///
    /// The banner reads the status the directory holds, and that value
    /// is polled every 30 seconds. Without the hand-back, the app would
    /// tell the user "the AI is live" and then keep showing "AI 未配置"
    /// for the next half minute.
    func test_theSheetHandsTheNewStatusBackToTheParent() throws {
        let source = try sheetSource()
        XCTAssertTrue(
            source.contains("onApplied(status)"),
            "the sheet must hand the new status to its parent"
        )
        let root = try ViewSource.read("RootView")
        XCTAssertTrue(
            root.contains("onApplied: { status in directory.applyAIStatus(status) }"),
            "RootView must give the new status to the directory, which the banner reads"
        )
    }

    /// The usage panel shows the same dot, so it must learn too.
    func test_theUsagePanelAlsoLearnsTheNewStatus() throws {
        let source = try ViewSource.read("UsageSheet")
        XCTAssertTrue(
            source.contains("onApplied: { status in aiStatus = status }"),
            "the usage panel's AI dot must follow the key"
        )
    }

    // MARK: - The keys must be spelled the same everywhere

    /// The client, the server and the shared list must agree on the key
    /// names.
    ///
    /// A typo would not fail loudly: the client would write
    /// `..._APIKEY`, the server would find no key, and the product
    /// would report "AI 未配置" while the user stared at a correctly
    /// pasted key.
    func test_theKeyNamesComeFromOneSharedList() throws {
        let sheet = try sheetSource()
        XCTAssertTrue(
            sheet.contains("AIEnvironmentKeys.apiKey"),
            "the sheet must use the shared key names"
        )
        XCTAssertFalse(
            sheet.contains("\"LLM_PROVIDER_PRIMARY_API_KEY\""),
            "the key name must not be spelled out again in the sheet"
        )
        let server = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/LagoonServer/Routes/AIRoutes.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            server.contains("AIEnvironmentKeys.managed"),
            "the server must use the shared managed-key list"
        )
    }
}
