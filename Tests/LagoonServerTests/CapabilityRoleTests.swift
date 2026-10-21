import XCTest
import Foundation
import Logging
import LagoonKit
@testable import LagoonServer

/// P2-10: the server knew which verbs it could not perform — the trash
/// resolver refused with `trashUnavailable`, the permanent-delete path
/// refused without UIDPLUS, the Sent route answered 404 — but none of that
/// was ever published. The client learned it by clicking.
///
/// These tests pin the other half of the fix: the capability probe must
/// agree with the resolvers. A probe that said "no trash folder" while the
/// resolver would have found one would disable delete for a working
/// account — a worse bug than the one this item fixes.
final class CapabilityRoleTests: XCTestCase {
    private static let key = TokenKeyFixture.freshKey()

    private func makeProvider(
        transport: ScriptedTransport
    ) throws -> (provider: IMAPProvider, account: Account) {
        let account = Account(
            id: UUID(),
            provider: .qq,
            oauthUser: "{{EMAIL_6a15e8cd839f8663}}",
            email: "{{EMAIL_6a15e8cd839f8663}}",
            credentials: try CredentialVault.seal(
                .imap(username: "{{EMAIL_6a15e8cd839f8663}}", authCode: "authcode0123456789")
            )
        )
        let provider = IMAPProvider(
            account: account,
            db: nil,
            logger: Logger(label: "capability-role-tests"),
            reconcilesInbox: false,
            transportFactory: { transport }
        )
        return (provider, account)
    }

    private func tag(_ number: Int) -> String { String(format: "A%04d", number) }

    private func scriptHandshake(
        _ transport: ScriptedTransport,
        capabilities: String = "IMAP4rev1 ID IDLE MOVE AUTH=PLAIN"
    ) async {
        await transport.enqueue("* OK Lagoon ready")
        await transport.enqueue("\(tag(1)) OK AUTHENTICATE completed")
        await transport.enqueue("* CAPABILITY \(capabilities)")
        await transport.enqueue("\(tag(2)) OK CAPABILITY completed")
        await transport.enqueue("\(tag(3)) OK ID completed")
    }

    private func scriptList(
        _ transport: ScriptedTransport,
        number: Int,
        mailboxes: [(name: String, attribute: String?)]
    ) async {
        for mailbox in mailboxes {
            let attributes = mailbox.attribute.map { "\\HasNoChildren \($0)" } ?? "\\HasNoChildren"
            await transport.enqueue(#"* LIST (\#(attributes)) "/" "\#(mailbox.name)""#)
        }
        await transport.enqueue("\(tag(number)) OK LIST completed")
    }

    // MARK: - The probe reports what the resolvers would find

    /// A QQ-shaped mailbox must report a trash folder and a sent folder.
    func test_theProbeReportsTheTrashAndSentRoles() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport)
            await scriptHandshake(transport, capabilities: "IMAP4rev1 ID IDLE MOVE UIDPLUS AUTH=PLAIN")
            await scriptList(transport, number: 4, mailboxes: [
                (name: "INBOX", attribute: nil),
                (name: "Archive", attribute: "\\Archive"),
                (name: "Sent Messages", attribute: nil),
                (name: "Deleted Messages", attribute: nil),
            ])
            // The archive resolver may CREATE when it finds nothing; here it
            // found one, so no CREATE is queued.

            let capabilities = await provider.capabilities()

