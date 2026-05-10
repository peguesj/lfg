import SwiftUI
import Charts
import LFGKit

// MARK: - PressureMonitorView

/// Live disk pressure monitor with an area chart of free space over time,
/// a gauge for the current internal disk breakdown, and per-volume status rows.
///
/// Refreshes automatically every 30 seconds via a Timer publisher.
struct PressureMonitorView: View {

    // MARK: State

    @State private var snapshots: [PressureSnapshot] = []
    @State private var currentTotal: UInt64 = 0
    @State private var currentFree: UInt64 = 0
    @State private var currentPurgeable: UInt64 = 0
    @State private var volumeRows: [VolumeRow] = []
    @State private var isLoading = false
    @State private var lastRefreshed: Date? = nil

    private let refreshInterval: TimeInterval = 30
    private let maxSnapshots = 60

    // MARK: Derived

    private var usedBytes: UInt64 {
        currentTotal > currentFree ? currentTotal - currentFree : 0
    }

    private var freeFraction: Double {
        guard currentTotal > 0 else { return 0 }
        return Double(currentFree) / Double(currentTotal)
    }

    private var gaugeColor: Color {
        let freeGB = Double(currentFree) / 1_073_741_824
        if freeGB > 20 { return .green }
        if freeGB > 10 { return .yellow }
        return .red
    }

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                gaugeSection
                chartSection
                volumeRowsSection
                footerRow
            }
            .padding()
        }
        .navigationTitle("Pressure Monitor")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await doRefresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
        .task {
            await doRefresh()
            for await _ in AsyncTimerSequence(interval: refreshInterval) {
                await doRefresh()
            }
        }
    }

    // MARK: Gauge Section

    private var gaugeSection: some View {
        GroupBox("Internal Disk") {
            HStack(spacing: 24) {
                Gauge(value: freeFraction) {
                    Image(systemName: "internaldrive.fill")
                } currentValueLabel: {
                    Text(String(format: "%.0f%%", freeFraction * 100))
                        .font(.caption.bold())
                        .foregroundStyle(gaugeColor)
                }
                .gaugeStyle(.accessoryCircular)
                .tint(gaugeColor)
                .scaleEffect(1.4)
                .frame(width: 80, height: 80)

                VStack(alignment: .leading, spacing: 6) {
                    diskRow("Total", bytes: currentTotal, color: .primary)
                    diskRow("Used", bytes: usedBytes, color: .red)
                    diskRow("Purgeable", bytes: currentPurgeable, color: .orange)
                    diskRow("Free", bytes: currentFree, color: gaugeColor)
                }
                Spacer()
            }
            .padding(.vertical, 8)
        }
    }

    private func diskRow(_ label: String, bytes: UInt64, color: Color) -> some View {
        HStack {
            Text(label)
                .font(.callout)
                .frame(width: 80, alignment: .leading)
            Text(SizeFormatter.format(bytes))
                .font(.callout.monospacedDigit())
                .foregroundStyle(color)
        }
    }

    // MARK: Chart Section

    private var chartSection: some View {
        GroupBox("Free Space History (last \(snapshots.count) readings)") {
            if snapshots.count < 2 {
                Text("Collecting data…")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 140)
            } else {
                Chart(snapshots) { snap in
                    AreaMark(
                        x: .value("Time", snap.timestamp),
                        y: .value("Free GB", snap.freeGB)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [gaugeColor.opacity(0.6), gaugeColor.opacity(0.1)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    LineMark(
                        x: .value("Time", snap.timestamp),
                        y: .value("Free GB", snap.freeGB)
                    )
                    .foregroundStyle(gaugeColor)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour().minute())
                    }
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel("\(value.as(Double.self).map { String(format: "%.0f", $0) } ?? "")GB")
                    }
                }
                .frame(height: 140)
                // Alert threshold lines
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        thresholdLine(proxy: proxy, geo: geo, gb: 10, color: .yellow, label: "Warn 10GB")
                        thresholdLine(proxy: proxy, geo: geo, gb: 20, color: .green, label: "OK 20GB")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func thresholdLine(
        proxy: ChartProxy,
        geo: GeometryProxy,
        gb: Double,
        color: Color,
        label: String
    ) -> some View {
        if let yPos = proxy.position(forY: gb) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: yPos))
                path.addLine(to: CGPoint(x: geo.size.width, y: yPos))
            }
            .stroke(color.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
    }

    // MARK: Volume Rows Section

    private var volumeRowsSection: some View {
        GroupBox("DevDrive Volumes") {
            if volumeRows.isEmpty {
                Text("No fleet volumes loaded.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ForEach(volumeRows) { row in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(row.statusColor)
                            .frame(width: 8, height: 8)
                        Text(row.id)
                            .font(.body.weight(.medium))
                            .frame(width: 120, alignment: .leading)
                        Text(row.mountPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Text(row.statusLabel)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(row.statusColor)
                    }
                    .padding(.vertical, 3)
                    if row.id != volumeRows.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    // MARK: Footer

    private var footerRow: some View {
        HStack {
            if isLoading {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Refreshing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let last = lastRefreshed {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                Text("Last refresh: \(last.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("Auto-refresh every \(Int(refreshInterval))s")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Refresh Logic

    @MainActor
    private func doRefresh() async {
        isLoading = true
        defer { isLoading = false }
        await refreshDiskInfo()
        await refreshVolumeRows()
        lastRefreshed = .now
    }

    @MainActor
    private func refreshDiskInfo() async {
        guard
            let attrs = try? FileManager.default.attributesOfFileSystem(
                forPath: NSHomeDirectory()
            )
        else { return }
        currentTotal = (attrs[.systemSize] as? UInt64) ?? 0
        currentFree = (attrs[.systemFreeSize] as? UInt64) ?? 0

        // Purgeable via statfs
        currentPurgeable = await fetchPurgeable()

        let snap = PressureSnapshot(
            timestamp: .now,
            freeGB: Double(currentFree) / 1_073_741_824
        )
        snapshots.append(snap)
        if snapshots.count > maxSnapshots {
            snapshots.removeFirst(snapshots.count - maxSnapshots)
        }
    }

    private func fetchPurgeable() async -> UInt64 {
        do {
            let result = try await ProcessRunner.shell(
                "df -k / | awk 'NR==2{print $4}'"
            )
            // df -k available is roughly "free + purgeable" on macOS; use as proxy
            if let kb = UInt64(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return kb * 1024
            }
        } catch {}
        return 0
    }

    @MainActor
    private func refreshVolumeRows() async {
        let fleetURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("DevDrive/fleet.json")
        guard let registry = try? FleetRegistry(url: fleetURL) else {
            volumeRows = []
            return
        }
        // Check mounted state
        let mounted: Set<String>
        if let result = try? await ProcessRunner.shell(
            "hdiutil info -plist 2>/dev/null | grep -A1 'mount-point' | grep -v 'mount-point' | sed 's/.*<string>\\(.*\\)<\\/string>.*/\\1/'"
        ) {
            mounted = Set(result.stdout.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        } else {
            mounted = []
        }

        volumeRows = registry.allDrives.sorted(by: { $0.id < $1.id }).map { drive in
            let isMounted = mounted.contains(drive.mount)
            return VolumeRow(
                id: drive.id,
                mountPath: drive.mount,
                host: drive.host,
                isMounted: isMounted
            )
        }
    }
}

// MARK: - Supporting Models

struct PressureSnapshot: Identifiable {
    let id = UUID()
    let timestamp: Date
    let freeGB: Double
}

private struct VolumeRow: Identifiable {
    let id: String
    let mountPath: String
    let host: String
    let isMounted: Bool

    var statusLabel: String { isMounted ? "Mounted" : "Detached" }
    var statusColor: Color { isMounted ? .green : .orange }
}

// MARK: - AsyncTimerSequence

/// Simple async sequence that emits on a fixed interval using Task.sleep.
private struct AsyncTimerSequence: AsyncSequence {
    typealias Element = Void
    let interval: TimeInterval

    struct AsyncIterator: AsyncIteratorProtocol {
        let interval: TimeInterval
        mutating func next() async -> Void? {
            guard !Task.isCancelled else { return nil }
            try? await Task.sleep(for: .seconds(interval))
            return Task.isCancelled ? nil : ()
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(interval: interval)
    }
}
