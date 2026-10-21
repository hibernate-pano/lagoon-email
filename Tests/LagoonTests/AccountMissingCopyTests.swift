import XCTest
import Foundation
@testable import Lagoon
@testable import LagoonKit

/// The copy for "this store cannot find the account".
///
/// ## What this pins
///
/// The real defect ended with the user being told **their authorization code
/// had expired**. It had not. The account row was stored under an encoding
/// the server could not match, the sync failed, and the failure was labelled
/// `needsReconnect` — so the app sent the user to re-enter a perfectly good
/// code, into a form whose write went to a row the server still could not
/// find. The user was stuck in a loop, being told the wrong thing.
///
/// A status alone does not fix that: the client also has to *say* the right
/// sentence. These tests hold the copy to it — the account-missing sentence
/// must not be the authorization-code sentence, in either language.
final class AccountMissingCopyTests: XCTestCase {
    private let zh = L10n(language: .zhHans)
    private let en = L10n(language: .english)

    /// The server's label for "the account row is gone" maps to the
    /// account-missing sentence — not to the authorization-code one.
    ///
    /// The label is spelled out rather than taken from `MailError` because
    /// this target only links the app, and `MailError` lives in
    /// `LagoonServer`. The link between the enum case and this string is
    /// pinned separately, where it can be seen:
    /// `AccountIDRepairTests.test_missingAccountIsItsOwnStatusAndCarriesItsOwnLabel`.
    func test_accountMissingLabelMapsToItsOwnSentence() {
        for l10n in [zh, en] {
            let sentence = SyncErrorReason.sentence(
                for: "account-missing", l10n: l10n
            )
            XCTAssertEqual(sentence, l10n.reasonAccountMissing)
            XCTAssertNotEqual(
                sentence, l10n.reasonAuthFailed,
                "a missing account row must never be reported as an expired authorization code"
            )
        }
    }

    /// The two statuses render differently. A headline that says "reconnect"
    /// next to a detail that says "reconnecting will not help" would be the
    /// same contradiction the old banner had.
    func test_accountMissingAndNeedsReconnectDoNotShareCopy() {
        XCTAssertNotEqual(zh.healthAccountMissing, zh.healthNeedsReconnect)
        XCTAssertNotEqual(en.healthAccountMissing, en.healthNeedsReconnect)
        XCTAssertNotEqual(zh.syncStatusAccountMissing, zh.syncStatusNeedsReconnect)
        XCTAssertNotEqual(en.syncStatusAccountMissing, en.syncStatusNeedsReconnect)
    }

    /// The detail puts the blame in the local data and says what does help.
    ///
    /// It names the authorization code only to rule it out — the old banner
    /// blamed the code — and it names reconnecting, because that is the
    /// action the banner offers and the one thing that rebuilds the row.
    func test_accountMissingDetailNamesTheRealCauseAndTheRealRemedy() {
        XCTAssertTrue(
            zh.reasonAccountMissing.contains("授权码"),
            "the Chinese copy must name the authorization code it is ruling out"
        )
        XCTAssertTrue(
            en.reasonAccountMissing.lowercased().contains("authorization code"),
            "the English copy must name the authorization code it is ruling out"
        )
        XCTAssertTrue(
            zh.reasonAccountMissing.contains("重新连接"),
            "the Chinese copy must name the action the banner offers"
        )
        XCTAssertTrue(
            en.reasonAccountMissing.lowercased().contains("reconnect"),
            "the English copy must name the action the banner offers"
        )
        for l10n in [zh, en] {
            XCTAssertFalse(
                l10n.reasonAccountMissing.isEmpty,
                "the account-missing detail must not be empty"
            )
            XCTAssertFalse(l10n.healthAccountMissing.isEmpty)
        }
    }

    /// Every status has a name. A status the picker cannot name would render
    /// as an empty row in the account menu.
    func test_everySyncStatusHasAText() {
        for status in [SyncHealth.Status.ok, .degraded, .needsReconnect, .accountMissing, .error] {
            XCTAssertFalse(zh.healthStatusText(status).isEmpty)
            XCTAssertFalse(en.healthStatusText(status).isEmpty)
            XCTAssertNotEqual(zh.healthStatusText(status), en.healthStatusText(status))
        }
    }

    /// The view projection keeps the distinction rather than collapsing it
    /// into `needsReconnect`.
    func test_viewStateKeepsAccountMissingSeparate() {
        let health = SyncHealth(status: .accountMissing, lastError: "account-missing")
        XCTAssertEqual(
            SyncHealthViewState.from(health),
            .accountMissing(reason: "account-missing")
        )
        XCTAssertNotEqual(
            SyncHealthViewState.from(health),
            .needsReconnect(reason: "account-missing")
        )
    }
}
