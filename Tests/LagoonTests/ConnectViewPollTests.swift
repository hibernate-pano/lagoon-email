import XCTest
import Foundation
@testable import Lagoon
@testable import LagoonKit

/// The Gmail OAuth handshake poll must only auto-select a row that the
/// round-trip just landed — never a row that already existed when the connect
/// surface opened. Stealing a pre-existing row bounces the user straight back
/// to the feed ("添加账号" flickers and never shows the form).
final class ConnectViewPollTests: XCTestCase {
    private func account(
        id: UUID = UUID(),
        provider: MailProviderKind = .gmail,
        _ status: SyncHealth.Status
    ) -> ConnectedAccount {
        ConnectedAccount(
            id: id,
            provider: provider,
            email: "a@example.com",
            isActive: false,
            syncHealth: SyncHealth(status: status),
            capabilities: MailCapabilities(
                archiveFolder: true, idle: true, move: true, serverSnippet: true
            )
        )
    }

    func test_firstConnect_newGmailRowIsSelected() {
        let landed = ConnectView.landedGmailAccount(
            current: [account(.ok)],
            baseline: []
        )
        XCTAssertEqual(landed?.provider, .gmail)
    }

    func test_addAccount_existingHealthyRowIsNotStolen() {
        // The reported bug: a stale/broken gmail row already existed server-side
        // when the user asked to add an account; the poll used to grab it within
        // one cycle. A healthy pre-existing row must never be selected.
        let row = account(.ok)
        let landed = ConnectView.landedGmailAccount(
            current: [row],
            baseline: [row]
        )
        XCTAssertNil(landed)
    }

    func test_addAccount_staleRowStillBrokenIsNotSelected() {
        let row = account(.error)
        let landed = ConnectView.landedGmailAccount(
            current: [row],
            baseline: [row]
        )
        XCTAssertNil(landed)
    }

    func test_reconnect_recoveredRowIsSelected() {
        // OAuth callback upserts credentials in place (same id) and ticks the
        // sync engine, so a reconnected row flips to .ok within seconds.
        let id = UUID()
        let landed = ConnectView.landedGmailAccount(
            current: [account(id: id, .ok)],
            baseline: [account(id: id, .needsReconnect)]
        )
        XCTAssertEqual(landed?.id, id)
    }

    func test_reconnect_stillBrokenIsNotSelected() {
        let id = UUID()
        let landed = ConnectView.landedGmailAccount(
            current: [account(id: id, .error)],
            baseline: [account(id: id, .needsReconnect)]
        )
        XCTAssertNil(landed)
    }

    func test_qqRowIsNeverSelectedByTheGmailPoll() {
        let landed = ConnectView.landedGmailAccount(
            current: [account(provider: .qq, .ok)],
            baseline: []
        )
        XCTAssertNil(landed)
    }
}
