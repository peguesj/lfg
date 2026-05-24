import Foundation

// MARK: - OffloadRule

/// Represents one entry from `drives[].symlinks[]` in fleet.json — a home-directory offload rule.
///
/// The raw format stored in fleet.json is an arrow-separated string:
/// ```
/// ~/.npm-cache → /Volumes/DDRV-901-DEVLIB/npm-cache
/// ```
///
/// Where:
/// - The left side is the **source** path that will be replaced by a symlink (may use `~`).
/// - The right side is the **target** path the symlink points to on the APFS volume.
///
/// Usage:
/// ```swift
/// let rule = OffloadRule(raw: "~/.npm-cache → /Volumes/DDRV-901-DEVLIB/npm-cache")!
/// print(rule.source)          // "~/.npm-cache"
/// print(rule.target)          // "/Volumes/DDRV-901-DEVLIB/npm-cache"
/// print(rule.resolvedSource)  // "/Users/jeremiah/.npm-cache"
/// print(rule.isHealthy)       // true if symlink exists and points to target
/// ```
public struct OffloadRule: Sendable, Equatable {

    // MARK: Properties

    /// The path being symlinked from, as written in fleet.json (may start with `~`).
    ///
    /// Example: `"~/.npm-cache"`
    public let source: String

    /// The absolute path the symlink points to (always absolute in fleet.json).
    ///
    /// Example: `"/Volumes/DDRV-901-DEVLIB/npm-cache"`
    public let target: String

    // MARK: Parsing

    /// The arrow separator used in fleet.json symlink strings.
    /// Uses the Unicode RIGHT ARROW character (U+2192) surrounded by spaces.
    private static let arrowSeparator = " → "

    /// Initialise by parsing the raw arrow-separated string from fleet.json.
    ///
    /// Returns `nil` when the string does not contain exactly one `" → "` separator
    /// or when either side is empty after trimming whitespace.
    ///
    /// - Parameter raw: A string of the form `"<source> → <target>"`.
    public init?(raw: String) {
        let parts = raw.components(separatedBy: Self.arrowSeparator)
        guard parts.count == 2 else { return nil }
        let lhs = parts[0].trimmingCharacters(in: .whitespaces)
        let rhs = parts[1].trimmingCharacters(in: .whitespaces)
        guard !lhs.isEmpty, !rhs.isEmpty else { return nil }
        source = lhs
        target = rhs
    }

    // MARK: Computed helpers

    /// The source path with `~` expanded to the current user's home directory.
    ///
    /// Example: `"~/.npm-cache"` → `"/Users/jeremiah/.npm-cache"`
    public var resolvedSource: String {
        if source.hasPrefix("~/") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return (home as NSString).appendingPathComponent(String(source.dropFirst(2)))
        }
        return source
    }

    /// Whether the symlink at `resolvedSource` currently exists and resolves to `target`.
    ///
    /// The check uses `FileManager.destinationOfSymbolicLink(atPath:)` so it will
    /// return `false` if the path does not exist, is not a symlink, or points to
    /// a different destination than `target`.
    public var isHealthy: Bool {
        let sourcePath = resolvedSource
        guard let destination = try? FileManager.default
            .destinationOfSymbolicLink(atPath: sourcePath) else {
            return false
        }
        // Normalise both paths before comparing to handle trailing slashes etc.
        return (destination as NSString).standardizingPath
            == (target as NSString).standardizingPath
    }
}
