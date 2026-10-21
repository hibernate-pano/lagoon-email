import XCTest
import Foundation
import Logging
import Hummingbird
import HummingbirdTesting
import NIOCore
@testable import LagoonServer
@testable import LagoonKit

/// `PATCH /api/stacks/:id` — changing a group after it exists.
///
/// ## Why this file exists
///
/// A group used to be a one-way door: `POST` created it, `DELETE` removed
/// it, and **nothing could change it**. The product's own copy called these
/// things 「规则」 — and a rule in a mail product means "condition + action" —
/// while what the code actually had was a saved filter with no action and no
/// way to fix it. So a user who matched the wrong keyword could only delete
/// the group and rebuild it, losing the name that the sidebar row and the
/// sweep both refer to.
///
/// The route that fixes that has one job beyond "the row changed": it must
/// not become a **cross-tenant write**. The delete was scoped to
/// `WHERE id = ? AND account_id = ?` for exactly that reason, and an update
/// that was not scoped the same way would let one account rename another
/// account's group by guessing its id. So the refusal is pinned here as
/// loudly as the success.
final class StackUpdateRouteTests: XCTestCase {
    private static let testLogger = Logger(label: "stack-update-tests")

    private func makeAccount(oauthUser: String, email: String) -> Account {
        Account(
            id: UUID(),
            provider: .qq,
            oauthUser: oauthUser,
            email: email,
            credentials: nil,
            isActive: false
        )
    }

    private func seedAccount(_ account: Account, db: LagoonDB) async throws {
        try await AccountStore.upsert(
            account,
            credentials: Data([1, 2, 3]),
            db: db
        )
    }

    private func makeRouter(db: LagoonDB) -> Router<BasicRequestContext> {
        let router = Router()
        StackRoutes.register(on: router, db: db, logger: Self.testLogger)
        return router
    }

    /// The server encodes dates ISO-8601; the plain `JSONDecoder()` default
    /// cannot read them.
    private static func iso8601Decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func errorCode(from buffer: ByteBuffer) throws -> String? {
        let object = try JSONSerialization.jsonObject(with: Data(buffer: buffer))
        return (object as? [String: Any])?["error"] as? String
    }

    // MARK: - The two things an update has to get right

    /// Renaming a group changes the row the sidebar shows and the name the
    /// sweep's toast quotes. The response carries the group *as it now
    /// stands*, so the client does not have to guess what the server did.
    func test_patch_renamesAGroup() async throws {
        let account = makeAccount(
            oauthUser: "stack-update-\(UUID().uuidString)",
            email: "me-\(UUID())@example.com"
        )
        try await TestDatabase.withConnection { conn in
            try await seedAccount(account, db: conn)
            let rule = try await StackStore.create(
                accountId: account.id, name: "工作", kind: .keyword, value: "发票", db: conn
            )

            let app = Application(router: makeRouter(db: conn))
            try await app.test(.router) { client in
                let body = """
                    {"name":"报销"}
                    """
                try await client.execute(
                    uri: "/api/stacks/\(rule.id.uuidString)?accountId=\(account.id.uuidString)",
                    method: .patch, body: ByteBuffer(string: body)
                ) { response in
                    XCTAssertEqual(response.status, .ok)
                    let decoded = try Self.iso8601Decoder().decode(
                        StackUpdateResponse.self, from: Data(buffer: response.body)
                    )
                    XCTAssertEqual(decoded.stack.rule.name, "报销")
                    XCTAssertEqual(decoded.stack.rule.id, rule.id)
                    // The fields the user did not touch are still there.
                    XCTAssertEqual(decoded.stack.rule.kind, .keyword)
                    XCTAssertEqual(decoded.stack.rule.value, "发票")
                }
            }

            let stored = try await StackStore.listStackRule(
                id: rule.id, accountId: account.id, db: conn
            )
            XCTAssertEqual(stored?.name, "报销", "the rename must be persisted")
        }
    }

