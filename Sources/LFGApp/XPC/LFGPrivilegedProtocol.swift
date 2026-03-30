import Foundation

/// Protocol for XPC communication with a privileged helper.
/// The helper will handle operations requiring root access
/// (cache clearing in system directories, Spotlight index management, etc.).
@objc protocol LFGPrivilegedProtocol {
    func clearSystemCache(at path: String, reply: @escaping (Bool, String?) -> Void)
    func setSpotlightIndexing(enabled: Bool, volume: String, reply: @escaping (Bool, String?) -> Void)
    func getDirectorySize(at path: String, reply: @escaping (UInt64, String?) -> Void)
}
