import Foundation

/// Minimal shell execution interface for ViewModel testability.
public protocol ShellRunnerProtocol: Sendable {
    func shell(_ command: String) async throws -> ProcessRunner.Result
}

extension ProcessRunner: ShellRunnerProtocol {
    public func shell(_ command: String) async throws -> ProcessRunner.Result {
        try await ProcessRunner.shell(command)
    }
}

/// Default instance used by production ViewModels.
public struct DefaultShellRunner: ShellRunnerProtocol {
    public init() {}
    public func shell(_ command: String) async throws -> ProcessRunner.Result {
        try await ProcessRunner.shell(command)
    }
}
