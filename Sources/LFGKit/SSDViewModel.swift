import Foundation
import Observation

@Observable
@MainActor
public final class SSDViewModel {
    public private(set) var indexedVolumes: [String] = []
    public private(set) var cpuPercent: Double = 0
    public private(set) var isRefreshing = false
    public private(set) var error: String? = nil

    private let runner: any ShellRunnerProtocol
    private let lfg: String

    public init(runner: any ShellRunnerProtocol = DefaultShellRunner()) {
        self.runner = runner
        self.lfg = "\(NSHomeDirectory())/tools/@yj/lfg/lfg"
    }

    public func refresh() async {
        isRefreshing = true
        error = nil
        defer { isRefreshing = false }
        do {
            let cpuResult = try await runner.shell(
                "ps -Ac -o %cpu,comm | awk '/mds/ {sum += $1} END {print sum+0}'"
            )
            cpuPercent = Double(cpuResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0

            let mdResult = try await ProcessRunner.run("/usr/bin/mdutil", arguments: ["-s", "-a"])
            indexedVolumes = parseIndexed(mdResult.stdout)
        } catch {
            self.error = error.localizedDescription
        }
    }

    public func excludeAll() async {
        do {
            _ = try await runner.shell("sudo \(lfg) ssd exclude --force")
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func parseIndexed(_ output: String) -> [String] {
        var current = ""
        var result: [String] = []
        for line in output.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasSuffix(":") && t.hasPrefix("/") {
                current = String(t.dropLast())
            } else if !current.isEmpty && t.contains("enabled") {
                result.append(current)
                current = ""
            }
        }
        return result
    }
}
