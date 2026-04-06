import AppKit

/// Watches for volume mount/unmount events via workspace notifications.
final class VolumeWatcherService {
    private var mountObserver: NSObjectProtocol?
    private var unmountObserver: NSObjectProtocol?

    var onMount: ((String) -> Void)?
    var onUnmount: ((String) -> Void)?

    func start() {
        let center = NSWorkspace.shared.notificationCenter

        mountObserver = center.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let path = notification.userInfo?["NSDevicePath"] as? String {
                self?.onMount?(path)
            }
        }

        unmountObserver = center.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let path = notification.userInfo?["NSDevicePath"] as? String {
                self?.onUnmount?(path)
            }
        }
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        if let obs = mountObserver { center.removeObserver(obs) }
        if let obs = unmountObserver { center.removeObserver(obs) }
    }
}
