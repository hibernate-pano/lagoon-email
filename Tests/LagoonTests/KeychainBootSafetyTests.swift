import XCTest
import Foundation
@testable import Lagoon

/// The app must survive a blocked Keychain.
///
/// ## What the defect was
///
/// On a rebuild the app hung forever on 「服务器启动中」 with no window. The
/// bundle is ad-hoc signed, so each build mints a new cdhash; the stored
/// Keychain items were bound to the *old* cdhash; macOS wanted the user to
/// confirm the read; and the confirmation is raised by a background
/// `SecurityAgent` that has no window. `SecItemCopyMatching` parked a
/// thread in `mach_msg2_trap` and never came back.
///
/// `bootstrap()` awaited that read before binding the port, so the whole
/// app was gated on a call that could never return.
///
/// ## Why these are source-level guards
///
/// The behaviour to pin is "a blocking call is not on the critical path",
/// and the machine that reported the bug has a Keychain that *is* blocked
/// right now — a test that exercised the real store would hang here too.
/// So the ordering is pinned in the source, and the parts that can be
/// pure functions (the migration plan, the copy-verification rule) are
/// tested directly as values.
final class KeychainBootSafetyTests: XCTestCase {

    private func embeddedServerSource() throws -> String {
        try String(
            contentsOf: ViewSource.url(under: "Services", "EmbeddedServer"),
            encoding: .utf8
        )
    }

    // MARK: - The port is bound before the secrets are known

    /// `bootstrap()` must not await a secret read before it binds.
    ///
    /// The failure mode this pins is exact: an `await` on the Keychain
    /// between the start of `bootstrap()` and the `LagoonRuntime.start`
    /// loop. Every Keychain read in that window is a read that can park
    /// the boot forever, which is the reported hang.
    ///
    /// The reads are allowed to *start* there — they run in detached
    /// tasks — so the guard looks for a direct `await` on the reader, not
    /// for the reader's name.
    func test_bootstrapDoesNotAwaitASecretReadBeforeBindingThePort() throws {
        let source = try embeddedServerSource()
        let bootstrapStart = try XCTUnwrap(
            source.range(of: "static func bootstrap() async throws -> Int {"),
            "bootstrap() is gone or renamed"
        )
        let startLoop = try XCTUnwrap(
            source.range(of: "LagoonRuntime.start("),
            "bootstrap() no longer starts the runtime"
        )
        let beforeBinding = String(source[bootstrapStart.lowerBound..<startLoop.lowerBound])

        // Any mention at all, not just an `await`/`try` spelling. A
        // blocked `SecItemCopyMatching` does not care how the call was
        // written: `try?`, `try`, `await` and a bare call all park the
        // thread the same way. Matching the call's *name* is the only
        // version that cannot be dodged by a punctuation change.
        for forbidden in [
            "KeychainStore.",
            "KeychainReader."
        ] {
            XCTAssertFalse(
                beforeBinding.contains(forbidden),
                """
                bootstrap() awaits the Keychain before binding the port: \
                "\(forbidden)" sits before LagoonRuntime.start. If that read \
                blocks (an ad-hoc-signed rebuild, an item whose ACL no longer \
                matches), the port is never bound and the app hangs on the \
                boot screen with no window — the exact reported defect.
                """
            )
        }
    }

    /// The offline resolution must actually be off the critical path.
    ///
    /// Starting the tasks is not enough: `await secrets.value` before the
    /// bind loop would re-introduce the hang with extra steps. The guard
    /// checks that the only use of the resolved value is *after* the
    /// server has been adopted.
    func test_theResolvedSecretsAreNotAwaitedBeforeTheBind() throws {
        let source = try embeddedServerSource()
        // From the top of `bootstrap()` to the adoption, not from the bind
        // loop: awaiting the secrets *before* the loop is the same hang
        // with the await moved one line up.
        let bootstrapStart = try XCTUnwrap(
            source.range(of: "static func bootstrap() async throws -> Int {"),
            "bootstrap() is gone or renamed"
        )
        let adopt = try XCTUnwrap(
            source.range(of: "EmbeddedServerHandle.shared.adopt("),
            "bootstrap() no longer adopts the server"
        )
        let beforeAdopt = String(source[bootstrapStart.lowerBound..<adopt.lowerBound])
        XCTAssertFalse(
            beforeAdopt.contains("await secrets.value"),
            """
            bootstrap() awaits the resolved secrets before adopting the \
            server. The bind would then wait for a Keychain read that can \
            never return — the app would look identical to the reported hang.
            """
        )
    }