            let resolved = try XCTUnwrap(capabilities, "the negotiation completed")
            XCTAssertEqual(resolved.trashFolder, true, "Deleted Messages is a trash folder")
            XCTAssertEqual(resolved.sentFolder, true, "Sent Messages is a sent folder")
            XCTAssertEqual(resolved.uidplus, true, "the server advertised UIDPLUS")
            XCTAssertEqual(resolved.archiveFolderName, "Archive", "the server's own name, not a made-up one")
        }
    }

    /// A server with no trash folder must say so.
    ///
    /// This is the answer that turns the delete verb off *before* the click.
    /// If the probe said "yes" here, the client would offer a verb the
    /// server answers 409 to.
    func test_theProbeReportsNoTrashFolder() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport)
            await scriptHandshake(transport)
            await scriptList(transport, number: 4, mailboxes: [
                (name: "INBOX", attribute: nil),
                (name: "Archive", attribute: "\\Archive"),
                (name: "Sent Messages", attribute: nil),
            ])

            let capabilities = await provider.capabilities()

            let resolved = try XCTUnwrap(capabilities)
            XCTAssertEqual(resolved.trashFolder, false, "there is no trash folder here")
            XCTAssertEqual(resolved.sentFolder, true)
        }
    }

    /// A server without UIDPLUS must say so.
    ///
    /// This is what turns 彻底删除 off. It has to be a *settled* answer:
    /// the client is about to make an irreversible decision based on it.
    func test_theProbeReportsNoUIDPlus() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport)
            await scriptHandshake(transport, capabilities: "IMAP4rev1 ID IDLE MOVE AUTH=PLAIN")
            await scriptList(transport, number: 4, mailboxes: [
                (name: "INBOX", attribute: nil),
                (name: "Archive", attribute: "\\Archive"),
            ])

            let capabilities = await provider.capabilities()

            let resolved = try XCTUnwrap(capabilities)
            XCTAssertEqual(resolved.uidplus, false, "no UIDPLUS in the capability list")
        }
    }

    // MARK: - The probe and the resolvers must not drift

    /// A **nested** trash folder must be found by both.
    ///
    /// QQ nests `废纸篓` under the account root in some locales. The
    /// codebase's own `isReservedFolder` already matched on the *leaf*
    /// segment for exactly this reason — but the trash and sent resolvers
    /// matched the full path, so a nested folder was invisible to them.
    ///
    /// A probe that disagreed with the resolver would be worse than either
    /// being wrong alone: the client would disable delete for an account
    /// whose trash folder works perfectly.
    func test_aNestedTrashFolderIsFoundByBothTheProbeAndTheResolver() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport)
            await scriptHandshake(transport, capabilities: "IMAP4rev1 ID IDLE MOVE UIDPLUS AUTH=PLAIN")
            await scriptList(transport, number: 4, mailboxes: [
                (name: "INBOX", attribute: nil),
                (name: "Archive", attribute: "\\Archive"),
                (name: "Sent Messages", attribute: nil),
                (name: "INBOX/废纸篓", attribute: nil),
            ])

            let capabilities = await provider.capabilities()

            let resolved = try XCTUnwrap(capabilities)
            XCTAssertEqual(
                resolved.trashFolder, true,
                "a nested 废纸篓 is still the trash folder — the role is the leaf segment"
            )
        }
    }

    /// A nested sent folder must be found too.
    func test_aNestedSentFolderIsFound() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport)
            await scriptHandshake(transport)
            await scriptList(transport, number: 4, mailboxes: [
                (name: "INBOX", attribute: nil),
                (name: "Archive", attribute: "\\Archive"),
                (name: "INBOX/已发送", attribute: nil),
            ])

            let capabilities = await provider.capabilities()

            let resolved = try XCTUnwrap(capabilities)
            XCTAssertEqual(resolved.sentFolder, true, "a nested 已发送 is still the sent folder")
        }
    }

    /// The SPECIAL-USE attribute wins over the name.
    ///
    /// A server that says "this folder is the trash" is stating the role
    /// outright; a name that merely *looks* like a trash folder is a guess.
    /// The attribute is the stronger signal, and the probe must honour it
    /// the same way the resolver does.
    func test_theSpecialUseAttributeIsHonoured() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport)
            await scriptHandshake(transport)
            await scriptList(transport, number: 4, mailboxes: [
                (name: "INBOX", attribute: nil),
                (name: "Archive", attribute: "\\Archive"),
                (name: "QQ特殊文件夹", attribute: "\\Trash"),
                (name: "Sent Messages", attribute: nil),
            ])

            let capabilities = await provider.capabilities()

            let resolved = try XCTUnwrap(capabilities)
            XCTAssertEqual(resolved.trashFolder, true, "the server stated the role outright")
        }
    }

    /// A folder that merely *contains* a role word is not that role.
    ///
    /// "Trash收集箱" is a user's own folder that happens to contain the
    /// word. Treating it as the trash would file mail into a folder the
    /// user created for something else — and the delete would still "work",
    /// so nothing would ever say it was wrong.
    func test_aFolderThatMerelyContainsTheWordIsNotTheRole() async throws {
        try await TokenKeyFixture.withKeyAsync(Self.key) {
            let transport = ScriptedTransport()
            let (provider, _) = try makeProvider(transport: transport)
            await scriptHandshake(transport)
            await scriptList(transport, number: 4, mailboxes: [
                (name: "INBOX", attribute: nil),
                (name: "Archive", attribute: "\\Archive"),
                (name: "Trash收集箱", attribute: nil),
                (name: "Sent Messages", attribute: nil),
            ])

            let capabilities = await provider.capabilities()

            let resolved = try XCTUnwrap(capabilities)
            XCTAssertEqual(
                resolved.trashFolder, false,
                "a user's own folder is not the trash, even when its name contains the word"
            )
        }
    }
}
