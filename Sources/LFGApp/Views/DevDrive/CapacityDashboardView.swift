import SwiftUI
import LFGKit

// MARK: - CapacitySnapshot

/// Live capacity figures for a single `VolumeBackend` mount point.
private struct CapacitySnapshot: Identifiable {
    let id: String          // == backend.id
    let backend: VolumeBackend
    let totalBytes: Int64
    let freeBytes: Int64
    let isMounted: Bool

    var usedBytes: Int64    { max(0, totalBytes - freeBytes) }
    var usageRatio: Double  { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }
    var totalGB: Double     { Double(totalBytes) / 1_073_741_824 }
    var freeGB: Double      { Double(freeBytes) / 1_073_741_824 }
    var usedGB: Double      { Double(usedBytes) / 1_073_741_824 }
}

// MARK: - RebalanceSuggestion

private struct RebalanceSuggestion: Identifiable {
    let id = UUID()
    let overloaded: CapacitySnapshot   // > 80% used
    let targetHost: MountedVolume      // has headroom on same or different host
    let message: String
}

// MARK: - CapacityDashboardView

/// Visual capacity overview for all DevDrive volumes.
///
/// - Stacked bar chart: one row per backend showing used / free / unmounted.
/// - Summary cards: total fleet used, free, and volume count.
/// - Rebalance suggestions: highlights over-full volumes and proposes targets.
struct CapacityDashboardView: View {

    // MARK: State

    @State private var snapshots: [CapacitySnapshot] = []
    @State private var registry: FleetRegistry?
    @State private var isLoading = true
    @State private var showRelocation = false
    @State private var relocationBackend: VolumeBackend?

    // MARK: Body

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Reading capacities…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                dashboardContent
            }
        }
        .navigationTitle("Capacity Dashboard")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { loadSnapshots() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .task { loadSnapshots() }
        .sheet(isPresented: $showRelocation) {
            if let backend = relocationBackend {
                DriveRelocationSheet(backend: backend)
            }
        }
    }

    // MARK: Dashboard content

    private var dashboardContent: some View {
        ScrollView {
            VStack(spacing: 20) {
                summaryCards
                    .padding(.horizontal)

                Divider()

                volumeBars
                    .padding(.horizontal)

                if !suggestions.isEmpty {
                    Divider()
                    suggestionsSection
                        .padding(.horizontal)
                }
            }
            .padding(.vertical, 16)
        }
    }

    // MARK: Summary cards

    private var summaryCards: some View {
        HStack(spacing: 16) {
            summaryCard(
                icon: "externaldrive.fill",
                label: "Volumes",
                value: "\(snapshots.count)",
                color: .blue
            )
            summaryCard(
                icon: "chart.bar.fill",
                label: "Total Used",
                value: String(format: "%.1f GB", totalUsedGB),
                color: .orange
            )
            summaryCard(
                icon: "circle.dashed",
                label: "Total Free",
                value: String(format: "%.1f GB", totalFreeGB),
                color: .green
            )
        }
    }

    private func summaryCard(icon: String, label: String, value: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.title2).foregroundStyle(color)
            Text(value).font(.title3.bold())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Volume bars

    private var volumeBars: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Volume Capacity").font(.headline)
                .padding(.bottom, 4)

            ForEach(snapshots.sorted { $0.usageRatio > $1.usageRatio }) { snap in
                VolumeBarRow(snapshot: snap) {
                    relocationBackend = snap.backend
                    showRelocation = true
                }
            }
        }
    }

    // MARK: Suggestions

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Rebalance Suggestions", systemImage: "arrow.triangle.2.circlepath")
                .font(.headline)

            ForEach(suggestions) { s in
                suggestionCard(s)
            }
        }
    }

    private func suggestionCard(_ s: RebalanceSuggestion) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(s.message).font(.callout)
                Text("Suggested target: \(s.targetHost.name) (\(String(format: "%.0f GB free", s.targetHost.freeGB)))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Relocate…") {
                relocationBackend = s.overloaded.backend
                showRelocation = true
            }
            .controlSize(.small).buttonStyle(.bordered)
        }
        .padding()
        .background(.orange.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Computed

    private var totalUsedGB: Double { snapshots.reduce(0) { $0 + $1.usedGB } }
    private var totalFreeGB: Double { snapshots.reduce(0) { $0 + $1.freeGB } }

    private var suggestions: [RebalanceSuggestion] {
        let allMounted = DiskScanner.scan()
        return snapshots
            .filter { $0.usageRatio > 0.80 && $0.isMounted }
            .compactMap { snap -> RebalanceSuggestion? in
                guard let target = allMounted.first(where: {
                    $0.mountPoint != snap.backend.mount &&
                    $0.freeGB > snap.usedGB + 2 &&
                    $0.usageRatio < 0.7
                }) else { return nil }
                return RebalanceSuggestion(
                    overloaded: snap,
                    targetHost: target,
                    message: "\(snap.id) is \(Int(snap.usageRatio * 100))% full (\(String(format: "%.1f GB used", snap.usedGB)))."
                )
            }
    }

    // MARK: Data loading

    private func loadSnapshots() {
        isLoading = true
        defer { isLoading = false }

        let fleetURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("DevDrive/fleet.json")
        registry = try? FleetRegistry(url: fleetURL)

        snapshots = (registry?.allVolumeBackends ?? []).map { backend in
            let mounted = FileManager.default.fileExists(atPath: backend.mount)
            var total: Int64 = 0
            var free: Int64 = 0
            if mounted,
               let attrs = try? FileManager.default.attributesOfFileSystem(forPath: backend.mount),
               let t = attrs[.systemSize] as? Int64,
               let f = attrs[.systemFreeSize] as? Int64 {
                total = t; free = f
            }
            return CapacitySnapshot(
                id: backend.id,
                backend: backend,
                totalBytes: total,
                freeBytes: free,
                isMounted: mounted
            )
        }
    }
}

// MARK: - VolumeBarRow

private struct VolumeBarRow: View {
    let snapshot: CapacitySnapshot
    let onRelocate: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(snapshot.id)
                .font(.callout.monospacedDigit())
                .frame(width: 100, alignment: .leading)
                .lineLimit(1)

            if snapshot.isMounted && snapshot.totalBytes > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.15))
                        RoundedRectangle(cornerRadius: 4)
                            .fill(barColor)
                            .frame(width: geo.size.width * snapshot.usageRatio)
                    }
                }
                .frame(height: 14)

                Text(String(format: "%.1f/%.1f GB  (%d%%)",
                            snapshot.usedGB, snapshot.totalGB,
                            Int(snapshot.usageRatio * 100)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 160, alignment: .leading)
            } else {
                Text(snapshot.isMounted ? "Mounted — no data" : "Not mounted")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }

            if snapshot.usageRatio > 0.80 {
                Button("Relocate…", action: onRelocate)
                    .controlSize(.mini).buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 2)
    }

    private var barColor: Color {
        switch snapshot.usageRatio {
        case ..<0.7:  .green
        case ..<0.85: .orange
        default:      .red
        }
    }
}