    /// The server must be given a placeholder key, not a resolved one.
    ///
    /// A key that has not been read yet cannot be passed. The placeholder
    /// is what lets the runtime start with a valid-shaped key and swap it
    /// later; passing `nil` is not an option because the cipher provider
    /// is non-optional, and generating a *real* key here would write a new
    /// secret over one that has not been read — orphaning every credential
    /// sealed with the old one.
    func test_theServerStartsWithAPlaceholderKeyRatherThanAnUnreadOne() throws {
        let source = try embeddedServerSource()
        // Anchor on the configuration, not the start call: the keys are
        // passed to `LagoonRuntimeConfiguration(...)` and only *used* by
        // `LagoonRuntime.start(...)`.
        let config = try XCTUnwrap(source.range(of: "LagoonRuntimeConfiguration("))
        let callSite = ViewSource.code(after: config.lowerBound, in: source, limit: 2200)
        // The symbol, spelled in fragments so a scan for the literal cannot
        // be satisfied by a comment that merely mentions it.
        let placeholder = "Placeholder" + "Secret.keyBase64"
        // The local key generator in `EmbeddedServer`, in fragments for
        // the same reason as `placeholder`.
        let generator = "random" + "KeyBase64"
        XCTAssertTrue(
            callSite.contains("usesPlaceholderKeys: true"),
            "the runtime is started without declaring that its keys are placeholders"
        )
        XCTAssertTrue(
            callSite.contains(placeholder),
            """
            the runtime is started with something other than the placeholder \
            key — a real key here would have to come from a Keychain read, \
            which is the read that hangs.
            """
        )
        XCTAssertFalse(
            callSite.contains(generator) || callSite.contains("UUID()"),
            """
            the runtime is started with a freshly generated key. That writes \
            a new secret before the stored one has been read — and a new key \
            cannot open what the old one sealed.
            """
        )
    }

    /// The server must never bind with authentication off.
    ///
    /// A nil token turns the auth middleware off (`APIAuthMiddleware` gates
    /// only when a token is set). The token used to be read from the
    /// Keychain *before* the bind, so deferring the Keychain work — this
    /// fix — silently removed the token from the bind if it was only
    /// written that way. The result would be an unauthenticated loopback
    /// server plus a client that still sends a bearer the server ignores.
    ///
    /// So the token passed to the configuration must be resolved with no
    /// Keychain call in its path: environment, then `UserDefaults`, then a
    /// generated value that is written to `UserDefaults` — the same store
    /// the client reads.
    func test_theServerBindsWithATokenResolvedWithoutTheKeychain() throws {
        let source = try embeddedServerSource()
        let bootstrapStart = try XCTUnwrap(
            source.range(of: "static func bootstrap() async throws -> Int {"),
            "bootstrap() is gone or renamed"
        )
        let bind = try XCTUnwrap(source.range(of: "LagoonRuntimeConfiguration("))
        let beforeBind = String(source[bootstrapStart.lowerBound..<bind.lowerBound])

        XCTAssertTrue(
            beforeBind.contains("UserDefaults.standard.string(forKey: \"lagoon.apiToken\")"),
            """
            the API token is not seeded from `UserDefaults`, which is what \
            the client reads. Without that seed a launch with no env var \
            passes nil and the server binds with auth off.
            """
        )
        XCTAssertTrue(
            beforeBind.contains("UserDefaults.standard.set(generated, forKey: \"lagoon.apiToken\")"),
            "a generated token is not persisted for the client to send"
        )
        let bindCall = ViewSource.code(after: bind.lowerBound, in: source, limit: 600)
        XCTAssertTrue(
            bindCall.contains("apiToken: apiToken"),
            "the configuration is not given the resolved token"
        )
    }

    /// The background token read must not change what the client sends.
    ///
    /// `resolveAllSecrets` runs *after* the bind. If it generated a token
    /// or overwrote `UserDefaults`, the server and the client would
    /// disagree and every request would 401.
    func test_theBackgroundTokenReadDoesNotReplaceTheLiveToken() throws {
        let source = try embeddedServerSource()
        let fnStart = try XCTUnwrap(
            source.range(of: "static func resolveAPIToken() async -> String? {"),
            "resolveAPIToken() is gone or renamed"
        )
        let body = ViewSource.code(after: fnStart.lowerBound, in: source, limit: 1200)
        XCTAssertFalse(
            body.contains("UUID()"),
            """
            the background token resolution generates a new token. The server \
            already bound with the token the client is sending; a new one \
            here makes them disagree.
            """
        )
        // The only write sits in the `.found` branch. A write in the
        // failure branch would seed `UserDefaults` from a read that never
        // produced a value.
        let failed = try XCTUnwrap(
            body.range(of: "case .failed, .missing:"),
            "the failure branch is gone or spelled differently"
        )
        let failureBranch = ViewSource.code(after: failed.lowerBound, in: body, limit: 300)
        XCTAssertFalse(
            failureBranch.contains("UserDefaults.standard.set("),
            "the background token resolution writes the default on a failed read"
        )
    }

