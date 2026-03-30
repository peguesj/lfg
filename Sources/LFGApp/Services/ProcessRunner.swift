import Foundation

/// Async wrapper around Foundation.Process for running shell commands.
struct ProcessRunner {
    struct Result {
        let exitCode: Int32
        let stdout: String
        let stderr: String
        var succeeded: Bool { exitCode == 0 }
    }

    /// Run an executable with arguments and return captured output.
    static func run(
        _ executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil
    ) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments

            if let env = environment {
                process.environment = env
            }
            if let dir = currentDirectory {
                process.currentDirectoryURL = dir
            }

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { proc in
                let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let result = Result(
                    exitCode: proc.terminationStatus,
                    stdout: String(data: outData, encoding: .utf8) ?? "",
                    stderr: String(data: errData, encoding: .utf8) ?? ""
                )
                continuation.resume(returning: result)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Convenience: run a shell command string via /bin/zsh.
    static func shell(_ command: String) async throws -> Result {
        try await run("/bin/zsh", arguments: ["-c", command])
    }
}
