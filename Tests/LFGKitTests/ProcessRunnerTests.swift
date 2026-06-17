import XCTest
@testable import LFGKit

final class ProcessRunnerTests: XCTestCase {

    // MARK: - Basic execution

    func testEchoReturnsStdout() async throws {
        let result = try await ProcessRunner.run("/bin/echo", arguments: ["hello"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testNonZeroExitCodeMarksFailure() async throws {
        let result = try await ProcessRunner.run("/usr/bin/false")
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertFalse(result.succeeded)
    }

    func testStderrCaptured() async throws {
        // `ls` on a nonexistent path writes to stderr and exits nonzero
        let result = try await ProcessRunner.run(
            "/bin/ls",
            arguments: ["/this/path/does/not/exist/xyzzy"]
        )
        XCTAssertFalse(result.succeeded)
        XCTAssertFalse(result.stderr.isEmpty, "stderr should contain the ls error message")
    }

    func testMultilineOutput() async throws {
        let result = try await ProcessRunner.run(
            "/bin/echo",
            arguments: ["-e", "line1\nline2\nline3"]
        )
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.stdout.contains("line1"))
    }

    // MARK: - shell() convenience

    func testShellPipeline() async throws {
        let result = try await ProcessRunner.shell("echo foo | tr 'f' 'b'")
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "boo")
    }

    func testShellExitCode() async throws {
        let result = try await ProcessRunner.shell("exit 42")
        XCTAssertEqual(result.exitCode, 42)
        XCTAssertFalse(result.succeeded)
    }

    func testShellEnvironmentVariableExpansion() async throws {
        let result = try await ProcessRunner.shell("echo $HOME")
        XCTAssertTrue(result.succeeded)
        let home = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(home.isEmpty)
        XCTAssertTrue(home.hasPrefix("/"), "HOME should be an absolute path, got: \(home)")
    }

    // MARK: - Environment injection

    func testCustomEnvironmentVariable() async throws {
        let result = try await ProcessRunner.run(
            "/bin/zsh",
            arguments: ["-c", "echo $MY_TEST_VAR"],
            environment: ["MY_TEST_VAR": "charlie"]
        )
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "charlie")
    }

    // MARK: - Invalid executable

    func testInvalidExecutableThrows() async {
        do {
            _ = try await ProcessRunner.run("/nonexistent/binary/lfg_test_xyz")
            XCTFail("Expected an error to be thrown for a nonexistent executable")
        } catch {
            // Expected — Process.run() throws when the executable doesn't exist
            XCTAssertNotNil(error)
        }
    }

    // MARK: - Concurrency: parallel invocations

    func testConcurrentExecutionProducesCorrectResults() async throws {
        // Run 4 echo commands concurrently via a task group; each should return
        // the expected value independently.
        let values = ["alpha", "bravo", "charlie", "delta"]
        let results = try await withThrowingTaskGroup(of: (String, String).self) { group in
            for v in values {
                group.addTask {
                    let r = try await ProcessRunner.run("/bin/echo", arguments: [v])
                    return (v, r.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
            var collected: [(String, String)] = []
            for try await pair in group { collected.append(pair) }
            return collected
        }
        XCTAssertEqual(results.count, 4)
        for (expected, actual) in results {
            XCTAssertEqual(actual, expected)
        }
    }
}