    // MARK: - A failed read is never "nothing is stored"

    /// The migration must not write `{}` when the read failed.
    ///
    /// This is the data-loss bug. The old code did
    ///
    ///     if (try? KeychainStore.loadString(service: envService)) == nil {
    ///         try? KeychainStore.saveString("{}", service: envService)
    ///     }
    ///
    /// which treats "I could not read it" as "there is nothing there" and
    /// destroys the stored AI provider keys and budget cap.
    ///
    /// The guard pins the switch: the `.failed` case must return **before**
    /// any write, and the only write of the empty map must sit in the
    /// `.missing` branch.
    func test_theLegacyMigrationDoesNotWriteADefaultOnAFailedRead() throws {
        let source = try embeddedServerSource()
        let fnStart = try XCTUnwrap(
            source.range(of: "static func migrateLegacyEnvIfNeeded()"),
            "the legacy environment migration is gone"
        )
        let body = ViewSource.code(after: fnStart.lowerBound, in: source, limit: 1600)

        let failedCase = try XCTUnwrap(
            body.range(of: "case .failed:"),
            "the migration does not handle a failed read separately"
        )
        let afterFailed = ViewSource.code(after: failedCase.lowerBound, in: body, limit: 260)
        let nextCase = afterFailed.range(of: "case .missing:")
        XCTAssertNotNil(nextCase, "the .failed branch must fall through to a .missing branch")
        let failedBranch = nextCase.map { String(afterFailed[afterFailed.startIndex..<$0.lowerBound]) } ?? ""
        XCTAssertFalse(
            failedBranch.contains("saveString"),
            """
            the failed-read branch writes to the Keychain. A failed read is \
            not proof of absence: writing "{}" here destroys the stored AI \
            keys and budget cap that the read never saw.
            """
        )
        XCTAssertFalse(
            failedBranch.contains("save("),
            "the failed-read branch writes to the Keychain"
        )

        let missingCase = try XCTUnwrap(
            body.range(of: "case .missing:"),
            "the migration has no .missing branch — the empty-map write has nowhere safe to live"
        )
        let afterMissing = ViewSource.code(after: missingCase.lowerBound, in: body, limit: 700)
        XCTAssertTrue(
            afterMissing.contains("\"{}\""),
            "the empty map is not written from the .missing branch"
        )
    }

    /// `KeychainRead` must not let a failure read as absence.
    ///
    /// `isMissing` is the predicate callers use to decide whether a write is
    /// safe, so it must be false for `.failed`. If it ever became true (say,
    /// "not found or failed" — a natural-looking simplification), every
    /// call site that checks it would start overwriting unread values.
    func test_aFailureIsNotReportedAsMissing() {
        let failure = KeychainRead<Data>.failed(.authorizationRequired)
        XCTAssertFalse(failure.isMissing, "a failed read must never be reported as absence")
        XCTAssertTrue(failure.isFailure)
        XCTAssertNil(failure.value)

        let missing = KeychainRead<Data>.missing
        XCTAssertTrue(missing.isMissing)
        XCTAssertFalse(missing.isFailure)

        XCTAssertEqual(
            KeychainRead<Data>.found(Data([1, 2, 3])).value,
            Data([1, 2, 3])
        )
    }

    /// Only a real absence licenses writing a default.
    ///
    /// `mayWriteDefault` is the single gate the migration consults. It must
    /// be true for exactly one plan.
    func test_onlyAProvenAbsenceAllowsWritingADefault() {
        XCTAssertTrue(KeychainMigrationPlan.nothingToMigrate.mayWriteDefault)
        XCTAssertFalse(KeychainMigrationPlan.move.mayWriteDefault)
        XCTAssertFalse(KeychainMigrationPlan.alreadyPresent.mayWriteDefault)
        XCTAssertFalse(
            KeychainMigrationPlan.sourceUnreadable.mayWriteDefault,
            "an unreadable source is not an absence, and must not license a default write"
        )
    }

    // MARK: - The old → new move is copy, then verify, then delete

