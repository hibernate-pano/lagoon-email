import Foundation
import LagoonKit

/// Loads the inline (`cid:`) images of one message.
///
/// ## Why this is a separate type
///
/// It is a plain, non-isolated enum so that the *request* behaviour — how
/// many requests are in flight at once — can be tested directly, without a
/// `View` and without a running server. A concurrency cap that can only be
/// observed through a SwiftUI view is a cap nobody will ever check.
enum InlineImageLoader {
    /// How many inline-image requests may be in flight at once.
    ///
    /// ## Why a cap at all
    ///
    /// The old code fanned every inline image into a `withTaskGroup` with no
    /// limit, so a marketing mail with 20 images opened 20 simultaneous
    /// requests — and each one re-fetched and re-parsed the **whole
    /// message** on the server, so 20 requests meant 20 full-message IMAP
    /// fetches competing for the same connection.
    ///
    /// ## Why four
    ///
    /// Four is where the pipe is full without the queue being long: the
    /// user's own loopback server handles four concurrent requests without
    /// any of them queueing behind the others, and the rest wait their turn
    /// instead of piling on. A bigger cap buys no measurable speed (the
    /// server was the bottleneck and it holds one IMAP connection) and
    /// costs responsiveness — with 20 in flight, the first image could not
    /// be drawn until 19 others had been negotiated.
    static let concurrency = 4

    /// One image that arrived.
    struct FetchedImage: Sendable {
        /// The server's per-message part id — the cache's key.
        let attachmentId: String
        /// The lower-cased Content-ID — the HTML renderer's key.
        let key: String
        let data: Data
    }

    /// What a load produced.
    struct LoadResult: Sendable {
        /// The images that arrived.
        let fetched: [FetchedImage]
        /// The images that did not.
        let failedKeys: [String]
        /// Why the one-shot route failed, if it did. nil means it did not
        /// fail — including the case where it was never tried because the
        /// cache already had everything.
        let batchFailureReason: String?
    }

    /// Load the inline images of one message.
    ///
    /// ## The order of business
    ///
    /// 1. **The one-shot route** answers with every image in a single
    ///    response. This is the path a current server takes: one round trip
    ///    instead of N, and one message parse on the server instead of N.
    /// 2. **The cache** answers for images already fetched in this session.
    ///    Re-opening a mail the user has read once costs nothing.
    /// 3. **The per-image fallback** is what an old server gets, and it is
    ///    the path that is *capped*: at most `concurrency` requests in
    ///    flight, and never more.
    ///
    /// The cap is on the fallback path only. The one-shot route is a single
    /// request by construction, so it needs no cap — and capping it would be
    /// meaningless.
    ///
    /// - Parameters:
    ///   - images: the attachments to load, with the lower-cased Content-ID
    ///     each one answers to.
    ///   - cached: the bytes already known, keyed by attachment id.
    ///     A plain snapshot rather than a closure over the cache itself: the
    ///     cache is `@MainActor`-isolated, and a `@Sendable` closure cannot
    ///     reach it. The snapshot is also the honest shape — the loader
    ///     decides what is missing once, from one read of the cache.
    ///   - fetchAll: the one-shot route. Throws when the server does not
    ///     have it, or could not be reached.
    ///   - fetchOne: the per-image fallback.
    static func load(
        images: [(attachment: Attachment, key: String)],
        cached: [String: Data],
        fetchAll: @escaping @Sendable () async throws -> [String: Data],
        fetchOne: @escaping @Sendable (Attachment) async throws -> Data
    ) async -> LoadResult {
        guard !images.isEmpty else {
            return LoadResult(fetched: [], failedKeys: [], batchFailureReason: nil)
        }

        var fetched: [FetchedImage] = []
        var failedKeys: [String] = []
        var batchFailureReason: String?

        // The cache first: an image already known is not fetched again.
        var outstanding: [(attachment: Attachment, key: String)] = []
        for image in images {
            if let data = cached[image.attachment.id] {
                fetched.append(FetchedImage(
                    attachmentId: image.attachment.id,
                    key: image.key,
                    data: data
                ))
            } else {
                outstanding.append(image)
            }
        }
        guard !outstanding.isEmpty else {
            return LoadResult(
                fetched: fetched,
                failedKeys: failedKeys,
                batchFailureReason: batchFailureReason
            )
        }

        // The one-shot route: one request for every remaining image.
        do {
            let response = try await fetchAll()
            var served = Set<String>()
            for image in outstanding {
                guard let data = response[image.key] else { continue }
                served.insert(image.key)
                fetched.append(FetchedImage(
                    attachmentId: image.attachment.id,
                    key: image.key,
                    data: data
                ))
            }
            // Whatever the server did not have (or refused to send, past
            // its own caps) is fetched the old way, one at a time up to the
            // concurrency cap. A partial answer is not a failure.
            let missing = outstanding.filter { !served.contains($0.key) }
            if !missing.isEmpty {
                let (arrived, failed) = await fetch(
                    images: missing,
                    fetchOne: fetchOne
                )
                fetched.append(contentsOf: arrived)
                failedKeys.append(contentsOf: failed)
            }
        } catch {
            // A server that predates this route answers 404. So does a
            // server that could not reach the mailbox. Either way the
            // per-image path is the right fallback — and the reason is
            // *kept*, not swallowed, so the banner can say why the images
            // are missing instead of leaving the user to guess.
            batchFailureReason = String(describing: error)
            let (arrived, failed) = await fetch(
                images: outstanding,
                fetchOne: fetchOne
            )
            fetched.append(contentsOf: arrived)
            failedKeys.append(contentsOf: failed)
        }

        return LoadResult(
            fetched: fetched,
            failedKeys: failedKeys,
            batchFailureReason: batchFailureReason
        )
    }

