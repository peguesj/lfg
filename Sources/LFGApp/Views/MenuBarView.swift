import SwiftUI
import LFGKit

/// MenuBar popover providing at-a-glance disk status, per-volume mount indicators,
/// and quick-action buttons for common DevDrive operations.
///
/// CP-114: Extends the volume section with a filter input, source-grouped sections,
/// four-state status dots, and section-level drift badges.
struct MenuBarView: View {
    @Environment(AppState.self) private var appState

    // MARK: Legacy state (preserved for quick-actions reload path)
    @State private var fleetRows: [MenuBarVolumeRow] = []
    @State private var isMountingAll = false
    @State private var isReconciling = false
    @State private var actionMessage: String? = nil

    // MARK: CP-114 state
    /// Filter text that narrows volumes by id or purpose.
    @State private var filterText: String = ""
    /// v3 registry loaded from fleet.json for grouped, rule-aware display.
    @State private var registry: FleetRegistry? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
            Divider()
            diskUsageSection
            Divider()
            moduleStatusSection
            Divider()
            volumeSection
            Divider()
            quickActionsSection
            Divider()
            footerSection
        }
        .padding()
        .frame(width: 300)
        .task {
            appState.updateDiskInfo()
            await loadFleet()
        }
    }

    // MARK: Sections

    private var headerRow: some View {
        HStack {
            Image(systemName: "externaldrive.fill")
                .foregroundStyle(.purple)
            Text("LFG — Local File Guardian")
                .font(.headline)
        }
    }

    private var diskUsageSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Internal Disk")
                    .font(.subheadline.bold())
                Spacer()
                Text(String(format: "%.0f%% used", appState.diskUsagePercent))
                    .font(.caption)
                    .foregroundStyle(appState.diskUsagePercent > 90 ? .red : .secondary)
            }
            ProgressView(value: appState.diskUsagePercent, total: 100)
                .tint(diskTint)
            Text("\(SizeFormatter.format(appState.freeDiskSpace)) free of \(SizeFormatter.format(appState.totalDiskSpace))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var diskTint: Color {
        if appState.diskUsagePercent > 90 { return .red }
        if appState.diskUsagePercent > 80 { return .orange }
        return .blue
    }

    private var moduleStatusSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Modules")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            ForEach(LFGModule.allCases) { module in
                let status = appState.moduleStatuses[module] ?? ModuleStatus()
                HStack {
                    Image(systemName: module.icon)
                        .foregroundStyle(module.color)
                        .frame(width: 18)
                    Text(module.rawValue)
                        .font(.callout)
                    Spacer()
                    moduleStateIndicator(status.state)
                }
            }
        }
    }

    @ViewBuilder
    private func moduleStateIndicator(_ state: ModuleRunState) -> some View {
        switch state {
        case .idle:
            Text("idle")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case .running:
            ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .error:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    // MARK: Volume section (CP-114)

    /// Returns a filtered list of all backends from the registry, sorted by id.
    private var filteredBackends: [VolumeBackend] {
        guard let reg = registry else { return [] }
        let all = reg.allVolumeBackends.sorted { $0.id < $1.id }
        let q = filterText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        let lower = q.lowercased()
        return all.filter { backend in
            backend.id.lowercased().contains(lower)
                || (backend.purpose ?? "").lowercased().contains(lower)
        }
    }

    /// All distinct host names represented in the filtered backends, plus "Internal"
    /// as a catch-all for volumes whose host is not listed in `allSourceVolumes`.
    private var groupedSections: [(header: String, backends: [VolumeBackend])] {
        guard let reg = registry else { return [] }
        let backends = filteredBackends
        let knownHosts = Set(reg.allSourceVolumes.map(\.name))

        // Build ordered host list: known external hosts first (sorted), then Internal.
        var hostOrder: [String] = reg.allSourceVolumes.map(\.name).sorted()
        if !hostOrder.contains("Internal") {
            hostOrder.append("Internal")
        }

        var result: [(header: String, backends: [VolumeBackend])] = []
        for host in hostOrder {
            let group: [VolumeBackend]
            if host == "Internal" {
                group = backends.filter { !knownHosts.contains($0.host) }
            } else {
                group = backends.filter { $0.host == host }
            }
            guard !group.isEmpty else { continue }
            result.append((header: host, backends: group))
        }
        return result
    }

    /// Four-state color for the status dot beside a volume.
    ///
    /// - Gray:   volume mount path does not exist on disk.
    /// - Green:  mounted and every offload rule is healthy.
    /// - Orange: mounted but at least one offload rule has drift.
    private func dotColor(for backend: VolumeBackend) -> Color {
        guard FileManager.default.fileExists(atPath: backend.mount) else {
            return .gray
        }
        let rules = backend.offloadRules
        if rules.isEmpty || rules.allSatisfy(\.isHealthy) {
            return .green
        }
        return .orange
    }

    /// Whether any volume in `backends` has drift (orange dot).
    private func hasDrift(_ backends: [VolumeBackend]) -> Bool {
        backends.contains { dotColor(for: $0) == .orange }
    }

    private var volumeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Filter input
            TextField("Filter volumes...", text: $filterText)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .controlSize(.small)

            if registry == nil {
                // Loading indicator while the registry task hasn't completed yet
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                    Text("Loading volumes…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if groupedSections.isEmpty {
                Text(filterText.isEmpty ? "No volumes registered" : "No volumes match filter")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(groupedSections, id: \.header) { section in
                    sectionView(header: section.header, backends: section.backends)
                }
            }
        }
    }

    @ViewBuilder
    private func sectionView(header: String, backends: [VolumeBackend]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            // Section header row
            HStack(spacing: 4) {
                Text(header)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                if hasDrift(backends) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Spacer()
            }

            // Per-volume rows
            ForEach(backends, id: \.id) { backend in
                HStack(spacing: 6) {
                    Circle()
                        .fill(dotColor(for: backend))
                        .frame(width: 7, height: 7)
                    Text(backend.id)
                        .font(.callout)
                    if let purpose = backend.purpose {
                        Text(purpose)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.bottom, 2)
    }

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let msg = actionMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
            HStack(spacing: 8) {
                Button {
                    Task { await mountAllDevDrives() }
                } label: {
                    Label("Mount All DevDrives", systemImage: "arrow.up.circle")
                        .font(.callout)
                }
                .disabled(isMountingAll || isReconciling)
                .controlSize(.small)

                Spacer()

                Button {
                    Task { await triggerReconcile() }
                } label: {
                    Label("Reconcile", systemImage: "arrow.triangle.2.circlepath")
                        .font(.callout)
                }
                .disabled(isMountingAll || isReconciling)
                .controlSize(.small)
            }
        }
    }

    private var footerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("Open LFG") {
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.plain)
            .font(.callout)

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(.red)
        }
    }

    // MARK: Async Actions

    @MainActor
    private func loadFleet() async {
        let fleetURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("DevDrive/fleet.json")

        // Load v3 registry for grouped, rule-aware display
        registry = try? FleetRegistry(url: fleetURL)

        // Legacy v2 rows (preserved for quick-actions reload path)
        guard let reg = registry else { return }

        let mountedPaths: Set<String>
        if let result = try? await ProcessRunner.shell(
            "hdiutil info -plist 2>/dev/null | grep -A1 'mount-point' | grep string | sed 's/.*<string>\\(.*\\)<\\/string>.*/\\1/'"
        ) {
            mountedPaths = Set(
                result.stdout
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            )
        } else {
            mountedPaths = []
        }

        fleetRows = reg.allDrives.sorted(by: { $0.id < $1.id }).map { drive in
            MenuBarVolumeRow(
                id: drive.id,
                mountPath: drive.mount,
                isMounted: mountedPaths.contains(drive.mount)
            )
        }
    }

    @MainActor
    private func mountAllDevDrives() async {
        isMountingAll = true
        actionMessage = "Mounting all volumes…"
        defer { isMountingAll = false }
        _ = try? await ProcessRunner.shell(
            "~/tools/@yj/lfg/lfg devdrive mount-all 2>&1"
        )
        actionMessage = "Mount complete."
        await loadFleet()
        appState.updateDiskInfo()
    }

    @MainActor
    private func triggerReconcile() async {
        isReconciling = true
        actionMessage = "Reconciling…"
        defer { isReconciling = false }
        _ = try? await ProcessRunner.shell(
            "python3 ~/tools/@yj/lfg/devdrive/daemon.py --once 2>&1"
        )
        actionMessage = "Reconcile complete."
        await loadFleet()
    }
}

// MARK: - MenuBarVolumeRow

private struct MenuBarVolumeRow: Identifiable {
    let id: String
    let mountPath: String
    let isMounted: Bool
}
