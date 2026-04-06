import SwiftUI
import Charts

struct WTFSView: View {
    @State private var entries: [ScanEntry] = []
    @State private var scanPath = NSHomeDirectory()
    @State private var isScanning = false
    @State private var totalSize: String = ""
    @State private var duration: String = ""

    private let scanner = DiskMonitorService()

    private var chartEntries: [ScanEntry] {
        Array(entries.prefix(20))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Where's The Free Space?")
                    .font(.title2.bold())
                Spacer()
                if !duration.isEmpty {
                    Text(duration).font(.caption).foregroundStyle(.secondary)
                }
                Button(action: { Task { await scan() } }) {
                    Label("Scan", systemImage: "arrow.clockwise")
                }
                .disabled(isScanning)
            }

            HStack {
                TextField("Scan path", text: $scanPath)
                    .textFieldStyle(.roundedBorder)
                Button("Browse") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    if panel.runModal() == .OK, let url = panel.url { scanPath = url.path }
                }
            }

            if isScanning {
                ProgressView("Scanning \(scanPath)...")
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if entries.isEmpty {
                ContentUnavailableView("No Results", systemImage: "folder.badge.questionmark",
                                       description: Text("Click Scan to analyze disk usage"))
            } else {
                if !chartEntries.isEmpty {
                    GroupBox("Top \(chartEntries.count) by Size") {
                        Chart(chartEntries, id: \.name) { entry in
                            BarMark(x: .value("MB", Double(entry.sizeBytes) / 1_048_576),
                                    y: .value("Name", entry.name))
                            .foregroundStyle(by: .value("Type", entry.isDirectory ? "Dir" : "File"))
                        }
                        .chartForegroundStyleScale(["Dir": Color.blue, "File": Color.orange])
                        .frame(height: CGFloat(chartEntries.count) * 24)
                    }
                }

                if !totalSize.isEmpty {
                    Text("Total: \(totalSize)").font(.headline)
                }

                List(entries) { entry in
                    HStack {
                        Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                            .foregroundStyle(entry.isDirectory ? .blue : .orange)
                            .frame(width: 20)
                        Text(entry.name)
                        Spacer()
                        Text(entry.sizeFormatted)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
        .navigationTitle("WTFS")
    }

    private func scan() async {
        isScanning = true
        defer { isScanning = false }
        do {
            let result = try await scanner.scan(path: URL(fileURLWithPath: scanPath))
            entries = result.entries
            totalSize = ByteCountFormatter.string(fromByteCount: result.totalBytes, countStyle: .file)
            duration = String(format: "%.1fs", result.duration)
        } catch {
            entries = []
        }
    }
}