    /// The fallback path: one request per image, with a hard cap on how
    /// many are in flight at once.
    ///
    /// ## Why the cap bounds *requests*, not just tasks
    ///
    /// A cap on the number of *tasks* would not bound the number of
    /// *requests* if a task could outlive its request — but here a task does
    /// not finish until its request has, so "tasks in flight" and
    /// "requests in flight" are the same number. The window below holds at
    /// most `concurrency` tasks alive at any moment, and each alive task
    /// is inside its request, so at most `concurrency` requests exist.
    ///
    /// The `URLSession` does not save us here: its default limit is 6
    /// connections per host, which is *higher* than the cap we want, so
    /// relying on it would have meant a 20-image mail still opening 6
    /// requests at once.
    ///
    /// - Returns: the images that arrived, and the keys of the ones that
    ///   did not.
    static func fetch(
        images: [(attachment: Attachment, key: String)],
        fetchOne: @escaping @Sendable (Attachment) async throws -> Data
    ) async -> (arrived: [FetchedImage], failedKeys: [String]) {
        var arrived: [FetchedImage] = []
        var failedKeys: [String] = []
        guard !images.isEmpty else { return (arrived, failedKeys) }

        // Each task carries its own (attachmentId, key) pair back, rather
        // than the caller looking the id up by key afterwards. Two parts of
        // one message can share a Content-ID (senders do this), and a
        // lookup by key would then attach the bytes to whichever came
        // first — caching one image under the other's id.
        await withTaskGroup(of: (String, String, Data?).self) { group in
            var iterator = images.makeIterator()
            // Prime the window with the first `concurrency` images.
            for _ in 0..<min(concurrency, images.count) {
                guard let next = iterator.next() else { break }
                group.addTask {
                    let data = try? await fetchOne(next.attachment)
                    return (next.attachment.id, next.key, data)
                }
            }
            // One slot frees as one result arrives; the next image takes
            // it. The window therefore never holds more than `concurrency`
            // tasks — and, because a task does not finish until its
            // request has, never more than that many requests either.
            for await (attachmentId, key, data) in group {
                if let data {
                    arrived.append(FetchedImage(
                        attachmentId: attachmentId,
                        key: key,
                        data: data
                    ))
                } else {
                    failedKeys.append(key)
                }
                if let next = iterator.next() {
                    group.addTask {
                        let data = try? await fetchOne(next.attachment)
                        return (next.attachment.id, next.key, data)
                    }
                }
            }
        }
        return (arrived, failedKeys)
    }

}
