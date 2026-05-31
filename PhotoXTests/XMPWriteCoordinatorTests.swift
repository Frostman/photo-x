import XCTest
@testable import PhotoX

/// Coverage for the XMP write-reliability layer. Saving culling
/// decisions is the project's #1 promise — these tests verify
/// the contract: per-stem serialization, retry on transient
/// failure, and structured failure reporting after exhaustion.
final class XMPWriteCoordinatorTests: XCTestCase {

    // MARK: - per-stem serialization

    /// Two writes for the same stem must execute sequentially.
    /// We assert this by recording start/end timestamps in the
    /// write closure and checking that B starts only after A
    /// returns.
    func test_sameStem_serializes() async {
        let coordinator = XMPWriteCoordinator(backoff: [])      // no retries needed
        let recorder = OrderRecorder()
        // A: takes 100 ms. B: starts shortly after.
        await coordinator.enqueueWork(stem: "A", kind: .rating(1)) {
            // Sleep synchronously on the worker. Swift Concurrency
            // doesn't really do "sync sleep" but Thread.sleep is fine
            // here — work runs nonisolated off the actor.
            recorder.record("A-start")
            Thread.sleep(forTimeInterval: 0.1)
            recorder.record("A-end")
        }
        await coordinator.enqueueWork(stem: "A", kind: .rating(2)) {
            recorder.record("B-start")
            recorder.record("B-end")
        }
        await coordinator.drain()
        XCTAssertEqual(recorder.events, ["A-start", "A-end", "B-start", "B-end"])
    }

    /// Writes for different stems may run concurrently. We can't
    /// assert true parallelism deterministically without timing
    /// hazards, but we CAN assert that B doesn't have to wait for
    /// A's slow completion — start order can interleave.
    func test_differentStems_canInterleave() async {
        let coordinator = XMPWriteCoordinator(backoff: [])
        let recorder = OrderRecorder()
        await coordinator.enqueueWork(stem: "A", kind: .rating(1)) {
            recorder.record("A-start")
            Thread.sleep(forTimeInterval: 0.1)
            recorder.record("A-end")
        }
        await coordinator.enqueueWork(stem: "B", kind: .rating(2)) {
            recorder.record("B-start")
            recorder.record("B-end")
        }
        await coordinator.drain()
        // B should have completed (start and end) before A's end,
        // because they ran concurrently on detached executors.
        let aEnd = recorder.events.firstIndex(of: "A-end")!
        let bEnd = recorder.events.firstIndex(of: "B-end")!
        XCTAssertLessThan(bEnd, aEnd,
                          "B should finish before A's slow write completes")
    }

    // MARK: - retry policy

    func test_succeedsAfterRetries_doesNotEmitFailure() async {
        let coordinator = XMPWriteCoordinator(
            backoff: [.milliseconds(1), .milliseconds(1)]
        )
        let attemptCount = Counter()
        await coordinator.enqueueWork(stem: "A", kind: .rating(1)) {
            attemptCount.increment()
            if attemptCount.value < 3 { throw TestError.transient }
            // 3rd attempt succeeds.
        }
        await coordinator.drain()
        XCTAssertEqual(attemptCount.value, 3)
        // No failure emitted.
        let failures = await collectFailures(from: coordinator, timeout: 0.05)
        XCTAssertTrue(failures.isEmpty,
                      "Success on retry must not surface a failure")
    }

