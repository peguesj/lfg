import Foundation
import CoreServices
import LFGKit

// MARK: - Event types

/// Coarse event fired by ``VolumeEventWatcher``.
public enum VolumeEvent: Sendable, Equatable {
    /// A directory appeared under /Volumes — the name is the last path component.
    case appeared(name: String)
    /// A directory disappeared under /Volumes.
    case disappeared(name: String)
}

// MARK: - Watcher

/// Watches `/Volumes` via `FSEventsStream` and debounces rapid mount/unmount sequences.
///
/// After debouncing (500 ms window), the `onEvent` closure is called on the provided queue.
///
/// Design note: FSEventsStream fires for any change under the watched path.
/// We reconcile against the live filesystem to derive appear/disappear semantics.
public final class VolumeEventWatcher: @unchecked Sendable {

    // MARK: Dependencies (injectable for testing)

    /// Closure called with debounced events. Defaults to calling `onEvent`.
    public var onEvent: ((VolumeEvent) -> Void)?

    /// Returns the set of directory names currently under /Volumes.
    /// Override in tests to inject a fake filesystem view.
    public var currentVolumes: () -> Set<String> = {
        let url = URL(fileURLWithPath: "/Volumes")
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return Set(contents.map(\.lastPathComponent))
    }

    // MARK: Private state

    private var stream: FSEventStreamRef?
    private var lastKnownVolumes: Set<String> = []
    private let debounceInterval: TimeInterval
    private let callbackQueue: DispatchQueue
    private var debouncer: Debouncer
    private var isRunning = false

    // MARK: Init

    public init(
        debounceInterval: TimeInterval = 0.5,
        callbackQueue: DispatchQueue = .main
    ) {
        self.debounceInterval = debounceInterval
        self.callbackQueue = callbackQueue
        self.debouncer = Debouncer(interval: debounceInterval, queue: callbackQueue)
    }

    // MARK: Lifecycle

    /// Start watching /Volumes. Safe to call multiple times (idempotent).
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        lastKnownVolumes = currentVolumes()
        startFSEvents()
    }

    /// Stop watching. The stream is invalidated and released.
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        debouncer.cancel()
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
    }

    // MARK: FSEvents

    private func startFSEvents() {
        let watchedPaths = ["/Volumes"] as CFArray
        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = UInt32(
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagWatchRoot |
            kFSEventStreamCreateFlagFileEvents
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<VolumeEventWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.handleRawFSEvent()
        }

        guard let s = FSEventStreamCreate(
            nil,
            callback,
            &ctx,
            watchedPaths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,   // latency — coarse; debouncer handles the 500 ms window
            flags
        ) else { return }

        stream = s
        FSEventStreamScheduleWithRunLoop(s, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        FSEventStreamStart(s)
    }

    // MARK: Internal event handling

    /// Called from the FSEvents callback; schedules a debounced diff pass.
    func handleRawFSEvent() {
        debouncer.call { [weak self] in
            self?.diffAndFire()
        }
    }

    /// For testing: fire a synthetic raw event immediately, bypassing FSEvents.
    public func simulateRawEvent() {
        handleRawFSEvent()
    }

    // MARK: Diff

    private func diffAndFire() {
        let now = currentVolumes()
        let appeared = now.subtracting(lastKnownVolumes)
        let disappeared = lastKnownVolumes.subtracting(now)
        lastKnownVolumes = now

        for name in appeared {
            onEvent?(.appeared(name: name))
        }
        for name in disappeared {
            onEvent?(.disappeared(name: name))
        }
    }
}