    /// Changing the value changes *what the group matches*. A group whose
    /// keyword is wrong matches the wrong mail, so this is the edit that the
    /// user most needs and the one the old one-way door made impossible.
    func test_patch_changesTheValue() async throws {
        let account = makeAccount(
            oauthUser: "stack-update-\(UUID().uuidString)",
            email: "me-\(UUID())@example.com"
        )
        try await TestDatabase.withConnection { conn in
            try await seedAccount(account, db: conn)
            let rule = try await StackStore.create(
                accountId: account.id, name: "财务", kind: .keyword, value: "发票", db: conn
            )

            let app = Application(router: makeRouter(db: conn))
            try await app.test(.router) { client in
                let body = """
                    {"value":"合同"}
                    """
                try await client.execute(
                    uri: "/api/stacks/\(rule.id.uuidString)?accountId=\(account.id.uuidString)",
                    method: .patch, body: ByteBuffer(string: body)
                ) { response in
                    XCTAssertEqual(response.status, .ok)
                    let decoded = try Self.iso8601Decoder().decode(
                        StackUpdateResponse.self, from: Data(buffer: response.body)
                    )
                    XCTAssertEqual(decoded.stack.rule.value, "合同")
                    XCTAssertEqual(decoded.stack.rule.name, "财务", "the name was not touched")
                }
            }

            let stored = try await StackStore.listStackRule(
                id: rule.id, accountId: account.id, db: conn
            )
            XCTAssertEqual(stored?.value, "合同", "the new match value must be persisted")
        }
    }

    /// The kind can change too: a group that matched a sender becomes one
    /// that matches a keyword. Without this, "I picked the wrong type" would
    /// be the one mistake the editor still could not fix.
    func test_patch_changesTheKind() async throws {
        let account = makeAccount(
            oauthUser: "stack-update-\(UUID().uuidString)",
            email: "me-\(UUID())@example.com"
        )
        try await TestDatabase.withConnection { conn in
            try await seedAccount(account, db: conn)
            let rule = try await StackStore.create(
                accountId: account.id, name: "收件", kind: .sender,
                value: "{{EMAIL_9f0f8816}}", db: conn
            )

            let app = Application(router: makeRouter(db: conn))
            try await app.test(.router) { client in
                let body = """
                    {"kind":"keyword","value":"通知"}
                    """
                try await client.execute(
                    uri: "/api/stacks/\(rule.id.uuidString)?accountId=\(account.id.uuidString)",
                    method: .patch, body: ByteBuffer(string: body)
                ) { response in
                    XCTAssertEqual(response.status, .ok)
                    let decoded = try Self.iso8601Decoder().decode(
                        StackUpdateResponse.self, from: Data(buffer: response.body)
                    )
                    XCTAssertEqual(decoded.stack.rule.kind, .keyword)
                    XCTAssertEqual(decoded.stack.rule.value, "通知")
                }
            }
        }
    }

    /// An update that carries nothing must not damage the row, and must not
    /// be a syntax error either. "PATCH with an empty body" is a client bug,
    /// not a server error — but it must leave the group alone.
    func test_patch_withNoFields_isANoOp() async throws {
        let account = makeAccount(
            oauthUser: "stack-update-\(UUID().uuidString)",
            email: "me-\(UUID())@example.com"
        )
        try await TestDatabase.withConnection { conn in
            try await seedAccount(account, db: conn)
            let rule = try await StackStore.create(
                accountId: account.id, name: "工作", kind: .keyword, value: "发票", db: conn
            )

            let app = Application(router: makeRouter(db: conn))
            try await app.test(.router) { client in
                let body = "{}"
                try await client.execute(
                    uri: "/api/stacks/\(rule.id.uuidString)?accountId=\(account.id.uuidString)",
                    method: .patch, body: ByteBuffer(string: body)
                ) { response in
                    XCTAssertEqual(response.status, .ok)
                    let decoded = try Self.iso8601Decoder().decode(
                        StackUpdateResponse.self, from: Data(buffer: response.body)
                    )
                    XCTAssertEqual(decoded.stack.rule.name, "工作")
                    XCTAssertEqual(decoded.stack.rule.value, "发票")
                }
            }
        }
    }

    // MARK: - The tenant boundary

