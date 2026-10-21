import XCTest
import Foundation
import Logging
import GRDB
import Hummingbird
import HummingbirdTesting
@testable import LagoonKit
@testable import LagoonServer

/// The briefing's background classification and the queue that runs it.
///
/// ## What was wrong
///
/// The background mode fired an unstructured `Task { … }` per request. Every
/// refresh that found unclassified mail started *another* classification, so
/// the calls piled up on the gateway — and splitting one batch into several
/// calls is not free, because every call pays the system prompt again. The
/// task was also invisible: nothing tracked it, and nothing could cancel it.
///
/// The queue bounds the concurrency, merges a submission into the job already
/// waiting for that account, and hands the job's messages back when it does
/// not finish — so a job that dies leaves the next refresh free to ask again.
final class BriefingClassificationQueueTests: XCTestCase {
    private func header(_ id: String, accountId: UUID) -> MessageHeader {
        MessageHeader(
            id: UUID(),
            accountId: accountId,
            remoteId: id,
            threadId: "t-\(id)",
            fromAddress: "sender@example.com",
            fromName: nil,
            subject: "s",
            snippet: nil,
            receivedAt: Date(),
            isRead: false,
            isArchived: false
        )
    }

    private func waitUntil(
        _ condition: @escaping @Sendable () async -> Bool,
        timeout: TimeInterval = 5
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                return await condition()
            }
        }
        return await condition()
    }

    // MARK: - The queue itself

    /// Two jobs for one account never run at the same time.
    ///
    /// This is the pile-up the queue exists to stop: the client refreshes the
    /// briefing every 30 s, and every refresh that found new mail used to
    /// start another classification for the same mailbox.
    func test_twoJobsForOneAccount_neverRunInParallel() async {
        let accountId = UUID()
        let queue = BriefingClassificationQueue(maxConcurrent: 4)
        let recorder = ConcurrencyRecorder()

        func job(_ id: String) -> BriefingClassificationQueue.Job {
            BriefingClassificationQueue.Job(
                accountId: accountId,
                messages: [header(id, accountId: accountId)],
                run: { _ in
                    await recorder.enter()
                    try await Task.sleep(for: .milliseconds(120))
                    await recorder.leave()
                },
                release: { _ in }
            )
        }

        await queue.submit(job("a"))
        await queue.submit(job("b"))

        let done = await waitUntil({ await recorder.finished == 2 })
        XCTAssertTrue(done, "both jobs must run")
        let peak = await recorder.maxConcurrent
        XCTAssertEqual(peak, 1, "one mailbox, one classification at a time")
    }

    /// A second submission for an account that is already waiting is merged
    /// into it, so the model is asked once about all the mail instead of
    /// twice about half of it — which is also twice the system prompt.
    func test_aSecondSubmissionForTheSameAccount_isMergedIntoTheWaitingJob() async {
        let accountId = UUID()
        let other = UUID()
        let queue = BriefingClassificationQueue(maxConcurrent: 1)
        let seenBox = SeenBox()

        // The first job takes the only slot, so the account's own job waits.
        await queue.submit(BriefingClassificationQueue.Job(
            accountId: other,
            messages: [header("blocker", accountId: other)],
            run: { _ in
                try await Task.sleep(for: .milliseconds(150))
            },
            release: { _ in }
        ))
        await queue.submit(BriefingClassificationQueue.Job(
            accountId: accountId,
            messages: [header("first", accountId: accountId)],
            run: { messages in
                await seenBox.append(messages.map(\.remoteId))
            },
            release: { _ in }
        ))
        await queue.submit(BriefingClassificationQueue.Job(
            accountId: accountId,
            messages: [header("second", accountId: accountId)],
            run: { messages in
                await seenBox.append(messages.map(\.remoteId))
            },
            release: { _ in }
        ))

        let done = await waitUntil({ await seenBox.count == 1 })
        XCTAssertTrue(done, "the merged job must run")
        let batches = await seenBox.batches
        XCTAssertEqual(batches.count, 1, "one call, not two")
        XCTAssertEqual(
            Set(batches.first ?? []), ["first", "second"],
            "the call must cover the messages of both submissions"
        )
    }

    /// A job that fails hands its messages back: a message left "in flight"
    /// is a message the briefing silently stops asking about.
    func test_aFailedJob_releasesItsMessages() async {
        let accountId = UUID()
        let queue = BriefingClassificationQueue()
        let released = SeenBox()

        await queue.submit(BriefingClassificationQueue.Job(
            accountId: accountId,
            messages: [header("a", accountId: accountId)],
            run: { _ in throw MailError.unreachable("scripted failure") },
            release: { messages in await released.append(messages.map(\.remoteId)) }
        ))

        let done = await waitUntil({ await released.count == 1 })
        XCTAssertTrue(done, "a failed job must release its messages")
        let releasedIds = await released.batches.first ?? []
        XCTAssertEqual(releasedIds, ["a"])
    }

    /// Cancelling a job stops the running work and hands the messages back.
    func test_cancellingAJob_stopsItAndReleasesItsMessages() async {
        let accountId = UUID()
        let queue = BriefingClassificationQueue()
        let released = SeenBox()
        let recorder = ConcurrencyRecorder()

        let job = BriefingClassificationQueue.Job(
            accountId: accountId,
            messages: [header("a", accountId: accountId)],
            run: { _ in
                await recorder.enter()
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    await recorder.sawCancellation()
                    throw error
                }
                await recorder.leave()
            },
            release: { messages in await released.append(messages.map(\.remoteId)) }
        )
        await queue.submit(job)

        // Let the job start before cancelling it.
        let started = await waitUntil({ await recorder.maxConcurrent == 1 })
        XCTAssertTrue(started)
        await queue.cancel(jobId: job.id)

        let done = await waitUntil({ await released.count == 1 })
        XCTAssertTrue(done, "a cancelled job must release its messages")
        let cancellations = await recorder.cancellations
        XCTAssertEqual(cancellations, 1, "and the running work must actually stop")
    }

    // MARK: - The route

    /// Two refreshes that both have work to do must not classify in
    /// parallel.
    ///
    /// Before the queue, each refresh fired its own unstructured task, so the
    /// gateway saw both calls at once — the same mailbox, the same budget.
    func test_repeatedBriefingRequests_doNotClassifyInParallel() async throws {
        let account = Account(
            id: UUID(),
            provider: .qq,
            oauthUser: "queue-\(UUID().uuidString)",
            email: "queue-\(UUID().uuidString)@qq.com",
            credentials: nil
        )
        let recorder = ConcurrencyRecorder()
        let classifier = RecordingClassifier(recorder: recorder)

        try await TestDatabase.withConnection { conn in
            try await AccountStore.upsert(
                account,
                // Opaque bytes: nothing in this file decrypts the credential
                // blob, and the briefing route never touches it.
                credentials: Data([1, 2, 3]),
                db: conn
            )
            try await seedMessage("m1", accountId: account.id, db: conn)

            let router = Router()
            BriefingRoutes.register(
                on: router,
                db: conn,
                logger: Logger(label: "queue-tests"),
                classifier: classifier,
                classificationMode: .background
            )
            let app = Application(router: router)
            let uri = "/api/briefing?accountId=\(account.id.uuidString)"

            try await app.test(.router) { client in
                try await client.execute(uri: uri, method: .get) { response in
                    XCTAssertEqual(response.status, .ok)
                }
            }
            // New mail arrives while the first classification is still
            // running: the second refresh has work of its own.
            try await seedMessage("m2", accountId: account.id, db: conn)
            try await app.test(.router) { client in
                try await client.execute(uri: uri, method: .get) { response in
                    XCTAssertEqual(response.status, .ok)
                }
            }

            let done = await waitUntil({ await recorder.finished == 2 })
            XCTAssertTrue(done, "both refreshes must have classified")
            let peak = await recorder.maxConcurrent
            XCTAssertEqual(peak, 1, "one mailbox, one classification at a time")
        }
    }

    private func seedMessage(
        _ remoteId: String,
        accountId: UUID,
        db: LagoonDB
    ) async throws {
        try await MessageStore.upsert(
            MessageHeader(
                id: UUID(),
                accountId: accountId,
                remoteId: remoteId,
                threadId: "t-\(remoteId)",
                fromAddress: "sender@example.com",
                fromName: nil,
                subject: "subject",
                snippet: nil,
                receivedAt: Date(),
                isRead: false,
                isArchived: false
            ),
            db: db
        )
    }
}

