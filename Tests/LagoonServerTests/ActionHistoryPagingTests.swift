import Foundation
import Logging
import XCTest
import Hummingbird
import HummingbirdTesting
import NIOCore
import GRDB
@testable import LagoonServer
@testable import LagoonKit

/// `GET /api/actions` is paged, and says so.
///
/// ## What was wrong
///
/// The route capped at 100 and the client loaded once. A user with 200
/// actions saw the newest 100 and a list that looked complete, so the older
/// 100 — including the ones closest to their undo expiry — were simply
/// unreachable. The audit called this out as indistinguishable from a broken
/// feature, and the fix has two halves that fail independently:
///
/// * the server can page but not report the size (the panel cannot say
///   "还有 N 条" and goes back to a silent cut-off), or
/// * the server can page but the cursor is wrong (rows get skipped or
///   repeated at every page boundary, which is worse than the cap: the user
///   sees a complete-looking list with holes in it).
///
/// Both are covered below, along with the ordering tie that makes the second
/// one possible.
final class ActionHistoryPagingTests: XCTestCase {
    private static let logger = Logger(label: "action-paging-tests")

    private func makeAccount() -> Account {
        Account(
            id: UUID(),
            provider: .qq,
            oauthUser: "paging-\(UUID().uuidString)",
            email: "paging-\(UUID().uuidString)@example.com",
            credentials: nil
        )
    }

    private func seedAccount(_ account: Account, db: LagoonDB) async throws {
        try await AccountStore.upsert(account, credentials: Data([1, 2, 3]), db: db)
    }

