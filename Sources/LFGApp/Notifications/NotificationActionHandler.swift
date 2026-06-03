import AppKit
import Foundation
import UserNotifications
import LFGKit

// MARK: - NotificationActionHandler

/// `UNUserNotificationCenterDelegate` that routes devdrive action-button taps
/// to the correct UI screen.
///
/// Wire this up once at app launch:
/// ```swift
/// UNUserNotificationCenter.current().delegate = NotificationActionHandler.shared
/// ```
final class NotificationActionHandler: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {

    static let shared = NotificationActionHandler()
    private override init() {}

    // MARK: - UNUserNotificationCenterDelegate

    /// Called when the user taps a notification action button (or the notification body itself).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        let info    = response.notification.request.content.userInfo
        let host    = info["lfg_host"] as? String ?? ""
        let volIds  = info["lfg_volume_ids"] as? [String] ?? []

        switch response.actionIdentifier {

        case DevDriveNotifAction.ignore.rawValue,
             UNNotificationDismissActionIdentifier:
            // Nothing to do — user dismissed.
            break

        case DevDriveNotifAction.useDefaultFallback.rawValue:
            applyDefaultFallback(hostName: host, volumeIds: volIds)

        case DevDriveNotifAction.chooseVolume.rawValue,
             UNNotificationDefaultActionIdentifier:
            // "Choose Volume…" or tap on the notification body → open the
            // detection screen if the host is expected; otherwise open fallback mgmt.
            DispatchQueue.main.async {
                if !host.isEmpty {
                    VolumeDetectWindowController.show(waitingForHost: host, volumeIds: volIds)
                } else {
                    FallbackVolumeWindowController.show(volumeIds: volIds)
                }
            }

        default:
            break
        }
    }

    /// Show notifications while the app is in foreground.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // MARK: - Default fallback helper

    private func applyDefaultFallback(hostName: String, volumeIds: [String]) {
        var policy = FallbackPolicy.load()
        for id in volumeIds {
            if policy.volumeOverrides[id] == nil {
                policy.volumeOverrides[id] = FallbackPolicy.VolumeOverride(action: .useDefaultFallback)
            } else {
                policy.volumeOverrides[id]?.action = .useDefaultFallback
            }
        }
        try? policy.save()

        // Notify the daemon via a sentinel file so it picks up the new policy on next tick.
        let sentinel = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/lfg/fallback_policy_updated")
        try? Data().write(to: sentinel)
    }
}
