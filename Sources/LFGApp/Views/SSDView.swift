import SwiftUI
import LFGKit  // for ProcessRunner

struct SSDView: View {
    @State private var mdsCPU: Double = 0
    @State private var volumeStatuses: [(path: String, enabled: Bool)] = []
    @State private var isRefreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Slows Sh*t Down").font(.title2.bold())
                Spacer()
                Button(action: { Task { await refresh() } }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }.disabled(isRefreshing)
            }

            if isRefreshing {
                ProgressView("Checking Spotlight...").frame(maxWidth: .infinity)
            } else {
                GroupBox("mds CPU Usage") {
                    HStack(spacing: 24) {
                        Gauge(value: mdsCPU, in: 0...100) { EmptyView() }
                            currentValueLabel: { Text("\(mdsCPU, specifier: "%.1f")%").font(.title2.bold()) }
                            .gaugeStyle(.accessoryCircular)
                            .tint(mdsCPU > 50 ? .red : mdsCPU > 20 ? .orange : .green)
                            .scaleEffect(1.4)
                            .frame(height: 70)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(mdsCPU > 50 ? "Heavy indexing" : mdsCPU > 20 ? "Active" : mdsCPU > 0 ? "Light" : "Idle")
                                .font(.headline)
                            Gauge(value: mdsCPU, in: 0...100) { Text("CPU").font(.caption2) }
                                .gaugeStyle(.accessoryLinear)
                                .tint(mdsCPU > 50 ? .red : mdsCPU > 20 ? .orange : .green)
                        }
                    }.padding(.vertical, 4)
                }

                GroupBox("Volume Index Status") {
                    if volumeStatuses.isEmpty {
                        Text("No volumes detected").foregroundStyle(.secondary)
                    } else {
                        ForEach(volumeStatuses, id: \.path) { vol in
                            HStack {
                                Image(systemName: vol.enabled ? "checkmark.circle.fill" : "xmark.circle")
                                    .foregroundStyle(vol.enabled ? .green : .gray)
                                Text(vol.path).font(.body.monospaced())
                                Spacer()
                                Text(vol.enabled ? "Indexed" : "Excluded").font(.caption)
                            }.padding(.vertical, 2)
                        }
                    }
                }
            }
        }
        .padding()
        .navigationTitle("SSD")
        .task { await refresh() }
    }

    private func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let cpuResult = try await ProcessRunner.shell("ps -Ac -o %cpu,comm | awk '/mds/ {sum += $1} END {print sum+0}'")
            mdsCPU = Double(cpuResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0

            let statusResult = try await ProcessRunner.run("/usr/bin/mdutil", arguments: ["-s", "-a"])
            volumeStatuses = parseVolumes(statusResult.stdout)
        } catch { }
    }

    private func parseVolumes(_ output: String) -> [(path: String, enabled: Bool)] {
        var results: [(String, Bool)] = []
        var currentPath = ""
        for line in output.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasSuffix(":") && t.hasPrefix("/") { currentPath = String(t.dropLast()) }
            else if !currentPath.isEmpty && t.contains("Indexing") {
                results.append((currentPath, t.contains("enabled"))); currentPath = ""
            }
        }
        return results
    }
}
