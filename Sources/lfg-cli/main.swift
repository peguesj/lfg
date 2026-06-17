import ArgumentParser
import Foundation
import LFGKit

@main
struct LFGCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lfg",
        abstract: "LFG - Local File Guardian CLI",
        version: LFGConstants.appVersion,
        subcommands: [Status.self, Scan.self],
        defaultSubcommand: Status.self
    )
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show disk usage summary"
    )

    func run() throws {
        let attrs = try FileManager.default.attributesOfFileSystem(
            forPath: NSHomeDirectory()
        )
        let total = (attrs[.systemSize] as? UInt64) ?? 0
        let free = (attrs[.systemFreeSize] as? UInt64) ?? 0
        let used = total - free
        let pct = total > 0 ? Double(used) / Double(total) * 100 : 0

        print("LFG Disk Status")
        print("  Total: \(SizeFormatter.format(total))")
        print("  Used:  \(SizeFormatter.format(used)) (\(String(format: "%.1f", pct))%)")
        print("  Free:  \(SizeFormatter.format(free))")
    }
}

struct Scan: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Scan for large files in common directories"
    )

    @Option(name: .shortAndLong, help: "Minimum file size to report (e.g. 100MB)")
    var threshold: String = "100MB"

    func run() throws {
        guard let thresholdBytes = SizeFormatter.parse(threshold) else {
            print("Invalid threshold: \(threshold)")
            throw ExitCode.failure
        }

        let dirs = ["Downloads", "Desktop"].map {
            NSString(string: "~/\($0)").expandingTildeInPath
        }
        let fm = FileManager.default
        var found = 0

        for dir in dirs {
            guard let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: dir),
                includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                      values.isDirectory != true,
                      let size = values.fileSize,
                      UInt64(size) >= thresholdBytes else { continue }
                print("  \(SizeFormatter.format(UInt64(size)))  \(url.lastPathComponent)")
                found += 1
            }
        }

        if found == 0 {
            print("No files >= \(threshold) found.")
        } else {
            print("\(found) file(s) found.")
        }
    }
}
