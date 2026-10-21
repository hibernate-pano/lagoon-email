import Foundation

/// A small in-memory cache for inline (`cid:`) image bytes, keyed by
/// attachment id.
///
/// ## Why a cache at all
///
/// The body of a message is cached **on the server** (`message_bodies`), but
/// the inline images were not: the client fetched every image again on every
/// open of the same mail. Re-opening a mail the user had already read once
/// re-issued N HTTP requests for bytes that had not changed — pure waste on
/// the user's own loopback server, and the reason "open the same mail twice"
/// felt slower than "open it once".
///
/// ## Why in-memory, and why cleared on launch
///
/// The bytes are **mail content**. The product's own storage rule (§6.6
/// rule 5) is that body text never sits in the clear on disk, and the
/// server seals the body at rest for exactly that reason. A disk-backed
/// image cache would be a plaintext copy of mail content outside that
/// guarantee, so the cache is memory-only: it lives as long as the process
/// and is gone when the app quits. That is the same lifetime the HTML
/// renderer already has for the document it is showing.
///
/// The cache is therefore a *session* cache, not a *store*: it makes
/// re-opening a mail within one app session free, and it deliberately does
/// not make it free across launches. That is the honest trade — a
/// persistent cache would need the same sealing treatment as the body, and
/// the body already has it.
///
/// ## What is keyed
///
/// The **attachment id** (the server's stable per-message part id), not the
/// Content-ID. Two different messages can legitimately use the same
/// `Content-ID` (`logo@company.com` is the classic), so keying by
/// Content-ID would let one mail's logo appear in another mail. The
/// attachment id is unique per message *and* per part, so it cannot
/// collide across mail either.
@MainActor
final class InlineImageCache {
    static let shared = InlineImageCache()

    /// attachment id → the image bytes.
    private var store: [String: Data] = [:]

    /// A hard ceiling on how many images are kept. A mail with 20 inline
    /// images is normal; a user walking through a hundred of them is not,
    /// and an unbounded cache would grow with every mail the user opens.
    /// The cap is generous enough that the realistic case never evicts, and
    /// small enough that the memory it can hold stays in the low tens of
    /// megabytes.
    private static let maxEntries = 200

    private init() {}

    /// The bytes for `attachmentId`, if they were already fetched.
    func cached(_ attachmentId: String) -> Data? {
        store[attachmentId]
    }

    /// The bytes known for the given attachment ids, and nothing else.
    ///
    /// A *snapshot* rather than a live view: the loader that consumes it
    /// runs off the main actor, and the cache is `@MainActor`-isolated, so
    /// it takes a copy rather than a reference. Copying also means the
    /// loader sees a consistent state — no image can appear or vanish
    /// halfway through its decision.
    func snapshot(for attachmentIds: [String]) -> [String: Data] {
        var out: [String: Data] = [:]
        for id in attachmentIds {
            if let data = store[id] {
                out[id] = data
            }
        }
        return out
    }

    /// Remember the bytes for `attachmentId`.
    ///
    /// The oldest entry is dropped when the cache is full. A dictionary has
    /// no order, so the eviction is by insertion counter rather than by
    /// "least recently used" — the honest label for it is "some entry", and
    /// pretending otherwise would be a lie in the code.
    func store(_ data: Data, for attachmentId: String) {
        if store.count >= Self.maxEntries, store[attachmentId] == nil {
            if let victim = insertionOrder.first {
                store.removeValue(forKey: victim)
                insertionOrder.removeFirst()
            }
        }
        store[attachmentId] = data
        insertionOrder.removeAll { $0 == attachmentId }
        insertionOrder.append(attachmentId)
    }

    /// Insertion order of the keys, oldest first. Kept beside the store
    /// because a `Dictionary` is unordered and eviction needs an order.
    private var insertionOrder: [String] = []

    /// Forget one attachment's bytes, so the next open fetches them again.
    ///
    /// Used by the retry path: without dropping the entry, "reload images"
    /// would replay the cached result and change nothing.
    func remove(_ attachmentId: String) {
        store.removeValue(forKey: attachmentId)
        insertionOrder.removeAll { $0 == attachmentId }
    }

    /// Forget everything. Exposed so a test can start from a known state.
    func removeAll() {
        store.removeAll()
        insertionOrder.removeAll()
    }
}
