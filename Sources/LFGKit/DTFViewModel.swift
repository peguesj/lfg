import Foundation
import Observation

public struct CacheItem: Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let path: String
    public let size: String

    public init(id: UUID = UUID(), name: String, path: String, size: String) {
        self.id = id
        self.name = name
        self.path = path
        self.size = size
    }
}

@Observable
@MainActor
public final class DTFViewModel {
    public private(set) var caches: [CacheItem] = []
    public private(set) var isDiscovering = false
    public private(set) var error: String? = nil

    private let runner: any ShellRunnerProtocol
    private let lfg: String

    public init(runner: any ShellRunnerProtocol = DefaultShellRunner()) {
        self.runner = runner
        self.lfg = "\(NSHomeDirectory())/tools/@yj/lfg/lfg"
    }

    public func discover() async {
        isDiscovering = true
        error = nil
        defer { isDiscovering = false }
        do {
            let result = try await runner.shell("\(lfg) dtf --dry-run 2>&1")
            caches = parse(result.stdout)
        } catch {
            self.error = error.localizedDescription
        }
    }

    public func clean(_ item: CacheItem) async {
        do {
            _ = try await runner.shell("rm -rf \"\(item.path)\"")
            caches.removeAll { $0.id == item.id }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // Parses lines like: "1.2G  /path/to/cache"
    private func parse(_ output: String) -> [CacheItem] {
        output.components(separatedBy: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let size = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let path = String(parts[1]).trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { return nil }
            let name = URL(fileURLWithPath: path).lastPathComponent
            return CacheItem(name: name, path: path, size: size)
        }
    }
}
