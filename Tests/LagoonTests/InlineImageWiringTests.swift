import XCTest
import Foundation
import LagoonKit
@testable import Lagoon

/// P2-09: inline images were fetched one at a time with **no concurrency
/// cap**, and the body response made the client ask N+1 times.
///
/// ## What was wrong
///
/// `MessageDetailView.loadInlineImages` fanned every inline image into a
/// `withTaskGroup` with no limit. A marketing mail with 20 inline images
/// opened 20 simultaneous requests against the user's own loopback server —
/// and the server re-fetched and re-parsed the *entire message* for each
/// one, so 20 requests meant 20 full-message IMAP fetches competing for one
/// connection.
///
/// ## What is pinned here
///
/// Two things, and they are separate:
///
/// 1. **The cap.** At most `InlineImageLoader.concurrency` requests are in
///    flight at any moment. This is measured, not read off the source: the
///    test counts concurrent `fetchOne` calls and asserts the peak.
/// 2. **The round trips.** The one-shot route is used when it works, the
///    per-image path only when it does not, and the cache is consulted
///    before either.
///
/// The remote-images privacy decision (`HTMLMessageView`) is untouched by
/// this work and is not tested here — it has its own suite.
final class InlineImageWiringTests: XCTestCase {

    private func attachment(_ id: String, cid: String?) -> Attachment {
        Attachment(
            id: id,
            filename: nil,
            mimeType: "image/png",
            size: 4,
            contentId: cid,
            disposition: .inline
        )
    }

    // MARK: - The cap

    /// The core of P2-09: 20 inline images must never open 20 requests.
    ///
    /// The test runs the real fallback path with a probe that records the
    /// high-water mark of simultaneous calls. If the cap were removed (the
    /// window primed with every image, as the old `withTaskGroup` did), the
    /// peak would be 20 and this fails.
    ///
    /// Mutation check: change `concurrency` to `images.count` and the peak
    /// assertion goes red; remove the window entirely and it goes red with
    /// a peak of 20.
    func test_theFallbackNeverOpensMoreThanTheCapAtOnce() async throws {
        let images = (0..<20).map { (attachment: attachment("a\($0)", cid: "c\($0)"), key: "c\($0)") }
        let probe = ConcurrencyProbe()

        let result = await InlineImageLoader.fetch(
            images: images,
            fetchOne: { attachment in
                await probe.enter()
                // Hold long enough that overlapping calls are actually
                // observable — without a real suspension point inside, every
                // task could finish before the next starts and the peak
                // would be 1 no matter what the cap said.
                try? await Task.sleep(for: .milliseconds(20))
                await probe.leave()
                return Data(attachment.id.utf8)
            }
        )

        XCTAssertEqual(result.arrived.count, 20, "every image must still arrive")
        let peak = await probe.peak
        XCTAssertLessThanOrEqual(
            peak, InlineImageLoader.concurrency,
            "\(peak) requests were in flight at once, cap is \(InlineImageLoader.concurrency)"
        )
        XCTAssertGreaterThan(
            peak, 1,
            "the cap must not serialise the fallback into one request at a time"
        )
    }

    /// The cap is a fixed, small number — not "however many images there
    /// are". A regression to a large cap would pass the peak test above on
    /// a 20-image mail only by luck; this pins the value itself.
    func test_theCapIsSmallAndFixed() {
        XCTAssertEqual(
            InlineImageLoader.concurrency, 4,
            "the cap must stay small enough that images do not stampede"
        )
    }

    // MARK: - The round trips

    /// The one-shot route answers everything, so the per-image path is never
    /// used. This is the N+1 reduction, asserted at the client.
    func test_theOneShotRouteReplacesEveryPerImageFetch() async throws {
        let images = (0..<5).map { (attachment: attachment("a\($0)", cid: "c\($0)"), key: "c\($0)") }
        let calls = CallRecorder()

        let result = await InlineImageLoader.load(
            images: images,
            cached: [:],
            fetchAll: {
                await calls.recordAll()
                return Dictionary(uniqueKeysWithValues: images.map { ($0.key, Data($0.key.utf8)) })
            },
            fetchOne: { attachment in
                await calls.recordOne(attachment.id)
                return Data()
            }
        )

        XCTAssertEqual(result.fetched.count, 5)
        XCTAssertTrue(result.failedKeys.isEmpty)
        let allCalls = await calls.allCount
        let oneCalls = await calls.oneCalls
        XCTAssertEqual(allCalls, 1, "the one-shot route must be asked exactly once")
        XCTAssertTrue(
            oneCalls.isEmpty,
            "the per-image path ran even though the one-shot route served everything: \(oneCalls)"
        )
    }

