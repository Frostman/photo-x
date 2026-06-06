import AppKit
import IndexingCore
import CoreGraphics
import XCTest
@testable import PhotoX

/// Unit coverage for `PresentationCoordinator` — start/stop/swap state
/// transitions, auto-stop on shoot close, auto-stop on target removal.
///
/// Tests instantiate a fresh coordinator (not the app singleton) with a
/// recording window factory, so no NSWindow ever needs to be displayed.
@MainActor
final class PresentationCoordinatorTests: XCTestCase {

    // MARK: - basics

    func test_startPresenting_setsActivePresenterAndTarget() {
        let (coord, watcher, factory) = makeCoordinator()
        let state = makeState(stems: ["A", "B"])
        let target = Self.syntheticTarget

        coord.startPresenting(state, on: target)

        XCTAssertTrue(coord.isPresenting(state))
        XCTAssertTrue(coord.isPresenting(state, on: target))
        XCTAssertEqual(coord.activeTarget?.id, target.id)
        XCTAssertEqual(factory.callCount, 1)
        XCTAssertFalse(watcher.targets.isEmpty || watcher.targets.contains(where: { $0.id == target.id }) == false,
                       "watcher state isn't tested here, just keeping references alive")
    }

    func test_stopPresenting_clearsState() {
        let (coord, _, _) = makeCoordinator()
        let state = makeState(stems: ["A"])

        coord.startPresenting(state, on: Self.syntheticTarget)
        coord.stopPresenting()

        XCTAssertNil(coord.activePresenter)
        XCTAssertNil(coord.activeTarget)
        XCTAssertFalse(coord.isPresenting(state))
    }

    func test_isPresenting_reflectsActivePresenter() {
        let (coord, _, _) = makeCoordinator()
        let stateA = makeState(stems: ["A"])
        let stateB = makeState(stems: ["B"])

        coord.startPresenting(stateA, on: Self.syntheticTarget)

        XCTAssertTrue(coord.isPresenting(stateA))
        XCTAssertFalse(coord.isPresenting(stateB))
    }

    // MARK: - swap behavior

    func test_startPresenting_swapsPresenter_whenAnotherStatePassed() {
        let (coord, _, factory) = makeCoordinator()
        let stateA = makeState(stems: ["A"])
        let stateB = makeState(stems: ["B"])
        let target = Self.syntheticTarget

        coord.startPresenting(stateA, on: target)
        coord.startPresenting(stateB, on: target)

        XCTAssertTrue(coord.isPresenting(stateB))
        XCTAssertFalse(coord.isPresenting(stateA))
        XCTAssertEqual(factory.callCount, 1,
                       "same target: window is reused, factory must not fire twice")
    }

    func test_startPresenting_repositions_whenSameStateNewTarget() {
        let (coord, _, factory) = makeCoordinator()
        let state = makeState(stems: ["A"])
        let t1 = Self.syntheticTarget
        let t2 = DisplayTarget(
            id: "synthetic.other",
            displayName: "Other Fake",
            frame: CGRect(x: -20_000, y: -20_000, width: 1920, height: 1080),
            kind: .synthetic
        )

        coord.startPresenting(state, on: t1)
        coord.startPresenting(state, on: t2)

        XCTAssertTrue(coord.isPresenting(state, on: t2))
        XCTAssertFalse(coord.isPresenting(state, on: t1))
        XCTAssertEqual(factory.callCount, 1,
                       "existing window should be repositioned, not recreated")
    }

    func test_startPresenting_isNoOp_whenSameStateSameTarget() {
        let (coord, _, factory) = makeCoordinator()
        let state = makeState(stems: ["A"])
        let target = Self.syntheticTarget

        coord.startPresenting(state, on: target)
        coord.startPresenting(state, on: target)

        XCTAssertTrue(coord.isPresenting(state, on: target))
        XCTAssertEqual(factory.callCount, 1)
    }

    // MARK: - auto-stop

