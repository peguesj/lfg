import Foundation

/// Shared async Process wrapper for LFGKit consumers.
/// Mirrors the LFGApp version for use by lfg-cli and tests.
public struct ProcessRunner {
    public struct Result: Sendable {
        public let exitCode: Int32
        public let stdout: String
        public let stderr: String
        public var succeeded: Bool { exitCode == 0 }
    }

    public static func run(
        _ executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil
    ) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let env = environment { process.environment = env }

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { proc in
                let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: Result(
                    exitCode: proc.terminationStatus,
                    stdout: String(data: outData, encoding: .utf8) ?? "",
                    stderr: String(data: errData, encoding: .utf8) ?? ""
                ))
            }

            do { try process.run() }
            catch { continuation.resume(throwing: error) }
        }
    }

    public static func shell(_ command: String) async throws -> Result {
        try await run("/bin/zsh", arguments: ["-c", command])
    }
}
