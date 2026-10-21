import Foundation
import LagoonKit

/// A message identified by *where it lives*, not just by its id.
///
/// ## Why the id alone is not enough
///
/// `remoteId` is the message's identity **inside one mailbox**. It is the
/// RFC `Message-ID` when the message has one — and when it does not, the
/// provider falls back to `uid:<n>`, where `n` is an IMAP UID. IMAP UIDs
/// count up independently per mailbox, so account A's `uid:42` and account
/// B's `uid:42` are the same string and different mail.
///
/// Every surface that lists one mailbox at a time can get away with the
/// bare id. A cross-account search cannot: its result list can hold
/// `uid:42` from two mailboxes, and a navigation key of `remoteId` alone
/// resolves to *whichever came first*. The user clicks a hit in their work
/// mailbox and reads their personal one.
///
/// So a search result is addressed by the pair. Everywhere else keeps the
/// bare id, because there it is unambiguous.
struct MessageRef: Hashable, Identifiable {
    let accountId: UUID
    let remoteId: String

    var id: String { "\(accountId.uuidString)|\(remoteId)" }

    init(accountId: UUID, remoteId: String) {
        self.accountId = accountId
        self.remoteId = remoteId
    }

    /// The reference for a search result.
    init(_ message: MessageHeader) {
        self.accountId = message.accountId
        self.remoteId = message.remoteId
    }
}