    /// Another account's group id must not be writable.
    ///
    /// This is the whole reason the update carries `account_id` in its WHERE
    /// clause. A 404 — not a 403 and not a silent success — because the
    /// client must not be able to tell "this id does not exist" from "this id
    /// belongs to someone else": either answer would confirm that the other
    /// account's group exists.
    func test_patch_onAnotherAccountsGroup_isRefused() async throws {
        let owner = makeAccount(
            oauthUser: "stack-update-owner-\(UUID().uuidString)",
            email: "owner-\(UUID())@example.com"
        )
        let intruder = makeAccount(
            oauthUser: "stack-update-intruder-\(UUID().uuidString)",
            email: "intruder-\(UUID())@example.com"
        )
        try await TestDatabase.withConnection { conn in
            try await seedAccount(owner, db: conn)
            try await seedAccount(intruder, db: conn)
            let rule = try await StackStore.create(
                accountId: owner.id, name: "工作", kind: .keyword, value: "发票", db: conn
            )

            let app = Application(router: makeRouter(db: conn))
            try await app.test(.router) { client in
                let body = """
                    {"name":"被偷走了"}
                    """
                try await client.execute(
                    uri: "/api/stacks/\(rule.id.uuidString)?accountId=\(intruder.id.uuidString)",
                    method: .patch, body: ByteBuffer(string: body)
                ) { response in
                    XCTAssertEqual(response.status, .notFound)
                    XCTAssertEqual(
                        try Self.errorCode(from: response.body), "unknown-stack"
                    )
                }
            }

            // The refusal must be a refusal: the owner's row is untouched.
            let stored = try await StackStore.listStackRule(
                id: rule.id, accountId: owner.id, db: conn
            )
            XCTAssertEqual(stored?.name, "工作", "another account renamed the group")
        }
    }

    /// A group that does not exist at all is the same 404 — the two cases
    /// are indistinguishable from outside, and that is the point.
    func test_patch_onAnUnknownId_isNotFound() async throws {
        let account = makeAccount(
            oauthUser: "stack-update-\(UUID().uuidString)",
            email: "me-\(UUID())@example.com"
        )
        try await TestDatabase.withConnection { conn in
            try await seedAccount(account, db: conn)
            let app = Application(router: makeRouter(db: conn))
            try await app.test(.router) { client in
                let body = """
                    {"name":"x"}
                    """
                try await client.execute(
                    uri: "/api/stacks/\(UUID().uuidString)?accountId=\(account.id.uuidString)",
                    method: .patch, body: ByteBuffer(string: body)
                ) { response in
                    XCTAssertEqual(response.status, .notFound)
                }
            }
        }
    }

    // MARK: - The validation an update has to share with create

    /// An empty name is refused, exactly as it is on create. A group with no
    /// name has nothing for the sidebar row to show.
    func test_patch_withAnEmptyName_isBadRequest() async throws {
        let account = makeAccount(
            oauthUser: "stack-update-\(UUID().uuidString)",
            email: "me-\(UUID())@example.com"
        )
        try await TestDatabase.withConnection { conn in
            try await seedAccount(account, db: conn)
            let rule = try await StackStore.create(
                accountId: account.id, name: "工作", kind: .keyword, value: "发票", db: conn
            )

            let app = Application(router: makeRouter(db: conn))
            try await app.test(.router) { client in
                let body = """
                    {"name":""}
                    """
                try await client.execute(
                    uri: "/api/stacks/\(rule.id.uuidString)?accountId=\(account.id.uuidString)",
                    method: .patch, body: ByteBuffer(string: body)
                ) { response in
                    XCTAssertEqual(response.status, .badRequest)
                    XCTAssertEqual(try Self.errorCode(from: response.body), "invalid-name")
                }
            }
        }
    }

    /// A whitespace-only name is an empty name: the value is trimmed before
    /// it is checked, so "   " cannot become a group called "   ".
    func test_patch_withABlankName_isBadRequest() async throws {
        let account = makeAccount(
            oauthUser: "stack-update-\(UUID().uuidString)",
            email: "me-\(UUID())@example.com"
        )
        try await TestDatabase.withConnection { conn in
            try await seedAccount(account, db: conn)
            let rule = try await StackStore.create(
                accountId: account.id, name: "工作", kind: .keyword, value: "发票", db: conn
            )

            let app = Application(router: makeRouter(db: conn))
            try await app.test(.router) { client in
                let body = """
                    {"name":"   "}
                    """
                try await client.execute(
                    uri: "/api/stacks/\(rule.id.uuidString)?accountId=\(account.id.uuidString)",
                    method: .patch, body: ByteBuffer(string: body)
                ) { response in
                    XCTAssertEqual(response.status, .badRequest)
                    XCTAssertEqual(try Self.errorCode(from: response.body), "invalid-name")
                }
            }
        }
    }

