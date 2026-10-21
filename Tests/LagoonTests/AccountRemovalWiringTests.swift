import XCTest
@testable import Lagoon

/// 「移除这个账号」 has to be reachable, and it has to report honestly.
///
/// The API route existed (`DELETE /api/accounts/:id`) and so did the store
/// method (`DirectoryStore.remove`) — and nothing in the UI called either.
/// A user who connected the wrong mailbox could only get rid of it by
/// deleting the whole database, which throws away every account they had.
///
/// These are structural guards: the removal must be *in* the account menu,
/// it must be confirmed, and a failure must produce a banner with a retry
/// rather than a shrug.
final class AccountRemovalWiringTests: XCTestCase {
    private func rootViewSource() throws -> String {
        try String(
            contentsOf: ViewSource.url(under: "Views", "RootView"),
            encoding: .utf8
        )
    }

    /// The account menu must offer the removal.
    func test_theAccountMenuOffersRemoval() throws {
        let source = try rootViewSource()
        XCTAssertTrue(
            source.contains("l10n.removeAccount"),
            "the account menu has no removal item — a wrong mailbox can never be undone"
        )
        XCTAssertTrue(
            source.contains("directory.remove"),
            "the removal item is not wired to the store"
        )
    }

    /// A removal is destructive, so it asks first.
    ///
    /// The prompt also has to say the one thing the user would otherwise
    /// worry about: the mail on the server is not touched. Without that
    /// sentence, a reasonable person reads "移除这个账号" as "delete my mail"
    /// and declines.
    func test_theRemovalIsConfirmedAndExplainsWhatItDoesNotDelete() throws {
        let source = try rootViewSource()
        XCTAssertTrue(
            source.contains("l10n.removeAccountConfirmTitle"),
            "the removal is not confirmed"
        )
        XCTAssertTrue(
            source.contains("l10n.removeAccountConfirmMessage"),
            "the confirmation says nothing about what the removal does"
        )

        let l10n = L10n(language: .zhHans)
        XCTAssertTrue(
            l10n.removeAccountConfirmMessage.contains("服务器上的邮件不会被删除"),
            "the confirmation must say the server-side mail is not deleted"
        )
    }

    /// A failed removal must be reported, and the retry must be the same
    /// removal.
    ///
    /// A removal that fails silently leaves the user looking at an account
    /// they just decided they did not want, with no way to tell whether it
    /// worked.
    func test_aFailedRemovalIsReportedWithARealRetry() throws {
        let source = try rootViewSource()
        XCTAssertTrue(
            source.contains("l10n.removeAccountFailedDetail"),
            "a failed removal has no detail — the banner would say nothing"
        )
        XCTAssertTrue(
            source.contains("l10n.retry"),
            "a failed removal offers no retry"
        )
        // The retry must re-run the same removal, not something else.
        XCTAssertTrue(
            source.contains("await self.removeAccount(account)"),
            "the retry must re-run the same removal"
        )
    }

    /// The store must not park a removal failure in `loadError`.
    ///
    /// `loadError` feeds the "the mail list could not be loaded" banner, so
    /// a removal failure parked there would be announced under the wrong
    /// headline — and would appear twice, once as that banner and once as
    /// the removal's own error. Spec INV-6: one banner at a time, and the
    /// right one.
    func test_theStoreDoesNotReportARemovalFailureAsALoadError() throws {
        let source = try String(
            contentsOf: ViewSource.url(under: "Models", "DirectoryStore"),
            encoding: .utf8
        )
        let removal = try XCTUnwrap(
            source.range(of: "public func remove("),
            "DirectoryStore lost its remove method"
        )
        let body = source[removal.lowerBound...]
        XCTAssertFalse(
            body.contains("loadError ="),
            "a removal failure must not be reported as a list-load failure"
        )
        XCTAssertTrue(
            body.contains("throw error"),
            "the removal must report its failure to the caller"
        )
    }
}