    /// A failed read of the source is never "nothing to migrate".
    func test_anUnreadableSourceIsNotTreatedAsAnAbsence() {
        let plan = keychainMigrationPlan(
            destination: .missing,
            source: .failed(.authorizationRequired)
        )
        XCTAssertEqual(plan, .sourceUnreadable)
        XCTAssertFalse(plan.mayWriteDefault)
    }

    /// A failed read of the destination blocks the move.
    ///
    /// If the destination cannot be read, this code cannot know the value
    /// is absent there. Copying on that assumption would overwrite a value
    /// it never saw — and then delete the old copy.
    func test_anUnreadableDestinationIsNotTreatedAsAnAbsence() {
        let plan = keychainMigrationPlan(
            destination: .failed(.authorizationRequired),
            source: .found(Data("secret".utf8))
        )
        XCTAssertEqual(plan, .sourceUnreadable)
        XCTAssertFalse(plan.mayWriteDefault)
    }

    func test_aValueInBothLocationsNeedsNoMove() {
        let plan = keychainMigrationPlan(
            destination: .found(Data("new".utf8)),
            source: .found(Data("old".utf8))
        )
        XCTAssertEqual(plan, .alreadyPresent)
        XCTAssertFalse(plan.mayWriteDefault)
    }

    func test_aValueOnlyInTheOldLocationIsMoved() {
        let plan = keychainMigrationPlan(
            destination: .missing,
            source: .found(Data("secret".utf8))
        )
        XCTAssertEqual(plan, .move)
        XCTAssertFalse(plan.mayWriteDefault)
    }

    func test_nothingAnywhereIsTheOnlyCaseThatMayWriteADefault() {
        let plan = keychainMigrationPlan(destination: .missing, source: .missing)
        XCTAssertEqual(plan, .nothingToMigrate)
        XCTAssertTrue(plan.mayWriteDefault)
    }

    /// A copy counts as landed only when the destination reads back the
    /// **same bytes**.
    ///
    /// This is the gate in front of the delete. Every other answer — a
    /// different value, no item, an unreadable item — leaves the old copy
    /// in place.
    func test_aCopyIsOnlyVerifiedWhenTheDestinationReadsBackTheSameBytes() {
        let secret = Data("the-only-copy".utf8)

        XCTAssertTrue(
            keychainCopyIsVerified(source: secret, readBack: .found(secret)),
            "the same bytes must verify"
        )
        XCTAssertFalse(
            keychainCopyIsVerified(source: secret, readBack: .found(Data("something-else".utf8))),
            "a different value in the destination is a failed copy, not a verified one"
        )
        XCTAssertFalse(
            keychainCopyIsVerified(source: secret, readBack: .missing),
            "no item in the destination is a failed copy"
        )
        XCTAssertFalse(
            keychainCopyIsVerified(source: secret, readBack: .failed(.authorizationRequired)),
            "an unreadable destination is a failed copy"
        )
    }

    /// The migration must verify before it deletes, and the delete must be
    /// the last of the three steps.
    ///
    /// The ordering is the safety property, and it lives in statement
    /// order, which no type can enforce. Reading the function body is the
    /// only way to pin it without a real Keychain.
    func test_theMoveCopiesThenVerifiesThenDeletes() throws {
        let path = ViewSource.url(under: "Services", "KeychainMigration")
        let source = try String(contentsOf: path, encoding: .utf8)
        let fnStart = try XCTUnwrap(
            source.range(of: "public func migrateKeychainItem("),
            "the migration entry point is gone"
        )
        let body = String(source[fnStart.lowerBound...])

        let copy = try XCTUnwrap(body.range(of: "// 1. Copy."), "the copy step is gone")
        let verify = try XCTUnwrap(body.range(of: "// 2. Verify"), "the verify step is gone")
        let delete = try XCTUnwrap(body.range(of: "// 3. Only now is it safe"), "the delete step is gone")
        XCTAssertLessThan(copy.lowerBound, verify.lowerBound, "verify must follow the copy")
        XCTAssertLessThan(verify.lowerBound, delete.lowerBound, "delete must follow the verify")

        // The delete must be guarded by the verification result — not by a
        // bare `try` that happens to sit below it.
        let betweenVerifyAndDelete = String(body[verify.lowerBound..<delete.lowerBound])
        XCTAssertTrue(
            betweenVerifyAndDelete.contains("keychainCopyIsVerified"),
            "the delete is not gated on a successful verification"
        )
        XCTAssertTrue(
            betweenVerifyAndDelete.contains("return .copyFailed"),
            "a failed verification must return without deleting the old copy"
        )
    }

