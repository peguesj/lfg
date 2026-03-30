import Foundation

public enum LFGConstants {
    public static let bundleID = "io.lfg.app"
    public static let helperBundleID = "io.lfg.helper"
    public static let appName = "LFG"
    public static let appVersion = "3.0.0-alpha"

    public enum Paths {
        public static let appSupport: String = {
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            return base.appendingPathComponent("LFG").path
        }()

        public static let logs: String = {
            NSString(string: "~/Library/Logs/LFG").expandingTildeInPath
        }()

        public static let caches: String = {
            let base = FileManager.default.urls(
                for: .cachesDirectory,
                in: .userDomainMask
            ).first!
            return base.appendingPathComponent("LFG").path
        }()
    }

    public enum Defaults {
        public static let pollIntervalSeconds: Double = 30
        public static let inboxThresholdBytes: UInt64 = 100 * 1024 * 1024 // 100 MB
        public static let snapshotRetentionDays: Int = 90
    }
}
