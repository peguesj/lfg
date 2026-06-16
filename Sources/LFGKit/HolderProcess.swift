import Foundation

// MARK: - HolderProcess

/// A process that holds one or more open file descriptors inside a watched directory.
///
/// Populated by parsing the output of `lsof +D <path>`. Used by:
/// - `MountOrchestrator.resync` — gate: non-empty holders block autonomous reclaim.
/// - `SymlinkHealthReport.UnavailableVolume` — surfaces holder info in the UI.
/// - `DevDriveHealthService` — notification body lists holder PIDs and paths.
///
/// Usage:
/// ```swift
/// let holders = HolderProcess.parse(lsofOutput: lsofStdout)
/// if holders.isEmpty {
///     // safe to proceed with symlink swap
/// } else {
///     let daemons = holders.filter(\.isLikelyDaemon)
///     // prompt user to quit daemons before reclaim
/// }
/// ```
public struct HolderProcess: Codable, Equatable, Sendable {

    // MARK: Properties

    /// The process ID.
    public let pid: Int32

    /// The process command name (from the `COMMAND` column of `lsof +D`).
    ///
    /// Note: `lsof` truncates command names at 9 characters. For the full executable
    /// path on macOS, a subsequent `proc_pidpath(pid)` call is needed; we store the
    /// truncated command name here since it is sufficient for daemon heuristics.
    public let executablePath: String

    /// Paths inside the watched directory that are held open by this process.
    ///
    /// Each entry corresponds to one line in the `lsof +D` output that references
    /// this PID. Duplicates within a single process are included.
    public let openFds: [String]

    // MARK: Daemon heuristic

    /// Heuristic: `true` when the command name contains known daemon indicators
    /// (e.g. `Rewind`, `backupd`, `mds`, `Dropbox`, `OneDrive`, `Spotlight`).
    ///
    /// The heuristic is conservative — false negatives are acceptable; false positives
    /// would incorrectly block a reclaim that is safe to run.
    public var isLikelyDaemon: Bool {
        let knownDaemons = [
            "Rewind", "backupd", "mds", "Spotlight",
            "Dropbox", "OneDrive", "GoogleDrive",
            "TimeMachineStatus", "nsurlsessiond"
        ]
        return knownDaemons.contains { executablePath.contains($0) }
    }

    // MARK: Init

    public init(pid: Int32, executablePath: String, openFds: [String]) {
        self.pid = pid
        self.executablePath = executablePath
        self.openFds = openFds
    }

    // MARK: Parsing

    /// Parse `lsof +D <path>` stdout into an array of `HolderProcess` values.
    ///
    /// `lsof +D` output format (space-separated, first row is header):
    /// ```
    /// COMMAND   PID  USER   FD   TYPE  DEVICE  SIZE/OFF   NODE  NAME
    /// Rewind  65488  yj    mem   REG    1,5   9437184   1234  /path/to/file
    /// ```
    ///
    /// - Parameter lsofOutput: The raw stdout from `lsof +D <directory>`.
    /// - Returns: Deduplicated array of `HolderProcess` values, one per unique PID,
    ///            sorted ascending by PID.
    public static func parse(lsofOutput: String) -> [HolderProcess] {
        var byPid: [Int32: (command: String, fds: [String])] = [:]

        let lines = lsofOutput.components(separatedBy: .newlines)
        // Drop the header line (first non-empty line starting with "COMMAND").
        let dataLines = lines.dropFirst()

        for line in dataLines {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            // Minimum column count: COMMAND PID USER FD TYPE DEVICE SIZE NODE NAME (9)
            guard parts.count >= 9 else { continue }
            guard let pid = Int32(parts[1]) else { continue }

            let command = String(parts[0])
            // NAME is everything from column index 8 onward (handles spaces in paths).
            let name = parts[8...].joined(separator: " ")

            if byPid[pid] == nil {
                byPid[pid] = (command: command, fds: [])
            }
            byPid[pid]?.fds.append(name)
        }

        return byPid.map { pid, info in
            HolderProcess(
                pid: pid,
                executablePath: info.command,
                openFds: info.fds
            )
        }.sorted { $0.pid < $1.pid }
    }
}
