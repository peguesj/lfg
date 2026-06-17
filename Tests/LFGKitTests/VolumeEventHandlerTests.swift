import XCTest
@testable import LFGKit

// MARK: - Tests for VolumeEvent semantics + Debouncer behaviour

/// These tests exercise the event-diffing logic that ``VolumeEventWatcher`` uses
/// to convert raw FSEvents into ``VolumeEvent`` values.
///
/// Because FSEvents requires a RunLoop and real kernel callbacks, we test the
/// diffing logic in isolation: we manipulate `currentVolumes` and call
/// `simulateRawEvent()` to drive `handleRawFSEvent()` → `diffAndFire()`.
/// The debouncer is configured with 0 ms interval so tests are synchronous.
final class VolumeEventHandlerTests: XCTestCase {

    // MARK: Helpers

    /// Creates a watcher with a zero debounce interval so `diffAndFire` runs
    /// synchronously within the same RunLoop tick via `DispatchQueue.main`.
    private func makeWatcher(
        initial: Set<String> = [],
        queue: DispatchQueue = .main
    ) -> VolumeEventWatcher {
        let w = VolumeEventWatcher(debounceInterval: 0, callbackQueue: queue)
        w.currentVolumes = { initial }
        return w
    }

    // MARK: Appear events

    func testNewVolumeFiresAppearedEvent() {
        var received: [VolumeEvent] = []
        let watcher = makeWatcher(initial: ["Macintosh HD"])
        watcher.onEvent = { received.append($0) }
        watcher.start()

        // Simulate YJ_MORE appearing
        watcher.currentVolumes = { ["Macintosh HD", "YJ_MORE"] }
        watcher.simulateRawEvent()

        // Run main queue to let debounced block fire
        let exp = expectation(description: "appeared event")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { exp.fulfill() }
        wait(for: [exp], timeout: 1)

        XCTAssertEqual(received, [.appeared(name: "YJ_MORE")])
    }

    func testMultipleAppearedInOneDiff() {
        var received: [VolumeEvent] = []
        let watcher = makeWatcher(initial: [])
        watcher.onEvent = { received.append($0) }
        watcher.start()

        watcher.currentVolumes = { ["YJ_MORE", "EXTERNAL2"] }
        watcher.simulateRawEvent()

        let exp = expectation(description: "two appeared")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { exp.fulfill() }
        wait(for: [exp], timeout: 1)

        XCTAssertEqual(received.count, 2)
        XCTAssertTrue(received.contains(.appeared(name: "YJ_MORE")))
        XCTAssertTrue(received.contains(.appeared(name: "EXTERNAL2")))
    }

    // MARK: Disappear events

    func testVolumeRemovalFiresDisappearedEvent() {
        var received: [VolumeEvent] = []
        let watcher = makeWatcher(initial: ["Macintosh HD", "YJ_MORE"])
        watcher.onEvent = { received.append($0) }
        watcher.start()

        watcher.currentVolumes = { ["Macintosh HD"] }
        watcher.simulateRawEvent()

        let exp = expectation(description: "disappeared event")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { exp.fulfill() }
        wait(for: [exp], timeout: 1)

        XCTAssertEqual(received, [.disappeared(name: "YJ_MORE")])
    }

    // MARK: No-change

    func testNoChangeProducesNoEvents() {
        var received: [VolumeEvent] = []
        let watcher = makeWatcher(initial: ["Macintosh HD"])
        watcher.onEvent = { received.append($0) }
        watcher.start()

        // No change to currentVolumes
        watcher.simulateRawEvent()

        let exp = expectation(description: "no events")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { exp.fulfill() }
        wait(for: [exp], timeout: 1)

        XCTAssertTrue(received.isEmpty)
    }

    // MARK: Stop

    func testStopPreventsSubsequentEventDelivery() {
        var received: [VolumeEvent] = []
        let watcher = makeWatcher(initial: [])
        watcher.onEvent = { received.append($0) }
        watcher.start()
        watcher.stop()

        watcher.currentVolumes = { ["YJ_MORE"] }
        watcher.simulateRawEvent()

        let exp = expectation(description: "no event after stop")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1)

        // After stop the debouncer is cancelled; no appeared event should fire.
        XCTAssertTrue(received.isEmpty)
    }

    // MARK: Idempotent start

    func testDoubleStartIsIdempotent() {
        var startCount = 0
        let watcher = makeWatcher(initial: [])
        watcher.onEvent = { _ in startCount += 1 }
        watcher.start()
        watcher.start()   // second call should be no-op

        watcher.currentVolumes = { ["YJ_MORE"] }
        watcher.simulateRawEvent()

        let exp = expectation(description: "single event")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { exp.fulfill() }
        wait(for: [exp], timeout: 1)

        XCTAssertEqual(startCount, 1)
    }
}