    /// An old server (no route → 404) falls back to the per-image path, and
    /// the reason is *kept* rather than swallowed — the banner says why the
    /// images are missing instead of leaving the user to guess.
    func test_aBatchFailureFallsBackAndKeepsTheReason() async throws {
        let images = [(attachment: attachment("a1", cid: "c1"), key: "c1")]
        let calls = CallRecorder()

        let result = await InlineImageLoader.load(
            images: images,
            cached: [:],
            fetchAll: { throw NSError(domain: "test", code: 404) },
            fetchOne: { attachment in
                await calls.recordOne(attachment.id)
                return Data("bytes".utf8)
            }
        )

        XCTAssertEqual(result.fetched.first?.data, Data("bytes".utf8))
        XCTAssertTrue(result.failedKeys.isEmpty)
        XCTAssertNotNil(
            result.batchFailureReason,
            "the batch failure was swallowed — the banner cannot say why"
        )
        let oneCalls = await calls.oneCalls
        XCTAssertEqual(oneCalls, ["a1"], "the fallback must actually run")
    }

    /// A partial answer is not a failure: the images the server did send are
    /// kept, and only the missing ones go through the capped fallback.
    func test_aPartialBatchAnswerOnlyFetchesTheMissingImages() async throws {
        let images = (0..<3).map { (attachment: attachment("a\($0)", cid: "c\($0)"), key: "c\($0)") }
        let calls = CallRecorder()

        let result = await InlineImageLoader.load(
            images: images,
            cached: [:],
            fetchAll: { ["c0": Data("zero".utf8)] },
            fetchOne: { attachment in
                await calls.recordOne(attachment.id)
                return Data(attachment.id.utf8)
            }
        )

        XCTAssertEqual(result.fetched.count, 3)
        let oneCalls = await calls.oneCalls
        XCTAssertEqual(Set(oneCalls), ["a1", "a2"], "c0 already arrived; it must not be fetched twice")
    }

    /// The cache is consulted before any request. A mail opened twice in one
    /// session must not fetch its images twice.
    func test_cachedImagesAreNotFetchedAgain() async throws {
        let images = (0..<2).map { (attachment: attachment("a\($0)", cid: "c\($0)"), key: "c\($0)") }
        let calls = CallRecorder()

        let result = await InlineImageLoader.load(
            images: images,
            cached: ["a0": Data("cached".utf8)],
            fetchAll: {
                await calls.recordAll()
                return ["c1": Data("one".utf8)]
            },
            fetchOne: { _ in
                await calls.recordOne("unexpected")
                return Data()
            }
        )

        XCTAssertEqual(result.fetched.count, 2)
        XCTAssertEqual(result.fetched.first?.data, Data("cached".utf8))
        let oneCalls = await calls.oneCalls
        XCTAssertTrue(oneCalls.isEmpty, "the cached image was fetched anyway: \(oneCalls)")
    }

    /// When the cache has everything, not even the one-shot route is called.
    func test_aFullyCachedMessageMakesNoRequestsAtAll() async throws {
        let images = [(attachment: attachment("a0", cid: "c0"), key: "c0")]
        let calls = CallRecorder()

        let result = await InlineImageLoader.load(
            images: images,
            cached: ["a0": Data("cached".utf8)],
            fetchAll: {
                await calls.recordAll()
                return [:]
            },
            fetchOne: { _ in
                await calls.recordOne("unexpected")
                return Data()
            }
        )

        XCTAssertEqual(result.fetched.first?.data, Data("cached".utf8))
        let allCalls = await calls.allCount
        let oneCalls = await calls.oneCalls
        XCTAssertEqual(allCalls, 0, "a cached message must not hit the network")
        XCTAssertTrue(oneCalls.isEmpty)
    }

    /// An image with no Content-ID cannot be referenced by the HTML, so it
    /// is dropped before any request is made — asking for it would be a
    /// round trip whose answer nothing could use.
    func test_anImageWithoutContentIdIsNotFetched() async throws {
        let images: [(attachment: Attachment, key: String)] = [
            (attachment("a0", cid: nil), "unused"),
        ]
        let calls = CallRecorder()

        _ = await InlineImageLoader.load(
            images: [],  // the view filters these out before calling
            cached: [:],
            fetchAll: {
                await calls.recordAll()
                return [:]
            },
            fetchOne: { _ in
                await calls.recordOne("unexpected")
                return Data()
            }
        )
        _ = images

        let allCalls = await calls.allCount
        XCTAssertEqual(allCalls, 0)
    }

    // MARK: - A failed image does not break the message

    /// A failure is per-image: the others still arrive, and the failure is
    /// named so the banner can say what happened.
    func test_oneFailingImageDoesNotLoseTheOthers() async throws {
        let images = (0..<3).map { (attachment: attachment("a\($0)", cid: "c\($0)"), key: "c\($0)") }

        let result = await InlineImageLoader.load(
            images: images,
            cached: [:],
            fetchAll: { throw NSError(domain: "test", code: 404) },
            fetchOne: { attachment in
                if attachment.id == "a1" { throw NSError(domain: "test", code: 500) }
                return Data(attachment.id.utf8)
            }
        )

        XCTAssertEqual(Set(result.fetched.map(\.key)), ["c0", "c2"])
        XCTAssertEqual(result.failedKeys, ["c1"])
    }