    func test_alwaysFails_emitsFailureWithCorrectAttemptCount() async {
        let coordinator = XMPWriteCoordinator(
            backoff: [.milliseconds(1), .milliseconds(1)]
        )
        let attemptCount = Counter()
        await coordinator.enqueueWork(stem: "A", kind: .label("Red")) {
            attemptCount.increment()
            throw TestError.permanent
        }
        await coordinator.drain()
        XCTAssertEqual(attemptCount.value, 3,
                       "1 initial + 2 retries = 3 attempts total")
        let failures = await collectFailures(from: coordinator, timeout: 0.05)
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.stem, "A")
        XCTAssertEqual(failures.first?.intent, .setLabel("Red"))
        XCTAssertEqual(failures.first?.attempts, 3)
        XCTAssertTrue(failures.first?.lastError.contains("permanent") ?? false)
    }

    // MARK: - intent coalescing

    /// Rapid successive `writeRating` calls on the same stem must
    /// coalesce: only the last value reaches disk, and the
    /// coordinator dispatches far fewer write batches than enqueues.
    func test_rapidSameStem_coalesces() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("xmp-coalesce-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let entry = PhotoEntry(
            rawURL: tmp.appendingPathComponent("A.ARW"),
            previewURL: tmp.appendingPathComponent("A.HIF"),
            stem: "A"
        )
        let coordinator = XMPWriteCoordinator(backoff: [])
        // Fire 10 rating writes back-to-back. With per-stem
        // serialization + coalescing, at most ~2 batches should
        // dispatch (the first one races; everything after coalesces
        // into a tail batch with the latest value).
        for v in 1...10 {
            await coordinator.writeRating(v, for: entry)
        }
        await coordinator.drain()

        let writeCount = await coordinator.intentWriteCount
        XCTAssertLessThanOrEqual(writeCount, 2,
            "10 rapid same-stem rating writes should coalesce to ≤ 2 disk batches, got \(writeCount)")
        XCTAssertGreaterThanOrEqual(writeCount, 1,
            "At least one write must reach disk")
        XCTAssertEqual(XMPSidecarReader.read(for: entry)?.rating, 10,
            "Final on-disk rating must be the latest value enqueued")
    }

    /// Rating + label submitted via `writeIntent` are written in one
    /// disk batch regardless of timing — used by the retry path and
    /// the undo/redo snapshot replay.
    func test_writeIntent_combinesFields_inOneBatch() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("xmp-intent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let entry = PhotoEntry(
            rawURL: tmp.appendingPathComponent("A.ARW"),
            previewURL: tmp.appendingPathComponent("A.HIF"),
            stem: "A"
        )
        let coordinator = XMPWriteCoordinator(backoff: [])
        await coordinator.writeIntent(
            .setBoth(rating: 4, label: "Blue"),
            for: entry
        )
        await coordinator.drain()
        let xmp = XMPSidecarReader.read(for: entry)
        XCTAssertEqual(xmp?.rating, 4)
        XCTAssertEqual(xmp?.label, "Blue")
        let writeCount = await coordinator.intentWriteCount
        XCTAssertEqual(writeCount, 1, "writeIntent must produce exactly one disk batch")
    }

    // MARK: - failure intent merge

    /// FailedWrite.merged(with:) carries both fields if a rating
    /// failure is followed by a label failure for the same stem.
    /// Mirrors the merge logic ViewerState's consumer applies.
    func test_failedWrite_mergedAcrossKinds_keepsBothFields() {
        let older = XMPWriteCoordinator.FailedWrite(
            stem: "A",
            intent: .setRating(3),
            attempts: 3,
            lastError: "old",
            timestamp: Date(timeIntervalSince1970: 100)
        )
        let newer = XMPWriteCoordinator.FailedWrite(
            stem: "A",
            intent: .setLabel("Red"),
            attempts: 3,
            lastError: "new",
            timestamp: Date(timeIntervalSince1970: 200)
        )
        let merged = older.merged(with: newer)
        XCTAssertEqual(merged.intent.rating, .some(.some(3)),
                       "rating from older must survive the merge")
        XCTAssertEqual(merged.intent.label, .some(.some("Red")),
                       "label from newer must be present")
        XCTAssertEqual(merged.lastError, "new",
                       "newer's error must replace older's")
        XCTAssertEqual(merged.timestamp, Date(timeIntervalSince1970: 200),
                       "newer's timestamp must replace older's")
    }

    /// When the same field fails twice for one stem, the newer
    /// value wins — merging is "other's set fields override".
    func test_failedWrite_mergedSameField_newerWins() {
        let older = XMPWriteCoordinator.FailedWrite(
            stem: "A",
            intent: .setRating(2),
            attempts: 3,
            lastError: "old",
            timestamp: Date(timeIntervalSince1970: 100)
        )
        let newer = XMPWriteCoordinator.FailedWrite(
            stem: "A",
            intent: .setRating(5),
            attempts: 3,
            lastError: "new",
            timestamp: Date(timeIntervalSince1970: 200)
        )
        let merged = older.merged(with: newer)
        XCTAssertEqual(merged.intent.rating, .some(.some(5)))
    }

    // MARK: - discard

    /// discardPendingWrites cancels the running task and clears
    /// state. After drain, no failure event should be emitted for
    /// the discarded write — close-shoot must leave the pill clear.
    func test_discardPendingWrites_clearsStateAndSuppressesFailure() async throws {
        let coordinator = XMPWriteCoordinator(backoff: [.milliseconds(10)])
        // Path that doesn't exist → applyIntent throws → would retry → would emit.
        let entry = PhotoEntry(
            rawURL: URL(fileURLWithPath: "/nonexistent-dir-\(UUID().uuidString)/A.ARW"),
            previewURL: URL(fileURLWithPath: "/nonexistent-dir-\(UUID().uuidString)/A.HIF"),
            stem: "A"
        )
        await coordinator.writeRating(5, for: entry)
        // Race window: discard before the failure could land.
        await coordinator.discardPendingWrites()
        await coordinator.drain()
        let inFlight = await coordinator.hasInFlightWrites
        XCTAssertFalse(inFlight, "discard must leave the coordinator idle")
        let failures = await collectFailures(from: coordinator, timeout: 0.3)
        XCTAssertTrue(failures.isEmpty,
                      "discarded writes must not surface as failures (got \(failures.count))")
    }

    // MARK: - hasInFlightWrites

    func test_hasInFlightWrites_trueWhilePending_falseAfterDrain() async {
        let coordinator = XMPWriteCoordinator(backoff: [])
        await coordinator.enqueueWork(stem: "A", kind: .rating(1)) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        var inFlight = await coordinator.hasInFlightWrites
        XCTAssertTrue(inFlight, "should be in flight right after enqueue")
        await coordinator.drain()
        inFlight = await coordinator.hasInFlightWrites
        XCTAssertFalse(inFlight, "should be quiet after drain")
    }

    // MARK: - helpers

    enum TestError: Error { case transient, permanent }

    /// Thread-safe in-order recorder for write closures (which run
    /// on detached executors). NSLock is the simplest correct
    /// option here.
    final class OrderRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [String] = []
        func record(_ s: String) {
            lock.lock(); defer { lock.unlock() }
            _events.append(s)
        }
        var events: [String] {
            lock.lock(); defer { lock.unlock() }
            return _events
        }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: Int = 0
        func increment() { lock.lock(); _value += 1; lock.unlock() }
        var value: Int {
            lock.lock(); defer { lock.unlock() }
            return _value
        }
    }

    /// Collect any failure events emitted within `timeout`. We
    /// don't have an event-driven "wait until drained" signal
    /// for the failure stream, so use a short timeout.
    private func collectFailures(
        from coordinator: XMPWriteCoordinator,
        timeout: TimeInterval
    ) async -> [XMPWriteCoordinator.FailedWrite] {
        let stream = await coordinator.failureStream
        var collected: [XMPWriteCoordinator.FailedWrite] = []
        let collectTask = Task {
            for await failure in stream {
                collected.append(failure)
            }
            return collected
        }
        try? await Task.sleep(for: .seconds(timeout))
        collectTask.cancel()
        return collected
    }
}
