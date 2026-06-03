import UserNotifications
import Foundation

// MARK: - Notification identifiers

public enum DevDriveNotifAction: String {
    case ignore            = "LFG_DD_IGNORE"
    case useDefaultFallback = "LFG_DD_DEFAULT_FALLBACK"
    case chooseVolume      = "LFG_DD_CHOOSE_VOLUME"
}

public enum DevDriveNotifCategory: String {
    /// Fired when one or more volumes need an absent external host drive.
    case volumeUnavailable = "LFG_DD_UNAVAILABLE"
}

// MARK: - DevDriveNotificationCategories

/// Registers UNNotificationCategory values and sends actionable devdrive alerts.
///
/// Call `registerCategories()` once at app launch (before any notification fires).
/// Action handling lives in `NotificationActionHandler`.
public enum DevDriveNotificationCategories {

    // MARK: Registration

    public static func registerCategories() {
        let ignore = UNNotificationAction(
            identifier: DevDriveNotifAction.ignore.rawValue,
            title: "Ignore",
            options: []
        )
        let useDefault = UNNotificationAction(
            identifier: DevDriveNotifAction.useDefaultFallback.rawValue,
            title: "Use Default Fallback",
            options: []
        )
        let choose = UNNotificationAction(
            identifier: DevDriveNotifAction.chooseVolume.rawValue,
            title: "Choose Volume…",
            options: [.foreground]   // brings app to foreground so the sheet can open
        )

        let category = UNNotificationCategory(
            identifier: DevDriveNotifCategory.volumeUnavailable.rawValue,
            actions: [ignore, useDefault, choose],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    // MARK: - Send helpers

    /// Fire an actionable "volumes unavailable" notification.
    ///
    /// `hostName` and `volumeIds` are embedded in `userInfo` so the action handler
    /// can open the correct detection screen.
    public static func sendUnavailableAlert(
        title: String,
        body: String,
        hostName: String,
        volumeIds: [String]
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = DevDriveNotifCategory.volumeUnavailable.rawValue
        content.userInfo = [
            "lfg_host": hostName,
            "lfg_volume_ids": volumeIds
        ]

        let id = "lfg.devdrive.unavailable.\(hostName)"
        // Remove any pending duplicate for this host before adding the new one.
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: nil)
        ) { _ in }
    }
}