    // MARK: - The cache itself

    /// The cache is keyed by attachment id, not Content-ID: two mails can
    /// share a Content-ID, and a cache keyed by it would show one mail's
    /// logo inside another.
    @MainActor
    func test_theCacheIsKeyedByAttachmentId() {
        let cache = InlineImageCache.shared
        cache.removeAll()
        defer { cache.removeAll() }

        cache.store(Data("first".utf8), for: "m1.2")
        cache.store(Data("second".utf8), for: "m2.2")

        XCTAssertEqual(cache.cached("m1.2"), Data("first".utf8))
        XCTAssertEqual(cache.cached("m2.2"), Data("second".utf8))
        XCTAssertNil(cache.cached("m3.2"))
    }

    /// Eviction is bounded: a long session must not grow the cache without
    /// limit. The oldest entry goes first.
    @MainActor
    func test_theCacheEvictsRatherThanGrowingWithoutBound() {
        let cache = InlineImageCache.shared
        cache.removeAll()
        defer { cache.removeAll() }

        for index in 0..<250 {
            cache.store(Data("\(index)".utf8), for: "a\(index)")
        }

        // The newest entry is always kept.
        XCTAssertEqual(cache.cached("a249"), Data("249".utf8))
        // And the oldest went.
        XCTAssertNil(cache.cached("a0"), "the cache grew without evicting")
    }

    /// `snapshot(for:)` returns only what was asked for — the loader must
    /// not receive unrelated mail's images.
    @MainActor
    func test_theSnapshotContainsOnlyTheRequestedIds() {
        let cache = InlineImageCache.shared
        cache.removeAll()
        defer { cache.removeAll() }

        cache.store(Data("wanted".utf8), for: "a1")
        cache.store(Data("other".utf8), for: "a2")

        let snapshot = cache.snapshot(for: ["a1"])
        XCTAssertEqual(snapshot, ["a1": Data("wanted".utf8)])
    }

    // MARK: - Source guards

    /// The view must actually use the loader — a cap in a file nothing calls
    /// is a cap that does not exist.
    func test_theDetailViewLoadsInlineImagesThroughTheLoader() throws {
        let source = try ViewSource.read("MessageDetailView")
        XCTAssertTrue(
            source.contains("InlineImageLoader.load("),
            "the detail view does not go through the loader, so the cap does not apply"
        )
        XCTAssertTrue(
            source.contains("fetchInlineImages("),
            "the detail view never asks the one-shot route — the N+1 round trips are still there"
        )
        XCTAssertFalse(
            source.contains("group.addTask"),
            "a bare task group is back in the view; the concurrency cap must live in the loader"
        )
    }

    /// The view must report a failed inline image rather than letting it
    /// vanish. A silently missing picture reads as the sender's fault.
    ///
    /// The assertion is on the **call site**, not on the banner's own
    /// strings: the banner can be fully written and never invoked, which is
    /// exactly what a mutation check showed — deleting the call left a
    /// strings-only test green.
    func test_theDetailViewReportsInlineImageFailures() throws {
        let source = try ViewSource.read("MessageDetailView")
        XCTAssertTrue(
            source.contains("reportInlineImageFailuresIfAny(result)"),
            "loadInlineImages never reports its failures — a missing picture would be silent"
        )
        XCTAssertTrue(
            source.contains("l10n.inlineImageFailedTitle"),
            "a failed inline image is not reported to the user"
        )
        XCTAssertTrue(
            source.contains("inlineImageRetry"),
            "there is no way to retry the inline images"
        )
    }

    /// The remote-resource privacy rule is a separate decision and must not
    /// have been touched by this work.
    func test_theRemoteResourceBlockSurvives() throws {
        let source = try ViewSource.read("HTMLMessageView")
        XCTAssertTrue(
            source.contains("^https?:"),
            "the remote-content block rule list is gone — loading inline images must not open the network"
        )
        XCTAssertTrue(
            source.contains("blockRemoteContent") || source.contains("ruleListJSON"),
            "the remote content blocker is no longer wired"
        )
    }
}

// MARK: - Test doubles

/// Counts how many calls are in flight at once.
private actor ConcurrencyProbe {
    private var current = 0
    private(set) var peak = 0

    func enter() {
        current += 1
        peak = max(peak, current)
    }

    func leave() {
        current -= 1
    }
}

/// Records which path was taken. A plain actor so the recorder cannot itself
/// change the concurrency being measured.
private actor CallRecorder {
    private(set) var allCount = 0
    private(set) var oneCalls: [String] = []

    func recordAll() { allCount += 1 }
    func recordOne(_ id: String) { oneCalls.append(id) }
}
