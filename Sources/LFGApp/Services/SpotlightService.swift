import Foundation

/// Wraps mdutil for Spotlight index management.
struct SpotlightService {
    /// Check Spotlight indexing status for a volume.
    static func status(volume: String) async throws -> String {
        let result = try await ProcessRunner.run(
            "/usr/bin/mdutil", arguments: ["-s", volume]
        )
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Enable Spotlight indexing on a volume.
    static func enable(volume: String) async throws -> ProcessRunner.Result {
        try await ProcessRunner.run(
            "/usr/bin/mdutil", arguments: ["-i", "on", volume]
        )
    }

    /// Disable Spotlight indexing on a volume.
    static func disable(volume: String) async throws -> ProcessRunner.Result {
        try await ProcessRunner.run(
            "/usr/bin/mdutil", arguments: ["-i", "off", volume]
        )
    }

    /// Erase and rebuild the Spotlight index on a volume.
    static func rebuild(volume: String) async throws -> ProcessRunner.Result {
        try await ProcessRunner.run(
            "/usr/bin/mdutil", arguments: ["-E", volume]
        )
    }
}
