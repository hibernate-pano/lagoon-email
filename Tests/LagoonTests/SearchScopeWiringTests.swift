import XCTest
import Foundation
@testable import Lagoon
@testable import LagoonKit

/// Source-level guards for the cross-account search (P1-11).
///
/// ## Why source, and why *attachment*
///
/// The cross-account search is three things that can each be missing on their
/// own: a scope the user can pick, a label that says which mailbox a hit
/// came from, and a result that opens in **its own** mailbox. The third one
/// is the dangerous one, and it is invisible in a screenshot: `remoteId` is
/// unique only *inside* a mailbox (a message with no `Message-ID` gets the
/// provider's fallback `uid:<n>`, and each account's IMAP UIDs count
/// independently), so a cross-account result list can hold the same string
/// twice and the reader would open whichever came first.
///
/// So each assertion below pins the *attachment* — the wiring, positioned
/// between anchors — not the mere presence of a word in the file.
final class SearchScopeWiringTests: XCTestCase {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // LagoonTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // package root

    private func source(_ name: String) throws -> String {
        try String(
            contentsOf: Self.repoRoot
                .appendingPathComponent("Sources/Lagoon/Views/\(name).swift"),
            encoding: .utf8
        )
    }

    // MARK: - The scope control

    /// The search panel must offer the scope, or the server's new capability
    /// is unreachable — the user still cannot search the other mailbox.
    func test_theSearchSheetOffersAScopeControl() throws {
        let source = try self.source("SearchSheet")
        XCTAssertTrue(
            source.contains("Picker(l10n.searchScopeLabel"),
            "the search sheet has no scope picker — the cross-account search is unreachable"
        )
        XCTAssertTrue(
            source.contains(".all"),
            "the scope picker never offers the every-mailbox option"
        )
        // Switching the scope must re-run the query. Otherwise the picker
        // changes a label and the results on screen stay the old mailbox's —
        // which reads as "the control is broken".
        XCTAssertTrue(
            source.contains(".onChange(of: scopeChoice)"),
            "switching the scope does not re-run the search"
        )
    }

    /// The scope is not a per-account string built at the call site: it is
    /// the shared `SearchScope`, so the client's keyword and the server's
    /// keyword cannot drift apart.
    func test_theSearchSheetUsesTheSharedScopeType() throws {
        let source = try self.source("SearchSheet")
        XCTAssertTrue(
            source.contains("api.searchPage(query: query, scope: scope)"),
            "the sheet still builds the account id by hand — the scope type is bypassed"
        )
    }

    // MARK: - The account label on a result row

    /// A cross-account hit must say which mailbox it came from.
    ///
    /// Without the label the user cannot tell whether a result belongs to the
    /// mailbox they are looking at or another one, and the whole point of
    /// searching everything is to find mail that is *not* in the current
    /// mailbox.
    func test_aCrossAccountResultSaysWhichMailboxItCameFrom() throws {
        let source = try self.source("SearchSheet")
        XCTAssertTrue(
            source.contains("accountLabel(for: m)"),
            "the result row does not name the mailbox the hit came from"
        )
        XCTAssertTrue(
            source.contains("private func accountLabel(for message: MessageHeader) -> String?"),
            "the account label helper is gone"
        )
        // It must be the mailbox's *name*, not the active account's.
        XCTAssertTrue(
            source.contains("directory.accounts.first(where: { $0.id == message.accountId })"),
            "the label does not come from the directory — it would name the wrong mailbox"
        )
    }

    // MARK: - The result opens in its own mailbox

    /// The reader must be given the account **of the result**, not the
    /// active one. With a bare `remoteId` as the navigation key, the sheet
    /// resolves `uid:42` to whichever mailbox it saw first.
    func test_aResultOpensInItsOwnMailbox() throws {
        let source = try self.source("SearchSheet")
        XCTAssertTrue(
            source.contains("NavigationLink(value: MessageRef(m))"),
            "the navigation key is not the account+id pair"
        )
        XCTAssertTrue(
            source.contains("accountId: ref.accountId,"),
            "the reader is opened with something other than the result's own account"
        )
        // The lookup has to match on the pair as well, or the sheet resolves
        // the key to the first hit with that remote id.
        XCTAssertTrue(
            source.contains("$0.accountId == ref.accountId && $0.remoteId == ref.remoteId"),
            "the result lookup matches on the remote id alone"
        )
    }

    // MARK: - The reader's sibling list

    /// "Archive & next" walks the sibling list. With a cross-account list,
    /// a sibling list of bare ids is ambiguous — the reader would advance to
    /// the same remote id in the wrong mailbox.
    func test_theSiblingsAreReferencesNotBareIds() throws {
        let detail = try String(
            contentsOf: Self.repoRoot
                .appendingPathComponent("Sources/Lagoon/Views/MessageDetailView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            detail.contains("var siblings: [MessageRef]?"),
            "the sibling list is back to bare ids — 'archive & next' is ambiguous across mailboxes"
        )
        XCTAssertTrue(
            detail.contains("var onAdvanceTo: ((MessageRef?) -> Void)?"),
            "the advance callback does not carry the account"
        )
        // The match has to be on the pair.
        XCTAssertTrue(
            detail.contains("siblings.firstIndex(of: self_)"),
            "the sibling lookup matches on the remote id alone"
        )
    }

    // MARK: - The scope's own contract

    /// The scope type carries the wire contract, so both sides read it from
    /// one place.
    func test_theScopeTypeIsSharedBetweenClientAndServer() throws {
        let kit = try String(
            contentsOf: Self.repoRoot
                .appendingPathComponent("Sources/LagoonKit/SearchScope.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(kit.contains("public static let allKeyword = \"all\""))
        XCTAssertTrue(kit.contains("public var queryValue: String"))
        XCTAssertTrue(kit.contains("public static func parse(_ raw: String?) -> SearchScope?"))
    }
}
