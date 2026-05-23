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
        XCTAssertEqual(failures.first?.kind, .label("Red"))
        XCTAssertEqual(failures.first?.attempts, 3)
        XCTAssertTrue(failures.first?.lastError.contains("permanent") ?? false)
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
