import Foundation

// MARK: - FleetEditor

/// Atomic read-modify-write helper for `fleet.json`.
///
/// All mutations deserialise the current file, apply a transform closure, then
/// serialise back using `Data.write(to:options:.atomic)` — a crash-safe write
/// via a temp-file rename.  The JSON is kept human-readable (pretty-printed +
/// sorted keys) to remain VCS-friendly.
///
/// Usage:
/// ```swift
/// try FleetEditor.updateBackend(id: "901DEVLIB", at: fleetURL) { drive in
///     drive["purpose"] = "Updated purpose string"
/// }
/// ```
public enum FleetEditor {

    // MARK: Backend (drives[])

    /// Mutate a single `drives[]` entry identified by `id`.
    ///
    /// - Parameters:
    ///   - id: The `"id"` field value to match (e.g. `"901DEVLIB"`).
    ///   - url: URL of `fleet.json`.
    ///   - transform: Closure that receives and may mutate the raw drive dictionary.
    /// - Throws: `FleetEditorError.backendNotFound` if no entry matches `id`,
    ///           plus any `JSONSerialization` or file I/O errors.
    public static func updateBackend(
        id: String,
        at url: URL,
        transform: (inout [String: Any]) -> Void
    ) throws {
        var raw = try readRaw(at: url)
        var drives = raw["drives"] as? [[String: Any]] ?? []

        guard let idx = drives.firstIndex(where: { ($0["id"] as? String) == id }) else {
            throw FleetEditorError.backendNotFound(id)
        }
        transform(&drives[idx])
        raw["drives"] = drives
        try writeRaw(raw, to: url)
    }

    /// Append a new entry to `drives[]`.
    public static func addBackend(_ entry: [String: Any], at url: URL) throws {
        var raw = try readRaw(at: url)
        var drives = raw["drives"] as? [[String: Any]] ?? []
        drives.append(entry)
        raw["drives"] = drives
        try writeRaw(raw, to: url)
    }

    /// Remove a `drives[]` entry by id.
    public static func removeBackend(id: String, at url: URL) throws {
        var raw = try readRaw(at: url)
        var drives = raw["drives"] as? [[String: Any]] ?? []
        drives.removeAll { ($0["id"] as? String) == id }
        raw["drives"] = drives
        try writeRaw(raw, to: url)
    }

    // MARK: Source volumes (external_hosts[])

    /// Mutate a `external_hosts[]` entry identified by `name`.
    public static func updateSourceVolume(
        name: String,
        at url: URL,
        transform: (inout [String: Any]) -> Void
    ) throws {
        var raw = try readRaw(at: url)
        var hosts = raw["external_hosts"] as? [[String: Any]] ?? []

        guard let idx = hosts.firstIndex(where: { ($0["name"] as? String) == name }) else {
            throw FleetEditorError.sourceVolumeNotFound(name)
        }
        transform(&hosts[idx])
        raw["external_hosts"] = hosts
        try writeRaw(raw, to: url)
    }

    // MARK: Private helpers

    private static func readRaw(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FleetEditorError.invalidJSON
        }
        return obj
    }

    private static func writeRaw(_ raw: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: raw,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - FleetEditorError

public enum FleetEditorError: LocalizedError {
    case backendNotFound(String)
    case sourceVolumeNotFound(String)
    case invalidJSON

    public var errorDescription: String? {
        switch self {
        case .backendNotFound(let id):       return "Backend '\(id)' not found in fleet.json"
        case .sourceVolumeNotFound(let n):   return "Source volume '\(n)' not found in fleet.json"
        case .invalidJSON:                   return "fleet.json is not a valid JSON object"
        }
    }
}