    /// The actions router on its own. `ActionsRoutes.register` builds a real
    /// provider factory when none is passed; nothing in `GET /api/actions`
    /// dials it, so a nil-returning builder keeps the test off the network.
    private func makeApp(db: LagoonDB) -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router<BasicRequestContext>()
        ActionsRoutes.register(
            on: router,
            db: db,
            logger: Self.logger,
            makeProvider: { _ in nil }
        )
        return Application(router: router)
    }

    private func get(
        _ app: Application<RouterResponder<BasicRequestContext>>,
        _ path: String
    ) async throws -> (status: HTTPResponse.Status, body: Data) {
        // The response arrives from the client's concurrent closure; a plain
        // captured `var` is a data race the compiler rightly rejects. The
        // write happens inside the handler and the read after `app.test`
        // returns — strictly ordered — so the box is the same one
        // `OverrideScopeTests` uses for exactly this.
        let box = Captured<(status: HTTPResponse.Status, body: Data)?>(nil)
        try await app.test(.router) { client in
            try await client.execute(uri: path, method: .get) { response in
                box.value = (response.status, Data(buffer: response.body))
            }
        }
        let (status, body) = try XCTUnwrap(box.value, "the route answered nothing")
        return (status, body)
    }

    private func decode(_ data: Data) throws -> AIActionListResponse {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AIActionListResponse.self, from: data)
    }

    /// Records `count` actions, each one second older than the last, so the
    /// intended order is 1 (newest) … count (oldest) and every row has a
    /// distinct timestamp.
    private func recordDistinct(
        _ count: Int, accountId: UUID, db: LagoonDB
    ) async throws -> [AIAction] {
        var rows: [AIAction] = []
        for index in 0..<count {
            let row = try await AIActionStore.record(
                accountId: accountId,
                kind: .archive,
                payload: ["remoteId": "m-\(index)", "remoteWrite": "false"],
                db: db
            )
            // Backdate it so ordering is deterministic rather than dependent
            // on how fast the loop runs.
            let stamp = Date(timeIntervalSince1970: 1_700_000_000 - Double(index))
            try db.write { raw in
                try raw.execute(
                    sql: "UPDATE ai_actions SET created_at = ? WHERE id = ?",
                    arguments: [stamp, row.id]
                )
            }
            rows.append(row)
        }
        return rows
    }

    // MARK: - Paging actually pages

    /// Two pages, and together they are the whole history — no row twice,
    /// no row missing.
    ///
    /// This is the property the old route could not have: it returned the
    /// newest 100 and stopped.
    func test_pagingReturnsEveryRowExactlyOnce() async throws {
        let account = makeAccount()
        try await TestDatabase.withConnection { conn in
            try await seedAccount(account, db: conn)
            let recorded = try await recordDistinct(250, accountId: account.id, db: conn)
            let app = makeApp(db: conn)
            let base = "/api/actions?accountId=\(account.id.uuidString)&limit=100"

            let first = try decode(try await get(app, base).body)
            XCTAssertEqual(first.actions.count, 100)
            XCTAssertEqual(first.totalCount, 250, "the total is the history, not the page")
            XCTAssertEqual(first.hasMore, true)

            let second = try decode(
                try await get(app, "\(base)&before=\(try XCTUnwrap(first.actions.last).id)").body
            )
            XCTAssertEqual(second.actions.count, 100)
            XCTAssertEqual(second.hasMore, true)

            let third = try decode(
                try await get(app, "\(base)&before=\(try XCTUnwrap(second.actions.last).id)").body
            )
            XCTAssertEqual(third.actions.count, 50)
            XCTAssertEqual(
                third.hasMore, false,
                "the last page must say so — otherwise the panel offers a button that loads nothing"
            )

            let all = (first.actions + second.actions + third.actions).map(\.id)
            XCTAssertEqual(all.count, 250, "three pages of 100/100/50 is the whole history")
            XCTAssertEqual(Set(all).count, 250, "no row may appear on two pages")
            XCTAssertEqual(
                Set(all), Set(recorded.map(\.id)),
                "the pages must cover every recorded action"
            )
        }
    }

    /// Newest first, across a page boundary.
    ///
    /// A cursor that compared only `created_at` and forgot the ordering would
    /// pass the set-equality test above while returning each page in an
    /// arbitrary order inside itself. The panel renders the rows in the order
    /// it receives them, so the assertion that the concatenated pages are
    /// monotonically descending is the one that pins what the user sees.
    func test_pagesArriveInDescendingOrder() async throws {
        let account = makeAccount()
        try await TestDatabase.withConnection { conn in
            try await seedAccount(account, db: conn)
            _ = try await recordDistinct(30, accountId: account.id, db: conn)
            let app = makeApp(db: conn)
            let base = "/api/actions?accountId=\(account.id.uuidString)&limit=10"

            var collected: [AIAction] = []
            var cursor: Int64?
            for _ in 0..<3 {
                let suffix = cursor.map { "&before=\($0)" } ?? ""
                let page = try decode(try await get(app, base + suffix).body)
                collected.append(contentsOf: page.actions)
                cursor = page.actions.last?.id
            }

            XCTAssertEqual(collected.count, 30)
            for (newer, older) in zip(collected, collected.dropFirst()) {
                XCTAssertGreaterThanOrEqual(
                    newer.createdAt, older.createdAt,
                    "the panel draws this order verbatim; it must be newest-first"
                )
            }
        }
    }

    /// Rows that share a timestamp must still page cleanly.
    ///
    /// This is not hypothetical: every bulk operation ("mark all as read",
    /// 清扫) writes one row per message inside the same millisecond. A
    /// `created_at`-only cursor lands between two identical timestamps and
    /// either skips the rest of the group or returns it forever.
    func test_rowsSharingATimestamp_pageWithoutLossOrRepetition() async throws {
        let account = makeAccount()
        try await TestDatabase.withConnection { conn in
            try await seedAccount(account, db: conn)
            // Six rows, all at the same instant — one bulk operation.
            var ids: [Int64] = []
            for index in 0..<6 {
                let row = try await AIActionStore.record(
                    accountId: account.id,
                    kind: .markRead,
                    payload: ["remoteId": "bulk-\(index)"],
                    db: conn
                )
                ids.append(row.id)
            }
            let stamp = Date(timeIntervalSince1970: 1_700_000_000)
            for id in ids {
                try conn.write { raw in
                    try raw.execute(
                        sql: "UPDATE ai_actions SET created_at = ? WHERE id = ?",
                        arguments: [stamp, id]
                    )
                }
            }
            let app = makeApp(db: conn)
            // A page size of 2 splits the tied group across three pages.
            let base = "/api/actions?accountId=\(account.id.uuidString)&limit=2"

            var collected: [Int64] = []
            var cursor: Int64?
            for _ in 0..<3 {
                let suffix = cursor.map { "&before=\($0)" } ?? ""
                let page = try decode(try await get(app, base + suffix).body)
                collected.append(contentsOf: page.actions.map(\.id))
                cursor = page.actions.last?.id
            }

            XCTAssertEqual(
                collected.count, 6,
                "a tie at a page boundary must not drop rows: \(collected)"
            )
            XCTAssertEqual(Set(collected), Set(ids), "every tied row must appear exactly once")
        }
    }

    // MARK: - The list reports its own size

    /// On a history shorter than one page, there is nothing older and the
    /// panel must not offer to load it.
    func test_shortHistory_reportsNoMore() async throws {
        let account = makeAccount()
        try await TestDatabase.withConnection { conn in
            try await seedAccount(account, db: conn)
            _ = try await recordDistinct(3, accountId: account.id, db: conn)
            let app = makeApp(db: conn)

            let page = try decode(
                try await get(app, "/api/actions?accountId=\(account.id.uuidString)").body
            )
            XCTAssertEqual(page.actions.count, 3)
            XCTAssertEqual(page.totalCount, 3)
            XCTAssertEqual(page.hasMore, false)
        }
    }

    /// An **empty** history reports zero, not nil.
    ///
    /// The difference matters: nil means "the server did not say", and the
    /// panel treats that as unknown rather than as an empty list.
    func test_emptyHistory_reportsZeroAndNoMore() async throws {
        let account = makeAccount()
        try await TestDatabase.withConnection { conn in
            try await seedAccount(account, db: conn)
            let app = makeApp(db: conn)

            let page = try decode(
                try await get(app, "/api/actions?accountId=\(account.id.uuidString)").body
            )
            XCTAssertTrue(page.actions.isEmpty)
            XCTAssertEqual(page.totalCount, 0)
            XCTAssertEqual(page.hasMore, false)
        }
    }

    /// A history that ends exactly on a page boundary.
    ///
    /// `actions.count == limit` is true here on the *last* page, so inferring
    /// `hasMore` from the count would offer a "load older" button that loads
    /// nothing. The server measures it by fetching one row past the page.
    func test_historyEndingOnAPageBoundary_saysThereIsNoMore() async throws {
        let account = makeAccount()
        try await TestDatabase.withConnection { conn in
            try await seedAccount(account, db: conn)
            _ = try await recordDistinct(4, accountId: account.id, db: conn)
            let app = makeApp(db: conn)

            let page = try decode(
                try await get(app, "/api/actions?accountId=\(account.id.uuidString)&limit=4").body
            )
            XCTAssertEqual(page.actions.count, 4)
            XCTAssertEqual(
                page.hasMore, false,
                "a full last page is still the last page; inferring from the count would lie"
            )
        }
    }

    /// The count is exactly the number of rows the pages can reach.
    ///
    /// This is the property that makes "还有 N 条" trustworthy, and it is
    /// stated as a convergence rather than as a hand-counted constant: if the
    /// count used a wider predicate than the page, the panel would say
    /// "还有 3 条" and then load zero rows — a dead end of the exact kind
    /// this change removes. The undone row is the interesting case, since it
    /// is the one the predicate must drop from both sides.
    func test_theCountEqualsWhatThePagesDeliver() async throws {
        let account = makeAccount()
        try await TestDatabase.withConnection { conn in
            try await seedAccount(account, db: conn)
            let live = try await recordDistinct(3, accountId: account.id, db: conn)
            // An undo of one of them, plus a terminal (listed but not
            // undoable) row.
            try conn.write { raw in
                _ = try AIActionStore.recordSync(
                    accountId: account.id, kind: .unsubscribe,
                    payload: ["remoteId": "unsub"], db: raw
                )
                _ = try AIActionStore.recordSync(
                    accountId: account.id, kind: .undo,
                    payload: ["undoOf": "\(live[0].id)"], db: raw
                )
            }
            let app = makeApp(db: conn)
            let base = "/api/actions?accountId=\(account.id.uuidString)&limit=2"

            var collected: [Int64] = []
            var cursor: Int64?
            var reportedTotal: Int?
            // Bound the loop: a cursor bug that never terminates must fail
            // here rather than hang the suite.
            for _ in 0..<20 {
                let suffix = cursor.map { "&before=\($0)" } ?? ""
                let page = try decode(try await get(app, base + suffix).body)
                reportedTotal = page.totalCount
                collected.append(contentsOf: page.actions.map(\.id))
                guard page.hasMore == true else { break }
                cursor = page.actions.last?.id
                if cursor == nil { break }
            }

            let total = try XCTUnwrap(reportedTotal)
            XCTAssertEqual(
                collected.count, total,
                "the pages must deliver exactly as many rows as the count promises"
            )
            XCTAssertEqual(Set(collected).count, collected.count, "no row may repeat")
            XCTAssertFalse(
                collected.contains(live[0].id),
                "an undone action must not be listed — ⌘Z would keep re-picking it"
            )
        }
    }

    /// An undo does not shorten the history.
    ///
    /// The server records an *undo* row for the action it reverses, and the
    /// history keeps saying what Lagoon did — so one row leaves and one
    /// arrives. The count is therefore unchanged.
    ///
    /// This matters to the panel, which has to decide whether to decrement
    /// its "还有 N 条" figure after an undo. If the count were *not* stable,
    /// a client that decremented would be right; if it is stable, a client
    /// that decrements would be wrong. This test is what tells the client
    /// which one it is.
    func test_anUndoDoesNotChangeTheCount() async throws {
        let account = makeAccount()
        try await TestDatabase.withConnection { conn in
            try await seedAccount(account, db: conn)
            let live = try await recordDistinct(3, accountId: account.id, db: conn)
            let app = makeApp(db: conn)
            let uri = "/api/actions?accountId=\(account.id.uuidString)&limit=10"

            let before = try decode(try await get(app, uri).body)
            XCTAssertEqual(before.totalCount, 3)

            // Undo one of them through the route, exactly as the panel does.
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/api/actions/\(live[0].id)/undo?accountId=\(account.id.uuidString)",
                    method: .post
                ) { response in
                    XCTAssertEqual(response.status, .ok)
                }
            }

            let after = try decode(try await get(app, uri).body)
            XCTAssertEqual(
                after.totalCount, 3,
                "the undone action leaves the list and the undo row takes its place; the count holds"
            )
            XCTAssertFalse(
                after.actions.contains { $0.id == live[0].id },
                "the reversed action must not be offered again"
            )
            XCTAssertTrue(
                after.actions.contains { $0.kind == .undo },
                "the history still records that something was undone"
            )
        }
    }

    // MARK: - Bad cursors

    /// A cursor that is not a positive integer is a 400.
    ///
    /// Ignoring it and answering with the first page would look to the panel
    /// like the history restarted, and the user would scroll the same rows
    /// twice without reaching the older ones.
    func test_malformedCursorIsRejected() async throws {
        let account = makeAccount()
        try await TestDatabase.withConnection { conn in
            try await seedAccount(account, db: conn)
            let app = makeApp(db: conn)
            let base = "/api/actions?accountId=\(account.id.uuidString)"

            for bad in ["abc", "0", "-3", "1.5"] {
                let (status, body) = try await get(app, "\(base)&before=\(bad)")
                XCTAssertEqual(status, .badRequest, "'before=\(bad)' must be refused")
                let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                XCTAssertEqual(object?["error"] as? String, "malformed-before")
            }
        }
    }

    /// Another account's action id must not work as a cursor.
    ///
    /// Every id in this API is caller-supplied, and the only thing scoping it
    /// is the query's `account_id`. An id accepted from outside the account
    /// would let one mailbox page through another's timestamps — and would
    /// also make this route an existence oracle for ids that are not the
    /// caller's.
    func test_anotherAccountsCursorIsRejected() async throws {
        let owner = makeAccount()
        let intruder = makeAccount()
        try await TestDatabase.withConnection { conn in
            try await seedAccount(owner, db: conn)
            try await seedAccount(intruder, db: conn)
            let secret = try await recordDistinct(1, accountId: owner.id, db: conn)
            let app = makeApp(db: conn)

            let (status, body) = try await get(
                app,
                "/api/actions?accountId=\(intruder.id.uuidString)&before=\(try XCTUnwrap(secret.first).id)"
            )
            XCTAssertEqual(status, .badRequest)
            let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(
                object?["error"] as? String, "unknown-before",
                "an id from another account is unknown here, not a cursor"
            )
        }
    }

    /// The `limit` parameter is clamped, and a nonsense one falls back to
    /// the default instead of becoming zero rows.
    func test_limitIsClamped() async throws {
        let account = makeAccount()
        try await TestDatabase.withConnection { conn in
            try await seedAccount(account, db: conn)
            _ = try await recordDistinct(5, accountId: account.id, db: conn)
            let app = makeApp(db: conn)
            let base = "/api/actions?accountId=\(account.id.uuidString)"

            // Zero and negative are floors, not "no rows": a page of none
            // would render an empty panel for a history that has entries.
            for bad in ["0", "-5", "not-a-number"] {
                let page = try decode(try await get(app, "\(base)&limit=\(bad)").body)
                XCTAssertFalse(
                    page.actions.isEmpty,
                    "an out-of-range page size must fall back to the default, not to nothing"
                )
            }
            // And an absurdly large one is capped rather than honoured.
            let capped = try decode(try await get(app, "\(base)&limit=100000").body)
            XCTAssertLessThanOrEqual(capped.actions.count, 500)
        }
    }

    /// The `since` bound still works alongside the cursor: the pages must
    /// stay inside the window the caller asked for.
    func test_pagingRespectsTheSinceWindow() async throws {
        let account = makeAccount()
        try await TestDatabase.withConnection { conn in
            try await seedAccount(account, db: conn)
            let old = try await AIActionStore.record(
                accountId: account.id, kind: .archive,
                payload: ["remoteId": "old"], db: conn
            )
            try conn.write { raw in
                try raw.execute(
                    sql: "UPDATE ai_actions SET created_at = ? WHERE id = ?",
                    arguments: [Date(timeIntervalSince1970: 1_600_000_000), old.id]
                )
            }
            _ = try await recordDistinct(4, accountId: account.id, db: conn)
            let app = makeApp(db: conn)
            let since = APITimeFixture.iso8601(Date(timeIntervalSince1970: 1_650_000_000))

            let page = try decode(
                try await get(
                    app,
                    "/api/actions?accountId=\(account.id.uuidString)&since=\(since)&limit=10"
                ).body
            )
            XCTAssertEqual(page.totalCount, 4, "the out-of-window row must not be counted")
            XCTAssertFalse(
                page.actions.contains { $0.id == old.id },
                "the out-of-window row must not be returned"
            )
        }
    }
}

/// Carries the route's answer out of the client's concurrent closure.
///
/// The same shape `OverrideScopeTests` uses, redeclared here because that one
/// is `private` to its file. The write happens inside the response handler
/// and the read after `app.test` returns — strictly ordered, no concurrent
/// access — which is why `@unchecked Sendable` is honest here.
private final class Captured<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// ISO-8601 with fractional seconds — the format the route parses.
enum APITimeFixture {
    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