/// Records how many classifications were in flight at the same time.
private actor ConcurrencyRecorder {
    private var current = 0
    private var peak = 0
    private(set) var completed = 0
    private(set) var cancelled = 0

    func enter() {
        current += 1
        peak = max(peak, current)
    }
    func leave() {
        current -= 1
        completed += 1
    }
    func sawCancellation() { cancelled += 1 }
    var maxConcurrent: Int { peak }
    var finished: Int { completed }
    var cancellations: Int { cancelled }
}

/// A classifier that is slow enough for an overlap to be visible, and that
/// records how many of its calls ran at the same time.
private final class RecordingClassifier: BriefingClassifying, @unchecked Sendable {
    private let recorder: ConcurrencyRecorder

    init(recorder: ConcurrencyRecorder) {
        self.recorder = recorder
    }

    func classify(
        _ messages: [MessageHeader],
        accountEmail: String,
        language: String?
    ) async throws -> [String: ClassificationOutcome] {
        await recorder.enter()
        do {
            try await Task.sleep(for: .milliseconds(200))
        } catch {
            await recorder.leave()
            throw error
        }
        await recorder.leave()
        return Dictionary(uniqueKeysWithValues: messages.map {
            ($0.remoteId, ClassificationOutcome(group: .subscriptionNoise))
        })
    }
}

/// A thread-safe box for the values a test wants to collect from a closure.
private actor SeenBox {
    private(set) var batches: [[String]] = []

    func append(_ batch: [String]) {
        batches.append(batch)
    }
    var count: Int { batches.count }
}
