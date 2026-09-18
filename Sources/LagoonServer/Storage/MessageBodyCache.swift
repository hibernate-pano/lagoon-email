import Foundation

/// In-memory cache of parsed message bodies (M1.6).
///
/// Re-parsing a 5 MB email with several attachments takes a few hundred
/// milliseconds on the IMAP path (BASE64 decode, multipart walk) and the
/// same on the Gmail path. Opening the same email twice in a row —
/// e.g. swipe-archive one tab, glance at the next, swipe back — would
/// re-pay that cost every time. The cache keys on `(accountId, remoteId)`
/// and evicts after `ttl`, so a re-fetch inside the 60s window is a
/// dictionary lookup.
///
/// The cache only stores the post-`FetchedBody` shape (text, html,
/// attachment metadata, hasMore) — attachment *bytes* never go in here,
/// and `fetchAttachment` does not consult the cache. That keeps the
/// memory ceiling proportional to message count, not message size.
actor MessageBodyCache {
    static let shared = MessageBodyCache()

    private struct Entry {
        let body: FetchedBody
        let storedAt: Date
    }

    private var entries: [Key: Entry] = [:]
    private let ttl: TimeInterval

    /// 60s window is a balance: long enough that scrolling back and
    /// forth in a triage session stays warm, short enough that a re-sync
    /// (e.g. user manually marks as read) does not serve stale metadata.
    init(ttl: TimeInterval = 60) {
        self.ttl = ttl
    }

    func get(accountId: UUID, remoteId: String) -> FetchedBody? {
        let key = Key(accountId: accountId, remoteId: remoteId)
        guard let entry = entries[key] else { return nil }
        if Date().timeIntervalSince(entry.storedAt) > ttl {
            entries.removeValue(forKey: key)
            return nil
        }
        return entry.body
    }

    func put(_ body: FetchedBody, accountId: UUID, remoteId: String) {
        entries[Key(accountId: accountId, remoteId: remoteId)] = Entry(
            body: body,
            storedAt: Date()
        )
    }

    func invalidate(accountId: UUID, remoteId: String) {
        entries.removeValue(forKey: Key(accountId: accountId, remoteId: remoteId))
    }

    func clear() {
        entries.removeAll()
    }

    private struct Key: Hashable {
        let accountId: UUID
        let remoteId: String
    }
}