    /// The verification read must name the destination.
    ///
    /// A location-less read searches both keychains, so with the old copy
    /// still present it would find *that* — call the failed write verified
    /// — and then delete the very item it mistook for proof.
    func test_theVerificationReadNamesTheDestinationLocation() throws {
        let path = ViewSource.url(under: "Services", "KeychainMigration")
        let source = try String(contentsOf: path, encoding: .utf8)
        let fnStart = try XCTUnwrap(source.range(of: "public func migrateKeychainItem("))
        let body = String(source[fnStart.lowerBound...])
        let verify = try XCTUnwrap(body.range(of: "// 2. Verify"))
        let delete = try XCTUnwrap(body.range(of: "// 3. Only now is it safe"))
        let verifyCode = ViewSource.code(
            after: verify.lowerBound,
            in: body[verify.lowerBound..<delete.lowerBound],
            limit: 700
        )
        XCTAssertTrue(
            verifyCode.contains("location: destination"),
            """
            the verification read does not name the destination. A search \
            would find the old copy and call the copy verified, then delete \
            the old copy on the strength of it.
            """
        )
    }

    // MARK: - The user has a way out

    /// The blocked state must have a screen with two real actions.
    ///
    /// A spinner that never stops is the defect. The screen must name the
    /// problem and offer both a way out (open Keychain Access) and a way to
    /// try again.
    func test_theBlockedKeychainHasAVisibleNextAction() throws {
        let source = try ViewSource.read("KeychainAuthorizationView")
        XCTAssertTrue(
            source.contains("Button(l10n.retry)"),
            "the blocked-Keychain screen offers no retry"
        )
        XCTAssertTrue(
            source.contains("Button(l10n.keychainOpenAccess)"),
            "the blocked-Keychain screen offers no way to open Keychain Access"
        )
        XCTAssertTrue(
            source.contains("NSWorkspace.shared.openApplication"),
            "the 「打开钥匙串访问」 button does not actually open it"
        )
        XCTAssertTrue(
            source.contains("activates = true"),
            "Keychain Access would open behind the app, which is a worse instruction than none"
        )
    }

    /// The app must route the blocked state to that screen — not to the
    /// connect form.
    ///
    /// Showing `ConnectView` to a user who *has* an account tells them
    /// their account is gone, and connecting again writes a second
    /// account over the first.
    func test_theBlockedStateIsShownInsteadOfTheConnectForm() throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LagoonTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Sources/Lagoon/LagoonApp.swift")
        let source = try String(contentsOf: path, encoding: .utf8)

        let blocked = try XCTUnwrap(
            source.range(of: "accounts.isKeychainBlocked"),
            "the app has no branch for a blocked Keychain"
        )
        let connect = try XCTUnwrap(
            source.range(of: "ConnectView()"),
            "the app no longer shows the connect form"
        )
        XCTAssertLessThan(
            blocked.lowerBound, connect.lowerBound,
            """
            the blocked-Keychain branch must be checked before the \
            "no account" branch, or a user whose account exists but cannot \
            be read is shown the connect form and talked into re-connecting.
            """
        )
        // The limit is a *character* count and the branch begins with a
        // long comment, so the budget has to cover prose before it reaches
        // code.
        let blockedBranch = ViewSource.code(after: blocked.lowerBound, in: source, limit: 900)
        XCTAssertTrue(
            blockedBranch.contains("KeychainAuthorizationView("),
            "the blocked-Keychain branch does not show the authorization screen"
        )
    }

    /// The account store must set the blocked flag on a failure.
    ///
    /// The view can only route on what the store publishes. A store that
    /// folded a failure into "no account" would make the screen above
    /// unreachable.
    func test_theAccountStorePublishesTheBlockedStateOnAFailure() throws {
        let path = ViewSource.url(under: "Models", "AccountStore")
        let source = try String(contentsOf: path, encoding: .utf8)
        XCTAssertTrue(
            source.contains("isKeychainBlocked = true"),
            "the account store never reports a blocked Keychain"
        )
        let failed = try XCTUnwrap(
            source.range(of: "case .failed("),
            "the account store does not handle a failed read separately"
        )
        let branch = ViewSource.code(after: failed.lowerBound, in: source, limit: 420)
        XCTAssertTrue(
            branch.contains("isKeychainBlocked = true"),
            "the .failed branch must set isKeychainBlocked"
        )
        XCTAssertTrue(
            branch.contains("accountId = nil"),
            "a blocked read must not leave a stale account id behind"
        )
    }
}
