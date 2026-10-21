import XCTest
@testable import Lagoon

/// 彻底删除 is the only verb in the product with no undo behind it, so the
/// one thing that must never happen is two deletes for the same message: the
/// second request would land on a row that is already gone and report a
/// failure for work that actually succeeded.
///
/// The guard used to be a single `isPurging` flag that was written and never
/// read — the comment claimed a double-click protection that did not exist.
/// These tests pin the replacement: a per-row claim, consulted by the purge
/// path, that does not lock the *other* rows while one delete is on the wire.
final class PurgeGuardTests: XCTestCase {

    /// The second click on the same row must be refused.
    func test_secondClaimOnTheSameRowIsRefused() {
        var guardState = PurgeGuard()
        XCTAssertTrue(guardState.claim("m1"), "the first purge may run")
        XCTAssertFalse(
            guardState.claim("m1"),
            "a second purge for the same message must not be admitted"
        )
    }

    /// A finished purge frees the row — including a *failed* one, or the
    /// message could never be purged again.
    func test_releaseFreesTheRow() {
        var guardState = PurgeGuard()
        XCTAssertTrue(guardState.claim("m1"))
        guardState.release("m1")
        XCTAssertTrue(
            guardState.claim("m1"),
            "a released row must be purgeable again"
        )
    }

    /// The guard is per row, not global: one delete in flight must not lock
    /// the confirmation of every other message. A global flag would have
    /// been "safer" and unusable — the user could not purge a second message
    /// until the first request came back.
    func test_oneRowInFlightDoesNotLockTheOthers() {
        var guardState = PurgeGuard()
        XCTAssertTrue(guardState.claim("m1"))
        XCTAssertTrue(guardState.isPurging("m1"))
        XCTAssertFalse(guardState.isPurging("m2"))
        XCTAssertTrue(
            guardState.claim("m2"),
            "a different message must not be blocked by another message's purge"
        )
    }

    /// Releasing one row leaves the other alone.
    func test_releaseOnlyFreesTheNamedRow() {
        var guardState = PurgeGuard()
        _ = guardState.claim("m1")
        _ = guardState.claim("m2")
        guardState.release("m1")
        XCTAssertFalse(guardState.isPurging("m1"))
        XCTAssertTrue(guardState.isPurging("m2"))
    }

    // MARK: - Wiring

    /// The guard is only worth anything if the purge path asks it. This is
    /// the wiring the old `isPurging` flag never had: the flag was written
    /// and never read, so two clicks fired two requests.
    func test_purgePathConsultsTheGuardBeforeDeleting() throws {
        let source = try ViewSource.read("MessageListView")
        let purge = try XCTUnwrap(
            source.range(of: "private func purge("),
            "the purge path must still exist"
        )
        let code = ViewSource.code(after: purge.lowerBound, in: source, limit: 1200)
        XCTAssertTrue(
            code.contains("purgeGuard.claim("),
            "the purge must claim the row before it fires, or a double click fires it twice"
        )
        XCTAssertTrue(
            code.contains("else { return }"),
            "a refused claim must end the purge, not continue into the request"
        )
    }

    /// The confirm button is disabled while its own row is being destroyed,
    /// so the second click cannot even queue a second request.
    func test_confirmButtonIsDisabledWhileTheRowIsPurging() throws {
        let source = try ViewSource.read("MessageListView")
        let alert = try XCTUnwrap(
            source.range(of: "l10n.purgeForever, role: .destructive"),
            "the purge confirmation must still offer the destructive button"
        )
        let code = ViewSource.code(after: alert.lowerBound, in: source, limit: 700)
        XCTAssertTrue(
            code.contains("purgeGuard.isPurging("),
            "the confirm button must ask the guard whether *this* row is busy"
        )
    }
}