    func test_shootBecomingNil_autoStops() async {
        let (coord, _, _) = makeCoordinator()
        let state = makeState(stems: ["A"])
        coord.startPresenting(state, on: Self.syntheticTarget)
        XCTAssertTrue(coord.isPresenting(state))

        state.shoot = nil

        // withObservationTracking re-fires on the next runloop turn.
        await yieldToMainActor()
        XCTAssertNil(coord.activePresenter, "shoot=nil must auto-stop")
        XCTAssertNil(coord.activeTarget)
    }

    func test_onTargetsRemoved_includesActiveTarget_autoStops() {
        let watcher = ExternalScreenWatcher(includesSynthetic: { true })
        let factory = RecordingWindowFactory()
        let coord = PresentationCoordinator(watcher: watcher, windowFactory: factory.callable())
        let state = makeState(stems: ["A"])
        let target = Self.syntheticTarget

        coord.startPresenting(state, on: target)
        XCTAssertTrue(coord.isPresenting(state))

        watcher.onTargetsRemoved?([target])

        XCTAssertNil(coord.activePresenter, "removed-target callback must auto-stop")
        XCTAssertNil(coord.activeTarget)
    }

    func test_onTargetsRemoved_otherTarget_doesNotStop() {
        let watcher = ExternalScreenWatcher(includesSynthetic: { true })
        let factory = RecordingWindowFactory()
        let coord = PresentationCoordinator(watcher: watcher, windowFactory: factory.callable())
        let state = makeState(stems: ["A"])
        let target = Self.syntheticTarget
        let other = DisplayTarget(
            id: "synthetic.other",
            displayName: "Other",
            frame: .zero,
            kind: .synthetic
        )

        coord.startPresenting(state, on: target)
        watcher.onTargetsRemoved?([other])

        XCTAssertTrue(coord.isPresenting(state),
                      "an unrelated removal must not tear down")
    }

    // MARK: - helpers

    /// Returns a brand-new coordinator + watcher + factory triple wired
    /// together. Each test gets its own — no app-singleton state leaks.
    private func makeCoordinator() -> (PresentationCoordinator, ExternalScreenWatcher, RecordingWindowFactory) {
        let watcher = ExternalScreenWatcher(includesSynthetic: { true })
        let factory = RecordingWindowFactory()
        let coord = PresentationCoordinator(watcher: watcher, windowFactory: factory.callable())
        return (coord, watcher, factory)
    }

    private func makeState(stems: [String]) -> ViewerState {
        let dir = URL(fileURLWithPath: "/tmp/photox-present-tests-fake")
        let pairs = stems.map { stem in
            PhotoEntry(
                rawURL: dir.appendingPathComponent("\(stem).ARW"),
                previewURL: dir.appendingPathComponent("\(stem).HIF"),
                stem: stem
            )
        }
        let state = ViewerState()
        state.shoot = Shoot(folderURL: dir, entries: pairs)
        return state
    }

    /// Pump the main actor twice — `withObservationTracking` schedules
    /// its `onChange` callback after the next storage write, which
    /// itself spawns a Task. Two yields is enough for the fake-shoot
    /// teardown chain to settle.
    private func yieldToMainActor() async {
        await Task.yield()
        await Task.yield()
        await Task.yield()
    }

    private static let syntheticTarget = DisplayTarget(
        id: "synthetic.fakeDisplay",
        displayName: "Fake Display 4K",
        frame: CGRect(x: -10_000, y: -10_000, width: 3840, height: 2160),
        kind: .synthetic
    )
}

/// Window factory that records each call (so tests can assert
/// new-vs-reused-window behavior) and returns a borderless NSWindow
/// that is never shown.
@MainActor
final class RecordingWindowFactory {
    private(set) var callCount: Int = 0
    private(set) var lastTarget: DisplayTarget?

    func callable() -> @MainActor (DisplayTarget) -> NSWindow {
        return { [weak self] target in
            self?.callCount += 1
            self?.lastTarget = target
            return NSWindow(
                contentRect: CGRect(x: -10_000, y: -10_000, width: 100, height: 100),
                styleMask: [.borderless],
                backing: .buffered,
                defer: true
            )
        }
    }
}