    /// The value has the same bounds it has on create: non-empty, and at
    /// most 200 characters. A group can never be edited into a shape it could
    /// not have been created in.
    func test_patch_withATooLongValue_isBadRequest() async throws {
        let account = makeAccount(
            oauthUser: "stack-update-\(UUID().uuidString)",
            email: "me-\(UUID())@example.com"
        )
        try await TestDatabase.withConnection { conn in
            try await seedAccount(account, db: conn)
            let rule = try await StackStore.create(
                accountId: account.id, name: "工作", kind: .keyword, value: "发票", db: conn
            )

            let app = Application(router: makeRouter(db: conn))
            try await app.test(.router) { client in
                let long = String(repeating: "a", count: 201)
                let body = """
                    {"value":"\(long)"}
                    """
                try await client.execute(
                    uri: "/api/stacks/\(rule.id.uuidString)?accountId=\(account.id.uuidString)",
                    method: .patch, body: ByteBuffer(string: body)
                ) { response in
                    XCTAssertEqual(response.status, .badRequest)
                    XCTAssertEqual(try Self.errorCode(from: response.body), "invalid-value")
                }
            }
        }
    }

    /// An unknown match type is refused. The column has a CHECK constraint
    /// (`kind IN ('sender','keyword')`), so letting an unknown kind through
    /// would be a 500 from the database rather than a 400 from the route.
    func test_patch_withABadKind_isBadRequest() async throws {
        let account = makeAccount(
            oauthUser: "stack-update-\(UUID().uuidString)",
            email: "me-\(UUID())@example.com"
        )
        try await TestDatabase.withConnection { conn in
            try await seedAccount(account, db: conn)
            let rule = try await StackStore.create(
                accountId: account.id, name: "工作", kind: .keyword, value: "发票", db: conn
            )

            let app = Application(router: makeRouter(db: conn))
            try await app.test(.router) { client in
                let body = """
                    {"kind":"recipient"}
                    """
                try await client.execute(
                    uri: "/api/stacks/\(rule.id.uuidString)?accountId=\(account.id.uuidString)",
                    method: .patch, body: ByteBuffer(string: body)
                ) { response in
                    XCTAssertEqual(response.status, .badRequest)
                    XCTAssertEqual(try Self.errorCode(from: response.body), "invalid-kind")
                }
            }

            // The refused write must not have landed.
            let stored = try await StackStore.listStackRule(
                id: rule.id, accountId: account.id, db: conn
            )
            XCTAssertEqual(stored?.kind, .keyword)
        }
    }

    /// A malformed id is the client's bug, and it is answered before the
    /// account scope is even consulted.
    func test_patch_withAMalformedId_isBadRequest() async throws {
        let account = makeAccount(
            oauthUser: "stack-update-\(UUID().uuidString)",
            email: "me-\(UUID())@example.com"
        )
        try await TestDatabase.withConnection { conn in
            try await seedAccount(account, db: conn)
            let app = Application(router: makeRouter(db: conn))
            try await app.test(.router) { client in
                let body = """
                    {"name":"x"}
                    """
                try await client.execute(
                    uri: "/api/stacks/not-a-uuid?accountId=\(account.id.uuidString)",
                    method: .patch, body: ByteBuffer(string: body)
                ) { response in
                    XCTAssertEqual(response.status, .badRequest)
                    XCTAssertEqual(
                        try Self.errorCode(from: response.body), "malformed-stackId"
                    )
                }
            }
        }
    }

    /// A missing account scope is refused for the same reason the delete
    /// refuses it: without it, the route has no idea whose group it is
    /// editing.
    func test_patch_withoutAnAccountId_isBadRequest() async throws {
        let account = makeAccount(
            oauthUser: "stack-update-\(UUID().uuidString)",
            email: "me-\(UUID())@example.com"
        )
        try await TestDatabase.withConnection { conn in
            try await seedAccount(account, db: conn)
            let rule = try await StackStore.create(
                accountId: account.id, name: "工作", kind: .keyword, value: "发票", db: conn
            )

            let app = Application(router: makeRouter(db: conn))
            try await app.test(.router) { client in
                let body = """
                    {"name":"x"}
                    """
                try await client.execute(
                    uri: "/api/stacks/\(rule.id.uuidString)",
                    method: .patch, body: ByteBuffer(string: body)
                ) { response in
                    XCTAssertEqual(response.status, .badRequest)
                    XCTAssertEqual(
                        try Self.errorCode(from: response.body), "malformed-accountId"
                    )
                }
            }
        }
    }
}
