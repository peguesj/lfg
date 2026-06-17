import Foundation
import Observation

@Observable
@MainActor
public final class WTFSViewModel {
    public private(set) var output: String = ""
    public private(set) var isScanning = false
    public private(set) var error: String? = nil

    private let runner: any ShellRunnerProtocol

    public init(runner: any ShellRunnerProtocol = DefaultShellRunner()) {
        self.runner = runner
    }

    public func scan(path: String = "~") async {
        isScanning = true
        error = nil
        defer { isScanning = false }
        do {
            let lfg = "\(NSHomeDirectory())/tools/@yj/lfg/lfg"
            let result = try await runner.shell("\(lfg) wtfs \(path)")
            if result.succeeded {
                output = result.stdout
            } else {
                error = result.stderr.isEmpty ? "Scan failed (exit \(result.exitCode))" : result.stderr
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
